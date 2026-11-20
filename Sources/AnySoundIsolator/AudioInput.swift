import AVFoundation

/// A piece of input for a stream: a copy of an audio buffer that can cross concurrency domains.
///
/// `AVAudioPCMBuffer` is not `Sendable`, and audio capture reuses its buffers,
/// so a capture callback cannot give a buffer to an `AsyncStream`.
/// Wrap the buffer first. The initializer copies the samples,
/// so the input does not change when the capture buffer does:
///
/// ```swift
/// let (buffers, input) = AsyncStream<AudioInput>.makeStream()
/// engine.inputNode.installTap(onBus: 0, bufferSize: 4_096, format: nil) { buffer, _ in
///     input.yield(AudioInput(buffer: buffer))
/// }
/// ```
///
/// The type has the role of `AnalyzerInput` in the Speech framework.
public struct AudioInput: @unchecked Sendable {
    /// The package's own copy of the audio.
    ///
    /// Do not change this buffer.
    public let buffer: AVAudioPCMBuffer

    /// Creates an input with a copy of a buffer's audio.
    ///
    /// - Parameter buffer: Audio in any PCM format. You can reuse the buffer afterward.
    public init(buffer: AVAudioPCMBuffer) {
        self.buffer = PCM.copy(of: buffer)
    }

    /// Wraps a buffer that the package made and that nothing else holds.
    init(owning buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
