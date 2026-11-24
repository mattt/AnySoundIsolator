#if MLX
    import Foundation
    import MLX
    import Synchronization

    /// The global actor of the package's MLX work: loading checkpoints and rendering windows.
    ///
    /// A call waits for the GPU, about 0.6 seconds for one window on an M4 Max,
    /// so the work runs on a thread of its own and not on Swift's cooperative pool,
    /// and callers suspend while it runs.
    /// The thread is the same for the life of the process.
    /// MLX keeps a compiled function's trace for each thread that calls it,
    /// and each new thread traces the function again,
    /// so a dispatch queue, whose worker threads come and go, would add traces without a limit.
    /// One actor for every runtime also matches MLX:
    /// the GPU is one device, and MLX schedules every evaluation under one process-wide lock.
    @globalActor actor InworldDevice {
        static let shared = InworldDevice()

        /// The name of the thread that runs the work.
        static let threadName = "AnySoundIsolator.Inworld"

        private let executor = ThreadExecutor(name: threadName)

        nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }
    }

    /// A serial executor that runs its jobs, in order, on one thread that it starts.
    ///
    /// The thread waits on a condition while there are no jobs and never ends,
    /// so the executor must live as long as the process.
    final class ThreadExecutor: SerialExecutor, @unchecked Sendable {
        // The condition guards `jobs`. The thread is set once in the initializer.
        private let condition = NSCondition()
        private var jobs: [UnownedJob] = []
        private var thread: Thread?

        init(name: String) {
            let thread = Thread { [unowned self] in run() }
            thread.name = name
            thread.qualityOfService = .userInitiated
            self.thread = thread
            thread.start()
        }

        func enqueue(_ job: consuming ExecutorJob) {
            let job = UnownedJob(job)
            condition.withLock {
                jobs.append(job)
                condition.signal()
            }
        }

        func checkIsolated() {
            precondition(Thread.current === thread, "The code is not on the executor's thread.")
        }

        private func run() -> Never {
            while true {
                let job = condition.withLock {
                    while jobs.isEmpty { condition.wait() }
                    return jobs.removeFirst()
                }
                job.runSynchronously(on: asUnownedSerialExecutor())
            }
        }
    }

    /// A loaded Inworld checkpoint, which renders one window at a time on the GPU.
    ///
    /// The runtime is isolated to ``InworldDevice``,
    /// so loading and rendering run on its thread, and the streams that share a runtime render in turn.
    @InworldDevice final class InworldRuntime {
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

        /// Creates a runtime from a function that renders one window, for tests.
        init(sampleRate: Int, chunk: Int, overlap: Int, forward: @escaping (MLXArray) -> MLXArray) {
            self.sampleRate = sampleRate
            self.chunk = chunk
            self.overlap = overlap
            self.forward = forward
            BufferCacheLimit.acquire()
        }

        /// Loads a checkpoint from a safetensors file whose metadata holds its configuration.
        ///
        /// - Throws: A ``SoundIsolationError`` when the file is not a checkpoint that the package runs,
        ///   or an MLX error when the file cannot be read.
        convenience init(contentsOf url: URL) throws {
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
            let (chunk, overlap) = configuration.windowSamples
            self.init(
                sampleRate: configuration.sampleRate,
                chunk: chunk,
                overlap: overlap,
                forward: compile(inputs: [], outputs: []) { network($0) }
            )
        }

        // The last owner can be on any thread.
        // An isolated deinitializer releases the compiled function and the weights on the thread of `InworldDevice`,
        // where MLX traced the function, and in turn with the renders of other runtimes.
        isolated deinit {
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
    /// MLX keeps the buffers that a computation frees, up to a limit that is its memory limit by default.
    /// On an M4 Max with 36 GB on 2026-11-20, one minute of audio had a peak memory footprint of 5.5 GB with that default,
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
        /// The runtime of one checkpoint file, while a stream uses it, and the load that callers share.
        private struct Entry {
            weak var runtime: InworldRuntime?
            let load = SharedWork<InworldRuntime>()
        }

        /// A checkpoint file: its location and the identity of the file that is there.
        ///
        /// The identity is part of the key, so that a file which replaces another at the same location,
        /// while a stream still uses the first, gets a runtime of its own.
        private struct Key: Hashable {
            let url: URL
            let identity: InworldAssetStore.FileIdentity?
        }

        /// The table keeps one small entry for each file that the process loaded.
        private nonisolated static let entries = Mutex<[Key: Entry]>([:])

        /// Returns the runtime for a checkpoint file, which the streams that are open at the same time share.
        ///
        /// The runtime stays in memory while an executor uses it.
        /// Its weights use about 260 MB.
        /// Callers that ask for a file that is not loaded share one load,
        /// and they wait for it without a lock.
        /// Cancelling one caller ends its wait; the load stops when no caller waits for it.
        ///
        /// - Parameters:
        ///   - url: The checkpoint file.
        ///   - load: Loads the file. Tests replace it.
        nonisolated static func shared(
            contentsOf url: URL,
            load: @escaping @Sendable (URL) async throws -> InworldRuntime = load(contentsOf:)
        ) async throws -> InworldRuntime {
            let key = key(for: url)
            let work = entries.withLock { entries in
                let entry = entries[key] ?? Entry()
                entries[key] = entry
                return entry.load
            }
            return try await work.value {
                // The work looks at the table itself.
                // A caller that looked before it waited could miss a load that ended in between,
                // and then load a second copy of the weights.
                if let loaded = entries.withLock({ $0[key]?.runtime }) { return loaded }
                // MLX selects the file format by the path extension,
                // which the blob that a cache entry links to does not have.
                let runtime = try await load(url)
                entries.withLock { $0[key]?.runtime = runtime }
                return runtime
            }
        }

        /// Loads a checkpoint file on ``InworldDevice``.
        private nonisolated static func load(contentsOf url: URL) async throws -> InworldRuntime {
            try await InworldRuntime(contentsOf: url)
        }

        /// The number of callers that wait for the load of a file, for tests.
        nonisolated static func loadingCallerCount(contentsOf url: URL) -> Int {
            entries.withLock { $0[key(for: url)]?.load.callerCount ?? 0 }
        }

        private nonisolated static func key(for url: URL) -> Key {
            let file = url.resolvingSymlinksInPath().standardizedFileURL
            return Key(url: file, identity: InworldAssetStore.fileIdentity(file))
        }
    }
#endif
