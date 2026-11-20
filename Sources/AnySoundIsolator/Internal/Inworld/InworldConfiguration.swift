// This file is adapted from Inworld Voice Isolator (https://github.com/inworld-ai/voice-isolator),
// Copyright 2026 Inworld AI, licensed under the Apache License, Version 2.0.
// It adapts the configuration in `src/inworld/voice_isolation/model.py`.
// This file was changed from the original:
// the code is rewritten from Python to Swift,
// and it refuses the forms of the network that this package does not port.
// See the NOTICE file.

#if MLX
    import Foundation

    /// The architecture of an Inworld checkpoint, read from the metadata of its safetensors file.
    ///
    /// The package implements the offline, two-sided form of the network.
    /// It refuses a checkpoint that is causal, is dual-mode, or has a look-ahead.
    struct InworldConfiguration: Decodable, Equatable {
        var width: Int
        var blockTypes: [String]
        var numHeads: Int
        var nFFT: Int
        var hopLength: Int
        var sampleRate: Int
        var bandPlan: [[Int]]
        var correctionBound: Float
        var chunkSeconds: Double
        var overlapSeconds: Double
        var exclusiveSelfAttention: Bool
        var exclusiveAxes: String
        var mambaState: Int
        var mambaConv: Int
        var mambaExpand: Int
        var causal: Bool
        var dualMode: Bool
        var lookaheadFrames: Int
        var modeFilm: Bool

        enum CodingKeys: String, CodingKey {
            case width
            case blockTypes = "block_types"
            case numHeads = "num_heads"
            case nFFT = "n_fft"
            case hopLength = "hop_length"
            case sampleRate = "sample_rate"
            case bandPlan = "band_plan"
            case correctionBound = "correction_bound"
            case chunkSeconds = "chunk_seconds"
            case overlapSeconds = "overlap_seconds"
            case exclusiveSelfAttention = "exclusive_self_attention"
            case exclusiveAxes = "exclusive_axes"
            case mambaState = "mamba_state"
            case mambaConv = "mamba_conv"
            case mambaExpand = "mamba_expand"
            case causal
            case dualMode = "dual_mode"
            case lookaheadFrames = "lookahead_frames"
            case modeFilm = "mode_film"
        }

        /// Checks that the package implements the architecture.
        ///
        /// - Throws: ``SoundIsolationError/unsupportedConfiguration(_:)`` with the reason.
        func validate() throws {
            func refuse(_ reason: String) -> SoundIsolationError {
                .unsupportedConfiguration("The Inworld checkpoint is not supported: \(reason).")
            }
            if causal || dualMode || lookaheadFrames != 0 || modeFilm {
                throw refuse("the package runs the offline checkpoint, not a causal or dual-mode one")
            }
            if blockTypes.contains(where: { $0 != "transformer" && $0 != "mamba" }) {
                throw refuse("unknown block type in \(blockTypes)")
            }
            if numHeads < 1 || width < 1 || width % (2 * numHeads) != 0 {
                throw refuse("width \(width) with \(numHeads) heads")
            }
            if mambaState < 1 || mambaState > InworldSelectiveScan.maximumStates {
                throw refuse("state size \(mambaState)")
            }
            if exclusiveSelfAttention && exclusiveAxes != "time" {
                throw refuse("exclusive attention along \(exclusiveAxes)")
            }
            if bandPlan.contains(where: { $0.count != 2 }) {
                throw refuse("band plan \(bandPlan)")
            }
            let window = windowSamples
            if sampleRate < 1 || nFFT < 2 || hopLength < 1 || window.chunk < 1 || window.overlap < 0 {
                throw refuse("sample rate \(sampleRate), FFT size \(nFFT), hop \(hopLength)")
            }
        }

        /// The number of frequency bins in one frame of the spectrum.
        var bins: Int { nFFT / 2 + 1 }

        /// The bin range of each band.
        /// The bands cover every bin once, as `band_edges` in Inworld's `model.py` computes them.
        var bandEdges: [Range<Int>] {
            let hzPerBin = Double(sampleRate) / Double(nFFT)
            var edges: [Range<Int>] = []
            var start = 0
            for pair in bandPlan {
                // Python's round() rounds halves to even.
                let width = max(1, Int((Double(pair[0]) / hzPerBin).rounded(.toNearestOrEven)))
                let upto = min(bins, Int((Double(pair[1]) / hzPerBin).rounded(.toNearestOrEven)))
                while start < upto {
                    let end = min(start + width, upto)
                    edges.append(start ..< end)
                    start = end
                }
            }
            if start < bins {
                edges.append(start ..< bins)
            }
            return edges
        }

        /// The window and its crossfade in samples, as `window_samples` in `model.py` computes them.
        /// The crossfade is at most half of the window.
        var windowSamples: (chunk: Int, overlap: Int) {
            let chunk = Int(chunkSeconds * Double(sampleRate))
            return (chunk, min(Int(overlapSeconds * Double(sampleRate)), chunk / 2))
        }
    }
#endif
