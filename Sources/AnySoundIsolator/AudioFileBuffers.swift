import AVFoundation

/// The audio of a file as a sequence of buffers.
///
/// The sequence opens the file when iteration starts and reads it one block at a time,
/// so a long recording is never in memory all at once.
/// Each buffer is deinterleaved Float32 audio at the file's sample rate and channel count.
/// The sequence reads the types that `AVAudioFile` reads.
public struct AudioFileBuffers: AsyncSequence, Sendable {
    public typealias Element = AVAudioPCMBuffer
    public typealias Failure = any Error

    /// The location of the file.
    public let url: URL

    /// The largest number of frames in one buffer.
    public let blockSize: AVAudioFrameCount

    /// Creates a sequence of a file's audio.
    ///
    /// - Parameters:
    ///   - url: The location of an audio file.
    ///   - blockSize: The largest number of frames in one buffer.
    public init(url: URL, blockSize: AVAudioFrameCount = 32_768) {
        precondition(blockSize > 0, "The block size must be positive.")
        self.url = url
        self.blockSize = blockSize
    }

    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(url: url, blockSize: blockSize)
    }

    /// Reads the file one block at a time.
    public struct AsyncIterator: AsyncIteratorProtocol {
        let url: URL
        let blockSize: AVAudioFrameCount
        private var file: AVAudioFile?

        init(url: URL, blockSize: AVAudioFrameCount) {
            self.url = url
            self.blockSize = blockSize
        }

        public mutating func next(
            isolation actor: isolated (any Actor)? = #isolation
        ) async throws -> AVAudioPCMBuffer? {
            try Task.checkCancellation()
            let file = try self.file ?? AudioFile.open(url)
            self.file = file
            // One read can return fewer frames than the block size before the end of the file,
            // so the end is the file's length, not a short read.
            guard file.framePosition < file.length else { return nil }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: blockSize) else {
                throw SoundIsolationError.invalidAudio("An audio buffer could not be allocated.")
            }
            do {
                try file.read(into: buffer, frameCount: blockSize)
            } catch {
                throw SoundIsolationError.invalidAudio(
                    "\(url.lastPathComponent) could not be read: \(error.localizedDescription)"
                )
            }
            return buffer.frameLength > 0 ? buffer : nil
        }
    }
}

/// Opens audio files for reading and writing.
enum AudioFile {
    /// Opens a file for reading as deinterleaved Float32 audio.
    static func open(_ url: URL) throws -> AVAudioFile {
        do {
            return try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            throw SoundIsolationError.invalidAudio(
                "\(url.lastPathComponent) could not be opened as audio: \(error.localizedDescription)"
            )
        }
    }

    /// Creates a file whose type comes from the path extension of its location.
    ///
    /// WAV and CAF files hold Float32 samples, so they hold the isolator's output exactly.
    /// An M4A file holds AAC, which is smaller and not exact.
    static func create(_ url: URL, format: AVAudioFormat) throws -> AVAudioFile {
        var settings: [String: Any] = [
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
        ]
        switch url.pathExtension.lowercased() {
        case "wav", "caf":
            settings[AVFormatIDKey] = kAudioFormatLinearPCM
            settings[AVLinearPCMBitDepthKey] = 32
            settings[AVLinearPCMIsFloatKey] = true
            settings[AVLinearPCMIsBigEndianKey] = false
            settings[AVLinearPCMIsNonInterleaved] = false
        case "m4a":
            settings[AVFormatIDKey] = kAudioFormatMPEG4AAC
        default:
            throw SoundIsolationError.unsupportedConfiguration(
                "\(url.lastPathComponent) must have the extension wav, caf, or m4a."
            )
        }
        do {
            return try AVAudioFile(
                forWriting: url,
                settings: settings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
        } catch {
            throw SoundIsolationError.backendFailure(underlying: error)
        }
    }
}
