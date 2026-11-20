/// Audio as one array of Float32 samples for each channel.
///
/// A ``SoundIsolationExecutor`` reads and writes this type.
/// It is a value type, so it crosses concurrency domains without a copy of an audio buffer,
/// and an engine can pass a channel to its own array type directly.
public struct AudioSamples: Sendable, Equatable {
    /// The samples of each channel.
    /// Every channel has the same number of samples.
    public var channels: [[Float]]

    /// Creates audio from the samples of each channel.
    ///
    /// - Parameter channels: The samples of each channel, all with the same count.
    public init(channels: [[Float]]) {
        precondition(
            channels.allSatisfy { $0.count == channels[0].count },
            "Every channel must have the same number of samples."
        )
        self.channels = channels
    }

    /// Creates audio with no frames.
    ///
    /// - Parameter channelCount: The number of channels.
    public init(channelCount: Int) {
        self.channels = Array(repeating: [], count: channelCount)
    }

    /// Creates silence.
    ///
    /// - Parameters:
    ///   - channelCount: The number of channels.
    ///   - frameCount: The number of frames in each channel.
    public init(channelCount: Int, frameCount: Int) {
        self.channels = Array(repeating: Array(repeating: 0, count: frameCount), count: channelCount)
    }

    /// The number of channels.
    public var channelCount: Int { channels.count }

    /// The number of frames, which is the number of samples in each channel.
    public var frameCount: Int { channels.first?.count ?? 0 }
}

extension AudioSamples {
    /// Appends the frames of other audio with the same channel count.
    mutating func append(_ other: AudioSamples) {
        precondition(other.channelCount == channelCount)
        for index in channels.indices {
            channels[index].append(contentsOf: other.channels[index])
        }
    }

    /// Removes and returns frames from the start.
    mutating func removeFirst(_ count: Int) -> AudioSamples {
        let head = AudioSamples(channels: channels.map { Array($0.prefix(count)) })
        for index in channels.indices {
            channels[index].removeFirst(min(count, channels[index].count))
        }
        return head
    }

    /// Returns one channel that is the average of the channels.
    func downmixed() -> AudioSamples {
        guard channelCount > 1 else { return self }
        var average = channels[0]
        for channel in channels.dropFirst() {
            for index in average.indices {
                average[index] += channel[index]
            }
        }
        let scale = 1 / Float(channelCount)
        return AudioSamples(channels: [average.map { $0 * scale }])
    }

    /// Pads with silence or trims the end, so that the audio has a given number of frames.
    mutating func resize(to count: Int) {
        for index in channels.indices {
            let difference = count - channels[index].count
            if difference > 0 {
                channels[index].append(contentsOf: repeatElement(0, count: difference))
            } else if difference < 0 {
                channels[index].removeLast(-difference)
            }
        }
    }
}
