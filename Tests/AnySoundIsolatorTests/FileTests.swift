import AVFoundation
import Foundation
import Testing

@testable import AnySoundIsolator

/// Tests of file input and output. Each test writes its own files from signals made in code.
@Suite struct FileTests {
    /// `AVAudioFile` can return fewer frames from one read than the caller asked for,
    /// so these lengths are not multiples of its internal block.
    @Test(arguments: [1, 47_700, 48_000, 48_300, 70_000])
    func fileReaderReturnsEveryFrame(count: Int) async throws {
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "audio.wav")
        let samples = (0 ..< count).map { Float($0 % 100) / 100 }
        try TestAudio.write([samples], to: url)

        #expect(try await TestAudio.read(url) == [samples])
    }

    @Test(arguments: ["wav", "caf"])
    func fileOutputMatchesTheContract(type: String) async throws {
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.wav")
        let voice = directory.appending(path: "voice.\(type)")
        let background = directory.appending(path: "background.\(type)")
        let input = [TestAudio.voice(seconds: 2.5, seed: 1), TestAudio.voice(seconds: 2.5, seed: 2)]
        try TestAudio.write(input, to: source)

        let isolator = SoundIsolator(model: StandInModel(gain: 0.25, latency: 999, blockSize: 5_000))
        let progress = Progress()
        try await isolator.isolate(contentsOf: source, to: voice, background: background, progress: progress)

        let isolated = try await TestAudio.read(voice)
        let removed = try await TestAudio.read(background)
        #expect(isolated == input.map { channel in channel.map { $0 * 0.25 } })
        for channel in 0 ..< 2 {
            let sum = zip(isolated[channel], removed[channel]).map { $0 + $1 }
            #expect(TestAudio.maximumDifference(sum, input[channel]) < 1e-6)
        }
        #expect(progress.totalUnitCount == 120_000)
        #expect(progress.completedUnitCount == 120_000)
    }

    @Test func systemModelIsolatesAFile() async throws {
        try #require(SystemSoundIsolationModel().isAvailable)
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.wav")
        let voice = directory.appending(path: "voice.wav")
        let background = directory.appending(path: "background.wav")
        let input = TestAudio.voice(seconds: 4, sampleRate: 16_000)
        try TestAudio.write([input], to: source, sampleRate: 16_000)

        let isolator = SoundIsolator()
        try await isolator.isolate(contentsOf: source, to: voice, background: background)

        let isolated = try await TestAudio.read(voice)[0]
        let removed = try await TestAudio.read(background)[0]
        #expect(isolated.count == input.count)
        #expect(abs(Alignment.lag(of: isolated, behind: input, maximumLag: 800)) <= 1)
        #expect(TestAudio.maximumDifference(zip(isolated, removed).map { $0 + $1 }, input) < 1e-6)

        // A file and a buffer of the same audio give the same samples.
        let whole = try await isolator.isolate(try TestAudio.buffer([input], sampleRate: 16_000))
        #expect(isolated == TestAudio.channels(whole.buffer)[0])
        let format = try AVAudioFile(forReading: voice).fileFormat
        #expect(format.sampleRate == 16_000)
        #expect(format.channelCount == 1)
    }

    @Test func compressedOutputHasTheInputLength() async throws {
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.wav")
        let voice = directory.appending(path: "voice.m4a")
        let input = TestAudio.voice(seconds: 2)
        try TestAudio.write([input], to: source)

        try await SoundIsolator(model: StandInModel(gain: 1)).isolate(contentsOf: source, to: voice)

        let decoded = try await TestAudio.read(voice)[0]
        #expect(decoded.count == input.count)
        #expect(Alignment.lag(of: decoded, behind: input, maximumLag: 4_000) == 0)
    }

    @Test func compressedInputIsRead() async throws {
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.m4a")
        let voice = directory.appending(path: "voice.wav")
        let input = TestAudio.voice(seconds: 2, sampleRate: 44_100)
        try TestAudio.write([input, input], to: source, sampleRate: 44_100)
        let decoded = try await TestAudio.read(source)

        try await SoundIsolator(model: StandInModel(gain: 1)).isolate(contentsOf: source, to: voice)

        #expect(try await TestAudio.read(voice) == decoded)
    }

    @Test func failureLeavesNoOutputFile() async throws {
        let directory = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "source.wav")
        try TestAudio.write([TestAudio.voice(seconds: 0.5)], to: source)
        let isolator = SoundIsolator(model: StandInModel(), isolating: .init(rawValue: "music"))

        let voice = directory.appending(path: "voice.wav")
        let background = directory.appending(path: "background.wav")
        await #expect(throws: SoundIsolationError.self) {
            try await isolator.isolate(contentsOf: source, to: voice, background: background)
        }
        #expect(!FileManager.default.fileExists(atPath: voice.path))
        #expect(!FileManager.default.fileExists(atPath: background.path))

        // An output type that the isolator cannot write is an error before any work.
        await #expect {
            try await SoundIsolator(model: StandInModel())
                .isolate(contentsOf: source, to: directory.appending(path: "voice.mp3"))
        } throws: { error in
            guard case SoundIsolationError.unsupportedConfiguration = error else { return false }
            return true
        }
        await #expect {
            try await SoundIsolator(model: StandInModel())
                .isolate(contentsOf: directory.appending(path: "missing.wav"), to: voice)
        } throws: { error in
            guard case SoundIsolationError.invalidAudio = error else { return false }
            return true
        }
    }
}
