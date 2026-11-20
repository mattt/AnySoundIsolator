import AVFoundation

/// Conversions between audio buffers and ``AudioSamples``.
enum PCM {
    /// Returns the deinterleaved Float32 format with the sample rate, channel count,
    /// and channel layout of another format.
    static func floatFormat(matching format: AVAudioFormat) throws -> AVAudioFormat {
        let channelCount = format.channelCount
        guard format.sampleRate.isFinite, format.sampleRate > 0, channelCount > 0 else {
            throw SoundIsolationError.invalidAudio(
                "The audio must have a channel and a positive sample rate."
            )
        }
        if channelCount <= 2,
            let float = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: format.sampleRate,
                channels: channelCount,
                interleaved: false
            )
        {
            return float
        }
        guard
            let layout = format.channelLayout
                ?? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | channelCount)
        else {
            throw SoundIsolationError.invalidAudio(
                "The audio has \(channelCount) channels and no channel layout."
            )
        }
        return AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: format.sampleRate,
            interleaved: false,
            channelLayout: layout
        )
    }

    /// The largest channel count of a format, which is the largest count of a discrete channel layout.
    static let maximumChannelCount = 0xFFFF

    /// The largest sample rate of a format, in hertz.
    /// It is far above any rate of real audio, and it keeps frame counts and time scales in range.
    static let maximumSampleRate = 16_777_216.0

    /// Returns the deinterleaved Float32 format for a sample rate and a channel count.
    ///
    /// The values can come from a caller's request or from an engine,
    /// so the method checks them before it converts them to unsigned integers.
    static func floatFormat(sampleRate: Double, channelCount: Int) throws -> AVAudioFormat {
        guard sampleRate.isFinite, sampleRate > 0, sampleRate <= maximumSampleRate,
            (1 ... maximumChannelCount).contains(channelCount)
        else {
            throw SoundIsolationError.invalidAudio(
                "The audio must have a channel and a positive sample rate; "
                    + "it has \(channelCount) channels at \(sampleRate) Hz."
            )
        }
        var description = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: 32,
            mReserved: 0
        )
        let layout =
            channelCount > 2
            ? AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_DiscreteInOrder | UInt32(channelCount))
            : nil
        guard let format = AVAudioFormat(streamDescription: &description, channelLayout: layout) else {
            throw SoundIsolationError.invalidAudio(
                "The audio must have a channel and a positive sample rate."
            )
        }
        return format
    }

    /// Returns a new buffer with a copy of a buffer's audio, in any PCM format.
    static func copy(of buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
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
        return copy
    }

    /// Copies the samples of a deinterleaved Float32 buffer.
    static func samples(from buffer: AVAudioPCMBuffer) -> AudioSamples {
        let frameCount = Int(buffer.frameLength)
        guard let data = buffer.floatChannelData else {
            return AudioSamples(channelCount: Int(buffer.format.channelCount))
        }
        return AudioSamples(
            channels: (0 ..< Int(buffer.format.channelCount)).map { channel in
                Array(UnsafeBufferPointer(start: data[channel], count: frameCount))
            }
        )
    }

    /// Makes a deinterleaved Float32 buffer that holds a copy of samples.
    static func buffer(from samples: AudioSamples, format: AVAudioFormat) throws -> AVAudioPCMBuffer {
        let frameCount = samples.frameCount
        guard samples.hasEqualChannelLengths, frameCount <= Int(Int32.max) else {
            throw SoundIsolationError.invalidResult(
                "The audio has channels with \(samples.channels.map(\.count)) samples."
            )
        }
        guard samples.channelCount == Int(format.channelCount),
            let buffer = AVAudioPCMBuffer(
                pcmFormat: format,
                frameCapacity: AVAudioFrameCount(max(frameCount, 1))
            ),
            let data = buffer.floatChannelData
        else {
            throw SoundIsolationError.invalidAudio("An audio buffer could not be allocated.")
        }
        for (channel, values) in samples.channels.enumerated() {
            values.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    data[channel].update(from: base, count: frameCount)
                }
            }
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        return buffer
    }
}

/// Reads the buffers of one stream as deinterleaved Float32 samples.
///
/// A stream has one format; a buffer in another format is an error.
struct Intake {
    /// The deinterleaved Float32 format of the stream, known after the first buffer.
    private(set) var format: AVAudioFormat?
    private var sourceFormat: AVAudioFormat?
    private var converter: AVAudioConverter?

    /// Copies a buffer's samples, converting the sample format if needed.
    mutating func samples(from buffer: AVAudioPCMBuffer) throws -> AudioSamples {
        let format = try configure(for: buffer.format)
        guard let converter else { return PCM.samples(from: buffer) }
        guard buffer.frameLength > 0 else {
            return AudioSamples(channelCount: Int(format.channelCount))
        }
        guard let converted = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: buffer.frameLength) else {
            throw SoundIsolationError.invalidAudio("An audio buffer could not be allocated.")
        }
        do {
            try converter.convert(to: converted, from: buffer)
        } catch {
            throw SoundIsolationError.backendFailure(underlying: error)
        }
        return PCM.samples(from: converted)
    }

    private mutating func configure(for source: AVAudioFormat) throws -> AVAudioFormat {
        if let format, let sourceFormat {
            guard sourceFormat.isEqual(source) else {
                throw SoundIsolationError.invalidAudio(
                    "The format of the input changed during the stream."
                )
            }
            return format
        }
        let float = try PCM.floatFormat(matching: source)
        if source.commonFormat != .pcmFormatFloat32 || source.isInterleaved {
            guard let converter = AVAudioConverter(from: source, to: float) else {
                throw SoundIsolationError.invalidAudio(
                    "The input's sample format cannot be converted to Float32."
                )
            }
            self.converter = converter
        }
        sourceFormat = source
        format = float
        return float
    }
}
