import AVFoundation
import Foundation
import Testing

@testable import AnySoundIsolator

/// Tests of the system's audio unit. They need no download and no recording.
///
/// A test that compares two renders of the same samples uses `TestAudio.expectSameRender`.
/// It requires equal samples, except on a machine where `Machine.systemUnitCanDiffer` is true:
/// there, a difference in the samples is a known issue with an unknown cause,
/// and the test still requires the same length and place in time, and a level within a factor of two.
@Suite(.enabled(if: SystemSoundIsolationModel().isAvailable))
struct SystemSoundIsolationModelTests {
    typealias Quality = SystemSoundIsolationModel.Quality

    /// The isolator checks the sound before it asks for an executor.
    /// A direct request for another sound is refused too, and not answered with a voice executor.
    @Test func executorForAnotherSoundIsRefused() async throws {
        let request = SoundIsolationRequest(
            sound: SoundIsolator.Sound(rawValue: "music"),
            sampleRate: 48_000,
            channelCount: 1
        )
        await #expect {
            _ = try await SystemSoundIsolationModel().makeExecutor(for: request)
        } throws: { error in
            guard case SoundIsolationError.unsupportedConfiguration = error else { return false }
            return true
        }
    }

    @Test(arguments: Quality.allCases, [8_000.0, 16_000.0, 44_100.0, 48_000.0, 96_000.0])
    func monoOutputIsOnTheInputTimeline(quality: Quality, sampleRate: Double) async throws {
        let input = TestAudio.voice(seconds: 3, sampleRate: sampleRate)
        let isolator = SoundIsolator(model: SystemSoundIsolationModel(quality: quality))
        let audio = try await isolator.isolate(try TestAudio.buffer([input], sampleRate: sampleRate))
        let isolated = TestAudio.channels(audio.buffer)[0]

        #expect(audio.buffer.format.sampleRate == sampleRate)
        #expect(isolated.count == input.count)
        #expect(TestAudio.channels(audio.source) == [input])
        // The unit's delay, 56 to 97 ms, is gone. One frame is the limit of what the unit reports.
        let lag = Alignment.lag(of: isolated, behind: input, maximumLag: Int(sampleRate / 20))
        #expect(abs(lag) <= 1)
        // The unit kept the signal; this is not a check of how it sounds.
        #expect(TestAudio.level(isolated) > 0.1 * TestAudio.level(input))
    }

    /// The unit changes a signal of a voice with noise, so an engine that returns its input does not pass.
    ///
    /// The other tests check the level, the delay, and that the two outputs add up to the input,
    /// and an unchanged input meets all three.
    /// Here the sound that the unit removed must be at least half as loud as the noise.
    /// On an Apple M4 Max it is 2 to 3 times as loud, because the unit also changes the synthetic voice.
    /// This is not a check of how the output sounds.
    @Test(arguments: Quality.allCases)
    func voiceWithNoiseIsChanged(quality: Quality) async throws {
        let voice = TestAudio.voice(seconds: 4)
        let noise = TestAudio.noise(count: voice.count, amplitude: 0.05)
        let input = zip(voice, noise).map { $0 + $1 }
        let isolator = SoundIsolator(model: SystemSoundIsolationModel(quality: quality))
        let audio = try await isolator.isolate(try TestAudio.buffer([input]))
        let isolated = TestAudio.channels(audio.buffer)[0]
        let removed = TestAudio.channels(audio.background())[0]

        #expect(isolated.allSatisfy { $0.isFinite })
        #expect(isolated != input)
        #expect(TestAudio.level(removed) > 0.5 * TestAudio.level(noise))
        #expect(TestAudio.level(isolated) > 0.1 * TestAudio.level(input))
    }

    @Test(arguments: Quality.allCases)
    func stereoOutputIsOnTheInputTimeline(quality: Quality) async throws {
        let input = [TestAudio.voice(seconds: 3, seed: 1), TestAudio.voice(seconds: 3, seed: 2)]
        let isolator = SoundIsolator(model: SystemSoundIsolationModel(quality: quality))
        // On some virtual machines the stereo unit does not always start; see the helper.
        try await TestAudio.withKnownStartFailure {
            let audio = try await isolator.isolate(try TestAudio.buffer(input))
            let isolated = TestAudio.channels(audio.buffer)

            #expect(isolated.count == 2)
            for channel in 0 ..< 2 {
                #expect(isolated[channel].count == input[channel].count)
                let lag = Alignment.lag(of: isolated[channel], behind: input[channel], maximumLag: 2_400)
                #expect(abs(lag) <= 1)
            }
        }
    }

    /// With its mix set to the unprocessed input, the unit returns the input itself, late.
    /// After the isolator removes the delay that the unit reports, the output is the input exactly.
    @Test(arguments: Quality.allCases, [1, 2])
    func reportedDelayIsRemovedExactly(quality: Quality, channelCount: Int) async throws {
        let input = (1 ... channelCount).map { TestAudio.voice(seconds: 1, seed: UInt64($0)) }
        let isolator = SoundIsolator(model: UnprocessedModel(quality: quality))
        // On some virtual machines the stereo unit does not always start; see the helper.
        try await TestAudio.withKnownStartFailure {
            let audio = try await isolator.isolate(try TestAudio.buffer(input))

            let output = TestAudio.channels(audio.buffer)
            #expect(output == input, TestAudio.difference(output, input))
        }
    }

    /// A unit that fails to start and a refused format are two different errors after one call,
    /// and the first keeps the unit's status.
    @Test func unitThatFailsToStartIsAnErrorAtOnce() throws {
        var calls = 0
        #expect {
            try SoundIsolationUnit.start(sampleRate: 48_000, channelCount: 2) {
                calls += 1
                return kAudioUnitErr_FailedInitialization
            }
        } throws: { error in
            guard case SoundIsolationError.backendFailure(let underlying) = error else { return false }
            let status = underlying as NSError
            return status.domain == NSOSStatusErrorDomain
                && status.code == Int(kAudioUnitErr_FailedInitialization)
                && status.localizedDescription.contains("status \(kAudioUnitErr_FailedInitialization)")
        }
        #expect(calls == 1)

        calls = 0
        #expect {
            try SoundIsolationUnit.start(sampleRate: 48_000, channelCount: 2) {
                calls += 1
                return kAudioUnitErr_FormatNotSupported
            }
        } throws: { error in
            guard case SoundIsolationError.unsupportedConfiguration = error else { return false }
            return true
        }
        #expect(calls == 1)

        calls = 0
        try SoundIsolationUnit.start(sampleRate: 48_000, channelCount: 2) {
            calls += 1
            return noErr
        }
        #expect(calls == 1)
    }

    /// The executor is public, so a caller can give it audio that the isolator would never give.
    /// The unit reads every channel by the length of the first, so the executor checks the input first.
    @Test func executorRefusesAudioThatDoesNotMatchIt() async throws {
        let model = SystemSoundIsolationModel(quality: .standard)
        let executor = try await model.makeExecutor(
            for: SoundIsolationRequest(sound: .voice, sampleRate: 48_000, channelCount: 1)
        )
        let voice = TestAudio.voice(seconds: 0.1)
        await #expect {
            _ = try await executor.process(AudioSamples(channels: [voice, voice]))
        } throws: { error in
            guard case SoundIsolationError.invalidAudio = error else { return false }
            return true
        }

        // `channels` can change after the initializer checked the lengths.
        var unequal = AudioSamples(channels: [voice])
        unequal.channels.append(Array(voice.prefix(10)))
        let stereo = try await model.makeExecutor(
            for: SoundIsolationRequest(sound: .voice, sampleRate: 48_000, channelCount: 2)
        )
        await #expect {
            _ = try await stereo.process(unequal)
        } throws: { error in
            guard case SoundIsolationError.invalidAudio = error else { return false }
            return true
        }
        // A refused input does not reach the unit, so the executor still works.
        let output = try await stereo.process(AudioSamples(channels: [voice, voice]))
        #expect(output.channelCount == 2)
        #expect(output.frameCount == voice.count)
    }

    /// The unit checks for cancellation before each block, so a cancelled call does not reach the unit,
    /// and the executor still works.
    @Test func cancelledCallDoesNotReachTheUnit() async throws {
        let executor = try await SystemSoundIsolationModel(quality: .standard).makeExecutor(
            for: SoundIsolationRequest(sound: .voice, sampleRate: 48_000, channelCount: 1)
        )
        let input = AudioSamples(channels: [TestAudio.voice(seconds: 0.5)])
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await executor.process(input)
        }
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(try await executor.process(input).frameCount == input.frameCount)
    }

    @Test func threeChannelsAreDownmixedByDefault() async throws {
        let input = (1 ... 3).map { TestAudio.voice(seconds: 1, seed: UInt64($0)) }
        let isolator = SoundIsolator()
        let together = try await isolator.isolate(try TestAudio.buffer(input))
        let average = input[0].indices.map { (input[0][$0] + input[1][$0] + input[2][$0]) * (1 / Float(3)) }
        let alone = try await isolator.isolate(try TestAudio.buffer([average]))

        #expect(together.buffer.format.channelCount == 3)
        #expect(TestAudio.channels(together.source) == input)
        // The three channels of the output are copies of one render, so they are equal on every machine.
        let output = TestAudio.channels(together.buffer)
        #expect(output.allSatisfy { $0 == output[0] })
        // The render of the three channels and the render of their average are two renders.
        TestAudio.expectSameRender([output[0]], TestAudio.channels(alone.buffer))
    }

    @Test func threeChannelsAreIsolatedSeparatelyWhenAsked() async throws {
        let input = (1 ... 3).map { TestAudio.voice(seconds: 1, seed: UInt64($0)) }
        let isolator = SoundIsolator()
        let together = try await isolator.isolate(
            try TestAudio.buffer(input),
            options: IsolationOptions(channelPolicy: .perChannel)
        )
        #expect(together.buffer.format.channelCount == 3)

        for (index, channel) in input.enumerated() {
            let alone = try await isolator.isolate(try TestAudio.buffer([channel]))
            let output = [TestAudio.channels(together.buffer)[index]]
            let expected = TestAudio.channels(alone.buffer)
            TestAudio.expectSameRender(output, expected, "channel \(index)")
        }
    }

    /// Live audio and one buffer give the same samples, whatever the buffer size,
    /// where the system's audio unit is repeatable. See `TestAudio.expectSameRender`.
    @Test(arguments: Quality.allCases, [480, 1_024, 7_001])
    func streamGivesTheSameOutputAsOneBuffer(quality: Quality, bufferSize: Int) async throws {
        let input = TestAudio.voice(seconds: 2)
        let isolator = SoundIsolator(model: SystemSoundIsolationModel(quality: quality))
        let whole = try await isolator.isolate(try TestAudio.buffer([input]))

        let source = Buffers(try TestAudio.buffers([input], size: bufferSize))
        let result = try await TestAudio.collect(isolator.streamIsolation(of: source))

        TestAudio.expectSameRender(result.isolated, TestAudio.channels(whole.buffer))
        #expect(result.source == [input])
        #expect(result.pieces > 1)
    }

    /// Streams that run at the same time each give the output that one stream gives,
    /// where the system's audio unit is repeatable. See `TestAudio.expectSameRender`.
    ///
    /// This test does not show the stop in the unit's disposal that `SoundIsolationUnit` describes:
    /// that needs the whole process at background priority, as `taskpolicy -b` gives.
    @Test(.timeLimit(.minutes(2)), arguments: [TaskPriority.medium, .background])
    func streamsAtTheSameTimeGiveTheSameOutput(priority: TaskPriority) async throws {
        let input = [TestAudio.voice(seconds: 1, sampleRate: 16_000)]
        let isolator = SoundIsolator()
        let expected = TestAudio.channels(
            try await isolator.isolate(try TestAudio.buffer(input, sampleRate: 16_000)).buffer
        )
        let count = 4 * ProcessInfo.processInfo.activeProcessorCount
        let outputs = try await withThrowingTaskGroup(of: [[Float]].self) { group in
            for _ in 0 ..< count {
                group.addTask(priority: priority) {
                    let audio = try await isolator.isolate(try TestAudio.buffer(input, sampleRate: 16_000))
                    return TestAudio.channels(audio.buffer)
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        #expect(outputs.count == count)
        for output in outputs {
            TestAudio.expectSameRender(output, expected)
        }
    }

    /// Runs a closure with the stack lower by a number of bytes.
    @inline(never)
    private static func withStackLowered<Result>(by byteCount: Int, _ body: () throws -> Result) rethrows -> Result {
        guard byteCount > 0 else { return try body() }
        return try withUnsafeTemporaryAllocation(byteCount: byteCount, alignment: 16) { pad in
            pad.initializeMemory(as: UInt8.self, repeating: 0)
            return try body()
        }
    }

    /// Renders one second of a voice with a new unit and returns everything that the unit gives.
    private static func render(stackLoweredBy byteCount: Int, quality: Quality) throws -> AudioSamples {
        let unit = try SoundIsolationUnit(
            sampleRate: 48_000,
            channelCount: 1,
            soundType: quality.soundType,
            wetDryMixPercent: 100
        )
        let input = AudioSamples(channels: [TestAudio.voice(seconds: 1)])
        return try withStackLowered(by: byteCount) {
            try unit.render(input, frameCount: input.frameCount + unit.latency)
        }
    }

    /// The system unit's output depends on the position of the stack, within 64 bytes, at the render call.
    /// The package makes that call from a fixed position, so the caller's stack, its thread,
    /// and its queue do not change the output.
    /// Without that, the positions below gave three different outputs on an Apple M4 Max.
    ///
    /// Each comparison is of two renders, so `TestAudio.expectSameRender` applies:
    /// on a machine where the unit differs for a cause that is not the stack, a difference does not fail.
    @Test(arguments: Quality.allCases)
    func outputDoesNotDependOnTheCallersStack(quality: Quality) async throws {
        let expected = try Self.render(stackLoweredBy: 0, quality: quality).channels
        for byteCount in stride(from: 16, through: 128, by: 16) {
            let output = try Self.render(stackLoweredBy: byteCount, quality: quality).channels
            TestAudio.expectSameRender(output, expected, "stack lowered by \(byteCount)")
        }

        let onAThread = try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result { try Self.render(stackLoweredBy: 0, quality: quality).channels })
            }
        }
        TestAudio.expectSameRender(onAThread, expected, "new thread")
        let onAQueue = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(with: Result { try Self.render(stackLoweredBy: 0, quality: quality).channels })
            }
        }
        TestAudio.expectSameRender(onAQueue, expected, "dispatch queue")
        let inATask = try await Task.detached {
            try Self.render(stackLoweredBy: 0, quality: quality).channels
        }.value
        TestAudio.expectSameRender(inATask, expected, "detached task")

        // The isolator gives the same samples, with the unit's delay removed.
        let isolator = SoundIsolator(model: SystemSoundIsolationModel(quality: quality))
        let audio = try await isolator.isolate(try TestAudio.buffer([TestAudio.voice(seconds: 1)]))
        let isolated = TestAudio.channels(audio.buffer)
        let aligned = expected.map { Array($0.suffix(48_000)) }
        TestAudio.expectSameRender(isolated, aligned, "isolator")
    }

    @Test func silenceStaysSilent() async throws {
        let audio = try await SoundIsolator().isolate(
            try TestAudio.buffer([Array(repeating: 0, count: 24_000)])
        )
        #expect(TestAudio.channels(audio.buffer)[0].allSatisfy { $0 == 0 })
    }

    @Test func bufferShorterThanTheDelayKeepsItsLength() async throws {
        let input = Array(TestAudio.voice(seconds: 1).prefix(1_000))
        let audio = try await SoundIsolator().isolate(try TestAudio.buffer([input]))
        #expect(audio.buffer.frameLength == 1_000)
    }
}

/// The system's audio unit with its mix set to the unprocessed input.
struct UnprocessedModel: SoundIsolationModel {
    let quality: SystemSoundIsolationModel.Quality

    var availability: Availability<Never> { .available }

    func makeExecutor(for request: SoundIsolationRequest) async throws -> any SoundIsolationExecutor {
        try SystemSoundIsolationExecutor(
            sampleRate: request.sampleRate,
            channelCount: request.channelCount,
            quality: quality,
            wetDryMixPercent: 0
        )
    }
}
