/// Isolated audio and the input frames that it came from.
struct IsolatedSamples: Sendable {
    var isolated: AudioSamples
    var source: AudioSamples
    /// The position of the first frame on the input's timeline.
    var position: Int
}

/// Runs the executors of one stream and keeps the package's contract:
/// the output has the input's sample rate, channel count, and length,
/// and each output frame is at the position of the input frame that it came from.
///
/// The pipeline converts between the input's format and each executor's format,
/// removes each executor's latency, and pads or trims the end of the output.
actor IsolationPipeline {
    /// One executor and the channels of the input that it processes.
    private struct Lane {
        let executor: any SoundIsolationExecutor
        let channels: Range<Int>
        /// Whether the executor takes the average of the lane's channels
        /// and its one channel of output goes to each of them.
        let downmixes: Bool
        /// Resamples the input to the executor's rate, when the rates differ.
        let intoExecutor: StreamResampler?
        /// Resamples the executor's output to the input's rate.
        let fromExecutor: StreamResampler?
        /// The frames of latency still to remove from the executor's output.
        var latencyRemaining: Int
        /// Aligned output at the input's rate that is not yet delivered.
        var ready: AudioSamples
    }

    private let model: any SoundIsolationModel
    private let sound: SoundIsolator.Sound
    private let options: IsolationOptions
    private var sampleRate: Double = 0
    private var lanes: [Lane] = []
    /// Input frames that have no output yet.
    private var pendingSource = AudioSamples(channelCount: 0)
    private var received = 0
    private var delivered = 0
    private var isFinished = false

    init(model: any SoundIsolationModel, sound: SoundIsolator.Sound, options: IsolationOptions) {
        self.model = model
        self.sound = sound
        self.options = options
    }

    /// Takes the next frames of the input and returns the output that is ready.
    func process(_ input: AudioSamples, sampleRate: Double) async throws -> [IsolatedSamples] {
        precondition(!isFinished, "The stream already finished.")
        if lanes.isEmpty {
            try await configure(sampleRate: sampleRate, channelCount: input.channelCount)
        }
        guard sampleRate == self.sampleRate, input.channelCount == pendingSource.channelCount else {
            throw SoundIsolationError.invalidAudio("The format of the input changed during the stream.")
        }
        guard input.frameCount > 0 else { return [] }
        pendingSource.append(input)
        received += input.frameCount
        for index in lanes.indices {
            var samples = AudioSamples(channels: Array(input.channels[lanes[index].channels]))
            if lanes[index].downmixes {
                samples = samples.downmixed()
            }
            if let resampler = lanes[index].intoExecutor {
                samples = try resampler.convert(samples)
            }
            try await run(samples, lane: index)
        }
        return deliver()
    }

    /// Ends the input and returns the rest of the output.
    func finish() async throws -> [IsolatedSamples] {
        guard !isFinished else { return [] }
        isFinished = true
        for index in lanes.indices {
            if let resampler = lanes[index].intoExecutor {
                try await run(try resampler.finish(), lane: index)
            }
            let executor = lanes[index].executor
            let tail: AudioSamples
            do {
                tail = try await executor.finish()
            } catch {
                throw isolationError(error)
            }
            try accept(tail, lane: index)
            if let resampler = lanes[index].fromExecutor {
                lanes[index].ready.append(try resampler.finish())
            }
            // The contract fixes the length; an engine's own rounding does not change it.
            lanes[index].ready.resize(to: received - delivered)
        }
        return deliver()
    }

    private func configure(sampleRate: Double, channelCount: Int) async throws {
        // Check the format before a model or a conversion reads it.
        _ = try PCM.floatFormat(sampleRate: sampleRate, channelCount: channelCount)
        guard model.supportedSounds.contains(sound) else {
            throw SoundIsolationError.unsupportedConfiguration(
                "The model cannot isolate the sound \"\(sound.rawValue)\"."
            )
        }
        let request = SoundIsolationRequest(sound: sound, sampleRate: sampleRate, channelCount: channelCount)
        var executors: [any SoundIsolationExecutor]
        do {
            executors = [try await model.makeExecutor(for: request)]
            // An executor for one channel processes the average of the channels,
            // or one channel of the input, with an executor for each of the others.
            if executors[0].channelCount == 1, options.channelPolicy == .perChannel {
                for _ in 1 ..< channelCount {
                    executors.append(try await model.makeExecutor(for: request))
                }
            }
        } catch {
            throw isolationError(error)
        }
        var lanes: [Lane] = []
        for (index, executor) in executors.enumerated() {
            let channels = executors.count == 1 ? 0 ..< channelCount : index ..< index + 1
            let downmixes = executor.channelCount == 1 && channels.count > 1
            guard executor.channelCount == channels.count || downmixes else {
                throw SoundIsolationError.invalidResult(
                    "The executor takes \(executor.channelCount) channels, and the input has \(channelCount)."
                )
            }
            guard executor.sampleRate.isFinite, executor.sampleRate > 0, executor.latency >= 0 else {
                throw SoundIsolationError.invalidResult(
                    "The executor reports a sample rate of \(executor.sampleRate) Hz "
                        + "and a latency of \(executor.latency) frames."
                )
            }
            let resamples = executor.sampleRate != sampleRate
            lanes.append(
                Lane(
                    executor: executor,
                    channels: channels,
                    downmixes: downmixes,
                    intoExecutor: resamples
                        ? try StreamResampler(
                            from: sampleRate,
                            to: executor.sampleRate,
                            channelCount: executor.channelCount
                        ) : nil,
                    fromExecutor: resamples
                        ? try StreamResampler(
                            from: executor.sampleRate,
                            to: sampleRate,
                            channelCount: executor.channelCount
                        ) : nil,
                    latencyRemaining: executor.latency,
                    ready: AudioSamples(channelCount: executor.channelCount)
                )
            )
        }
        self.sampleRate = sampleRate
        self.pendingSource = AudioSamples(channelCount: channelCount)
        self.lanes = lanes
    }

    /// Gives audio at the executor's rate to a lane's executor and keeps its output.
    private func run(_ samples: AudioSamples, lane index: Int) async throws {
        guard samples.frameCount > 0 else { return }
        let executor = lanes[index].executor
        let output: AudioSamples
        do {
            output = try await executor.process(samples)
        } catch {
            throw isolationError(error)
        }
        try accept(output, lane: index)
    }

    /// Removes the latency from an executor's output and converts it to the input's rate.
    private func accept(_ output: AudioSamples, lane index: Int) throws {
        let expected = lanes[index].executor.channelCount
        guard output.channelCount == expected else {
            throw SoundIsolationError.invalidResult(
                "The executor returned \(output.channelCount) channels instead of \(expected)."
            )
        }
        // `AudioSamples.channels` is a public property that an executor can change,
        // so check the lengths before any copy reads a channel by the length of the first.
        guard output.hasEqualChannelLengths else {
            throw SoundIsolationError.invalidResult(
                "The executor returned channels with \(output.channels.map(\.count)) samples, which are not equal."
            )
        }
        var output = output
        let dropped = min(lanes[index].latencyRemaining, output.frameCount)
        if dropped > 0 {
            _ = output.removeFirst(dropped)
            lanes[index].latencyRemaining -= dropped
        }
        if let resampler = lanes[index].fromExecutor {
            output = try resampler.convert(output)
        }
        lanes[index].ready.append(output)
    }

    /// Returns the output frames that every lane has, with the input frames at the same position.
    private func deliver() -> [IsolatedSamples] {
        let available = lanes.map(\.ready.frameCount).min() ?? 0
        let count = min(available, received - delivered)
        guard count > 0 else { return [] }
        var isolated: [[Float]] = []
        for index in lanes.indices {
            let ready = lanes[index].ready.removeFirst(count).channels
            // The one channel that came from a downmix goes to each channel of the output.
            isolated +=
                lanes[index].downmixes
                ? Array(repeating: ready[0], count: lanes[index].channels.count) : ready
        }
        let piece = IsolatedSamples(
            isolated: AudioSamples(channels: isolated),
            source: pendingSource.removeFirst(count),
            position: delivered
        )
        delivered += count
        return [piece]
    }
}
