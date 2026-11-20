#if MLX
    import AVFoundation
    import Foundation
    import MLX
    import Testing

    @testable import AnySoundIsolator

    /// Tests that compute on the GPU with MLX. They need no download.
    /// Set `ENABLE_MLX_TESTS=1` to run them, as `mise run test:mlx` does.
    @Suite(.enabled(if: shouldRunMLXTests), .serialized) struct InworldNetworkTests {
        /// The inverse transform recovers the signal, for lengths on and off the hop,
        /// and for a signal shorter than half a window.
        @Test(arguments: [384_000, 48_123, 700])
        func spectralTransformRoundTrips(length: Int) {
            let transform = InworldSpectralTransform(nFFT: 2_048, hop: 480)
            let signal = MLXRandom.normal([2, length]) * 0.1
            let restored = transform.inverse(transform.forward(signal), length: length)
            #expect(restored.shape == [2, length])
            #expect(abs(restored - signal).max().item(Float.self) < 1e-5)
        }

        /// With a hop larger than half the window, the windows end before the length that the caller asks for.
        /// The inverse keeps the samples that they cover and pads the rest with zeros, as `torch.istft` does.
        /// Here the windows cover 11 of 13 samples.
        @Test func inverseWithALongHopPadsTheSamplesThatNoWindowCovers() {
            let transform = InworldSpectralTransform(nFFT: 8, hop: 7)
            let signal = MLXRandom.normal([1, 13]) * 0.1
            let restored = transform.inverse(transform.forward(signal), length: 13)
            #expect(restored.shape == [1, 13])
            let values = restored.asArray(Float.self)
            let expected = signal.asArray(Float.self)
            #expect(zip(values.prefix(11), expected.prefix(11)).allSatisfy { abs($0 - $1) < 1e-5 })
            #expect(values.suffix(2) == [0, 0])
        }

        /// The Metal kernel gives the result of the same recurrence written in Swift.
        @Test func scanKernelMatchesTheRecurrence() {
            let (rows, frames, channels, states) = (3, 50, 8, 16)
            MLXRandom.seed(3)
            let u = MLXRandom.normal([rows, frames, channels])
            let delta = abs(MLXRandom.normal([rows, frames, channels])) * 0.5 + 0.01
            let a = -abs(MLXRandom.normal([channels, states])) - 0.1
            let b = MLXRandom.normal([rows, frames, states])
            let c = MLXRandom.normal([rows, frames, states])
            let d = MLXRandom.normal([channels])
            let z = MLXRandom.normal([rows, frames, channels])
            let y = InworldSelectiveScan.scan(u: u, delta: delta, a: a, b: b, c: c, d: d, z: z).asArray(Float.self)

            let (us, deltas, zs) = (u.asArray(Float.self), delta.asArray(Float.self), z.asArray(Float.self))
            let (rates, bs, cs, ds) = (
                a.asArray(Float.self), b.asArray(Float.self), c.asArray(Float.self), d.asArray(Float.self)
            )
            // A NaN does not raise the largest error below, so check for one first.
            #expect(y.count == rows * frames * channels)
            #expect(y.allSatisfy { $0.isFinite })
            var worst: Float = 0
            for row in 0 ..< rows {
                for channel in 0 ..< channels {
                    var h = [Float](repeating: 0, count: states)
                    for t in 0 ..< frames {
                        let at = (row * frames + t) * channels + channel
                        let bt = (row * frames + t) * states
                        var out: Float = 0
                        for n in 0 ..< states {
                            h[n] =
                                exp(deltas[at] * rates[channel * states + n]) * h[n] + deltas[at] * us[at] * bs[bt + n]
                            out += h[n] * cs[bt + n]
                        }
                        out += us[at] * ds[channel]
                        out *= zs[at] / (1 + exp(-zs[at]))
                        worst = max(worst, abs(out - y[at]) / max(1, abs(out)))
                    }
                }
            }
            #expect(worst < 1e-4)
        }

        /// A small checkpoint with random weights runs through the public API,
        /// and a stream gives the frames of Inworld's offline placement.
        @Test func smallCheckpointKeepsTheContractAndThePlacement() async throws {
            try await withTemporaryDirectory { directory in
                let checkpoint = directory.appending(path: "small.safetensors")
                try InworldFixture.writeSmallCheckpoint(to: checkpoint)
                let model = InworldSoundIsolationModel(assets: .file(checkpoint))
                #expect(model.availability == .available)
                #expect(try await model.assetInstallationRequest() == nil)
                let isolator = SoundIsolator(model: model)

                // 2.6 windows at 48 kHz, so the last window is off the hop.
                let samples = TestAudio.voice(seconds: 0.26)
                let runtime = try InworldRuntime.shared(contentsOf: checkpoint)
                #expect(runtime.chunk == 4_800 && runtime.overlap == 1_200)

                // The offline render, with the length known, as upstream writes it.
                var expected = [Float](repeating: 0, count: samples.count)
                var weight = expected
                let starts = Array(stride(from: 0, to: samples.count - 4_800, by: 3_600)) + [samples.count - 4_800]
                for (index, start) in starts.enumerated() {
                    var w = [Float](repeating: 1, count: 4_800)
                    if index > 0 {
                        let fadeIn = starts[index - 1] + 3_600 - start
                        for i in 0 ..< fadeIn { w[i] = 0 }
                        let ramp = InworldWindowAssembler.linspace(0, 1, 1_200)
                        for i in 0 ..< 1_200 { w[fadeIn + i] = ramp[i] }
                    }
                    if start + 4_800 < samples.count {
                        let ramp = InworldWindowAssembler.linspace(1, 0, 1_200)
                        for i in 0 ..< 1_200 { w[3_600 + i] = ramp[i] }
                    }
                    let voice = await runtime.render(Array(samples[start ..< start + 4_800]))
                    for i in 0 ..< 4_800 {
                        expected[start + i] += voice[i] * w[i]
                        weight[start + i] += w[i]
                    }
                }
                expected = zip(expected, weight).map { $0 / max($1, 1e-6) }
                #expect(expected.allSatisfy { $0.isFinite })

                let whole = try await isolator.isolate(try TestAudio.buffer([samples]))
                #expect(TestAudio.maximumDifference(TestAudio.channels(whole.buffer)[0], expected) < 1e-6)

                for size in [1_000, 4_800, 7_777] {
                    let buffers = try TestAudio.buffers([samples], size: size)
                    let stream = try await TestAudio.collect(isolator.streamIsolation(of: Buffers(buffers)))
                    #expect(stream.isolated[0].count == samples.count)
                    #expect(TestAudio.maximumDifference(stream.isolated[0], expected) < 1e-6)
                    #expect(stream.source[0] == samples)
                }
            }
        }

        /// Stereo input at another sample rate keeps its format and its length,
        /// and a clip shorter than one window is one pass.
        @Test(arguments: [0.26, 0.05])
        func otherFormatsKeepTheContract(seconds: Double) async throws {
            try await withTemporaryDirectory { directory in
                let checkpoint = directory.appending(path: "small.safetensors")
                try InworldFixture.writeSmallCheckpoint(to: checkpoint)
                let isolator = SoundIsolator(model: InworldSoundIsolationModel(assets: .file(checkpoint)))
                let left = TestAudio.voice(seconds: seconds, sampleRate: 44_100, seed: 1)
                let right = TestAudio.voice(seconds: seconds, sampleRate: 44_100, seed: 2)
                let buffer = try TestAudio.buffer([left, right], sampleRate: 44_100)
                for policy in IsolationOptions.ChannelPolicy.allCases {
                    let audio = try await isolator.isolate(buffer, options: IsolationOptions(channelPolicy: policy))
                    let channels = TestAudio.channels(audio.buffer)
                    #expect(audio.buffer.format.sampleRate == 44_100)
                    #expect(channels.count == 2)
                    #expect(channels[0].count == left.count)
                    #expect(channels.allSatisfy { $0.allSatisfy(\.isFinite) })
                    // A downmix gives one result for both channels.
                    #expect((channels[0] == channels[1]) == (policy == .downmix))
                }
            }
        }

        /// A call suspends during a render. A second call that starts then waits for the first,
        /// so the two together give the output of two calls in a row.
        @Test func overlappingCallsRunOneAtATime() async throws {
            try await withTemporaryDirectory { directory in
                let checkpoint = directory.appending(path: "small.safetensors")
                try InworldFixture.writeSmallCheckpoint(to: checkpoint)
                let model = InworldSoundIsolationModel(assets: .file(checkpoint))
                let request = SoundIsolationRequest(sound: .voice, sampleRate: 48_000, channelCount: 1)
                // Each piece is longer than a window, so each call renders.
                let piece = AudioSamples(channels: [Array(TestAudio.voice(seconds: 0.26).prefix(7_000))])

                let inOrder = try await model.makeExecutor(for: request)
                var expected = try await inOrder.process(piece).channels[0]
                expected += try await inOrder.process(piece).channels[0]
                let expectedRest = try await inOrder.finish().channels[0]
                #expect(expected.count + expectedRest.count == 14_000)

                for _ in 0 ..< 5 {
                    let executor = try await model.makeExecutor(for: request)
                    async let first = executor.process(piece)
                    async let second = executor.process(piece)
                    let (one, two) = try await (first.channels[0], second.channels[0])
                    // The pieces are equal, so either call can be the first to run.
                    #expect(one + two == expected || two + one == expected)
                    #expect(try await executor.finish().channels[0] == expectedRest)
                }
            }
        }

        /// A call that is cancelled while it waits for another leaves the queue and takes none of its input.
        @Test func callCancelledWhileItWaitsTakesNoInput() async throws {
            try await withTemporaryDirectory { directory in
                let checkpoint = directory.appending(path: "small.safetensors")
                try InworldFixture.writeSmallCheckpoint(to: checkpoint)
                let model = InworldSoundIsolationModel(assets: .file(checkpoint))
                let request = SoundIsolationRequest(sound: .voice, sampleRate: 48_000, channelCount: 1)
                let piece = AudioSamples(channels: [Array(TestAudio.voice(seconds: 0.26).prefix(7_000))])

                let alone = try await model.makeExecutor(for: request)
                let expected = try await alone.process(piece).channels[0]
                let expectedRest = try await alone.finish().channels[0]

                let executor = try #require(
                    try await model.makeExecutor(for: request) as? InworldSoundIsolationExecutor
                )
                // The test holds the queue, so the call waits. A failure below still releases it.
                try await executor.admission.enter()
                var isHeld = true
                defer { if isHeld { executor.admission.leave() } }
                let waiting = Task { try await executor.process(piece) }
                try await waitUntil("the call waits") { executor.admission.waitingCount == 1 }
                waiting.cancel()
                await #expect(throws: CancellationError.self) { _ = try await waiting.value }
                #expect(executor.admission.waitingCount == 0)
                executor.admission.leave()
                isHeld = false

                #expect(try await executor.process(piece).channels[0] == expected)
                #expect(try await executor.finish().channels[0] == expectedRest)
            }
        }

        @Test func audioThatIsNotFiniteIsRefused() async throws {
            try await withTemporaryDirectory { directory in
                let checkpoint = directory.appending(path: "small.safetensors")
                try InworldFixture.writeSmallCheckpoint(to: checkpoint)
                let isolator = SoundIsolator(model: InworldSoundIsolationModel(assets: .file(checkpoint)))
                var samples = TestAudio.voice(seconds: 0.1)
                samples[100] = .nan
                let buffer = try TestAudio.buffer([samples])
                await #expect {
                    _ = try await isolator.isolate(buffer)
                } throws: { error in
                    if case SoundIsolationError.invalidAudio = error { return true }
                    return false
                }
            }
        }

        /// A weight whose shape does not follow from the configuration is an error with the weight's name,
        /// before the network computes with it.
        @Test(arguments: [
            ("blocks.1.time_mamba.forward_blocks.A_log", [32, 5]),
            ("blocks.1.freq_mamba.backward_blocks.conv1d.weight", [32, 1, 3]),
            ("blocks.0.time_transformer.attn.qkv.weight", [48, 12]),
            ("band_embedding", [3, 16]),
            ("encoders.0.1.bias", [15]),
        ])
        func checkpointWithAWrongShapeIsRefused(name: String, shape: [Int]) async throws {
            try await withTemporaryDirectory { directory in
                let checkpoint = directory.appending(path: "small.safetensors")
                try InworldFixture.writeSmallCheckpoint(to: checkpoint) { arrays in
                    #expect(arrays[name] != nil && arrays[name]?.shape != shape)
                    arrays[name] = MLXArray.zeros(shape)
                }
                let isolator = SoundIsolator(model: InworldSoundIsolationModel(assets: .file(checkpoint)))
                let buffer = try TestAudio.buffer([TestAudio.voice(seconds: 0.1)])
                await #expect {
                    _ = try await isolator.isolate(buffer)
                } throws: { error in
                    guard case SoundIsolationError.unsupportedConfiguration(let message) = error else { return false }
                    return message.contains(name)
                }
            }
        }

        @Test func fileThatIsNotACheckpointIsRefused() async throws {
            try await withTemporaryDirectory { directory in
                let file = directory.appending(path: "other.safetensors")
                try save(arrays: ["weight": MLXArray.ones([2])], url: file)
                let isolator = SoundIsolator(model: InworldSoundIsolationModel(assets: .file(file)))
                let buffer = try TestAudio.buffer([TestAudio.voice(seconds: 0.1)])
                await #expect {
                    _ = try await isolator.isolate(buffer)
                } throws: { error in
                    if case SoundIsolationError.unsupportedConfiguration = error { return true }
                    return false
                }
            }
        }
    }
#endif
