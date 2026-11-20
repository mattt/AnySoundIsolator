#if MLX
    import AVFoundation
    import AnySoundIsolator
    import Foundation
    import Testing

    /// Tests with Inworld's released checkpoint and golden fixtures, through the package's public API.
    ///
    /// Set `ENABLE_INWORLD_TESTS=1` to run them, as `mise run test:parity` does.
    /// They download the checkpoint (256 MB) unless it is in the Hugging Face cache,
    /// and they read the fixtures that `mise run fetch:fixtures` puts in `Fixtures/`.
    @Suite(.enabled(if: shouldRunInworldTests), .serialized) struct InworldParityTests {
        /// The largest error that Inworld's own parity test accepts.
        static let tolerance: Float = 1e-4

        static let fixtures = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appending(path: "Fixtures")

        /// Returns an isolator whose checkpoint is installed.
        static func isolator() async throws -> SoundIsolator {
            let isolator = SoundIsolator(model: InworldSoundIsolationModel())
            if let request = try await isolator.assetInstallationRequest() {
                try await request.downloadAndInstall()
            }
            #expect(isolator.isAvailable)
            return isolator
        }

        /// Reads a one-dimensional Float32 array from a NumPy file.
        static func expectedArray(_ fixture: String) throws -> [Float] {
            let url = fixtures.appending(path: "\(fixture)/expected.npy")
            let data = try Data(contentsOf: url)
            // Version 1 of the format: a magic string, a version, a header length, a header, then the samples.
            guard data.count > 10, data.prefix(6) == Data([0x93] + Array("NUMPY".utf8)), data[6] == 1 else {
                throw CocoaError(.fileReadCorruptFile)
            }
            let headerLength = Int(data[8]) | Int(data[9]) << 8
            let header = String(decoding: data[10 ..< 10 + headerLength], as: UTF8.self)
            guard header.contains("'<f4'"), header.contains("'fortran_order': False") else {
                throw CocoaError(.fileReadCorruptFile)
            }
            return data.dropFirst(10 + headerLength).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }

        static func level(_ samples: [Float]) -> Float {
            (samples.reduce(0) { $0 + $1 * $1 } / Float(max(samples.count, 1))).squareRoot()
        }

        /// The file path of the public API gives Inworld's reference render.
        @Test(arguments: ["offline_3s", "offline_11s"])
        func fileMatchesTheGoldenFixture(fixture: String) async throws {
            let isolator = try await Self.isolator()
            let expected = try Self.expectedArray(fixture)
            try await withTemporaryDirectory { directory in
                let output = directory.appending(path: "voice.wav")
                let progress = Progress()
                try await isolator.isolate(
                    contentsOf: Self.fixtures.appending(path: "\(fixture)/input.wav"),
                    to: output,
                    progress: progress
                )
                #expect(progress.completedUnitCount == Int64(expected.count))
                let voice = try await TestAudio.read(output)
                #expect(voice.count == 1)
                let error = TestAudio.maximumDifference(voice[0], expected)
                let below = 20 * log10(Self.level(expected) / error)
                print("parity: \(fixture) file: maximum absolute error \(error), \(below) dB below the signal")
                #expect(error <= Self.tolerance)
            }
        }

        /// A stream in pieces of any size, and one buffer, give the frames that the file gives.
        @Test func streamMatchesTheFile() async throws {
            let isolator = try await Self.isolator()
            let input = try await TestAudio.read(Self.fixtures.appending(path: "offline_11s/input.wav"))[0]
            // The fixture, and 25 seconds made from it whose last window is off the hop.
            let clips = ["11 s": input, "25 s": Array((input + input + input).prefix(1_200_003))]
            for (name, samples) in clips.sorted(by: { $0.key < $1.key }) {
                try await withTemporaryDirectory { directory in
                    let source = directory.appending(path: "source.wav")
                    let output = directory.appending(path: "voice.wav")
                    try TestAudio.write([samples], to: source)
                    try await isolator.isolate(contentsOf: source, to: output)
                    let file = try await TestAudio.read(output)[0]
                    #expect(file.count == samples.count)

                    for size in [4_096, 48_000, 123_457] {
                        let buffers = try TestAudio.buffers([samples], size: size)
                        let stream = try await TestAudio.collect(isolator.streamIsolation(of: Buffers(buffers)))
                        let difference = TestAudio.maximumDifference(stream.isolated[0], file)
                        print("parity: \(name) stream in pieces of \(size) against the file: \(difference)")
                        #expect(difference <= 1e-6)
                    }
                    let whole = try await isolator.isolate(try TestAudio.buffer([samples]))
                    let difference = TestAudio.maximumDifference(TestAudio.channels(whole.buffer)[0], file)
                    print("parity: \(name) one buffer against the file: \(difference)")
                    #expect(difference <= 1e-6)
                }
            }
        }

        /// At a sample rate that the isolator converts, a stream is still close to the file.
        @Test func streamMatchesTheFileAtAnotherSampleRate() async throws {
            let isolator = try await Self.isolator()
            // The fixture's samples, read as 44.1 kHz audio; the test compares two renders of the same input.
            let samples = try await TestAudio.read(Self.fixtures.appending(path: "offline_11s/input.wav"))[0]
            try await withTemporaryDirectory { directory in
                let source = directory.appending(path: "source.wav")
                let output = directory.appending(path: "voice.wav")
                try TestAudio.write([samples], to: source, sampleRate: 44_100)
                try await isolator.isolate(contentsOf: source, to: output)
                let file = try await TestAudio.read(output)[0]
                #expect(file.count == samples.count)
                let buffers = try TestAudio.buffers([samples], size: 4_410, sampleRate: 44_100)
                let stream = try await TestAudio.collect(isolator.streamIsolation(of: Buffers(buffers)))
                let difference = TestAudio.maximumDifference(stream.isolated[0], file)
                print("parity: 44.1 kHz stream in pieces of 4410 against the file: \(difference)")
                #expect(difference <= 1e-4)
            }
        }
    }
#endif
