import AVFoundation
import Foundation
import Testing

@testable import AnySoundIsolator

/// A report on how repeatable the system's audio unit is on the machine that runs the tests.
///
/// On the CI runners with macOS 27, two renders of the same samples differed in some runs,
/// and the cause is unknown.
/// This test prints the facts that tell the possible causes apart.
/// It has no expectation and catches every error, so it never fails a run.
///
/// Each line of the report starts with `[system-unit]`.
/// Every render is of the same second of a synthetic voice, mono at 48 kHz, with a new unit,
/// and its line has a checksum of the exact samples.
/// How to read the checksums of one quality:
///
/// - `blocks of 4096` is three renders that are alike in every respect.
///   If their checksums differ, the unit is not repeatable at all, and the other lines say no more.
/// - `blocks of 480`, `1024`, and `3001`: a checksum that differs from `blocks of 4096`
///   shows a dependence on the number of frames in each render call.
/// - `with ... bytes held`: the test holds heap blocks while it makes the unit,
///   so the heap can put the unit's own buffers at other addresses.
///   A different checksum shows a dependence on where the heap puts the unit's memory.
/// - `second unit, first alive` and `third unit, after two`:
///   a different checksum shows a dependence on earlier units of the process.
/// - `at the same time`: four renders in four tasks.
///   A different checksum shows a dependence on other renders that run then.
/// - `isolator` lines are the package's results for one buffer (twice), a stream, and a file.
///   They have the unit's delay removed, so their checksums are equal to each other
///   and not to the lines above.
///
/// In the whole test run, other tests render at the same time as this one.
/// To see the unit with no other render in the process, run this test alone:
/// `swift test --filter SystemUnitDiagnostics`.
@Suite(.enabled(if: SystemSoundIsolationModel().isAvailable))
struct SystemUnitDiagnostics {
    typealias Quality = SystemSoundIsolationModel.Quality

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
            var reference: [Float]?
            var checksums: Set<String> = []
            func add(_ name: String, _ render: () async throws -> [Float]) async {
                do {
                    let output = try await render()
                    let checksum = TestAudio.checksum(output)
                    checksums.insert(checksum)
                    var line = "\(quality) \(name): \(checksum), level \(TestAudio.level(output))"
                    if let reference, output != reference {
                        line += ", \(TestAudio.difference([output], [reference]).rawValue)"
                    }
                    reference = reference ?? output
                    lines.append(line)
                } catch {
                    lines.append("\(quality) \(name): error \(error)")
                }
            }

            for _ in 1 ... 3 {
                await add("blocks of 4096") { try Self.render(quality, blockSize: 4_096) }
            }
            for blockSize in [480, 1_024, 3_001] {
                await add("blocks of \(blockSize)") { try Self.render(quality, blockSize: blockSize) }
            }
            for byteCount in [24, 1_000, 40_000] {
                let held = (0 ..< 5).map { _ in UnsafeMutableRawPointer.allocate(byteCount: byteCount, alignment: 1) }
                defer { held.forEach { $0.deallocate() } }
                await add("with 5 blocks of \(byteCount) bytes held") {
                    try Self.render(quality, blockSize: 4_096)
                }
            }
            do {
                let first = try Self.makeUnit(quality)
                _ = try Self.render(first, blockSize: 4_096)
                await add("second unit, first alive") { try Self.render(quality, blockSize: 4_096) }
                let second = try Self.makeUnit(quality)
                _ = try Self.render(second, blockSize: 4_096)
                await add("third unit, after two") { try Self.render(quality, blockSize: 4_096) }
                // Both units stay alive until here.
                withExtendedLifetime((first, second)) {}
            } catch {
                lines.append("\(quality) units in sequence: error \(error)")
            }
            let together = await withTaskGroup(of: Result<[Float], any Error>.self) { group in
                for _ in 0 ..< 4 {
                    group.addTask { Result { try Self.render(quality, blockSize: 4_096) } }
                }
                return await group.reduce(into: []) { $0.append($1) }
            }
            for result in together {
                await add("at the same time") { try result.get() }
            }
            lines.append("\(quality): \(checksums.count) different checksums from the unit")

            // The package's results, with the unit's delay removed.
            reference = nil
            checksums = []
            let isolator = SoundIsolator(model: SystemSoundIsolationModel(quality: quality))
            for _ in 1 ... 2 {
                await add("isolator, one buffer") {
                    TestAudio.channels(try await isolator.isolate(try TestAudio.buffer([Self.input])).buffer)[0]
                }
            }
            await add("isolator, stream of 480") {
                let source = Buffers(try TestAudio.buffers([Self.input], size: 480))
                return try await TestAudio.collect(isolator.streamIsolation(of: source)).isolated[0]
            }
            await add("isolator, file") {
                let directory = try TestAudio.temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let source = directory.appending(path: "source.wav")
                let voice = directory.appending(path: "voice.wav")
                try TestAudio.write([Self.input], to: source)
                try await isolator.isolate(contentsOf: source, to: voice)
                return try await TestAudio.read(voice)[0]
            }
            lines.append("\(quality): \(checksums.count) different checksums from the isolator")
        }
        print(lines.map { "[system-unit] \($0)" }.joined(separator: "\n"))
    }

    private static let input = TestAudio.voice(seconds: 1)

    private static func makeUnit(_ quality: Quality) throws -> SoundIsolationUnit {
        try SoundIsolationUnit(sampleRate: 48_000, channelCount: 1, soundType: quality.soundType, wetDryMixPercent: 100)
    }

    /// Renders the input and the unit's delay with a new unit.
    private static func render(_ quality: Quality, blockSize: Int) throws -> [Float] {
        try render(makeUnit(quality), blockSize: blockSize)
    }

    /// Renders the input and the unit's delay, with a number of frames in each render call.
    private static func render(_ unit: SoundIsolationUnit, blockSize: Int) throws -> [Float] {
        let total = input.count + unit.latency
        var output: [Float] = []
        while output.count < total {
            let count = min(blockSize, total - output.count)
            let start = min(output.count, input.count)
            let piece = AudioSamples(channels: [Array(input[start ..< min(start + count, input.count)])])
            output += try unit.render(piece, frameCount: count).channels[0]
        }
        return output
    }
}
