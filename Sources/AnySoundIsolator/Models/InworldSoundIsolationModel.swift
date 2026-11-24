#if MLX
    import Foundation
    import Synchronization

    /// A model that isolates voice with Inworld's Voice Isolator, which runs on the GPU with MLX.
    ///
    /// The type exists when the package is built with the `MLX` trait.
    /// The model is `voice-isolator-v1`, Inworld's offline checkpoint,
    /// in a Swift port whose output matches Inworld's reference renders.
    ///
    /// The model needs one file, `denoiser.safetensors` (256 MB), which isolation never downloads.
    /// Install it first:
    ///
    /// ```swift
    /// let isolator = SoundIsolator(model: InworldSoundIsolationModel())
    /// if let request = try await isolator.assetInstallationRequest() {
    ///     try await request.downloadAndInstall()
    /// }
    /// try await isolator.isolate(contentsOf: recording, to: voice)
    /// ```
    ///
    /// The network takes one channel at 48 kHz.
    /// The isolator resamples other rates,
    /// and ``IsolationOptions/channelPolicy`` applies to input with two or more channels.
    ///
    /// The network works in windows of 8 seconds that overlap by 2 seconds.
    /// The package places the windows as Inworld's offline render does:
    /// every window is a full one, and the last window ends at the end of the audio.
    /// Audio that is shorter than one window is one short window.
    /// A stream gives the same frames as a file with the same audio, and it gives them later:
    /// the first frames after 8 seconds of input, then 6 seconds for each further 6 seconds of input,
    /// and the last frames after the input ends.
    /// The delay is too long for a conversation.
    /// Use this model for recordings.
    ///
    /// The model is slower than ``SystemSoundIsolationModel`` and uses much more memory.
    /// On an Apple M4 Max on 2026-11-20, it isolated about 10 seconds of audio in each second,
    /// and the process had a peak memory footprint of 4.2 to 4.6 GB, whatever the length of the audio.
    /// Streams that are open at the same time share the loaded weights and render their windows in turn.
    /// While a stream is open, the model limits MLX's cache of free GPU buffers to 512 MB,
    /// unless the limit is already lower.
    /// The limit is one setting for the process, so it also applies to other MLX code in the app
    /// during that time. When its last stream ends, the model puts the earlier limit back,
    /// unless the app set another limit in the meantime.
    ///
    /// The first render in a process takes longer than the others,
    /// because Metal compiles the network's GPU kernels or reads them from its cache for the app.
    /// With an empty cache, the first render took about 2.4 seconds longer.
    /// To keep that time away from the user's first recording,
    /// isolate a tenth of a second of silence with ``SoundIsolator/isolate(_:options:)``
    /// after the app starts.
    ///
    /// The trait supports macOS on Apple silicon.
    /// The model compiles for iOS, but it is not run there,
    /// and one window needs more memory than iOS gives to most apps.
    public struct InworldSoundIsolationModel: SoundIsolationModel {
        /// The source of the checkpoint file.
        public enum Assets: Sendable, Hashable {
            /// The pinned checkpoint, which an ``AssetInstallationRequest`` downloads from Hugging Face
            /// into the Hugging Face cache and verifies.
            ///
            /// The cache is `~/.cache/huggingface/hub`, or the directory that
            /// the `HF_HUB_CACHE` or `HF_HOME` environment variable names.
            /// In a sandboxed app, it is `Application Support/AnySoundIsolator/HuggingFace/hub`
            /// in the app's container, which the package excludes from backups.
            case builtIn

            /// A copy of `denoiser.safetensors` that the app supplies.
            ///
            /// The model uses the file as it is, and neither downloads it nor verifies its digest.
            case file(URL)
        }

        /// A reason for which the model is unavailable.
        public enum UnavailableReason: Sendable, Hashable {
            /// The checkpoint file is not installed.
            /// Install it with ``InworldSoundIsolationModel/assetInstallationRequest()``.
            case assetsNotInstalled

            /// An installation of the checkpoint file is running.
            case assetsInstalling

            /// The device is not a Mac or an iOS device with Apple silicon, which MLX needs.
            case unsupportedHardware
        }

        /// The source of the checkpoint file.
        public let assets: Assets

        let checkpoint: InworldCheckpoint
        let store: InworldAssetStore

        /// Creates a model without loading weights, and without file system or network access.
        ///
        /// - Parameter assets: The source of the checkpoint file.
        public init(assets: Assets = .builtIn) {
            self.init(assets: assets, checkpoint: .offline, store: .shared)
        }

        /// Creates a model with a specific checkpoint and store, for tests.
        init(assets: Assets = .builtIn, checkpoint: InworldCheckpoint, store: InworldAssetStore) {
            if case .file(let url) = assets {
                self.assets = .file(url.standardizedFileURL)
            } else {
                self.assets = assets
            }
            self.checkpoint = checkpoint
            self.store = store
        }

        /// The attribution and license of the model, for an app to show.
        public var attribution: String {
            """
            Inworld Voice Isolator (voice-isolator-v1). Copyright 2026 Inworld AI. \
            Licensed under the Apache License, Version 2.0. \
            https://huggingface.co/\(checkpoint.repository)
            """
        }

        /// The number of bytes that the request from ``assetInstallationRequest()`` downloads
        /// when the checkpoint is not in the cache.
        public var assetByteCount: Int64 { checkpoint.size }

        /// The location of the checkpoint file, whether or not the file is there.
        var file: URL {
            switch assets {
            case .builtIn: store.fileURL(for: checkpoint)
            case .file(let url): url
            }
        }

        /// What is wrong with the location of a file that the app supplies.
        private var missingFileDescription: String {
            file.isFileURL
                ? "The Inworld checkpoint is not at \(file.path)."
                : "The location of the Inworld checkpoint, \(file.absoluteString), is not a file URL."
        }

        /// Whether the device can run the model and the checkpoint file is installed.
        ///
        /// The check uses no network and computes no digest.
        /// It reads the record of the verification, a file of less than 1 KB, and the attributes of the checkpoint file.
        /// One read took about 0.07 milliseconds on an Apple M4 Max on 2026-11-24,
        /// so the property is synchronous, as the availability of the other models is.
        ///
        /// A location for ``Assets/file(_:)`` that is not a file URL reads as not installed.
        public var availability: Availability<UnavailableReason> {
            #if arch(arm64)
                switch assets {
                case .builtIn:
                    if store.isInstalling(checkpoint) { return .unavailable(.assetsInstalling) }
                    return store.status(of: checkpoint) == .installed ? .available : .unavailable(.assetsNotInstalled)
                case .file(let url):
                    // MLX loads from a file URL only, and it stops the program for another URL.
                    return url.isFileURL && InworldAssetStore.fileIdentity(url) != nil
                        ? .available : .unavailable(.assetsNotInstalled)
                }
            #else
                return .unavailable(.unsupportedHardware)
            #endif
        }

        /// Returns a request for the checkpoint file (256 MB), or `nil` when the file is installed.
        ///
        /// This method downloads nothing.
        /// The request's ``AssetInstallationRequest/downloadAndInstall()`` downloads the file and verifies it.
        /// A file that is already in the Hugging Face cache is verified and not downloaded again.
        /// Requests that run at the same time share one download.
        ///
        /// - Throws: ``SoundIsolationError/unavailableModel(_:)`` when the device cannot run the model,
        ///   or ``SoundIsolationError/missingAssets(_:)`` when the file that the app supplies is absent.
        public func assetInstallationRequest() async throws -> AssetInstallationRequest? {
            switch availability {
            case .available:
                return nil
            case .unavailable(.unsupportedHardware):
                throw SoundIsolationError.unavailableModel("The Inworld model needs Apple silicon.")
            case .unavailable(.assetsNotInstalled), .unavailable(.assetsInstalling):
                break
            }
            guard case .builtIn = assets else {
                throw SoundIsolationError.missingAssets(missingFileDescription)
            }
            let checkpoint = checkpoint
            let store = store
            // The request owns its progress object, which follows the shared installation.
            let mirror = MirroredProgress(following: store.progress(for: checkpoint))
            return AssetInstallationRequest(progress: mirror.progress) {
                try await store.install(checkpoint)
                withExtendedLifetime(mirror) {}
            }
        }

        /// Makes an executor that takes one channel at 48 kHz.
        ///
        /// The method loads the weights, which takes about 0.1 seconds, unless an open stream has them.
        /// It never downloads.
        ///
        /// - Parameter request: The sound to isolate and the format of the input.
        /// - Throws: ``SoundIsolationError/missingAssets(_:)`` when the checkpoint file is not installed,
        ///   ``SoundIsolationError/unavailableModel(_:)`` when the device cannot run the model,
        ///   or ``SoundIsolationError/unsupportedConfiguration(_:)`` when the model does not isolate the sound
        ///   or the file is not the offline checkpoint.
        public func makeExecutor(for request: SoundIsolationRequest) async throws -> any SoundIsolationExecutor {
            // The isolator checks the sound before it asks; a direct caller may not.
            guard supportedSounds.contains(request.sound) else {
                throw SoundIsolationError.unsupportedConfiguration(
                    "The model cannot isolate the sound \"\(request.sound.rawValue)\"."
                )
            }
            switch availability {
            case .available:
                break
            case .unavailable(.unsupportedHardware):
                throw SoundIsolationError.unavailableModel("The Inworld model needs Apple silicon.")
            case .unavailable(.assetsNotInstalled), .unavailable(.assetsInstalling):
                throw SoundIsolationError.missingAssets(
                    assets == .builtIn
                        ? "The Inworld checkpoint is not installed. Install it with assetInstallationRequest()."
                        : missingFileDescription
                )
            }
            return InworldSoundIsolationExecutor(runtime: try await InworldRuntime.shared(contentsOf: file))
        }
    }

    /// Runs the windows of one stream through a loaded checkpoint.
    ///
    /// A call suspends while the runtime renders a window, and an actor lets another call start then.
    /// The executor makes a call wait until the call in progress returns,
    /// so overlapping calls run one at a time, and no window is rendered twice.
    /// Calls that wait start in the order in which they reached the executor.
    ///
    /// A call that throws leaves the executor as it was before the call,
    /// so the caller can give the same input again.
    /// A call that is cancelled while it waits leaves the queue and throws `CancellationError`.
    /// A call that is cancelled between two windows discards the windows that it rendered and throws.
    actor InworldSoundIsolationExecutor: SoundIsolationExecutor {
        nonisolated let sampleRate: Double
        nonisolated let channelCount = 1
        /// The output is on the input's timeline; the windows delay its delivery, not its position.
        nonisolated let latency = 0
        private let runtime: InworldRuntime
        private var assembler: InworldWindowAssembler
        /// The queue of calls, which admits one call at a time.
        nonisolated let admission = Admission()

        init(runtime: InworldRuntime) {
            self.runtime = runtime
            sampleRate = Double(runtime.sampleRate)
            assembler = InworldWindowAssembler(chunk: runtime.chunk, overlap: runtime.overlap)
        }

        /// Collects the input and renders each window that is complete.
        func process(_ input: AudioSamples) async throws -> AudioSamples {
            guard input.channelCount == 1 else {
                throw SoundIsolationError.invalidAudio(
                    "The Inworld executor takes one channel, and the input has \(input.channelCount)."
                )
            }
            let samples = input.channels[0]
            guard samples.allSatisfy(\.isFinite) else {
                throw SoundIsolationError.invalidAudio("The audio contains NaN or infinite samples.")
            }
            try await admission.enter()
            defer { admission.leave() }
            // The assembler is a value, so a copy is the state to return to.
            let before = assembler
            do {
                try Task.checkCancellation()
                assembler.append(samples)
                var ready: [Float] = []
                while let window = assembler.nextWindow() {
                    try Task.checkCancellation()
                    ready += assembler.accept(await runtime.render(window))
                }
                return AudioSamples(channels: [ready])
            } catch {
                assembler = before
                throw error
            }
        }

        /// Renders the window that ends at the end of the stream.
        func finish() async throws -> AudioSamples {
            try await admission.enter()
            defer { admission.leave() }
            try Task.checkCancellation()
            var voice: [Float]?
            if let window = assembler.lastWindow() {
                voice = await runtime.render(window)
            }
            let ready = assembler.finish(voice)
            await runtime.releaseBuffers()
            return AudioSamples(channels: [ready])
        }

        /// A queue that admits one call at a time, in the order in which the calls arrive.
        ///
        /// A mutex guards the queue, so that a cancellation handler can remove a call from it
        /// without the actor.
        /// Each continuation leaves the queue under the mutex, so it has one owner,
        /// and it is resumed after the mutex is released.
        final class Admission: Sendable {
            private typealias Waiter = CheckedContinuation<Void, any Error>

            private struct State {
                var isBusy = false
                var waiting: [(id: UUID, waiter: Waiter)] = []
            }

            private let state = Mutex(State())

            /// The number of calls that wait for the call in progress.
            var waitingCount: Int { state.withLock { $0.waiting.count } }

            /// Waits until the calls that arrived earlier have left.
            ///
            /// - Throws: `CancellationError` when the task is cancelled before the call is admitted.
            func enter() async throws {
                let id = UUID()
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (waiter: Waiter) in
                        let admitted: Result<Void, any Error>? = state.withLock { state in
                            // The handler sets the flag before it runs,
                            // so a call that it did not find in the queue sees the flag.
                            if Task.isCancelled { return .failure(CancellationError()) }
                            guard state.isBusy else {
                                state.isBusy = true
                                return .success(())
                            }
                            state.waiting.append((id, waiter))
                            return nil
                        }
                        if let admitted { waiter.resume(with: admitted) }
                    }
                } onCancel: {
                    let waiter = state.withLock { state -> Waiter? in
                        guard let index = state.waiting.firstIndex(where: { $0.id == id }) else { return nil }
                        return state.waiting.remove(at: index).waiter
                    }
                    waiter?.resume(throwing: CancellationError())
                }
            }

            /// Admits the next call, or marks the queue as free.
            func leave() {
                let next = state.withLock { state -> Waiter? in
                    guard !state.waiting.isEmpty else {
                        state.isBusy = false
                        return nil
                    }
                    return state.waiting.removeFirst().waiter
                }
                next?.resume()
            }
        }
    }
#endif
