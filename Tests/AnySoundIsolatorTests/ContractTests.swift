import AVFoundation
import CoreMedia
import Foundation
import Synchronization
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

    /// A change to the caller's buffer after it is wrapped, and before the stream reads the input,
    /// does not reach the stream.
    @Test func inputKeepsItsAudioWhenTheBufferChangesLater() async throws {
        let original = TestAudio.voice(seconds: 0.1)
        let shared = try TestAudio.buffer([original])
        let input = AudioInput(buffer: shared)
        let data = try #require(shared.floatChannelData)[0]
        for index in 0 ..< Int(shared.frameLength) { data[index] = 9 }
        shared.frameLength = 1

        #expect(TestAudio.channels(input.buffer) == [original])
        let (stream, continuation) = AsyncStream<AudioInput>.makeStream()
        continuation.yield(input)
        continuation.finish()
        let isolator = SoundIsolator(model: StandInModel(gain: 1))
        let result = try await TestAudio.collect(isolator.streamIsolation(of: stream))
        #expect(result.isolated == [original])
        #expect(result.source == [original])
    }

    /// A result that a caller makes holds copies, so the caller can reuse its buffers.
    @Test func resultCopiesTheBuffersOfItsInitializer() async throws {
        let isolated: [Float] = [0.5, 0.25, -0.5]
        let original: [Float] = [1, 0.5, -1]
        let buffer = try TestAudio.buffer([isolated])
        let source = try TestAudio.buffer([original])
        let audio = IsolatedAudio(buffer: buffer, source: source, framePosition: 7)
        for changed in [buffer, source] {
            let data = try #require(changed.floatChannelData)[0]
            for index in 0 ..< 3 { data[index] = 9 }
        }

        #expect(audio.buffer !== buffer)
        #expect(audio.source !== source)
        #expect(TestAudio.channels(audio.buffer) == [isolated])
        #expect(TestAudio.channels(audio.source) == [original])
        #expect(TestAudio.channels(audio.background()) == [[0.5, 0.25, -0.5]])
        #expect(audio.framePosition == 7)
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

    // MARK: - Values that a caller or an engine supplies

    /// An executor can change `AudioSamples.channels` so that the channels differ in length.
    @Test(arguments: [false, true])
    func outputWithUnequalChannelsIsAnError(atTheEnd: Bool) async throws {
        let isolator = SoundIsolator(model: MalformedModel(atTheEnd: atTheEnd))
        let stereo = [TestAudio.voice(seconds: 0.1, seed: 1), TestAudio.voice(seconds: 0.1, seed: 2)]
        await #expect {
            _ = try await isolator.isolate(try TestAudio.buffer(stereo))
        } throws: { error in
            guard case SoundIsolationError.invalidResult = error else { return false }
            return true
        }
    }

    @Test(arguments: [Double.infinity, .nan, -48_000, 0, 1e12])
    func executorWithAnInvalidSampleRateIsAnError(sampleRate: Double) async throws {
        let isolator = SoundIsolator(model: StandInModel(sampleRate: sampleRate))
        await #expect(throws: SoundIsolationError.self) {
            _ = try await isolator.isolate(try TestAudio.buffer([input]))
        }
    }

    /// The resampler returns its output in blocks, so a large ratio of the rates needs no large buffer.
    @Test func executorAtAVeryHighSampleRateKeepsTheLength() async throws {
        // 2,000 frames at 8 kHz are 96,000 frames at 384 kHz, which is more than one block.
        let short = Array(TestAudio.voice(seconds: 0.25, sampleRate: 8_000))
        let isolator = SoundIsolator(model: StandInModel(sampleRate: 384_000, gain: 1))
        let audio = try await isolator.isolate(try TestAudio.buffer([short], sampleRate: 8_000))
        #expect(audio.buffer.frameLength == 2_000)
        #expect(TestAudio.channels(audio.buffer)[0].allSatisfy { $0.isFinite })
    }

    @Test(arguments: [
        SoundIsolationRequest(sound: .voice, sampleRate: 48_000, channelCount: -1),
        SoundIsolationRequest(sound: .voice, sampleRate: 48_000, channelCount: 0),
        SoundIsolationRequest(sound: .voice, sampleRate: -1, channelCount: 1),
        SoundIsolationRequest(sound: .voice, sampleRate: .nan, channelCount: 1),
        SoundIsolationRequest(sound: .voice, sampleRate: .infinity, channelCount: 2),
    ])
    func systemModelRefusesAnInvalidRequest(request: SoundIsolationRequest) async throws {
        try #require(SystemSoundIsolationModel().isAvailable)
        await #expect(throws: SoundIsolationError.self) {
            _ = try await SystemSoundIsolationModel().makeExecutor(for: request)
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

    /// `AsyncStream` ends without an error when the task that waits for it is cancelled.
    /// The isolator does not read that as the end of the input.
    @Test func cancellationWhileTheSourceWaitsThrows() async throws {
        let finished = Counter()
        let isolator = SoundIsolator(model: StandInModel(latency: 100, afterFinish: { await finished.increment() }))
        let (buffers, continuation) = AsyncStream<AudioInput>.makeStream()
        let (pieces, delivered) = AsyncStream<Int>.makeStream()
        continuation.yield(AudioInput(buffer: try TestAudio.buffer([input])))
        let task = Task {
            var frames = 0
            for try await audio in isolator.streamIsolation(of: buffers) {
                frames += Int(audio.buffer.frameLength)
                delivered.yield(frames)
            }
            return frames
        }
        // The first piece arrived, so the stream now waits for input that never comes.
        var iterator = pieces.makeAsyncIterator()
        _ = await iterator.next()
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await task.value
        }
        // The engine was not asked for the rest of its output.
        #expect(await finished.value == 0)
        continuation.finish()
    }

    /// The single-buffer method checks for cancellation before it reads the buffer,
    /// and again after the engine's last call, so a cancelled task never gets a result.
    @Test func cancellationStopsOneBuffer() async throws {
        let executors = Counter()
        let input = input
        let before = Task {
            let buffer = try TestAudio.buffer([input])
            withUnsafeCurrentTask { $0?.cancel() }
            return try await SoundIsolator(model: StandInModel(executors: executors)).isolate(buffer)
        }
        await #expect(throws: CancellationError.self) { _ = try await before.value }
        #expect(await executors.value == 0)

        // The engine returns from `finish()` after the task was cancelled in it.
        let model = StandInModel(afterFinish: { withUnsafeCurrentTask { $0?.cancel() } })
        let during = Task { try await SoundIsolator(model: model).isolate(try TestAudio.buffer([input])) }
        await #expect(throws: CancellationError.self) { _ = try await during.value }
    }

    @Test func failureEndsTheStream() async throws {
        struct SourceFailure: Error {}
        let buffer = try TestAudio.buffer([Array(input.prefix(1_000))])
        let calls = Mutex(0)
        let source = Buffers {
            let call = calls.withLock { value in
                value += 1
                return value
            }
            if call == 2 { throw SourceFailure() }
            return buffer
        }
        var iterator = SoundIsolator(model: StandInModel()).streamIsolation(of: source).makeAsyncIterator()
        #expect(try await iterator.next()?.buffer.frameLength == 1_000)
        await #expect(throws: SourceFailure.self) {
            _ = try await iterator.next()
        }
        // The source would return more audio, but the stream ended with the error.
        #expect(try await iterator.next() == nil)
        #expect(try await iterator.next() == nil)
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func engineFailureEndsTheStream() async throws {
        struct EngineFailure: Error {}
        let buffer = try TestAudio.buffer([Array(input.prefix(1_000))])
        let calls = Mutex(0)
        let model = StandInModel(afterProcess: { frames in
            calls.withLock { $0 += 1 }
            if frames > 1_000 { throw EngineFailure() }
        })
        var iterator = SoundIsolator(model: model).streamIsolation(of: Buffers { buffer }).makeAsyncIterator()
        #expect(try await iterator.next()?.buffer.frameLength == 1_000)
        await #expect {
            _ = try await iterator.next()
        } throws: { error in
            guard case SoundIsolationError.backendFailure(let underlying) = error else { return false }
            return underlying is EngineFailure
        }
        #expect(try await iterator.next() == nil)
        // The engine was not called again with the audio that failed or with new audio.
        #expect(calls.withLock { $0 } == 2)
    }

    /// The comparison that the tests use fails for a signal that is not finite.
    @Test func differenceOfSignalsThatAreNotFiniteIsInfinite() {
        let signal: [Float] = [0, 0.5, -0.5, 1]
        #expect(TestAudio.maximumDifference(signal, signal) == 0)
        #expect(TestAudio.maximumDifference(signal, [0, 0.5, -0.25, 1]) == 0.25)
        #expect(TestAudio.maximumDifference(signal, [0, 0.5, -0.5]) == .infinity)
        for value in [Float.nan, .infinity, -.infinity] {
            var other = signal
            other[2] = value
            #expect(TestAudio.maximumDifference(signal, other) == .infinity)
            #expect(TestAudio.maximumDifference(other, signal) == .infinity)
            #expect(TestAudio.maximumDifference(other, other) == .infinity)
            #expect(!(TestAudio.maximumDifference(other, other) < 1e-6))
        }
        let nans = [Float](repeating: .nan, count: 4)
        #expect(!(TestAudio.maximumDifference(nans, signal) <= 1e-4))
    }

    /// A sample rate that is not a whole number keeps its fraction in the time range.
    /// A rate rounded to 44,101 Hz would be wrong by 20 ms after one hour.
    @Test func timeRangeKeepsAFractionalSampleRate() throws {
        let sampleRate = 44_100.5
        let buffer = try TestAudio.buffer([Array(repeating: 0, count: 1_024)], sampleRate: sampleRate)
        let hour = AVAudioFramePosition(sampleRate * 3_600)
        let first = IsolatedAudio(buffer: buffer, source: buffer, framePosition: hour)
        let second = IsolatedAudio(buffer: buffer, source: buffer, framePosition: hour + 1_024)

        #expect(abs(first.timeRange.start.seconds - Double(hour) / sampleRate) < 1e-8)
        #expect(abs(first.timeRange.duration.seconds - 1_024 / sampleRate) < 1e-8)
        #expect(first.timeRange.end == second.timeRange.start)

        // A whole rate stays exact, with the rate as the time scale.
        let whole = IsolatedAudio(
            buffer: try TestAudio.buffer([[0, 0, 0]]),
            source: try TestAudio.buffer([[0, 0, 0]]),
            framePosition: 48_001
        )
        #expect(whole.timeRange.start == CMTime(value: 48_001, timescale: 48_000))
        #expect(whole.timeRange.duration == CMTime(value: 3, timescale: 48_000))
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

/// An engine for two channels whose output has channels of different lengths.
struct MalformedModel: SoundIsolationModel {
    /// Whether the malformed output comes from `finish` and not from `process`.
    let atTheEnd: Bool

    var availability: Availability<Never> { .available }

    func makeExecutor(for request: SoundIsolationRequest) async throws -> any SoundIsolationExecutor {
        Executor(sampleRate: request.sampleRate, atTheEnd: atTheEnd)
    }

    struct Executor: SoundIsolationExecutor {
        let sampleRate: Double
        let atTheEnd: Bool
        var channelCount: Int { 2 }
        var latency: Int { 0 }

        func process(_ input: AudioSamples) -> AudioSamples {
            atTheEnd ? input : malformed(input)
        }

        func finish() -> AudioSamples {
            atTheEnd ? malformed(AudioSamples(channelCount: 2, frameCount: 8)) : AudioSamples(channelCount: 2)
        }

        private func malformed(_ samples: AudioSamples) -> AudioSamples {
            var samples = samples
            samples.channels[1].removeLast(3)
            return samples
        }
    }
}

actor Counter {
    var value = 0
    func increment() { value += 1 }
}
