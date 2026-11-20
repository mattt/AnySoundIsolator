import AVFoundation
import Foundation
import Testing

@testable import AnySoundIsolator

/// A report on how repeatable the system's audio unit is on the machine that runs the tests.
///
/// On virtual machines with macOS 27, the unit gave two different outputs for the same samples.
/// This test prints the facts that tell the possible causes apart.
/// It has no expectation and catches every error, so it never fails a run.
/// Run it alone, so that no other test makes a unit in the process:
/// `swift test --filter SystemUnitDiagnostics`.
///
/// Each line of the report starts with `[system-unit]`.
/// Every render is of the same second of a synthetic voice, mono at 48 kHz.
/// A line names the output (`output 1` is the first of its quality, `output 2` the next different one),
/// and gives its checksum, its level, and the units of the process at two times:
/// when the test made the unit, and when the render started.
/// `2 in use, 1 in disposal` means two units that are not released,
/// and one that was released and that the package's disposal queue has not yet disposed of.
///
/// The first run on such a machine showed no dependence on the block size or on the heap.
/// It gave `output 1` for the first render and for a unit made while another unit was in use,
/// and `output 2` for each render that came directly after another render.
/// The rule that this report tests: a unit gives `output 2`
/// when the test makes it while a released unit waits for its disposal or is in it.
/// What each group of lines shows for that rule:
///
/// - `first`: `output 1` by definition.
/// - `after a render`: as in the first run, where each of these gave `output 2`.
///   The line shows whether a unit was still in disposal when the test made the next one.
///   If it shows `0 in disposal` and `output 2`, the rule is wrong.
/// - `directly after a render`: two renders with nothing between them; the line is for the second.
///   On an Apple M4 Max, the second unit is made with one unit in disposal. The rule says `output 2`.
/// - `after the disposals`: the test waits for the disposal queue and then makes the unit.
///   The rule says `output 1`. If these lines give `output 2`,
///   the rule is wrong, and the cause is that no other unit is in use.
/// - `after the disposals and 0.5 s`: the same with a pause,
///   in case the system does more work after a disposal returns. The rule says `output 1`.
/// - `with one unit in use, directly after a render`: an idle unit stays in use,
///   and the renders follow each other with no wait. The rule says `output 2`.
///   If these lines give `output 1`, a unit in use is what matters, and the disposal is not.
/// - `made before a disposal, rendered in it`: the test makes the unit with no disposal pending,
///   then releases another unit and renders at once.
///   `output 2` here shows that a disposal during the render matters, and not only during the making.
/// - `at the same time, after the disposals`: four renders in four tasks, with no disposal pending at the start.
///   The rule says `output 1` for each, unless a disposal during a render matters.
/// - `stereo unit`: whether a unit for two channels starts, and after how many calls to `AudioUnitInitialize`.
///   In two of four CI runs it failed with status -10875 for high quality.
///   A count of 2 or 3 shows that another call helps.
/// - `isolator` lines are the package's results for one buffer (twice), a stream, and a file.
///   They have the unit's delay removed, so their checksums are not those of the lines above.
@Suite(.enabled(if: SystemSoundIsolationModel().isAvailable))
struct SystemUnitDiagnostics {
    typealias Quality = SystemSoundIsolationModel.Quality

    /// One render and the units of the process around it.
    private struct Render {
        var output: [Float]
        var whenMade: SoundIsolationUnit.Census
        var whenRendered: SoundIsolationUnit.Census
    }

