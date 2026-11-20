import AVFoundation
import Accelerate
import Foundation
import Synchronization
import Testing

@testable import AnySoundIsolator

/// Signals, files, and measurements for tests. No test reads a recording.
enum TestAudio {
    /// A random number generator with a seed, so every run makes the same signal.
    struct Generator: RandomNumberGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            var value = state
            value ^= value >> 33
            value = value &* 0xff51_afd7_ed55_8ccd
            value ^= value >> 33
            return value
        }
    }

    /// A signal like speech, for an engine that keeps voices and removes everything else.
    ///
    /// The signal is a series of syllables. Each has a pitch that glides,
    /// harmonics shaped by three resonances as a vowel's are, and a soft start and end.
    /// The pitch, length, resonances, and pauses are random,
    /// so the signal does not repeat, and its correlation with a delayed copy has one clear peak.
    static func voice(seconds: Double, sampleRate: Double = 48_000, seed: UInt64 = 1) -> [Float] {
        let key = "\(seconds) \(sampleRate) \(seed)"
        if let cached = voices.withLock({ $0[key] }) { return cached }
        let samples = makeVoice(seconds: seconds, sampleRate: sampleRate, seed: seed)
        voices.withLock { $0[key] = samples }
        return samples
    }

    /// Describes how two sets of channels differ, for the message of a failed comparison.
    ///
    /// The description tells a small numeric difference from missing or moved audio.
    static func difference(_ first: [[Float]], _ second: [[Float]]) -> Comment {
        guard first.count == second.count else {
            return "\(first.count) channels and \(second.count) channels"
        }
        var parts: [String] = []
        for (channel, (a, b)) in zip(first, second).enumerated() where a != b {
            guard a.count == b.count else {
                parts.append("channel \(channel): \(a.count) frames and \(b.count) frames")
                continue
            }
            let different = a.indices.filter { a[$0] != b[$0] }
            let largest = different.map { abs(a[$0] - b[$0]) }.max() ?? .nan
            parts.append(
                "channel \(channel): \(different.count) of \(a.count) frames differ, "
                    + "from frame \(different.first ?? -1) through \(different.last ?? -1), "
                    + "largest difference \(largest), levels \(level(a)) and \(level(b))"
            )
        }
        return Comment(rawValue: parts.isEmpty ? "no difference" : parts.joined(separator: "; "))
    }

    /// Signals that tests already made; many tests use the same one.
    private static let voices = Mutex<[String: [Float]]>([:])

    private static func makeVoice(seconds: Double, sampleRate: Double, seed: UInt64) -> [Float] {
        var generator = Generator(state: seed)
        let count = Int(seconds * sampleRate)
        var samples: [Float] = []
        samples.reserveCapacity(count)
        while samples.count < count {
            let length = Int(Double.random(in: 0.09 ... 0.28, using: &generator) * sampleRate)
            let pause = Int(Double.random(in: 0.01 ... 0.08, using: &generator) * sampleRate)
            let startPitch = Double.random(in: 95 ... 210, using: &generator)
            let endPitch = startPitch * Double.random(in: 0.8 ... 1.25, using: &generator)
            let resonances = [
                Double.random(in: 300 ... 900, using: &generator),
                Double.random(in: 900 ... 2_300, using: &generator),
                Double.random(in: 2_400 ... 3_400, using: &generator),
            ]
            let harmonics = (1 ... 40).filter { Double($0) * max(startPitch, endPitch) < min(4_000, sampleRate * 0.45) }
            // The resonances shape each harmonic by its frequency at the middle of the glide.
            let gains = harmonics.map { harmonic in
                let frequency = (startPitch + endPitch) / 2 * Double(harmonic)
                return resonances.enumerated().reduce(0.0) { gain, resonance in
                    let distance = (frequency - resonance.element) / 120
                    return gain + 1 / (1 + distance * distance) / Double(resonance.offset + 1)
                }
            }
            var phase = 0.0
            for index in 0 ..< length {
                let position = Double(index) / Double(length)
                let pitch = startPitch + (endPitch - startPitch) * position
                phase += 2 * .pi * pitch / sampleRate
                var value = 0.0
                for (harmonic, gain) in zip(harmonics, gains) {
                    value += gain * sin(phase * Double(harmonic))
                }
                let loudness = sin(.pi * position)
                let breath = Double.random(in: -1 ... 1, using: &generator)
                samples.append(Float(0.25 * value * loudness + 0.004 * breath))
            }
            samples.append(contentsOf: repeatElement(0, count: pause))
        }
        return Array(samples.prefix(count))
    }

    /// A buffer of deinterleaved Float32 audio.
    static func buffer(_ channels: [[Float]], sampleRate: Double = 48_000) throws -> AVAudioPCMBuffer {
        try PCM.buffer(
            from: AudioSamples(channels: channels),
            format: PCM.floatFormat(sampleRate: sampleRate, channelCount: channels.count)
        )
    }

    /// The samples of a buffer's channels.
    static func channels(_ buffer: AVAudioPCMBuffer) -> [[Float]] {
        PCM.samples(from: buffer).channels
    }

    /// Splits each channel into buffers of a given size.
    static func buffers(_ channels: [[Float]], size: Int, sampleRate: Double = 48_000) throws -> [AVAudioPCMBuffer] {
        try stride(from: 0, to: channels[0].count, by: size).map { start in
            try buffer(channels.map { Array($0[start ..< min(start + size, $0.count)]) }, sampleRate: sampleRate)
        }
    }

    /// Collects a stream into one array for each channel, and checks that its pieces are in order.
    static func collect<Source: AsyncSequence>(
        _ stream: IsolationStream<Source>
    ) async throws -> (isolated: [[Float]], source: [[Float]], pieces: Int) {
        var isolated: [[Float]] = []
        var source: [[Float]] = []
        var pieces = 0
        for try await audio in stream {
            let piece = channels(audio.buffer)
            if isolated.isEmpty {
                isolated = Array(repeating: [], count: piece.count)
                source = isolated
            }
            guard Int(audio.framePosition) == isolated[0].count else {
                throw Failure.outOfOrder
            }
            for (index, values) in piece.enumerated() { isolated[index] += values }
            for (index, values) in channels(audio.source).enumerated() { source[index] += values }
            pieces += 1
        }
        return (isolated, source, pieces)
    }

    enum Failure: Error { case outOfOrder }

    /// A new directory for a test's files.
    static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "AnySoundIsolatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Writes channels to a file whose type comes from its extension.
    static func write(_ channels: [[Float]], to url: URL, sampleRate: Double = 48_000) throws {
        let buffer = try buffer(channels, sampleRate: sampleRate)
        let file = try AudioFile.create(url, format: buffer.format)
        try file.write(from: buffer)
        file.close()
    }

    /// Reads all of a file's channels.
    static func read(_ url: URL) async throws -> [[Float]] {
        var channels: [[Float]] = []
        for try await input in AudioFileBuffers(url: url) {
            let piece = self.channels(input.buffer)
            if channels.isEmpty { channels = Array(repeating: [], count: piece.count) }
            for (index, values) in piece.enumerated() { channels[index] += values }
        }
        return channels
    }

    /// The largest difference between two signals of the same length.
    static func maximumDifference(_ lhs: [Float], _ rhs: [Float]) -> Float {
        guard lhs.count == rhs.count else { return .infinity }
        return zip(lhs, rhs).reduce(0) { max($0, abs($1.0 - $1.1)) }
    }

    /// The root mean square of a signal.
    static func level(_ samples: [Float]) -> Float {
        var result: Float = 0
        vDSP_rmsqv(samples, 1, &result, vDSP_Length(samples.count))
        return result
    }
}

