import AVFoundation
import Accelerate
import CoreMedia

/// A piece of isolated sound, with the input frames that it came from.
///
/// ``buffer`` and ``source`` have the same format and the same number of frames,
/// and frame `n` of one corresponds to frame `n` of the other.
/// Both are deinterleaved Float32 audio with the input's sample rate and channel count.
///
/// Because the two buffers match frame for frame,
/// the sound that the isolator removed is ``source`` minus ``buffer``,
/// and a mix of the isolated sound with some of that background is a crossfade
/// between ``buffer`` and ``source``.
/// ``background()`` and ``mixed(backgroundLevel:)`` compute them.
///
/// These relations hold in every channel, whatever the ``IsolationOptions/channelPolicy``.
/// After a downmix, ``buffer`` has the same samples in every channel,
/// and the background keeps the differences between the channels of ``source``.
///
/// The package makes the buffers and does not change them afterward.
/// Do not change them if you share the value between tasks.
public struct IsolatedAudio: @unchecked Sendable {
    /// The isolated sound.
    public let buffer: AVAudioPCMBuffer

    /// The frames of the input that ``buffer`` was isolated from.
    public let source: AVAudioPCMBuffer

    /// The position of the first frame on the input's timeline,
    /// counted in frames from the start of the stream or file.
    public let framePosition: AVAudioFramePosition

    /// Creates a piece of isolated sound.
    ///
    /// - Parameters:
    ///   - buffer: The isolated sound, as deinterleaved Float32 audio.
    ///   - source: The input frames, in the same format and with the same length.
    ///   - framePosition: The position of the first frame on the input's timeline.
    public init(buffer: AVAudioPCMBuffer, source: AVAudioPCMBuffer, framePosition: AVAudioFramePosition) {
        precondition(
            buffer.frameLength == source.frameLength && buffer.format.channelCount == source.format.channelCount,
            "The isolated sound and its source must have the same length and channel count."
        )
        precondition(
            buffer.floatChannelData != nil && source.floatChannelData != nil,
            "The buffers must hold Float32 samples."
        )
        self.buffer = buffer
        self.source = source
        self.framePosition = framePosition
    }

    /// The time range of this piece on the input's timeline.
    public var timeRange: CMTimeRange {
        let timescale = CMTimeScale(buffer.format.sampleRate.rounded())
        return CMTimeRange(
            start: CMTime(value: framePosition, timescale: timescale),
            duration: CMTime(value: CMTimeValue(buffer.frameLength), timescale: timescale)
        )
    }

    /// Returns the sound that the isolator removed, which is the source minus the isolated sound.
    ///
    /// - Returns: A new buffer in the format of ``buffer``.
    public func background() -> AVAudioPCMBuffer {
        mixed(backgroundLevel: 1, isolatedLevel: 0)
    }

    /// Returns the isolated sound with some of the background mixed back in.
    ///
    /// A level of 0 gives the isolated sound alone, and a level of 1 gives the source.
    /// The result is `(1 - level) * buffer + level * source`.
    ///
    /// - Parameter backgroundLevel: The gain of the background, from 0 through 1.
    /// - Returns: A new buffer in the format of ``buffer``.
    public func mixed(backgroundLevel: Float) -> AVAudioPCMBuffer {
        mixed(backgroundLevel: backgroundLevel, isolatedLevel: 1)
    }

    /// Returns `isolatedLevel * buffer + backgroundLevel * (source - buffer)`.
    private func mixed(backgroundLevel: Float, isolatedLevel: Float) -> AVAudioPCMBuffer {
        let frameCount = vDSP_Length(buffer.frameLength)
        guard
            let result = AVAudioPCMBuffer(
                pcmFormat: buffer.format,
                frameCapacity: max(buffer.frameLength, 1)
            ),
            let isolated = buffer.floatChannelData,
            let original = source.floatChannelData,
            let output = result.floatChannelData
        else {
            preconditionFailure("An audio buffer could not be allocated.")
        }
        result.frameLength = buffer.frameLength
        var sourceGain = backgroundLevel
        var isolatedGain = isolatedLevel - backgroundLevel
        for channel in 0 ..< Int(buffer.format.channelCount) {
            vDSP_vsmsma(
                original[channel],
                1,
                &sourceGain,
                isolated[channel],
                1,
                &isolatedGain,
                output[channel],
                1,
                frameCount
            )
        }
        return result
    }
}