    @Test func reportOnRepeatability() async {
        var lines: [String] = []
        let version = ProcessInfo.processInfo.operatingSystemVersionString
        lines.append(
            "machine: virtual \(Machine.isVirtual ? "yes" : "no"), macOS \(version), "
                + "model \(Machine.string("hw.model") ?? "unknown"), "
                + "chip \(Machine.string("machdep.cpu.brand_string") ?? "unknown"), "
                + "\(ProcessInfo.processInfo.activeProcessorCount) processors"
        )
        lines.append(
            "the tests \(Machine.systemUnitCanDiffer ? "accept" : "do not accept") different samples on this machine"
        )

        for quality in Quality.allCases {
            // The different outputs of this quality, in the order in which they appeared.
            var outputs: [[Float]] = []
            func name(_ output: [Float]) -> String {
                if !outputs.contains(output) { outputs.append(output) }
                return "output \(outputs.firstIndex(of: output)! + 1) (\(TestAudio.checksum(output)))"
            }
            func add(_ title: String, _ render: () async throws -> Render) async {
                do {
                    let render = try await render()
                    lines.append(
                        "\(quality) \(title): \(name(render.output)), level \(TestAudio.level(render.output)), "
                            + "made with \(Self.describe(render.whenMade)), "
                            + "rendered with \(Self.describe(render.whenRendered))"
                    )
                } catch {
                    lines.append("\(quality) \(title): error \(error)")
                }
            }

            await add("first") { try Self.render(quality) }
            for _ in 1 ... 3 {
                await add("after a render") { try Self.render(quality) }
            }
            for _ in 1 ... 3 {
                await add("directly after a render") {
                    _ = try Self.render(quality)
                    return try Self.render(quality)
                }
            }
            for _ in 1 ... 3 {
                await add("after the disposals") {
                    SoundIsolationUnit.waitForDisposals()
                    return try Self.render(quality)
                }
            }
            for _ in 1 ... 2 {
                await add("after the disposals and 0.5 s") {
                    SoundIsolationUnit.waitForDisposals()
                    try await Task.sleep(for: .milliseconds(500))
                    return try Self.render(quality)
                }
            }
            do {
                SoundIsolationUnit.waitForDisposals()
                let idle = try Self.makeUnit(quality)
                await add("with one unit in use, after the disposals") { try Self.render(quality) }
                for _ in 1 ... 3 {
                    await add("with one unit in use, directly after a render") {
                        _ = try Self.render(quality)
                        return try Self.render(quality)
                    }
                }
                withExtendedLifetime(idle) {}
            } catch {
                lines.append("\(quality) with one unit in use: error \(error)")
            }
            for _ in 1 ... 3 {
                await add("made before a disposal, rendered in it") {
                    SoundIsolationUnit.waitForDisposals()
                    let whenMade = SoundIsolationUnit.census
                    let unit = try Self.makeUnit(quality)
                    // Use and release another unit, so that its disposal runs during the render.
                    _ = try Self.render(quality)
                    return try Self.render(unit, whenMade: whenMade)
                }
            }
            SoundIsolationUnit.waitForDisposals()
            let together = await withTaskGroup(of: Result<Render, any Error>.self) { group in
                for _ in 0 ..< 4 {
                    group.addTask { Result { try Self.render(quality) } }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            for result in together {
                await add("at the same time, after the disposals") { try result.get() }
            }
            lines.append("\(quality): \(outputs.count) different outputs from the unit")

            for _ in 1 ... 3 {
                let census = SoundIsolationUnit.census
                do {
                    let unit = try SoundIsolationUnit(
                        sampleRate: 48_000,
                        channelCount: 2,
                        soundType: quality.soundType,
                        wetDryMixPercent: 100
                    )
                    lines.append(
                        "\(quality) stereo unit: started after \(unit.initializationAttempts) calls, "
                            + "made with \(Self.describe(census))"
                    )
                } catch {
                    lines.append("\(quality) stereo unit: error \(error), made with \(Self.describe(census))")
                }
            }

            // The package's results, with the unit's delay removed.
            outputs = []
            let isolator = SoundIsolator(model: SystemSoundIsolationModel(quality: quality))
            func addIsolated(_ title: String, _ isolate: () async throws -> [Float]) async {
                do {
                    let output = try await isolate()
                    lines.append("\(quality) \(title): \(name(output)), level \(TestAudio.level(output))")
                } catch {
                    lines.append("\(quality) \(title): error \(error)")
                }
            }
            for _ in 1 ... 2 {
                await addIsolated("isolator, one buffer") {
                    TestAudio.channels(try await isolator.isolate(try TestAudio.buffer([Self.input])).buffer)[0]
                }
            }
            await addIsolated("isolator, stream of 480") {
                let source = Buffers(try TestAudio.buffers([Self.input], size: 480))
                return try await TestAudio.collect(isolator.streamIsolation(of: source)).isolated[0]
            }
            await addIsolated("isolator, file") {
                let directory = try TestAudio.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let source = directory.appending(path: "source.wav")
                let voice = directory.appending(path: "voice.wav")
                try TestAudio.write([Self.input], to: source)
                try await isolator.isolate(contentsOf: source, to: voice)
                return try await TestAudio.read(voice)[0]
            }
            lines.append("\(quality): \(outputs.count) different outputs from the isolator")
        }
        print(lines.map { "[system-unit] \($0)" }.joined(separator: "\n"))
    }

    private static let input = TestAudio.voice(seconds: 1)

    private static func describe(_ census: SoundIsolationUnit.Census) -> String {
        "\(census.inUse) in use, \(census.inDisposal) in disposal"
    }

    private static func makeUnit(_ quality: Quality) throws -> SoundIsolationUnit {
        try SoundIsolationUnit(sampleRate: 48_000, channelCount: 1, soundType: quality.soundType, wetDryMixPercent: 100)
    }

    /// Renders the input and the unit's delay with a new unit.
    private static func render(_ quality: Quality) throws -> Render {
        let whenMade = SoundIsolationUnit.census
        return try render(makeUnit(quality), whenMade: whenMade)
    }

    /// Renders the input and the unit's delay with a unit.
    private static func render(_ unit: SoundIsolationUnit, whenMade: SoundIsolationUnit.Census) throws -> Render {
        let whenRendered = SoundIsolationUnit.census
        let samples = AudioSamples(channels: [input])
        let output = try unit.render(samples, frameCount: input.count + unit.latency).channels[0]
        return Render(output: output, whenMade: whenMade, whenRendered: whenRendered)
    }
}
