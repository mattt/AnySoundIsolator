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
        guard
            let copy = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: max(buffer.frameLength, 1)
            )
        else {
            preconditionFailure("An audio buffer could not be allocated.")
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        for (from, to) in zip(source, destination) {
            if let bytes = from.mData, let target = to.mData {
                target.copyMemory(from: bytes, byteCount: Int(min(from.mDataByteSize, to.mDataByteSize)))
            }
        }
        self.buffer = copy
    }

    /// Wraps a buffer that the package made and that nothing else holds.
    init(owning buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }
}
