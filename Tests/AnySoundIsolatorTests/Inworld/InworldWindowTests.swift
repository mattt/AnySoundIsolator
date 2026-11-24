#if MLX
    import Foundation
    import Testing

    @testable import AnySoundIsolator

    /// Tests of the window placement, which need no model file and no GPU.
    @Suite struct InworldWindowTests {
        /// A stand-in for the network: its output depends on every sample of the window
        /// and on each sample's place in the window, so a window in the wrong place gives another result.
        static func render(_ window: [Float]) -> [Float] {
            let mean = window.reduce(0, +) / Float(window.count)
            return window.enumerated().map { index, sample in
                sample * (0.5 + 0.25 * sin(Float(index) * 0.37)) + mean
            }
        }

        /// The offline render of a whole clip, written as `VoiceIsolatorNetwork.enhance`
        /// in Inworld's `model.py` writes it, with the length of the clip known.
        static func offlineRender(_ samples: [Float], chunk: Int, overlap: Int) -> [Float] {
            let count = samples.count
            guard count > chunk else { return count == 0 ? [] : render(samples) }
            var output = [Float](repeating: 0, count: count)
            var weight = [Float](repeating: 0, count: count)
            let starts = Array(stride(from: 0, to: count - chunk, by: chunk - overlap)) + [count - chunk]
            for (index, start) in starts.enumerated() {
                let end = start + chunk
                var w = [Float](repeating: 1, count: chunk)
                if index > 0 {
                    let fadeIn = starts[index - 1] + chunk - overlap - start
                    for i in 0 ..< fadeIn { w[i] = 0 }
                    let ramp = InworldWindowAssembler.linspace(0, 1, overlap)
                    for i in 0 ..< overlap { w[fadeIn + i] = ramp[i] }
                }
                if overlap > 0 && end < count {
                    let ramp = InworldWindowAssembler.linspace(1, 0, overlap)
                    for i in 0 ..< overlap { w[chunk - overlap + i] = ramp[i] }
                }
                let voice = render(Array(samples[start ..< end]))
                for i in 0 ..< chunk {
                    output[start + i] += voice[i] * w[i]
                    weight[start + i] += w[i]
                }
            }
            return zip(output, weight).map { $0 / max($1, 1e-6) }
        }

        /// Runs a clip through the assembler in pieces of a given size.
        static func streamRender(_ samples: [Float], chunk: Int, overlap: Int, pieceSize: Int) -> [Float] {
            var assembler = InworldWindowAssembler(chunk: chunk, overlap: overlap)
            var output: [Float] = []
            var position = 0
            while position < samples.count {
                let end = min(position + pieceSize, samples.count)
                assembler.append(Array(samples[position ..< end]))
                position = end
                while let window = assembler.nextWindow() {
                    output += assembler.accept(render(window))
                }
            }
            output += assembler.finish(assembler.lastWindow().map(render))
            return output
        }

        static func noise(_ count: Int) -> [Float] {
            var generator = SystemRandomNumberGenerator()
            return (0 ..< count).map { _ in Float.random(in: -1 ... 1, using: &generator) }
        }

        /// Lengths on each side of every boundary of the placement, for a window of 64 and a hop of 48.
        static let lengths = [0, 1, 20, 63, 64, 65, 79, 80, 81, 111, 112, 113, 127, 128, 160, 161, 208, 400, 1_001]

        @Test(arguments: lengths, [1, 7, 48, 64, 5_000])
        func streamEqualsTheOfflineRender(length: Int, pieceSize: Int) {
            let samples = Self.noise(length)
            let expected = Self.offlineRender(samples, chunk: 64, overlap: 16)
            let actual = Self.streamRender(samples, chunk: 64, overlap: 16, pieceSize: pieceSize)
            #expect(actual == expected)
        }

        @Test(arguments: lengths, [(64, 32), (64, 0), (10, 3)])
        func streamEqualsTheOfflineRenderForOtherWindows(length: Int, window: (chunk: Int, overlap: Int)) {
            let samples = Self.noise(length)
            let expected = Self.offlineRender(samples, chunk: window.chunk, overlap: window.overlap)
            let actual = Self.streamRender(samples, chunk: window.chunk, overlap: window.overlap, pieceSize: 13)
            #expect(actual == expected)
        }

        @Test func streamEqualsTheOfflineRenderAtTheReleasedWindowSize() throws {
            let (chunk, overlap) = try InworldFixture.configuration(InworldFixture.offlineConfiguration).windowSamples
            // 11 seconds, as in Inworld's fixture, and a length that leaves a last window off the hop.
            for length in [528_000, 1_000_003] {
                let samples = Self.noise(length)
                let expected = Self.offlineRender(samples, chunk: chunk, overlap: overlap)
                let actual = Self.streamRender(samples, chunk: chunk, overlap: overlap, pieceSize: 32_768)
                #expect(actual == expected)
            }
        }

        @Test func framesArriveOneHopAtATime() {
            var assembler = InworldWindowAssembler(chunk: 64, overlap: 16)
            assembler.append(Self.noise(63))
            #expect(assembler.nextWindow() == nil)
            assembler.append(Self.noise(1))
            let first = assembler.nextWindow()
            #expect(first?.count == 64)
            // The last crossfade of the window waits for the next window.
            #expect(assembler.accept(Self.render(first!)).count == 48)
            #expect(assembler.nextWindow() == nil)
            assembler.append(Self.noise(48))
            let second = assembler.nextWindow()
            #expect(assembler.accept(Self.render(second!)).count == 48)
            // The windows so far reach the end, so nothing more is rendered.
            #expect(assembler.lastWindow() == nil)
            #expect(assembler.finish(nil).count == 16)
        }

        @Test func linspaceMatchesTorch() {
            let ramp = InworldWindowAssembler.linspace(0, 1, 96_000)
            #expect(ramp.first == 0 && ramp.last == 1)
            #expect(ramp[1] == Float(1.0416774784971494e-05))
            #expect(ramp[47_999] == Float(0.49999478459358215))
            #expect(ramp[48_000] == Float(0.5000052452087402))
            #expect(ramp[95_998] == Float(0.9999895691871643))
        }

        // MARK: - Configuration

        @Test func releasedConfigurationIsSupported() throws {
            let configuration = try InworldFixture.configuration(InworldFixture.offlineConfiguration)
            try configuration.validate()
            #expect(configuration.windowSamples == (384_000, 96_000))
            #expect(configuration.bins == 1_025)
        }

        @Test func bandEdgesMatchInworld() throws {
            let edges = try InworldFixture.configuration(InworldFixture.offlineConfiguration).bandEdges
            #expect(edges.count == 46)
            #expect(Array(edges.prefix(3)) == [0 ..< 4, 4 ..< 8, 8 ..< 12])
            #expect(Array(edges[10 ... 12]) == [40 ..< 43, 43 ..< 54, 54 ..< 65])
            #expect(Array(edges.suffix(3)) == [938 ..< 1_023, 1_023 ..< 1_024, 1_024 ..< 1_025])
        }

        /// Values that would overflow the arithmetic on the configuration, or that make no network.
        @Test func configurationWithValuesOutOfRangeIsRefused() throws {
            let changes: [(inout InworldConfiguration) -> Void] = [
                { $0.chunkSeconds = .infinity }, { $0.chunkSeconds = .nan }, { $0.chunkSeconds = 1e300 },
                { $0.chunkSeconds = 0 }, { $0.overlapSeconds = -.infinity }, { $0.overlapSeconds = .nan },
                { $0.numHeads = .max }, { $0.numHeads = 0 }, { $0.width = .max }, { $0.width = -512 },
                { $0.sampleRate = 0 }, { $0.sampleRate = .max }, { $0.nFFT = .max }, { $0.nFFT = 1 },
                { $0.nFFT -= 1 },
                { $0.hopLength = 0 }, { $0.hopLength = .max }, { $0.hopLength = $0.nFFT }, { $0.mambaExpand = .max },
                { $0.mambaExpand = 0 },
                { $0.mambaConv = 0 }, { $0.mambaState = 0 }, { $0.mambaState = .max },
                { $0.bandPlan = [[100]] }, { $0.bandPlan = [[.min, .max]] }, { $0.correctionBound = .nan },
            ]
            for (index, change) in changes.enumerated() {
                var configuration = try InworldFixture.configuration(InworldFixture.offlineConfiguration)
                change(&configuration)
                #expect("Change \(index) is refused.") {
                    try configuration.validate()
                } throws: { error in
                    guard case SoundIsolationError.unsupportedConfiguration = error else { return false }
                    return true
                }
            }
        }

        @Test func streamingCheckpointsAreRefused() throws {
            var configuration = try InworldFixture.configuration(InworldFixture.offlineConfiguration)
            configuration.causal = true
            #expect(throws: SoundIsolationError.self) { try configuration.validate() }
            configuration.causal = false
            configuration.lookaheadFrames = 2
            #expect(throws: SoundIsolationError.self) { try configuration.validate() }
        }
    }
#endif
