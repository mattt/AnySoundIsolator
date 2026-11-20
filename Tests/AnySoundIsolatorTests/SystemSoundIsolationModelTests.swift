import AVFoundation
import Foundation
import Testing

@testable import AnySoundIsolator

/// Tests of the system's audio unit. They need no download and no recording.
@Suite(.enabled(if: SystemSoundIsolationModel().isAvailable))
struct SystemSoundIsolationModelTests {
    typealias Quality = SystemSoundIsolationModel.Quality

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

    @Test(arguments: Quality.allCases)
    func stereoOutputIsOnTheInputTimeline(quality: Quality) async throws {
        let input = [TestAudio.voice(seconds: 3, seed: 1), TestAudio.voice(seconds: 3, seed: 2)]
        let isolator = SoundIsolator(model: SystemSoundIsolationModel(quality: quality))
        let audio = try await isolator.isolate(try TestAudio.buffer(input))
        let isolated = TestAudio.channels(audio.buffer)

        #expect(isolated.count == 2)
        for channel in 0 ..< 2 {
            #expect(isolated[channel].count == input[channel].count)
            let lag = Alignment.lag(of: isolated[channel], behind: input[channel], maximumLag: 2_400)
            #expect(abs(lag) <= 1)
        }
    }

    /// With its mix set to the unprocessed input, the unit returns the input itself, late.
    /// After the isolator removes the delay that the unit reports, the output is the input exactly.
    @Test(arguments: Quality.allCases, [1, 2])
    func reportedDelayIsRemovedExactly(quality: Quality, channelCount: Int) async throws {
        let input = (1 ... channelCount).map { TestAudio.voice(seconds: 1, seed: UInt64($0)) }
        let isolator = SoundIsolator(model: UnprocessedModel(quality: quality))
        let audio = try await isolator.isolate(try TestAudio.buffer(input))

        let output = TestAudio.channels(audio.buffer)
        #expect(output == input, TestAudio.difference(output, input))
    }

    @Test func threeChannelsAreDownmixedByDefault() async throws {
        let input = (1 ... 3).map { TestAudio.voice(seconds: 1, seed: UInt64($0)) }
        let isolator = SoundIsolator()
        let together = try await isolator.isolate(try TestAudio.buffer(input))
        let average = input[0].indices.map { (input[0][$0] + input[1][$0] + input[2][$0]) * (1 / Float(3)) }
        let alone = try await isolator.isolate(try TestAudio.buffer([average]))

        #expect(together.buffer.format.channelCount == 3)
        #expect(TestAudio.channels(together.source) == input)
        let expected = TestAudio.channels(alone.buffer)
        for channel in TestAudio.channels(together.buffer) {
            #expect(channel == expected[0], TestAudio.difference([channel], expected))
        }
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
            #expect(output == expected, TestAudio.difference(output, expected))
        }
    }

    @Test(arguments: Quality.allCases, [480, 1_024, 7_001])
    func streamGivesTheSameOutputAsOneBuffer(quality: Quality, bufferSize: Int) async throws {
        let input = TestAudio.voice(seconds: 2)
        let isolator = SoundIsolator(model: SystemSoundIsolationModel(quality: quality))
        let whole = try await isolator.isolate(try TestAudio.buffer([input]))

        let source = Buffers(try TestAudio.buffers([input], size: bufferSize))
        let result = try await TestAudio.collect(isolator.streamIsolation(of: source))

        // Live audio and a file give the same samples, whatever the buffer size.
        let expected = TestAudio.channels(whole.buffer)
        #expect(result.isolated == expected, TestAudio.difference(result.isolated, expected))
        #expect(result.source == [input])
        #expect(result.pieces > 1)
    }

    /// Streams that run at the same time each give the output that one stream gives.
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
            #expect(output == expected, TestAudio.difference(output, expected))
        }
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
