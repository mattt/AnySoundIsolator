#if MLX
    import Foundation
    import MLX
    import Synchronization

    /// A loaded Inworld checkpoint, which renders one window at a time on the GPU.
    ///
    /// The runtime is an actor, so the streams that share it render their windows in turn.
    actor InworldRuntime {
        /// The sample rate of the audio that the network reads and writes, in hertz.
        nonisolated let sampleRate: Int
        /// The number of samples in a window.
        nonisolated let chunk: Int
        /// The number of samples in the crossfade between two windows.
        nonisolated let overlap: Int

        /// The network, compiled by MLX.
        /// MLX fuses chains of elementwise operations into Metal kernels that it builds at run time,
        /// which made a window about 30 percent faster in the port's measurements.
        private let forward: (MLXArray) -> MLXArray

        /// Loads a checkpoint from a safetensors file whose metadata holds its configuration.
        ///
        /// - Throws: A ``SoundIsolationError`` when the file is not a checkpoint that the package runs,
        ///   or an MLX error when the file cannot be read.
        init(contentsOf url: URL) throws {
            let (arrays, metadata) = try loadArraysAndMetadata(url: url)
            guard let json = metadata["config"] else {
                throw SoundIsolationError.unsupportedConfiguration(
                    "\(url.lastPathComponent) is not an Inworld checkpoint: its metadata has no configuration."
                )
            }
            let configuration: InworldConfiguration
            do {
                configuration = try JSONDecoder().decode(InworldConfiguration.self, from: Data(json.utf8))
            } catch {
                throw SoundIsolationError.unsupportedConfiguration(
                    "The configuration in \(url.lastPathComponent) cannot be read: \(error.localizedDescription)"
                )
            }
            let network = try Device.withDefaultDevice(.gpu) {
                let network = try InworldNetwork(configuration: configuration, weights: arrays)
                eval(Array(arrays.values))
                return network
            }
            sampleRate = configuration.sampleRate
            (chunk, overlap) = configuration.windowSamples
            forward = compile(inputs: [], outputs: []) { network($0) }
            BufferCacheLimit.acquire()
        }

        deinit {
            BufferCacheLimit.release()
        }

        /// Returns the isolated voice of mono samples at ``sampleRate``, with the same length.
        ///
        /// - Parameter samples: One window, or a whole clip that is shorter than a window.
        func render(_ samples: [Float]) -> [Float] {
            Device.withDefaultDevice(.gpu) {
                forward(MLXArray(samples, [1, samples.count])).asArray(Float.self)
            }
        }

        /// Returns to the system the GPU buffers that MLX keeps for reuse.
        func releaseBuffers() {
            Memory.clearCache()
        }
    }

    /// Limits MLX's cache of free GPU buffers while a runtime is loaded.
    ///
    /// MLX keeps the buffers that a computation frees, without a limit by default.
    /// On an M4 Max on 2026-11-20, one minute of audio had a peak memory footprint of 5.5 GB without a limit,
    /// 4.3 GB and 3 percent more time with a limit of 512 MB, and 2.5 GB and 35 percent more time with no cache.
    /// The limit is one setting for the process, so the package lowers it only while a runtime is loaded,
    /// and then puts back the limit that it found.
    private enum BufferCacheLimit {
        static let byteCount = 512 << 20

        private struct State {
            var users = 0
            var previous: Int?
        }

        private static let state = Mutex(State())

        static func acquire() {
            state.withLock { state in
                state.users += 1
                guard state.users == 1 else { return }
                let current = Memory.cacheLimit
                if current > byteCount {
                    state.previous = current
                    Memory.cacheLimit = byteCount
                }
            }
        }

        static func release() {
            state.withLock { state in
                state.users -= 1
                guard state.users == 0 else { return }
                // Leave a limit that the app set in the meantime as it is.
                if let previous = state.previous, Memory.cacheLimit == byteCount {
                    Memory.cacheLimit = previous
                }
                state.previous = nil
                Memory.clearCache()
            }
        }
    }

    extension InworldRuntime {
        private struct Weak {
            weak var runtime: InworldRuntime?
        }

        private static let loaded = Mutex<[URL: Weak]>([:])

        /// Returns the runtime for a checkpoint file, which the streams that are open at the same time share.
        ///
        /// The runtime stays in memory while an executor uses it.
        /// Its weights use about 260 MB.
        static func shared(contentsOf url: URL) throws -> InworldRuntime {
            let key = url.resolvingSymlinksInPath().standardizedFileURL
            return try loaded.withLock { loaded in
                if let runtime = loaded[key]?.runtime { return runtime }
                // MLX selects the file format by the path extension,
                // which the blob that a cache entry links to does not have.
                let runtime = try InworldRuntime(contentsOf: url)
                loaded[key] = Weak(runtime: runtime)
                return runtime
            }
        }
    }
#endif
