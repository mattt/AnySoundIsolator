import AVFoundation

/// The audio of a file as a sequence of inputs for a stream.
///
/// The sequence opens the file when iteration starts and reads it one block at a time,
/// so a long recording is never in memory all at once.
/// Each input is deinterleaved Float32 audio at the file's sample rate and channel count.
/// The sequence reads the types that `AVAudioFile` reads.
public struct AudioFileBuffers: AsyncSequence, Sendable {
    /// A block of the file's audio.
    public typealias Element = AudioInput

    /// An error from reading the file, or `CancellationError`.
    public typealias Failure = any Error

    /// The location of the file.
    public let url: URL

    /// The largest number of frames in one input.
    public let blockSize: AVAudioFrameCount

    /// Creates a sequence of a file's audio.
    ///
    /// - Parameters:
    ///   - url: The location of an audio file.
    ///   - blockSize: The largest number of frames in one input.
    public init(url: URL, blockSize: AVAudioFrameCount = 32_768) {
        precondition(blockSize > 0, "The block size must be positive.")
        self.url = url
        self.blockSize = blockSize
    }

    /// Creates an iterator that opens the file and reads it from its start.
    public func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(url: url, blockSize: blockSize)
    }

    /// Reads the file one block at a time.
    ///
    /// After the end of the file or an error, the iterator closes the file,
    /// and each later call to ``next(isolation:)`` returns `nil`.
    public struct AsyncIterator: AsyncIteratorProtocol {
        let url: URL
        let blockSize: AVAudioFrameCount
        private var file: AVAudioFile?
        private var isFinished = false

        init(url: URL, blockSize: AVAudioFrameCount) {
            self.url = url
            self.blockSize = blockSize
        }

        /// Reads the next block of the file.
        ///
        /// - Parameter actor: The actor that the caller runs on.
        /// - Returns: The next block, or `nil` at the end of the file and after an error.
        /// - Throws: ``SoundIsolationError/invalidAudio(_:)`` when the file cannot be read
        ///   or ends before the number of frames that it states, or `CancellationError`.
        public mutating func next(
            isolation actor: isolated (any Actor)? = #isolation
        ) async throws -> AudioInput? {
            guard !isFinished else { return nil }
            do {
                let input = try read()
                if input == nil { finish() }
                return input
            } catch {
                finish()
                throw error
            }
        }

        /// Ends the iteration and closes the file.
        private mutating func finish() {
            isFinished = true
            file = nil
        }

        /// Reads the next block, or returns `nil` at the end of the file.
        private mutating func read() throws -> AudioInput? {
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
            // The file states more frames than this read reached.
            // To end the stream here would report a short output as a success.
            guard buffer.frameLength > 0 else {
                throw SoundIsolationError.invalidAudio(
                    "\(url.lastPathComponent) ended after \(file.framePosition) of its \(file.length) frames."
                )
            }
            return AudioInput(owning: buffer)
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

    /// The path extensions of the file types that the isolator writes.
    static let writableExtensions: Set<String> = ["wav", "caf", "m4a"]

    /// Checks a destination before any file is opened,
    /// and returns the location that the output replaces.
    ///
    /// The location has its symbolic links resolved,
    /// so output through a link replaces the file that the link names and keeps the link.
    static func destination(_ url: URL) throws -> URL {
        guard url.isFileURL, writableExtensions.contains(url.pathExtension.lowercased()) else {
            throw SoundIsolationError.unsupportedConfiguration(
                "\(url.lastPathComponent) must have the extension wav, caf, or m4a."
            )
        }
        let location = url.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: location.path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw SoundIsolationError.unsupportedConfiguration(
                "\(url.lastPathComponent) is a directory."
            )
        }
        return location
    }

    /// Whether two locations name one file.
    ///
    /// Two different paths name one file when one is a hard link to the other,
    /// or when the file system ignores a difference between them, such as case.
    /// The second rule also applies when neither file exists yet:
    /// `Voice.wav` and `voice.wav` in one directory are one file on a volume that ignores case,
    /// so the second move would replace the first.
    static func isSameFile(_ first: URL, _ second: URL) -> Bool {
        if first == second || first.path == second.path { return true }
        if let firstIdentity = identity(of: first), let secondIdentity = identity(of: second) {
            return firstIdentity == secondIdentity
        }
        // A file is absent, so compare the directories and the names.
        let directory = first.deletingLastPathComponent()
        guard let directoryIdentity = identity(of: directory),
            directoryIdentity == identity(of: second.deletingLastPathComponent())
        else { return false }
        // Swift compares strings by canonical equivalence, as APFS and HFS+ compare names.
        // On a volume that compares the bytes of names, this refuses two names that would be two files.
        let (firstName, secondName) = (first.lastPathComponent, second.lastPathComponent)
        if firstName == secondName { return true }
        // When the volume does not say, the check assumes that it ignores case, as macOS volumes do by default.
        let isCaseSensitive =
            (try? directory.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames ?? false
        return !isCaseSensitive
            && firstName.folding(options: .caseInsensitive, locale: nil)
                == secondName.folding(options: .caseInsensitive, locale: nil)
    }

    /// The device and the inode of a file.
    private struct Identity: Equatable {
        let device: dev_t
        let inode: ino_t
    }

    /// The identity of a file, or `nil` when the file does not exist.
    private static func identity(of url: URL) -> Identity? {
        var status = stat()
        guard stat(url.path, &status) == 0 else { return nil }
        return Identity(device: status.st_dev, inode: status.st_ino)
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

/// An output file that is written next to its destination and moved there after success.
///
/// Until the move, the destination is not opened or changed,
/// so a failure cannot damage a file that was there before.
struct StagedAudioFile {
    /// The location that the finished file replaces.
    let destination: URL
    /// The location of the file while it is written.
    ///
    /// It is in the destination's directory, so the move stays on one volume and is atomic.
    /// It keeps the destination's extension, which selects the file type.
    let temporary: URL
    private let file: AVAudioFile

    init(destination: URL, format: AVAudioFormat) throws {
        self.destination = destination
        let name = ".\(destination.deletingPathExtension().lastPathComponent).\(UUID().uuidString)"
        self.temporary = destination.deletingLastPathComponent()
            .appending(path: name)
            .appendingPathExtension(destination.pathExtension)
        do {
            self.file = try AudioFile.create(temporary, format: format)
        } catch {
            // A failed creation can leave an empty file.
            try? FileManager.default.removeItem(at: temporary)
            throw error
        }
    }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        do {
            try file.write(from: buffer)
        } catch {
            throw SoundIsolationError.backendFailure(underlying: error)
        }
    }

    /// Closes the file explicitly: a reference that is released late
    /// can leave the file open with its header unwritten.
    func close() {
        file.close()
    }

    /// Moves the closed file to its destination, which replaces a file that is there.
    func replaceDestination() throws {
        guard rename(temporary.path, destination.path) == 0 else {
            throw SoundIsolationError.backendFailure(
                underlying: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            )
        }
    }

    /// Closes and removes the temporary file. The destination does not change.
    func discard() {
        file.close()
        try? FileManager.default.removeItem(at: temporary)
    }
}
