/// A type that describes a sound isolation engine and makes an executor for each stream.
///
/// A ``SoundIsolator`` works with any conforming type.
/// The package has ``SystemSoundIsolationModel``,
/// and with the `MLX` package trait it has `InworldSoundIsolationModel`, which downloads its weights.
/// Your own model conforms in the same way, whether it runs on the device or calls a hosted service:
///
/// - A model that needs files reports them in ``availability``
///   and returns a request from ``assetInstallationRequest()``.
///   It never downloads in ``makeExecutor(for:)``.
/// - A model for a hosted service keeps its credentials and its `URLSession`,
///   and its executor sends audio in ``SoundIsolationExecutor/process(_:)``.
///
/// A model is a value that is cheap to create.
/// Creating a model does not load weights or use the network.
public protocol SoundIsolationModel: Sendable {
    /// The reasons for which this model can be unavailable.
    associatedtype UnavailableReason

    /// Whether the model is ready to isolate sound.
    var availability: Availability<UnavailableReason> { get }

    /// The sounds that the model can isolate.
    ///
    /// The default is voice only.
    var supportedSounds: Set<SoundIsolator.Sound> { get }

    /// Returns a request that installs the model's assets,
    /// or `nil` when the model needs none or they are installed.
    ///
    /// The default implementation returns `nil`.
    ///
    /// - Throws: A ``SoundIsolationError`` when the model cannot run on this device.
    func assetInstallationRequest() async throws -> AssetInstallationRequest?

    /// Makes an executor for one stream of audio.
    ///
    /// The executor chooses the sample rate and channel count that it works in.
    /// If they differ from the request, the isolator converts the audio.
    /// It resamples to and from the executor's rate.
    /// When the executor takes one channel and the input has more,
    /// ``IsolationOptions/channelPolicy`` decides what the executor receives:
    /// the average of the channels, which is the default,
    /// or one channel, in which case the isolator calls this method once for each channel.
    /// An executor never sees which of the two it serves.
    ///
    /// - Parameter request: The sound to isolate and the format of the input.
    /// - Returns: An executor with no audio in it.
    /// - Throws: A ``SoundIsolationError`` when the model cannot serve the request.
    func makeExecutor(for request: SoundIsolationRequest) async throws -> any SoundIsolationExecutor
}

extension SoundIsolationModel {
    /// Voice only.
    public var supportedSounds: Set<SoundIsolator.Sound> { [.voice] }

    /// Returns `nil`, for a model that needs no assets.
    public func assetInstallationRequest() async throws -> AssetInstallationRequest? { nil }

    /// Whether the model is ready to isolate sound.
    public var isAvailable: Bool {
        if case .available = availability {
            return true
        } else {
            return false
        }
    }
}

/// The sound to isolate and the format of the audio that a stream supplies.
public struct SoundIsolationRequest: Sendable, Hashable {
    /// The sound to isolate.
    public var sound: SoundIsolator.Sound

    /// The sample rate of the input, in hertz.
    public var sampleRate: Double

    /// The number of channels in the input.
    public var channelCount: Int

    /// Creates a request.
    ///
    /// - Parameters:
    ///   - sound: The sound to isolate.
    ///   - sampleRate: The sample rate of the input, in hertz.
    ///   - channelCount: The number of channels in the input.
    public init(sound: SoundIsolator.Sound, sampleRate: Double, channelCount: Int) {
        self.sound = sound
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}

/// A type that isolates the sound in one stream of audio.
///
/// The isolator calls ``process(_:)`` with consecutive pieces of the input,
/// then ``finish()`` once.
/// The calls never overlap.
///
/// An executor does not align or trim its output.
/// It states its ``latency``, and the isolator removes that many frames from the start
/// of the output and makes the output as long as the input.
/// An executor can return any number of frames from each call, including none,
/// so an engine that works in windows, or a service that answers once,
/// returns audio when it has some.
///
/// The executor works at its own ``sampleRate`` and ``channelCount``.
/// Every ``AudioSamples`` value that it receives and returns has that channel count.
public protocol SoundIsolationExecutor: Sendable {
    /// The sample rate of the audio that the executor reads and writes, in hertz.
    var sampleRate: Double { get }

    /// The number of channels that the executor reads and writes.
    var channelCount: Int { get }

    /// The number of frames by which the output trails the input.
    ///
    /// Frame `n` of the input corresponds to frame `n + latency` of all the audio
    /// that the executor returns.
    var latency: Int { get }

    /// Takes the next frames of the input and returns the output that is ready.
    ///
    /// - Parameter input: The next frames of the input.
    /// - Returns: Isolated audio, which can have any number of frames.
    func process(_ input: AudioSamples) async throws -> AudioSamples

    /// Returns the output that remains after the last input.
    ///
    /// The isolator pads or trims the end of the output to the input's length,
    /// so the executor can return less than its latency here.
    ///
    /// - Returns: The rest of the isolated audio.
    func finish() async throws -> AudioSamples
}
