import AVFoundation

/// Isolated sound that arrives while the isolator reads a sequence of audio.
///
/// ``SoundIsolator/streamIsolation(of:options:)`` and
/// ``SoundIsolator/streamIsolation(contentsOf:options:)``
/// return this type.
/// The stream does no work until you iterate it.
/// Each iteration reads the source from its start with a new executor,
/// and the stream reads one piece of the source only when it needs more input,
/// so a slow consumer slows the source and nothing accumulates.
///
/// Across all of its elements, the stream delivers exactly as many frames as the source,
/// in order and without gaps.
/// The boundaries between elements are not the boundaries between pieces of the source:
/// an engine with latency returns the first frames late, and the rest after the source ends.
///
/// To stop early, stop iterating or cancel the task.
/// A cancelled stream throws `CancellationError`,
/// also when its source ends without an error because the task is cancelled, as `AsyncStream` does.
/// An error from the source ends the stream with that error.
/// An error is the end of the stream: the iterator returns `nil` afterward
/// and does not give the engine the audio that it had not processed.
public struct IsolationStream<Source: AsyncSequence>: AsyncSequence
where Source.Element == AudioInput {
    /// A piece of isolated sound with the input frames that it came from.
    public typealias Element = IsolatedAudio

    /// A ``SoundIsolationError``, an error from the source, or `CancellationError`.
    public typealias Failure = any Error

    let source: Source
    let model: any SoundIsolationModel
    let sound: SoundIsolator.Sound
    let options: IsolationOptions

    /// Creates an iterator with a new executor that reads the source from its start.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(
            source: source.makeAsyncIterator(),
            pipeline: IsolationPipeline(model: model, sound: sound, options: options)
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

        /// Reads the source until some isolated sound is ready, and returns it.
        ///
        /// - Parameter actor: The actor that the caller runs on.
        /// - Returns: The next piece of isolated sound, or `nil` after the last one or after an error.
        /// - Throws: A ``SoundIsolationError``, an error from the source, or `CancellationError`.
        public mutating func next(
            isolation actor: isolated (any Actor)? = #isolation
        ) async throws -> IsolatedAudio? {
            do {
                while ready.isEmpty {
                    guard !isFinished else { return nil }
                    try Task.checkCancellation()
                    let input = try await source.next(isolation: actor)
                    // A source such as `AsyncStream` returns `nil` when its task is cancelled.
                    // That is not the end of the input, so do not flush the engine.
                    try Task.checkCancellation()
                    if let input {
                        let samples = try intake.samples(from: input.buffer)
                        let sampleRate = input.buffer.format.sampleRate
                        ready = try await pipeline.process(samples, sampleRate: sampleRate)
                    } else {
                        isFinished = true
                        ready = try await pipeline.finish()
                    }
                }
                // The engine can take a long time, so check again before delivery.
                try Task.checkCancellation()
                guard let format = intake.format else { return nil }
                return try IsolatedAudio(ready.removeFirst(), format: format)
            } catch {
                // A failure is the end of the stream.
                isFinished = true
                ready = []
                throw error
            }
        }
    }
}

extension IsolationStream: Sendable where Source: Sendable {}

extension IsolatedAudio {
    /// Makes buffers from samples in a deinterleaved Float32 format.
    init(_ samples: IsolatedSamples, format: AVAudioFormat) throws {
        self.init(
            owning: try PCM.buffer(from: samples.isolated, format: format),
            source: try PCM.buffer(from: samples.source, format: format),
            framePosition: AVAudioFramePosition(samples.position)
        )
    }
}
