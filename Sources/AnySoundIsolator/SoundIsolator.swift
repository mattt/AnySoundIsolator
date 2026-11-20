import AVFoundation
import Foundation

/// Isolates a sound, such as a voice, from a recording or a live stream.
///
/// Create an isolator with a model, which is the engine that does the work,
/// then give it a file, a buffer, or a sequence of buffers:
///
/// ```swift
/// let isolator = SoundIsolator()
/// try await isolator.isolate(contentsOf: recording, to: voice)
/// ```
///
/// Every model gives output with the same properties:
///
/// - The isolated sound has the input's sample rate, channel count, and number of frames.
/// - Frame `n` of the output corresponds to frame `n` of the input.
///   The isolator removes an engine's delay, so you never correct for it.
///
/// Because of this, the sound that the isolator removed is the input minus the output.
/// ``IsolatedAudio`` provides the removed background and a mix of the two.
///
/// An isolator is a value with no state.
/// You can use one isolator for many files and streams at the same time;
/// each has its own executor.
public struct SoundIsolator: Sendable {
    /// A kind of sound that a model can isolate.
    ///
    /// Voice is the only sound now.
    /// The type can gain values, such as music, without a change to the rest of the API.
    public struct Sound: RawRepresentable, Hashable, Sendable {
        /// The name of the sound, such as `voice`.
        public let rawValue: String

        /// Creates a sound from its name.
        ///
        /// - Parameter rawValue: The name of the sound.
        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        /// A person's voice, apart from noise, music, and other background sound.
        public static let voice = Sound(rawValue: "voice")
    }

    /// The engine that isolates the sound.
    public let model: any SoundIsolationModel

    /// The sound that the isolator keeps.
    public let sound: Sound

    /// Creates an isolator.
    ///
    /// Creating an isolator does not load a model or check that it supports the sound.
    /// An unsupported sound is an error when isolation starts.
    ///
    /// - Parameters:
    ///   - model: The engine to use. The default is the system's audio unit, which needs no download.
    ///   - sound: The sound to keep.
    public init(model: any SoundIsolationModel = SystemSoundIsolationModel(), isolating sound: Sound = .voice) {
        self.model = model
        self.sound = sound
    }

    /// Whether the model is ready to isolate sound.
    public var isAvailable: Bool { model.isAvailable }

    /// Returns a request that installs the model's assets,
    /// or `nil` when the model needs none or they are installed.
    ///
    /// Isolation never downloads.
    /// For a model with assets, call this method first and install what it asks for:
    ///
    /// ```swift
    /// if let request = try await isolator.assetInstallationRequest() {
    ///     try await request.downloadAndInstall()
    /// }
    /// ```
    ///
    /// - Throws: A ``SoundIsolationError`` when the model cannot run on this device.
    public func assetInstallationRequest() async throws -> AssetInstallationRequest? {
        do {
            return try await model.assetInstallationRequest()
        } catch {
            throw isolationError(error)
        }
    }

    // MARK: - Files

