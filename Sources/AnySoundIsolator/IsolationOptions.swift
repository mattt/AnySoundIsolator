/// Options that control how an isolator uses its model for one file, buffer, or stream.
///
/// Pass options to an isolation method when the default does not suit the recording.
/// The options are the same for every model, as `GenerationOptions` is in AnyLanguageModel;
/// a setting that belongs to one engine goes in that model's initializer.
///
/// ```swift
/// let options = IsolationOptions(channelPolicy: .perChannel)
/// try await isolator.isolate(contentsOf: interview, to: voices, options: options)
/// ```
public struct IsolationOptions: Sendable, Hashable {
    /// What the isolator does when the input has more channels than the engine takes.
    ///
    /// The policy applies only when the model's executor takes one channel
    /// and the input has two or more.
    /// An engine that takes all of the input's channels, such as the system model with stereo input,
    /// receives them together, and the policy has no effect.
    ///
    /// With either policy, the output has the input's channel count,
    /// and in each channel the isolated sound and the background add up to the source.
    public enum ChannelPolicy: String, Sendable, Hashable, CaseIterable {
        /// Average the channels, isolate the sound once, and put the result in every channel.
        ///
        /// The engine runs once, whatever the number of channels.
        /// The isolated sound is the same in every channel, so it has no stereo position.
        /// The background of a channel is that channel's source minus the isolated sound,
        /// so the background keeps the differences between the channels,
        /// and ``IsolatedAudio/mixed(backgroundLevel:)`` at a level of 1 is still the source.
        case downmix

        /// Isolate the sound in each channel separately, with one executor for each channel.
        ///
        /// The engine's work grows with the number of channels.
        /// Use this policy when the channels hold different sounds,
        /// such as an interview with one speaker in each channel.
        case perChannel
    }

    /// What the isolator does when the input has more channels than the engine takes.
    ///
    /// The default is ``ChannelPolicy/downmix``.
    public var channelPolicy: ChannelPolicy

    /// Creates options.
    ///
    /// - Parameter channelPolicy: What the isolator does when the input has more channels
    ///   than the engine takes.
    public init(channelPolicy: ChannelPolicy = .downmix) {
        self.channelPolicy = channelPolicy
    }
}
