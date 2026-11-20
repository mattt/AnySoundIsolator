import AVFoundation
import Foundation
import Testing

@testable import AnySoundIsolator

/// Tests of what the isolator promises for every engine, with a stand-in engine
/// that returns half of its input.
@Suite struct ContractTests {
    let input = TestAudio.voice(seconds: 1.5)

    /// The latency of the stand-in engine and the size of the blocks that it returns.
    static let engines = [(latency: 0, blockSize: 1), (0, 1_000), (777, 1), (777, 1_000)]

    @Test(arguments: engines, [100, 4_800, 100_000])
    func outputMatchesInputFrameForFrame(engine: (latency: Int, blockSize: Int), bufferSize: Int) async throws {
        let isolator = SoundIsolator(model: StandInModel(latency: engine.latency, blockSize: engine.blockSize))
        let buffers = try TestAudio.buffers([input], size: bufferSize)
        let result = try await TestAudio.collect(isolator.streamIsolation(of: Buffers(buffers)))

        // The latency is gone, and no frame is missing or extra.
        #expect(result.isolated == [input.map { $0 * 0.5 }])
        #expect(result.source == [input])
    }

    @Test(arguments: [-300, 300])
    func outputHasTheInputLengthWhenTheEngineDoesNot(extraFrames: Int) async throws {
        let isolator = SoundIsolator(model: StandInModel(latency: 123, extraFrames: extraFrames))
        let audio = try await isolator.isolate(try TestAudio.buffer([input]))
        let isolated = TestAudio.channels(audio.buffer)[0]

        #expect(isolated.count == input.count)
        let kept = input.count - max(0, -extraFrames)
        #expect(Array(isolated[..<kept]) == input[..<kept].map { $0 * 0.5 })
        #expect(isolated[kept...].allSatisfy { $0 == 0 })
    }

    @Test(arguments: [16_000.0, 44_100.0, 96_000.0])
    func engineAtAnotherSampleRateStaysOnTheTimeline(sampleRate: Double) async throws {
        let input = TestAudio.voice(seconds: 2, sampleRate: sampleRate)
        let isolator = SoundIsolator(
            model: StandInModel(sampleRate: 48_000, gain: 1, latency: 480, blockSize: 4_096)
        )
        let buffers = try TestAudio.buffers([input], size: 4_000, sampleRate: sampleRate)
        let result = try await TestAudio.collect(isolator.streamIsolation(of: Buffers(buffers)))
        let isolated = result.isolated[0]

        #expect(isolated.count == input.count)
        #expect(Alignment.lag(of: isolated, behind: input, maximumLag: 500) == 0)
        // The test signal has nothing above 4 kHz, so it survives two sample rate conversions.
        let middle = 2_000 ..< input.count - 2_000
        let difference = zip(isolated[middle], input[middle]).map { $0 - $1 }
        #expect(TestAudio.level(difference) < 0.05 * TestAudio.level(Array(input[middle])))
    }

    @Test func oneChannelEngineProcessesEachChannelWhenAsked() async throws {
        let channels = (1 ... 3).map { TestAudio.voice(seconds: 0.5, seed: UInt64($0)) }
        let executors = Counter()
        let isolator = SoundIsolator(model: StandInModel(latency: 50, executors: executors))
        let audio = try await isolator.isolate(
            try TestAudio.buffer(channels),
            options: IsolationOptions(channelPolicy: .perChannel)
        )

        #expect(audio.buffer.format.channelCount == 3)
        #expect(TestAudio.channels(audio.buffer) == channels.map { channel in channel.map { $0 * 0.5 } })
        #expect(await executors.value == 3)
    }

    @Test(arguments: [2, 3])
    func oneChannelEngineGetsADownmixByDefault(channelCount: Int) async throws {
        let channels = (1 ... channelCount).map { TestAudio.voice(seconds: 0.5, seed: UInt64($0)) }
        let executors = Counter()
        let isolator = SoundIsolator(model: StandInModel(gain: 0.5, latency: 50, blockSize: 700, executors: executors))
        #expect(IsolationOptions().channelPolicy == .downmix)
        let result = try await TestAudio.collect(
            isolator.streamIsolation(of: Buffers(try TestAudio.buffers(channels, size: 1_000)))
        )

        // The engine ran once, on the average of the channels.
        #expect(await executors.value == 1)
        let scale = 1 / Float(channelCount)
        let average = channels[0].indices.map { index in
            channels.reduce(Float(0)) { $0 + $1[index] } * scale
        }
        // The output has the input's channels, each with the one result, and the source is unchanged.
        #expect(result.isolated == Array(repeating: average.map { $0 * 0.5 }, count: channelCount))
        #expect(result.source == channels)
    }

