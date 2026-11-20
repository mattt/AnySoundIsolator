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
/// When the input has more channels than the engine takes,
/// ``IsolationOptions/channelPolicy`` selects what the isolator does.
/// By default it isolates the sound in the average of the channels
/// and puts that one result in every channel of the output.
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
    /// The source, the destination, and the background must be different files,
    /// and a destination cannot be a directory.
    /// The isolator checks both destinations before it opens a file.
    ///
    /// The isolator writes each output to a temporary file in the destination's directory.
    /// When all the audio is written, it moves each temporary file to its destination,
    /// which replaces an existing file there.
    /// If isolation fails or is cancelled before that,
    /// the isolator removes the temporary files and leaves each destination as it was:
    /// an existing file keeps its content, and no new file appears.
    ///
    /// The two moves are separate steps.
    /// The isolator moves the background first and the isolated sound second.
    /// If the second move fails, the method throws,
    /// `destination` is as it was, and `background` holds its new content.
    ///
    /// - Parameters:
    ///   - source: The location of the recording.
    ///   - destination: The location for the isolated sound.
    ///   - background: The location for the sound that was removed, or `nil` to not write it.
    ///     At each frame, the two files add up to the source.
    ///   - options: Options for this file, such as the channel policy.
    ///   - progress: A progress object to update.
    ///     The isolator sets its total to the number of frames in the source.
    /// - Throws: A ``SoundIsolationError``, or `CancellationError`.
    public func isolate(
        contentsOf source: URL,
        to destination: URL,
        background: URL? = nil,
        options: IsolationOptions = IsolationOptions(),
        progress: Progress? = nil
    ) async throws {
        // Check every location before any file is opened or created.
        let isolatedLocation = try AudioFile.destination(destination)
        let backgroundLocation = try background.map { try AudioFile.destination($0) }
        let locations =
            [source.resolvingSymlinksInPath().standardizedFileURL, isolatedLocation]
            + (backgroundLocation.map { [$0] } ?? [])
        for (index, location) in locations.enumerated() {
            guard !locations[..<index].contains(where: { AudioFile.isSameFile($0, location) }) else {
                throw SoundIsolationError.unsupportedConfiguration(
                    "The source, the destination, and the background must be different files."
                )
            }
        }
        let input = try AudioFile.open(source)
        let frameCount = input.length
        let format = input.processingFormat
        progress?.totalUnitCount = frameCount
        progress?.completedUnitCount = 0

        var staged: [StagedAudioFile] = []
        do {
            let isolatedFile = try StagedAudioFile(destination: isolatedLocation, format: format)
            staged.append(isolatedFile)
            let backgroundFile = try backgroundLocation.map { try StagedAudioFile(destination: $0, format: format) }
            if let backgroundFile { staged.append(backgroundFile) }
            for try await audio in streamIsolation(contentsOf: source, options: options) {
                try isolatedFile.write(audio.buffer)
                try backgroundFile?.write(audio.background())
                progress?.completedUnitCount = audio.framePosition + AVAudioFramePosition(audio.buffer.frameLength)
            }
            try Task.checkCancellation()
            // Close each file before its move, so that its header is written.
            for file in staged { file.close() }
            // The background moves first, so a failure of either move leaves the destination as it was.
            for file in staged.reversed() { try file.replaceDestination() }
        } catch {
            for file in staged { file.discard() }
            throw error
        }
    }

    /// Isolates the sound in a file and returns it in pieces while the file is processed.
    ///
    /// Use this method to play, show, or save the start of a long recording
    /// before the isolator reaches its end.
    ///
    /// - Parameters:
    ///   - source: The location of a file that `AVAudioFile` reads.
    ///   - options: Options for this file, such as the channel policy.
    /// - Returns: A stream that reads the file when you iterate it.
    public func streamIsolation(
        contentsOf source: URL,
        options: IsolationOptions = IsolationOptions()
    ) -> IsolationStream<AudioFileBuffers> {
        streamIsolation(of: AudioFileBuffers(url: source), options: options)
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
    /// - Parameters:
    ///   - audio: The input, in order.
    ///   - options: Options for this stream, such as the channel policy.
    /// - Returns: A stream that reads the input when you iterate it.
    public func streamIsolation<Source: AsyncSequence>(
        of audio: Source,
        options: IsolationOptions = IsolationOptions()
    ) -> IsolationStream<Source> where Source.Element == AudioInput {
        IsolationStream(source: audio, model: model, sound: sound, options: options)
    }

    /// Isolates the sound in one buffer.
    ///
    /// Use this method for audio that is already in memory.
    /// The isolator reads the buffer before the method first suspends.
    /// For live audio, use ``streamIsolation(of:options:)``:
    /// separate calls to this method do not share an engine's state,
    /// so the output would be wrong at each boundary between buffers.
    ///
    /// - Parameters:
    ///   - buffer: Audio in any PCM format.
    ///   - options: Options for this buffer, such as the channel policy.
    ///   - actor: The actor that the caller runs on. Leave the default.
    /// - Returns: The isolated sound and the source, both as long as the buffer.
    /// - Throws: A ``SoundIsolationError``, or `CancellationError`.
    public func isolate(
        _ buffer: AVAudioPCMBuffer,
        options: IsolationOptions = IsolationOptions(),
        isolation actor: isolated (any Actor)? = #isolation
    ) async throws -> IsolatedAudio {
        var intake = Intake()
        let samples = try intake.samples(from: buffer)
        let sampleRate = buffer.format.sampleRate
        let format = try PCM.floatFormat(matching: buffer.format)

        let pipeline = IsolationPipeline(model: model, sound: sound, options: options)
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