/// A sequence of inputs that a closure produces from buffers, for tests.
///
/// The closure does not have to be sendable, so it can hold audio buffers.
struct Buffers: AsyncSequence {
    typealias Element = AudioInput
    typealias Failure = any Error

    let produce: () throws -> AVAudioPCMBuffer?

    init(_ produce: @escaping () throws -> AVAudioPCMBuffer?) {
        self.produce = produce
    }

    init(_ buffers: [AVAudioPCMBuffer]) {
        var remaining = buffers[...]
        self.produce = { remaining.popFirst() }
    }

    func makeAsyncIterator() -> AsyncIterator { AsyncIterator(produce: produce) }

    struct AsyncIterator: AsyncIteratorProtocol {
        let produce: () throws -> AVAudioPCMBuffer?

        mutating func next(isolation actor: isolated (any Actor)? = #isolation) async throws -> AudioInput? {
            try produce().map { AudioInput(buffer: $0) }
        }
    }
}

/// Measures how far one signal is from another in time.
enum Alignment {
    /// Returns the delay of `signal` behind `reference`, in frames,
    /// from `-maximumLag` through `maximumLag`.
    /// A negative delay means that the signal is early.
    ///
    /// The search correlates the middle of the reference with the signal at each delay.
    static func lag(of signal: [Float], behind reference: [Float], maximumLag: Int = 6_000) -> Int {
        let count = min(signal.count, reference.count) - 2 * maximumLag
        precondition(count > 0, "The signals are too short for the search.")
        var best = -Float.infinity
        var bestLag = 0
        signal.withUnsafeBufferPointer { signal in
            reference.withUnsafeBufferPointer { reference in
                for lag in -maximumLag ... maximumLag {
                    var sum: Float = 0
                    vDSP_dotpr(
                        signal.baseAddress! + maximumLag + lag,
                        1,
                        reference.baseAddress! + maximumLag,
                        1,
                        &sum,
                        vDSP_Length(count)
                    )
                    if sum > best {
                        best = sum
                        bestLag = lag
                    }
                }
            }
        }
        return bestLag
    }
}