    @Test func backgroundAfterADownmixKeepsEachChannel() async throws {
        let channels = (1 ... 2).map { TestAudio.voice(seconds: 0.5, seed: UInt64($0)) }
        let audio = try await SoundIsolator(model: StandInModel(gain: 1)).isolate(try TestAudio.buffer(channels))
        let isolated = TestAudio.channels(audio.buffer)
        let background = TestAudio.channels(audio.background())
        let restored = TestAudio.channels(audio.mixed(backgroundLevel: 1))

        #expect(isolated[0] == isolated[1])
        for channel in 0 ..< 2 {
            // In each channel, the isolated sound and the background add up to the source.
            let sum = zip(isolated[channel], background[channel]).map { $0 + $1 }
            #expect(TestAudio.maximumDifference(sum, channels[channel]) < 1e-6)
            #expect(TestAudio.maximumDifference(restored[channel], channels[channel]) < 1e-6)
        }
        // An engine that returns its input removes nothing from the average,
        // so the background is what differs between the channels: half of left minus right.
        let side = zip(channels[0], channels[1]).map { ($0 - $1) / 2 }
        #expect(TestAudio.maximumDifference(background[0], side) < 1e-6)
        #expect(TestAudio.maximumDifference(background[1], side.map { -$0 }) < 1e-6)
    }

    @Test func downmixAtAnotherSampleRateStaysOnTheTimeline() async throws {
        let channels = (1 ... 2).map { TestAudio.voice(seconds: 2, sampleRate: 16_000, seed: UInt64($0)) }
        let isolator = SoundIsolator(model: StandInModel(sampleRate: 48_000, gain: 1, latency: 480))
        let audio = try await isolator.isolate(try TestAudio.buffer(channels, sampleRate: 16_000))
        let isolated = TestAudio.channels(audio.buffer)
        let average = zip(channels[0], channels[1]).map { ($0 + $1) / 2 }

        #expect(isolated[0].count == average.count)
        #expect(isolated[0] == isolated[1])
        #expect(Alignment.lag(of: isolated[0], behind: average, maximumLag: 500) == 0)
    }

    @Test func engineThatTakesEveryChannelGetsOneExecutor() async throws {
        let channels = (1 ... 2).map { TestAudio.voice(seconds: 0.5, seed: UInt64($0)) }
        // The channel policy does not apply to an engine that takes all of the channels.
        for policy in IsolationOptions.ChannelPolicy.allCases {
            let executors = Counter()
            let isolator = SoundIsolator(model: StandInModel(channelCount: nil, executors: executors))
            let audio = try await isolator.isolate(
                try TestAudio.buffer(channels),
                options: IsolationOptions(channelPolicy: policy)
            )

            #expect(TestAudio.channels(audio.buffer) == channels.map { channel in channel.map { $0 * 0.5 } })
            #expect(await executors.value == 1)
        }
    }

    @Test func backgroundAndMixComeFromTheSource() async throws {
        let isolator = SoundIsolator(model: StandInModel(gain: 0.25, latency: 10))
        let audio = try await isolator.isolate(try TestAudio.buffer([input]))
        let isolated = TestAudio.channels(audio.buffer)[0]
        let background = TestAudio.channels(audio.background())[0]

        // The isolated sound and the background add up to the input.
        let sum = zip(isolated, background).map { $0 + $1 }
        #expect(TestAudio.maximumDifference(sum, input) < 1e-6)
        #expect(TestAudio.maximumDifference(background, input.map { $0 * 0.75 }) < 1e-6)

        #expect(TestAudio.channels(audio.mixed(backgroundLevel: 0))[0] == isolated)
        #expect(TestAudio.maximumDifference(TestAudio.channels(audio.mixed(backgroundLevel: 1))[0], input) < 1e-6)
        let half = TestAudio.channels(audio.mixed(backgroundLevel: 0.5))[0]
        #expect(TestAudio.maximumDifference(half, input.map { $0 * 0.625 }) < 1e-6)

        #expect(audio.framePosition == 0)
        #expect(audio.timeRange.duration.seconds == 1.5)
    }

