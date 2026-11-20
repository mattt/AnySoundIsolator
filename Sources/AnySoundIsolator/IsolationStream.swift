import AVFoundation

/// Isolated sound that arrives while the isolator reads a sequence of buffers.
///
/// ``SoundIsolator/streamIsolation(of:)`` and ``SoundIsolator/streamIsolation(contentsOf:)``
/// return this type.
/// The stream does no work until you iterate it.
/// Each iteration reads the source from its start with a new executor,
/// and the stream reads one source buffer only when it needs more input,
/// so a slow consumer slows the source and nothing accumulates.
///
/// Across all of its elements, the stream delivers exactly as many frames as the source,
/// in order and without gaps.
/// The boundaries between elements are not the boundaries between source buffers:
/// an engine with latency returns the first frames late, and the rest after the source ends.
///
/// To stop early, stop iterating or cancel the task.
/// An error from the source ends the stream with that error.
public struct IsolationStream<Source: AsyncSequence>: AsyncSequence
where Source.Element == AVAudioPCMBuffer {
    public typealias Element = IsolatedAudio
    public typealias Failure = any Error

    let source: Source
    let model: any SoundIsolationModel
    let sound: SoundIsolator.Sound

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            source: source.makeAsyncIterator(),
            pipeline: IsolationPipeline(model: model, sound: sound)
        )
    }

    /// Reads the source and returns isolated sound as it becomes ready.
    public struct AsyncIterator: AsyncIteratorProtocol {
        private var source: Source.AsyncIterator
        private let pipeline: IsolationPipeline
        private var intake = Intake()
        private var ready: [IsolatedSamples] = []
        private var isFinished = false

        init(source: Source.AsyncIterator, pipeline: IsolationPipeline) {
            self.source = source
            self.pipeline = pipeline
        }

        public mutating func next(
            isolation actor: isolated (any Actor)? = #isolation
        ) async throws -> IsolatedAudio? {
            while ready.isEmpty {
                guard !isFinished else { return nil }
                try Task.checkCancellation()
                if let buffer = try await source.next(isolation: actor) {
                    // Copy the samples before the next suspension; the caller can reuse the buffer.
                    let samples = try intake.samples(from: buffer)
                    let sampleRate = buffer.format.sampleRate
                    ready = try await pipeline.process(samples, sampleRate: sampleRate)
                } else {
                    isFinished = true
                    ready = try await pipeline.finish()
                }
            }
            guard let format = intake.format else { return nil }
            return try IsolatedAudio(ready.removeFirst(), format: format)
        }
    }
}

extension IsolationStream: Sendable where Source: Sendable {}

extension IsolatedAudio {
    /// Makes buffers from samples in a deinterleaved Float32 format.
    init(_ samples: IsolatedSamples, format: AVAudioFormat) throws {
        self.init(
            buffer: try PCM.buffer(from: samples.isolated, format: format),
            source: try PCM.buffer(from: samples.source, format: format),
            framePosition: AVAudioFramePosition(samples.position)
        )
    }
}
