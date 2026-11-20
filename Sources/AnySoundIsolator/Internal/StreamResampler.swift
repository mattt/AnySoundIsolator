import AVFoundation

/// Changes the sample rate of a stream of audio, one piece at a time.
///
/// The output starts at the same instant as the input.
/// The converter keeps some frames until it has the input that follows them,
/// so the output of one call can be shorter than its input;
/// ``finish()`` returns the frames that remain.
///
/// `AVAssetReader` can also resample,
/// but in the spike that this package comes from,
/// its output length varied between runs on the same file.
/// `AVAudioConverter` gave the same length every time.
final class StreamResampler {
    /// The largest number of frames that one call to the converter returns.
    /// The converter is called again while it has more, so a large ratio of the rates needs no large buffer.
    private static let maximumBlock = 65_536.0

    private let converter: AVAudioConverter
    private let inputFormat: AVAudioFormat
    private let outputFormat: AVAudioFormat

    init(from inputRate: Double, to outputRate: Double, channelCount: Int) throws {
        inputFormat = try PCM.floatFormat(sampleRate: inputRate, channelCount: channelCount)
        outputFormat = try PCM.floatFormat(sampleRate: outputRate, channelCount: channelCount)
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw SoundIsolationError.unsupportedConfiguration(
                "Audio at \(inputRate) Hz cannot be resampled to \(outputRate) Hz."
            )
        }
        converter.sampleRateConverterQuality = AVAudioQuality.max.rawValue
        self.converter = converter
    }

    /// Resamples the next piece of the stream.
    func convert(_ input: AudioSamples) throws -> AudioSamples {
        guard input.frameCount > 0 else { return AudioSamples(channelCount: input.channelCount) }
        return try run(PCM.buffer(from: input, format: inputFormat), endOfStream: false)
    }

    /// Returns the frames that the converter kept.
    func finish() throws -> AudioSamples {
        try run(nil, endOfStream: true)
    }

    private func run(_ buffer: AVAudioPCMBuffer?, endOfStream: Bool) throws -> AudioSamples {
        let ratio = outputFormat.sampleRate / inputFormat.sampleRate
        let expected = (Double(buffer?.frameLength ?? 0) * ratio).rounded(.up)
        let capacity = AVAudioFrameCount(min(max(4096, expected + 64), Self.maximumBlock))
        var pending = buffer
        var output = AudioSamples(channelCount: Int(outputFormat.channelCount))
        while true {
            guard let chunk = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
                throw SoundIsolationError.invalidAudio("An audio buffer could not be allocated.")
            }
            var error: NSError?
            let status = converter.convert(to: chunk, error: &error) { _, inputStatus in
                if let next = pending {
                    pending = nil
                    inputStatus.pointee = .haveData
                    return next
                }
                inputStatus.pointee = endOfStream ? .endOfStream : .noDataNow
                return nil
            }
            if let error { throw SoundIsolationError.backendFailure(underlying: error) }
            output.append(PCM.samples(from: chunk))
            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                return output
            case .error:
                throw SoundIsolationError.invalidAudio("The audio could not be resampled.")
            @unknown default:
                throw SoundIsolationError.invalidAudio("The audio could not be resampled.")
            }
        }
    }
}