    @Test func sixteenBitInterleavedInputIsConverted() async throws {
        let format = try #require(
            AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 2, interleaved: true)
        )
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4))
        buffer.frameLength = 4
        let samples = try #require(buffer.int16ChannelData)[0]
        for (index, value) in [16_384, -16_384, 8_192, -8_192, 0, 0, 32_767, -32_768].enumerated() {
            samples[index] = Int16(value)
        }
        let audio = try await SoundIsolator(model: StandInModel(channelCount: nil, gain: 1)).isolate(buffer)

        #expect(audio.buffer.format.sampleRate == 16_000)
        #expect(audio.buffer.format.commonFormat == .pcmFormatFloat32)
        let channels = TestAudio.channels(audio.buffer)
        #expect(TestAudio.maximumDifference(channels[0], [0.5, 0.25, 0, 1]) < 1e-4)
        #expect(TestAudio.maximumDifference(channels[1], [-0.5, -0.25, 0, -1]) < 1e-4)
    }

    @Test func inputCopiesABufferThatTheCallerReuses() async throws {
        let shared = try TestAudio.buffer([Array(repeating: 0, count: 100)])
        let data = try #require(shared.floatChannelData)[0]
        var block = 0
        let source = Buffers {
            guard block < 5 else { return nil }
            block += 1
            for index in 0 ..< 100 { data[index] = Float(block) }
            return shared
        }
        let isolator = SoundIsolator(model: StandInModel(gain: 1, latency: 30, blockSize: 250))
        let result = try await TestAudio.collect(isolator.streamIsolation(of: source))

        #expect(result.isolated[0] == (1 ... 5).flatMap { Array(repeating: Float($0), count: 100) })
    }

    @Test func emptyInputGivesNoOutput() async throws {
        let isolator = SoundIsolator(model: StandInModel())
        let result = try await TestAudio.collect(isolator.streamIsolation(of: Buffers([])))
        #expect(result.pieces == 0)

        let audio = try await isolator.isolate(try TestAudio.buffer([[]]))
        #expect(audio.buffer.frameLength == 0)
    }

    @Test func unsupportedSoundIsAnError() async throws {
        let isolator = SoundIsolator(model: StandInModel(), isolating: .init(rawValue: "music"))
        await #expect {
            _ = try await isolator.isolate(try TestAudio.buffer([input]))
        } throws: { error in
            guard case SoundIsolationError.unsupportedConfiguration = error else { return false }
            return true
        }
    }

    @Test func engineErrorKeepsItsCause() async throws {
        struct EngineFailure: Error {}
        let isolator = SoundIsolator(model: StandInModel(failure: EngineFailure()))
        await #expect {
            _ = try await isolator.isolate(try TestAudio.buffer([input]))
        } throws: { error in
            guard case SoundIsolationError.backendFailure(let underlying) = error else { return false }
            return underlying is EngineFailure
        }

        let missing = SoundIsolator(model: StandInModel(failure: SoundIsolationError.missingAssets("None.")))
        await #expect {
            _ = try await missing.isolate(try TestAudio.buffer([input]))
        } throws: { error in
            guard case SoundIsolationError.missingAssets = error else { return false }
            return true
        }
    }

    @Test func sourceErrorIsRethrownUnchanged() async throws {
        struct SourceFailure: Error {}
        let first = try TestAudio.buffer([input])
        var sent = false
        let source = Buffers {
            if sent { throw SourceFailure() }
            sent = true
            return first
        }
        let isolator = SoundIsolator(model: StandInModel())
        await #expect(throws: SourceFailure.self) {
            _ = try await TestAudio.collect(isolator.streamIsolation(of: source))
        }
    }

    @Test func formatChangeDuringAStreamIsAnError() async throws {
        let buffers = [
            try TestAudio.buffer([input]),
            try TestAudio.buffer([input], sampleRate: 44_100),
        ]
        let isolator = SoundIsolator(model: StandInModel())
        await #expect {
            _ = try await TestAudio.collect(isolator.streamIsolation(of: Buffers(buffers)))
        } throws: { error in
            guard case SoundIsolationError.invalidAudio = error else { return false }
            return true
        }
    }

    @Test func cancellationStopsAStream() async throws {
        let isolator = SoundIsolator(model: StandInModel())
        let input = input
        let task = Task {
            let buffer = try TestAudio.buffer([input])
            let source = Buffers { buffer }
            var frames = 0
            for try await audio in isolator.streamIsolation(of: source) {
                frames += Int(audio.buffer.frameLength)
                if frames > 200_000 { withUnsafeCurrentTask { $0?.cancel() } }
            }
            return frames
        }
        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
    }

    @Test func assetRequestRunsOnlyWhenAsked() async throws {
        let count = Counter()
        let request = AssetInstallationRequest(progress: Progress(totalUnitCount: 1)) {
            await count.increment()
        }
        #expect(await count.value == 0)
        try await request.downloadAndInstall()
        #expect(await count.value == 1)
        #expect(try await SoundIsolator(model: StandInModel()).assetInstallationRequest() == nil)
    }
}

actor Counter {
    var value = 0
    func increment() { value += 1 }
}
