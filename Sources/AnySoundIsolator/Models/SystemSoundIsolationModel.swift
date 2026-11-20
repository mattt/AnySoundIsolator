import AVFoundation
import AudioToolbox

/// A model that isolates voice with the system's sound isolation audio unit.
///
/// The audio unit (`kAudioUnitSubType_AUSoundIsolation`) is part of the operating system,
/// so this model needs no download and runs offline.
/// On an Apple M4 Max, it processes a minute of mono audio in less than a second.
///
/// ```swift
/// let isolator = SoundIsolator(model: SystemSoundIsolationModel(quality: .standard))
/// ```
///
/// The model processes audio in the format that it arrives in:
///
/// - **Sample rate.** The audio unit runs at the input's sample rate.
///   The package tests 8, 16, 44.1, 48, and 96 kHz.
///   If the unit refuses a rate, isolation throws
///   ``SoundIsolationError/unsupportedConfiguration(_:)``.
/// - **Mono and stereo.** One or two channels go to the audio unit together.
///   The unit processes two channels jointly, so the left output depends on the right input.
/// - **More channels.** With three or more channels, the model takes one channel,
///   and ``IsolationOptions/channelPolicy`` applies:
///   by default the isolator averages the channels and isolates the voice once,
///   and with ``IsolationOptions/ChannelPolicy/perChannel``
///   each channel has its own audio unit.
///
/// The audio unit delays its output by about 93 ms in high quality and 56 ms in standard quality,
/// and by more for stereo.
/// The isolator removes the delay that the unit reports.
/// At a sample rate that does not divide 48,000, such as 44.1 kHz,
/// the delay is not a whole number of frames,
/// so the output can be off the input's timeline by less than one frame.
public struct SystemSoundIsolationModel: SoundIsolationModel {
    /// The voice isolation that the audio unit performs.
    public enum Quality: String, Sendable, CaseIterable {
        /// The audio unit's high-quality voice model, with a delay of about 93 ms.
        case high

        /// The audio unit's standard voice model, with a delay of about 56 ms.
        case standard

        var soundType: Int {
            switch self {
            case .high: kAUSoundIsolationSoundType_HighQualityVoice
            case .standard: kAUSoundIsolationSoundType_Voice
            }
        }
    }

    /// A reason for which the system model is unavailable.
    public enum UnavailableReason: Sendable, Hashable {
        /// The operating system has no sound isolation audio unit.
        case audioUnitNotFound
    }

    /// The voice isolation that the audio unit performs.
    public let quality: Quality

    /// Creates a model.
    ///
    /// - Parameter quality: The voice isolation to perform.
    public init(quality: Quality = .high) {
        self.quality = quality
    }

    /// Whether the operating system has the sound isolation audio unit.
    public var availability: Availability<UnavailableReason> {
        SoundIsolationUnit.isInstalled ? .available : .unavailable(.audioUnitNotFound)
    }

    /// Makes an executor that runs one audio unit at the input's sample rate.
    ///
    /// The executor takes the input's channels when there are one or two, and one channel otherwise.
    ///
    /// - Parameter request: The sound to isolate and the format of the input.
    /// - Throws: ``SoundIsolationError/unavailableModel(_:)`` when the system has no audio unit,
    ///   or ``SoundIsolationError/unsupportedConfiguration(_:)`` when the unit refuses the format.
    public func makeExecutor(for request: SoundIsolationRequest) async throws -> any SoundIsolationExecutor {
        guard SoundIsolationUnit.isInstalled else {
            throw SoundIsolationError.unavailableModel(
                "This system has no sound isolation audio unit."
            )
        }
        // The unit takes one or two channels. For more, the isolator applies its channel policy.
        return try SystemSoundIsolationExecutor(
            sampleRate: request.sampleRate,
            channelCount: request.channelCount <= 2 ? request.channelCount : 1,
            quality: quality
        )
    }
}

/// Runs one instance of the sound isolation audio unit for one stream.
actor SystemSoundIsolationExecutor: SoundIsolationExecutor {
    nonisolated let sampleRate: Double
    nonisolated let channelCount: Int
    nonisolated let latency: Int
    private let unit: SoundIsolationUnit

    /// Creates an executor.
    ///
    /// The mix is 100 percent isolated sound, because the package mixes the background itself.
    /// A test sets it to 0 to measure the unit's delay with the unprocessed input.
    init(
        sampleRate: Double,
        channelCount: Int,
        quality: SystemSoundIsolationModel.Quality,
        wetDryMixPercent: Float = 100
    ) throws {
        let unit = try SoundIsolationUnit(
            sampleRate: sampleRate,
            channelCount: channelCount,
            soundType: quality.soundType,
            wetDryMixPercent: wetDryMixPercent
        )
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.latency = unit.latency
        self.unit = unit
    }

    func process(_ input: AudioSamples) throws -> AudioSamples {
        try unit.render(input, frameCount: input.frameCount)
    }

    /// Renders silence until the unit has returned the frames that it delayed.
    func finish() throws -> AudioSamples {
        try unit.render(AudioSamples(channelCount: channelCount), frameCount: latency)
    }
}