    /// Isolates the sound in an audio file and writes it to another file.
    ///
    /// The isolator reads and writes one block at a time, so the length of the file does not
    /// change the memory that it uses.
    /// The source can be any file that `AVAudioFile` reads.
    /// The destination's path extension selects its type:
    /// `wav` and `caf` hold Float32 samples and so hold the output exactly;
    /// `m4a` holds AAC, which is smaller and is not exact.
    /// An existing file at a destination is replaced.
    /// The source, the destination, and the background must be different files.
    /// If isolation fails or is cancelled, the isolator removes the files that it started.
    ///
    /// - Parameters:
    ///   - source: The location of the recording.
    ///   - destination: The location for the isolated sound.
    ///   - background: The location for the sound that was removed, or `nil` to not write it.
    ///     At each frame, the two files add up to the source.
    ///   - progress: A progress object to update.
    ///     The isolator sets its total to the number of frames in the source.
    /// - Throws: A ``SoundIsolationError``, or `CancellationError`.
    public func isolate(
        contentsOf source: URL,
        to destination: URL,
        background: URL? = nil,
        progress: Progress? = nil
    ) async throws {
        let destinations = [destination] + (background.map { [$0] } ?? [])
        let locations = ([source] + destinations).map(\.standardizedFileURL)
        guard Set(locations).count == locations.count else {
            throw SoundIsolationError.unsupportedConfiguration(
                "The source, the destination, and the background must be different files."
            )
        }
        let input = try AudioFile.open(source)
        let frameCount = input.length
        let format = input.processingFormat
        progress?.totalUnitCount = frameCount
        progress?.completedUnitCount = 0

        do {
            let isolatedFile = try AudioFile.create(destination, format: format)
            let backgroundFile = try background.map { try AudioFile.create($0, format: format) }
            // Close each file explicitly: a reference that is released late
            // can leave the file open with its header unwritten.
            defer {
                isolatedFile.close()
                backgroundFile?.close()
            }
            for try await audio in streamIsolation(contentsOf: source) {
                do {
                    try isolatedFile.write(from: audio.buffer)
                    try backgroundFile?.write(from: audio.background())
                } catch {
                    throw SoundIsolationError.backendFailure(underlying: error)
                }
                progress?.completedUnitCount = audio.framePosition + AVAudioFramePosition(audio.buffer.frameLength)
            }
        } catch {
            for url in destinations {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    /// Isolates the sound in a file and returns it in pieces while the file is processed.
    ///
    /// Use this method to play, show, or save the start of a long recording
    /// before the isolator reaches its end.
    ///
    /// - Parameter source: The location of a file that `AVAudioFile` reads.
    /// - Returns: A stream that reads the file when you iterate it.
    public func streamIsolation(contentsOf source: URL) -> IsolationStream<AudioFileBuffers> {
        streamIsolation(of: AudioFileBuffers(url: source))
    }

    // MARK: - Buffers

    /// Isolates the sound in a sequence of audio, such as live audio.
    ///
    /// The audio can be in any PCM format.
    /// Every input must have the same format, and each follows the one before it without a gap.
    /// Wrap each capture buffer in an ``AudioInput``, which copies it:
    ///
    /// ```swift
    /// let (buffers, input) = AsyncStream<AudioInput>.makeStream()
    /// // In the capture callback: input.yield(AudioInput(buffer: buffer))
    ///
    /// for try await audio in isolator.streamIsolation(of: buffers) {
    ///     await player.scheduleBuffer(audio.buffer)
    /// }
    /// ```
    ///
    /// - Parameter audio: The input, in order.
    /// - Returns: A stream that reads the input when you iterate it.
    public func streamIsolation<Source: AsyncSequence>(
        of audio: Source
    ) -> IsolationStream<Source> where Source.Element == AudioInput {
        IsolationStream(source: audio, model: model, sound: sound)
    }

    /// Isolates the sound in one buffer.
    ///
    /// Use this method for audio that is already in memory.
    /// The isolator reads the buffer before the method first suspends.
    /// For live audio, use ``streamIsolation(of:)``:
    /// separate calls to this method do not share an engine's state,
    /// so the output would be wrong at each boundary between buffers.
    ///
    /// - Parameters:
    ///   - buffer: Audio in any PCM format.
    ///   - actor: The actor that the caller runs on. Leave the default.
    /// - Returns: The isolated sound and the source, both as long as the buffer.
    /// - Throws: A ``SoundIsolationError``, or `CancellationError`.
    public func isolate(
        _ buffer: AVAudioPCMBuffer,
        isolation actor: isolated (any Actor)? = #isolation
    ) async throws -> IsolatedAudio {
        var intake = Intake()
        let samples = try intake.samples(from: buffer)
        let sampleRate = buffer.format.sampleRate
        let format = try PCM.floatFormat(matching: buffer.format)

        let pipeline = IsolationPipeline(model: model, sound: sound)
        var pieces = try await pipeline.process(samples, sampleRate: sampleRate)
        try Task.checkCancellation()
        pieces += try await pipeline.finish()

        var result = IsolatedSamples(
            isolated: AudioSamples(channelCount: samples.channelCount),
            source: AudioSamples(channelCount: samples.channelCount),
            position: 0
        )
        for piece in pieces {
            result.isolated.append(piece.isolated)
            result.source.append(piece.source)
        }
        return try IsolatedAudio(result, format: format)
    }
}
