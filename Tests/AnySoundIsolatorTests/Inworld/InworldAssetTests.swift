#if MLX
    import Foundation
    import Testing

    @testable import AnySoundIsolator

    /// Tests of the checkpoint's installation with a stub server, which use no network.
    @Suite struct InworldAssetTests {
        let data = InworldFixture.bytes(70_000)

        @Test func installationDownloadsVerifiesAndRecordsTheFile() async throws {
            try await withTemporaryDirectory { root in
                let server = StubModelServer(files: [InworldFixture.path: data])
                let store = server.makeStore(root: root)
                let checkpoint = InworldFixture.checkpoint(for: data)
                let model = InworldSoundIsolationModel(checkpoint: checkpoint, store: store)

                #expect(model.availability == .unavailable(.assetsNotInstalled))
                #expect(!model.isAvailable)
                let request = try #require(try await model.assetInstallationRequest())
                #expect(request.progress.totalUnitCount == Int64(data.count))
                // A request does not download until the caller asks.
                #expect(server.requests.isEmpty)

                try await request.downloadAndInstall()
                #expect(server.downloadCount(of: InworldFixture.path) == 1)
                #expect(request.progress.completedUnitCount == Int64(data.count))
                #expect(try Data(contentsOf: store.fileURL(for: checkpoint)) == data)
                #expect(store.status(of: checkpoint) == .installed)
                #expect(model.availability == .available)
                #expect(try await model.assetInstallationRequest() == nil)

                // A second installation uses the marker: no request and no digest.
                let requests = server.requests.count
                try await store.install(checkpoint)
                #expect(server.requests.count == requests)
            }
        }

        @Test func fileWithAWrongDigestIsRefusedAndRemoved() async throws {
            try await withTemporaryDirectory { root in
                var corrupt = data
                corrupt[100] ^= 0xFF
                let server = StubModelServer(files: [InworldFixture.path: corrupt])
                let store = server.makeStore(root: root)
                let checkpoint = InworldFixture.checkpoint(for: data)
                let model = InworldSoundIsolationModel(checkpoint: checkpoint, store: store)
                let request = try #require(try await model.assetInstallationRequest())

                await #expect {
                    try await request.downloadAndInstall()
                } throws: { error in
                    guard case SoundIsolationError.assetVerificationFailed(let message) = error else { return false }
                    return message.contains(InworldFixture.path)
                }
                #expect(model.availability == .unavailable(.assetsNotInstalled))
                #expect(!FileManager.default.fileExists(atPath: store.fileURL(for: checkpoint).path))

                // After the server has the right file, a new installation downloads it.
                server.setFile(InworldFixture.path, data)
                try await store.install(checkpoint)
                #expect(model.availability == .available)
            }
        }

        @Test func fileThatAnotherToolCachedIsVerifiedWithoutADownload() async throws {
            try await withTemporaryDirectory { root in
                let server = StubModelServer(files: [InworldFixture.path: data])
                let checkpoint = InworldFixture.checkpoint(for: data)
                // One store downloads, as another tool would. A store with other markers sees an unverified file.
                try await server.makeStore(root: root).install(checkpoint)
                let other = StubModelServer(files: [:])
                let store = InworldAssetStore(
                    cacheDirectory: root.appending(path: "hub"),
                    markerDirectory: root.appending(path: "other-markers"),
                    host: URL(string: "https://\(other.host)")!
                )
                #expect(store.status(of: checkpoint) == .missing)
                try await store.install(checkpoint)
                #expect(store.status(of: checkpoint) == .installed)
                #expect(other.requests.isEmpty)
            }
        }

        @Test func replacedFileReadsAsNotInstalled() async throws {
            try await withTemporaryDirectory { root in
                let server = StubModelServer(files: [InworldFixture.path: data])
                let store = server.makeStore(root: root)
                let checkpoint = InworldFixture.checkpoint(for: data)
                try await store.install(checkpoint)
                let file = store.fileURL(for: checkpoint).resolvingSymlinksInPath()
                var other = data
                other[0] ^= 0xFF
                try FileManager.default.removeItem(at: file)
                try other.write(to: file)
                #expect(store.status(of: checkpoint) == .missing)
            }
        }

        @Test func concurrentRequestsShareOneDownload() async throws {
            try await withTemporaryDirectory { root in
                let server = StubModelServer(files: [InworldFixture.path: data])
                let checkpoint = InworldFixture.checkpoint(for: data)
                let model = InworldSoundIsolationModel(checkpoint: checkpoint, store: server.makeStore(root: root))
                let first = try #require(try await model.assetInstallationRequest())
                let second = try #require(try await model.assetInstallationRequest())
                async let one: Void = first.downloadAndInstall()
                async let two: Void = second.downloadAndInstall()
                _ = try await (one, two)
                #expect(server.downloadCount(of: InworldFixture.path) == 1)
                #expect(first.progress.completedUnitCount == Int64(data.count))
                #expect(second.progress.completedUnitCount == Int64(data.count))
            }
        }

        @Test func isolationNeverDownloads() async throws {
            try await withTemporaryDirectory { root in
                let server = StubModelServer(files: [InworldFixture.path: data])
                let checkpoint = InworldFixture.checkpoint(for: data)
                let model = InworldSoundIsolationModel(checkpoint: checkpoint, store: server.makeStore(root: root))
                let isolator = SoundIsolator(model: model)
                let buffer = try TestAudio.buffer([TestAudio.voice(seconds: 0.5)])
                await #expect {
                    _ = try await isolator.isolate(buffer)
                } throws: { error in
                    if case SoundIsolationError.missingAssets = error { return true }
                    return false
                }
                #expect(server.requests.isEmpty)
            }
        }

        @Test func suppliedFileThatIsAbsentIsMissing() async throws {
            let url = URL(fileURLWithPath: "/nonexistent/denoiser.safetensors")
            let model = InworldSoundIsolationModel(assets: .file(url))
            #expect(model.availability == .unavailable(.assetsNotInstalled))
            await #expect {
                _ = try await model.assetInstallationRequest()
            } throws: { error in
                if case SoundIsolationError.missingAssets = error { return true }
                return false
            }
            let request = SoundIsolationRequest(sound: .voice, sampleRate: 48_000, channelCount: 1)
            await #expect {
                _ = try await model.makeExecutor(for: request)
            } throws: { error in
                if case SoundIsolationError.missingAssets = error { return true }
                return false
            }
        }

        @Test func builtInCheckpointIsTheReleasedOfflineFile() {
            let model = InworldSoundIsolationModel()
            #expect(model.assets == .builtIn)
            #expect(model.assetByteCount == 256_260_128)
            #expect(model.checkpoint.repository == "inworld/voice-isolator")
            #expect(model.checkpoint.path == "denoiser.safetensors")
            #expect(model.checkpoint.revision.count == 40)
            #expect(model.checkpoint.sha256 == "647335a6aeb4dc706b895532c209d51e0e84a4849d17b339f00d4392a050ae53")
            #expect(model.supportedSounds == [.voice])
        }

        // MARK: - Cache location

        @Test func cacheFollowsTheHuggingFaceEnvironment() {
            let support = URL(fileURLWithPath: "/support")
            let home = URL(fileURLWithPath: "/home/user")
            func directory(_ environment: [String: String]) -> String {
                InworldAssetStore.defaultCacheDirectory(
                    environment: environment,
                    applicationSupport: support,
                    home: home
                ).standardizedFileURL.path
            }
            #expect(directory(["HF_HUB_CACHE": "/cache/hub", "HF_HOME": "/hf"]) == "/cache/hub")
            #expect(directory(["HF_HOME": "/hf"]) == "/hf/hub")
            #if os(macOS)
                #expect(directory([:]) == "/home/user/.cache/huggingface/hub")
            #endif
            // A sandboxed app keeps the file in its container's Application Support directory.
            #expect(
                directory(["APP_SANDBOX_CONTAINER_ID": "com.example.app"])
                    == "/support/AnySoundIsolator/HuggingFace/hub"
            )
        }
    }
#endif
