import AVFoundation
import AnySoundIsolator
import Foundation
import Testing

/// The code of the README's examples, so that a change to the API that breaks one fails the build.
/// This file imports the package as a client does, without `@testable`.
enum ReadmeExamples {
    static func isolateFile(recording: URL, voice: URL) async throws {
        let isolator = SoundIsolator()
        try await isolator.isolate(contentsOf: recording, to: voice)
    }

    static func isolateFileWithProgress(recording: URL, voice: URL, background: URL) async throws {
        let isolator = SoundIsolator()
        let progress = Progress()
        try await isolator.isolate(
            contentsOf: recording,
            to: voice,
            background: background,
            progress: progress
        )
    }

    static func streamFile(recording: URL, player: AVAudioPlayerNode) async throws {
        let isolator = SoundIsolator()
        for try await audio in isolator.streamIsolation(contentsOf: recording) {
            await player.scheduleBuffer(audio.buffer)
        }
    }

    static func streamLiveAudio(engine: AVAudioEngine, player: AVAudioPlayerNode) async throws {
        let isolator = SoundIsolator()
        let (buffers, input) = AsyncStream<AudioInput>.makeStream()
        engine.inputNode.installTap(onBus: 0, bufferSize: 4_096, format: nil) { buffer, _ in
            input.yield(AudioInput(buffer: buffer))
        }
        try engine.start()

        for try await audio in isolator.streamIsolation(of: buffers) {
            await player.scheduleBuffer(audio.buffer)
        }
    }

    static func mix(audio: IsolatedAudio) {
        let background = audio.background()
        let mostlyVoice = audio.mixed(backgroundLevel: 0.25)
        _ = (background, mostlyVoice)
    }

    static func chooseModel() async throws {
        let isolator = SoundIsolator(model: SystemSoundIsolationModel(quality: .standard))
        guard isolator.isAvailable else { return }
        if let request = try await isolator.assetInstallationRequest() {
            try await request.downloadAndInstall()
        }
    }
}

/// The README's example of a custom model.
struct HalfVolumeModel: SoundIsolationModel {
    var availability: Availability<Never> { .available }

    func makeExecutor(for request: SoundIsolationRequest) async throws -> any SoundIsolationExecutor {
        HalfVolumeExecutor(sampleRate: request.sampleRate, channelCount: request.channelCount)
    }
}

struct HalfVolumeExecutor: SoundIsolationExecutor {
    let sampleRate: Double
    let channelCount: Int
    let latency = 0

    func process(_ input: AudioSamples) async throws -> AudioSamples {
        AudioSamples(channels: input.channels.map { channel in channel.map { $0 * 0.5 } })
    }

    func finish() async throws -> AudioSamples {
        AudioSamples(channelCount: channelCount)
    }
}

@Suite struct ReadmeExampleTests {
    @Test func customModelRuns() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let samples = try #require(buffer.floatChannelData)[0]
        for index in 0 ..< 4 { samples[index] = Float(index) }

        let audio = try await SoundIsolator(model: HalfVolumeModel()).isolate(buffer)
        let isolated = try #require(audio.buffer.floatChannelData)[0]
        #expect((0 ..< 4).map { isolated[$0] } == [0, 0.5, 1, 1.5])
    }
}