/// A stand-in engine with one channel at its own sample rate.
///
/// It returns its input multiplied by a gain, late by its latency,
/// and it holds frames back, so its output arrives in blocks as a windowed engine's does.
struct StandInModel: SoundIsolationModel {
    var sampleRate: Double? = nil
    var channelCount: Int? = 1
    var gain: Float = 0.5
    var latency = 0
    var blockSize = 1
    /// Frames to add to or remove from the end of the output.
    var extraFrames = 0
    var sounds: Set<SoundIsolator.Sound> = [.voice]
    var failure: (any Error & Sendable)? = nil
    /// Counts the executors that the model makes.
    var executors: Counter? = nil

    var availability: Availability<Never> { .available }
    var supportedSounds: Set<SoundIsolator.Sound> { sounds }

    func makeExecutor(for request: SoundIsolationRequest) async throws -> any SoundIsolationExecutor {
        if let failure { throw failure }
        await executors?.increment()
        return StandInExecutor(
            sampleRate: sampleRate ?? request.sampleRate,
            channelCount: channelCount ?? request.channelCount,
            latency: latency,
            gain: gain,
            blockSize: blockSize,
            extraFrames: extraFrames
        )
    }
}

actor StandInExecutor: SoundIsolationExecutor {
    nonisolated let sampleRate: Double
    nonisolated let channelCount: Int
    nonisolated let latency: Int
    private let gain: Float
    private let blockSize: Int
    private let extraFrames: Int
    private var held: AudioSamples

    init(sampleRate: Double, channelCount: Int, latency: Int, gain: Float, blockSize: Int, extraFrames: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.latency = latency
        self.gain = gain
        self.blockSize = blockSize
        self.extraFrames = extraFrames
        // The output starts with silence as long as the latency.
        self.held = AudioSamples(channelCount: channelCount, frameCount: latency)
    }

    func process(_ input: AudioSamples) -> AudioSamples {
        held.append(AudioSamples(channels: input.channels.map { channel in channel.map { $0 * gain } }))
        // Keep the frames that a short output leaves out, so that `finish` can drop them.
        let ready = max(0, held.frameCount + min(0, extraFrames))
        return held.removeFirst(ready / blockSize * blockSize)
    }

    func finish() -> AudioSamples {
        var rest = held.removeFirst(held.frameCount)
        rest.resize(to: max(0, rest.frameCount + extraFrames))
        return rest
    }
}
