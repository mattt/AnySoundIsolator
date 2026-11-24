// This file is adapted from Inworld Voice Isolator (https://github.com/inworld-ai/voice-isolator),
// Copyright 2026 Inworld AI, licensed under the Apache License, Version 2.0.
// It adapts the entry `voice-isolator-v1` in `src/inworld/voice_isolation/registry.py`.
// This file was changed from the original:
// only the repository, revision, file name, size, and SHA-256 digest are copied;
// the code that downloads and verifies the file is new.
// See the NOTICE file.

#if MLX
    import CryptoKit
    import Foundation
    import HuggingFace
    import Synchronization

    /// A checkpoint file on Hugging Face, pinned to a revision, a size, and a SHA-256 digest.
    struct InworldCheckpoint: Sendable, Hashable, Codable {
        /// The Hugging Face repository, as an owner and a name.
        var repository: String
        /// The commit that pins the file.
        var revision: String
        /// The path of the file in the repository.
        var path: String
        /// The size of the file in bytes.
        var size: Int64
        /// The lowercase hexadecimal SHA-256 digest of the file.
        var sha256: String

        /// `voice-isolator-v1`, the offline checkpoint, with 8-second windows that overlap by 2 seconds.
        ///
        /// The values are those that `registry.py` in Inworld's package records.
        static let offline = InworldCheckpoint(
            repository: "inworld/voice-isolator",
            revision: "9b0285b3fe8403aa8e2f1dbb2165a80a4294c970",
            path: "denoiser.safetensors",
            size: 256_260_128,
            sha256: "647335a6aeb4dc706b895532c209d51e0e84a4849d17b339f00d4392a050ae53"
        )
    }

    /// Locates, checks, and installs a checkpoint in the Hugging Face cache.
    ///
    /// The store follows AnySpeechRecognizer's `ModelAssetStore`.
    /// swift-huggingface downloads the file at the pinned revision into the cache,
    /// at `<cache>/models--<owner>--<name>/snapshots/<revision>/<path>`, and the runtime loads it in place.
    ///
    /// After the file matches its size and its SHA-256 digest,
    /// the store writes a verification marker in its own directory.
    /// The marker records the identity of the file that was hashed:
    /// its device, file number, size, and times of modification and of status change.
    /// A status check then compares the file with the marker and computes no digest,
    /// so it is fast enough to run before each stream.
    /// A file that was replaced or edited in place has another identity,
    /// reads as not installed, and is hashed again by the next installation.
    /// Callers that install the same checkpoint at the same time share one download.
    final class InworldAssetStore: Sendable {
        /// The local state of a checkpoint.
        enum Status: Sendable, Hashable {
            /// The file is present and recorded as verified.
            case installed
            /// The file is absent, has the wrong size, or is not verified.
            case missing
        }

        /// The record that an installation writes after the file passes verification.
        struct VerificationMarker: Sendable, Hashable, Codable {
            var checkpoint: InworldCheckpoint
            /// The location of the verified file.
            var file: String
            /// The identity of the file that was hashed,
            /// so that a file that is replaced or edited in place reads as unverified.
            var identity: FileIdentity
        }

        /// What the file system records about one state of a file's contents.
        ///
        /// A write to the file changes its times, and a new file has another number.
        /// The time of status change cannot be set back, as the time of modification can.
        struct FileIdentity: Sendable, Hashable, Codable {
            var device: Int64
            var number: UInt64
            var size: Int64
            /// The time of the last modification, in nanoseconds.
            var modified: Int64
            /// The time of the last status change, in nanoseconds.
            var changed: Int64

            init(_ info: stat) {
                device = Int64(info.st_dev)
                number = UInt64(info.st_ino)
                size = Int64(info.st_size)
                modified = Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec)
                changed = Int64(info.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(info.st_ctimespec.tv_nsec)
            }
        }

        private final class Installation: Sendable {
            let work = SharedWork<URL>()
            let progress: Progress
            init(byteCount: Int64) { progress = Progress(totalUnitCount: byteCount) }
        }

        /// The store that every model uses, so that every caller in a process shares downloads.
        static let shared = InworldAssetStore()

        /// Returns the cache directory for model files.
        ///
        /// `HF_HUB_CACHE` and `HF_HOME` keep their usual meaning.
        /// A Mac app outside the sandbox shares `~/.cache/huggingface/hub` with other tools.
        /// A sandboxed app, which includes every iOS app, uses
        /// `Application Support/AnySoundIsolator/HuggingFace/hub` in its container,
        /// because the system can purge `Library/Caches` when storage is low.
        /// The store excludes that directory from backups when it installs a file.
        static func defaultCacheDirectory(
            environment: [String: String] = ProcessInfo.processInfo.environment,
            applicationSupport: URL = .applicationSupportDirectory,
            home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        ) -> URL {
            if let hubCache = environment["HF_HUB_CACHE"] {
                return URL(fileURLWithPath: NSString(string: hubCache).expandingTildeInPath)
            }
            if let hfHome = environment["HF_HOME"] {
                return URL(fileURLWithPath: NSString(string: hfHome).expandingTildeInPath).appending(path: "hub")
            }
            #if os(macOS)
                if environment["APP_SANDBOX_CONTAINER_ID"] == nil {
                    return home.appending(path: ".cache/huggingface/hub", directoryHint: .isDirectory)
                }
            #endif
            return packageCacheDirectory(applicationSupport: applicationSupport)
        }

        /// The cache directory that the package owns, for sandboxed apps.
        static func packageCacheDirectory(applicationSupport: URL = .applicationSupportDirectory) -> URL {
            applicationSupport.appending(path: "AnySoundIsolator/HuggingFace/hub", directoryHint: .isDirectory)
        }

        /// `Application Support/AnySoundIsolator/Verified`, in the app's container when the app is sandboxed.
        static var defaultMarkerDirectory: URL {
            URL.applicationSupportDirectory.appending(path: "AnySoundIsolator/Verified", directoryHint: .isDirectory)
        }

        let cache: HubCache
        let markerDirectory: URL
        private let client: HubClient
        private let installations = Mutex<[String: Installation]>([:])
        /// Runs verification, which blocks its thread.
        let files = BlockingFileWork(label: "AnySoundIsolator.InworldAssetStore")

        /// Creates a store without file system or network access.
        ///
        /// The client sends no access token, because the checkpoint is public.
        ///
        /// - Parameters:
        ///   - cacheDirectory: The Hugging Face cache that holds model files.
        ///   - markerDirectory: The directory for verification markers.
        ///   - session: The session for downloads. Tests add `URLProtocol` stubs.
        ///   - host: The Hub server.
        init(
            cacheDirectory: URL = defaultCacheDirectory(),
            markerDirectory: URL = defaultMarkerDirectory,
            session: URLSession = URLSession(configuration: .default),
            host: URL = HubClient.defaultHost
        ) {
            let cache = HubCache(cacheDirectory: cacheDirectory)
            self.cache = cache
            self.markerDirectory = markerDirectory.standardizedFileURL
            client = HubClient(session: session, host: host, tokenProvider: .none, cache: cache)
        }

        /// The location of a checkpoint's file in the cache, whether or not the file is there.
        func fileURL(for checkpoint: InworldCheckpoint) -> URL {
            cache.snapshotsDirectory(repo: Self.repo(checkpoint), kind: .model)
                .appending(path: checkpoint.revision, directoryHint: .isDirectory)
                .appending(path: checkpoint.path)
        }

        /// The verification marker of a checkpoint in this store's cache.
        ///
        /// The name includes a digest of the checkpoint and of the file's location,
        /// so different checkpoints, and caches in different directories, never share a marker.
        func markerURL(for checkpoint: InworldCheckpoint) -> URL {
            let subject =
                "\(checkpoint.repository)\n\(checkpoint.revision)\n\(checkpoint.path)\n"
                + "\(checkpoint.size)\n\(checkpoint.sha256)\n\(fileURL(for: checkpoint).standardizedFileURL.path)"
            let digest = SHA256.hash(data: Data(subject.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
            let name = checkpoint.repository.replacing("/", with: "--")
            return markerDirectory.appending(path: "\(name)--\(checkpoint.revision)--\(digest).json")
        }

        /// Checks the verification marker against the file's size and identity,
        /// without network access and without computing a digest.
        func status(of checkpoint: InworldCheckpoint) -> Status {
            let file = fileURL(for: checkpoint)
            guard let data = try? Data(contentsOf: markerURL(for: checkpoint)),
                let marker = try? JSONDecoder().decode(VerificationMarker.self, from: data),
                marker.checkpoint == checkpoint, marker.file == file.standardizedFileURL.path,
                let identity = Self.fileIdentity(file), identity.size == checkpoint.size, identity == marker.identity
            else { return .missing }
            return .installed
        }

        /// Whether an installation of the checkpoint is running in this store.
        func isInstalling(_ checkpoint: InworldCheckpoint) -> Bool {
            installations.withLock { $0[key(for: checkpoint)]?.work.isRunning == true }
        }

        /// The byte progress of the checkpoint's current or most recent installation.
        func progress(for checkpoint: InworldCheckpoint) -> Progress {
            installation(for: checkpoint).progress
        }

        /// Downloads the file unless it is in the cache, verifies it, and records it as verified.
        ///
        /// A checkpoint that is already installed returns without network access or digest computation.
        /// A file that another tool put in the cache is verified and not downloaded again.
        /// A file that fails verification is removed, so that a later installation downloads it again.
        ///
        /// - Returns: The location of the file in the cache.
        /// - Throws: ``SoundIsolationError/assetVerificationFailed(_:)``, a download error,
        ///   a file system error, or `CancellationError`.
        @discardableResult
        func install(_ checkpoint: InworldCheckpoint) async throws -> URL {
            let installation = installation(for: checkpoint)
            return try await installation.work.value { [self] in
                let file = fileURL(for: checkpoint)
                let progress = installation.progress
                if status(of: checkpoint) == .installed {
                    progress.completedUnitCount = checkpoint.size
                    return file
                }
                excludePackageCacheFromBackup()
                let marker = markerURL(for: checkpoint)
                try? FileManager.default.removeItem(at: marker)
                progress.completedUnitCount = 0
                do {
                    // A file in the cache at the pinned revision returns without a request.
                    _ = try await client.downloadFile(
                        at: checkpoint.path,
                        from: Self.repo(checkpoint),
                        revision: checkpoint.revision,
                        progress: progress
                    )
                } catch let error as URLError where error.code == .cancelled && Task.isCancelled {
                    throw CancellationError()
                }
                try Task.checkCancellation()
                try await verifyAndRecord(checkpoint)
                progress.completedUnitCount = checkpoint.size
                return file
            }
        }

        /// Verifies the file in the cache and writes its verification marker,
        /// on the store's file queue.
        ///
        /// The digest reads the whole file, which takes about 90 ms on an M4 Max when the file is in memory,
        /// so it runs on a dispatch queue and not on the caller's actor or Swift's cooperative pool.
        /// It runs in the caller's task and checks for cancellation before each block.
        ///
        /// - Throws: ``SoundIsolationError/assetVerificationFailed(_:)``, a file system error,
        ///   or `CancellationError`.
        func verifyAndRecord(_ checkpoint: InworldCheckpoint) async throws {
            try await files.run { [self] in
                // Verify the pinned location, not the returned one,
                // so that a response for another commit cannot satisfy the checkpoint.
                let identity = try verify(checkpoint)
                try FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)
                let record = VerificationMarker(
                    checkpoint: checkpoint,
                    file: fileURL(for: checkpoint).standardizedFileURL.path,
                    identity: identity
                )
                try JSONEncoder().encode(record).write(to: markerURL(for: checkpoint), options: .atomic)
            }
        }

        /// Checks the size and the SHA-256 digest of the file in the cache,
        /// and removes the file when either is wrong.
        ///
        /// The identity comes from the open file that is hashed, before and after the digest,
        /// and the location must still name that file afterward.
        /// A file that changes during the check is not recorded as verified.
        ///
        /// - Returns: The identity of the file that was hashed.
        private func verify(_ checkpoint: InworldCheckpoint) throws -> FileIdentity {
            let file = fileURL(for: checkpoint)
            func reject(_ reason: String) -> SoundIsolationError {
                discard(file, of: checkpoint)
                return .assetVerificationFailed("The model file \(checkpoint.path) failed verification: \(reason)")
            }
            guard Self.fileIdentity(file) != nil, let reader = try? FileHandle(forReadingFrom: file),
                let identity = Self.fileIdentity(descriptor: reader.fileDescriptor)
            else {
                throw SoundIsolationError.assetVerificationFailed(
                    "The model file \(checkpoint.path) is not in the cache at the pinned revision."
                )
            }
            defer { try? reader.close() }
            guard identity.size == checkpoint.size else {
                throw reject("expected \(checkpoint.size) bytes, received \(identity.size) bytes.")
            }
            let digest = try Self.sha256(of: reader)
            guard Self.fileIdentity(descriptor: reader.fileDescriptor) == identity,
                Self.fileIdentity(file) == identity
            else {
                throw SoundIsolationError.assetVerificationFailed(
                    "The model file \(checkpoint.path) changed while it was verified."
                )
            }
            guard digest == checkpoint.sha256 else {
                throw reject("expected SHA-256 \(checkpoint.sha256), received \(digest).")
            }
            return identity
        }

        /// Removes the file's entry in the snapshot and the blob that it links to.
        private func discard(_ file: URL, of checkpoint: InworldCheckpoint) {
            let target = file.resolvingSymlinksInPath()
            let blobs = cache.blobsDirectory(repo: Self.repo(checkpoint), kind: .model).resolvingSymlinksInPath()
            if target.deletingLastPathComponent().path == blobs.path {
                try? FileManager.default.removeItem(at: target)
            }
            try? FileManager.default.removeItem(at: file)
        }

        /// Keeps the files in the package's own cache out of device backups.
        /// The store leaves a shared cache, which other tools manage, as it is.
        private func excludePackageCacheFromBackup() {
            var directory = Self.packageCacheDirectory()
            guard cache.cacheDirectory.standardizedFileURL == directory.standardizedFileURL else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try? directory.setResourceValues(values)
        }

        private func key(for checkpoint: InworldCheckpoint) -> String {
            markerURL(for: checkpoint).path
        }

        private func installation(for checkpoint: InworldCheckpoint) -> Installation {
            installations.withLock { installations in
                let key = key(for: checkpoint)
                if let existing = installations[key] { return existing }
                let created = Installation(byteCount: checkpoint.size)
                installations[key] = created
                return created
            }
        }

        private static func repo(_ checkpoint: InworldCheckpoint) -> Repo.ID {
            Repo.ID(rawValue: checkpoint.repository) ?? Repo.ID(namespace: "", name: checkpoint.repository)
        }

        /// The identity of the regular file at a location, following symbolic links.
        static func fileIdentity(_ url: URL) -> FileIdentity? {
            var info = stat()
            guard stat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            return FileIdentity(info)
        }

        /// The identity of an open regular file.
        static func fileIdentity(descriptor: Int32) -> FileIdentity? {
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { return nil }
            return FileIdentity(info)
        }

        /// The lowercase hexadecimal SHA-256 digest of a file's contents.
        static func sha256(of url: URL) throws -> String {
            let reader = try FileHandle(forReadingFrom: url)
            defer { try? reader.close() }
            return try sha256(of: reader)
        }

        /// The lowercase hexadecimal SHA-256 digest of an open file, from its current position to its end.
        static func sha256(of reader: FileHandle) throws -> String {
            var hasher = SHA256()
            // Each read returns an autoreleased buffer.
            // A pool for each block keeps the memory of the whole file from staying resident.
            while try autoreleasepool(invoking: {
                try Task.checkCancellation()
                guard let block = try reader.read(upToCount: 1 << 20), !block.isEmpty else { return false }
                hasher.update(data: block)
                return true
            }) {}
            return hasher.finalize().map { String(format: "%02x", $0) }.joined()
        }
    }

    /// Runs file work that blocks its thread on a serial dispatch queue.
    ///
    /// The actor's executor is the queue, so the work holds neither the caller's actor
    /// nor a thread of Swift's cooperative pool.
    /// The work runs in the caller's task, so it sees the task's cancellation,
    /// and no continuation is left waiting when the task is cancelled.
    actor BlockingFileWork {
        /// The queue that runs the work. Tests suspend it.
        nonisolated let queue: DispatchSerialQueue

        nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

        init(label: String) {
            queue = DispatchSerialQueue(label: label)
        }

        func run<T: Sendable>(_ work: @Sendable () throws -> T) throws -> T {
            try work()
        }
    }

    /// A progress object for one caller that follows the progress of a shared installation.
    ///
    /// Each caller has its own object because a `Progress` can have only one parent,
    /// and a caller can add an installation's progress to its own.
    final class MirroredProgress: Sendable {
        let progress: Progress
        private let observation: Mutex<NSKeyValueObservation?>

        init(following source: Progress) {
            let progress = Progress(totalUnitCount: source.totalUnitCount)
            self.progress = progress
            // The first call is at registration, so no change falls between a read of the count and the observation.
            observation = Mutex(
                source.observe(\.completedUnitCount, options: [.initial]) { source, _ in
                    progress.completedUnitCount = source.completedUnitCount
                }
            )
        }

        deinit {
            observation.withLock { $0?.invalidate() }
        }
    }
#endif
