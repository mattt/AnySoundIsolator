// This file is adapted from Inworld Voice Isolator (https://github.com/inworld-ai/voice-isolator),
// Copyright 2026 Inworld AI, licensed under the Apache License, Version 2.0.
// It adapts the network in `src/inworld/voice_isolation/model.py`.
// This file was changed from the original:
// the code is rewritten from Python for PyTorch to Swift for MLX,
// and only the offline, two-sided form of the network is ported.
// See the NOTICE file.

#if MLX
    import Foundation
    import MLX

    // The network of Inworld's Voice Isolator, ported from `model.py` in Inworld's repository,
    // which is under the Apache License, Version 2.0; see the NOTICE file.
    // Names follow the checkpoint's weights.
    // Shapes are written as [batch, bands, frames, width], where batch counts windows.

    extension InworldNetwork {
        /// Looks up weights by name and reports a missing one.
        struct WeightStore {
            let arrays: [String: MLXArray]

            func callAsFunction(_ name: String) throws -> MLXArray {
                guard let array = arrays[name] else {
                    throw SoundIsolationError.invalidResult("The Inworld checkpoint has no weight named \(name).")
                }
                return array
            }

            func linear(_ prefix: String, bias: Bool = true) throws -> Linear {
                Linear(weight: try self("\(prefix).weight"), bias: bias ? try self("\(prefix).bias") : nil)
            }

            func layerNorm(_ prefix: String) throws -> LayerNorm {
                LayerNorm(weight: try self("\(prefix).weight"), bias: try self("\(prefix).bias"))
            }
        }

        struct Linear {
            let weight: MLXArray
            let bias: MLXArray?

            func callAsFunction(_ x: MLXArray) -> MLXArray {
                let y = matmul(x, weight.T)
                return bias.map { y + $0 } ?? y
            }
        }

        struct LayerNorm {
            let weight: MLXArray
            let bias: MLXArray

            func callAsFunction(_ x: MLXArray) -> MLXArray {
                MLXFast.layerNorm(x, weight: weight, bias: bias, eps: 1e-5)
            }
        }

        /// GELU with the error function, as `torch.nn.GELU()` computes it.
        static func gelu(_ x: MLXArray) -> MLXArray {
            x * (1 + erf(x * Float(1 / 2.0.squareRoot()))) * 0.5
        }

        static func silu(_ x: MLXArray) -> MLXArray {
            x * sigmoid(x)
        }

        /// `torch.nn.functional.softplus` with its default threshold of 20.
        static func softplus(_ x: MLXArray) -> MLXArray {
            which(x .> 20, x, log1p(exp(x)))
        }

        /// Removes each token's component along its own value (exclusive self attention).
        static func makeExclusive(_ output: MLXArray, _ value: MLXArray) -> MLXArray {
            let coefficient =
                (output * value).sum(axis: -1, keepDims: true)
                / maximum((value * value).sum(axis: -1, keepDims: true), 1e-6)
            return output - coefficient * value
        }

        /// Rotary positions over the frames, with the halves of each head rotated together.
        struct RotaryTables {
            let cos: MLXArray
            let sin: MLXArray

            /// Tables `[frames, headDim / 2]`, computed in float32 as `rope_tables` does.
            init(frames: Int, headDim: Int) {
                let half = headDim / 2
                let inverse = (0 ..< half).map { Foundation.pow(Float(10000), -Float($0) / Float(half)) }
                var cosValues = [Float](repeating: 0, count: frames * half)
                var sinValues = [Float](repeating: 0, count: frames * half)
                for t in 0 ..< frames {
                    for i in 0 ..< half {
                        let angle = Float(t) * inverse[i]
                        cosValues[t * half + i] = Foundation.cos(angle)
                        sinValues[t * half + i] = Foundation.sin(angle)
                    }
                }
                cos = MLXArray(cosValues, [frames, half])
                sin = MLXArray(sinValues, [frames, half])
            }

            /// Rotates `x` `[batch, heads, frames, headDim]`.
            func apply(_ x: MLXArray) -> MLXArray {
                let half = x.dim(-1) / 2
                let x1 = x[.ellipsis, ..<half]
                let x2 = x[.ellipsis, half...]
                return concatenated([x1 * cos - x2 * sin, x1 * sin + x2 * cos], axis: -1)
            }
        }

        /// Splits `[batch, length, 3 * width]` into queries, keys, and values `[batch, heads, length, headDim]`.
        fileprivate static func splitHeads(_ qkv: MLXArray, heads: Int) -> (MLXArray, MLXArray, MLXArray) {
            let (batch, length) = (qkv.dim(0), qkv.dim(1))
            let headDim = qkv.dim(2) / 3 / heads
            let split = qkv.reshaped(batch, length, 3, heads, headDim).transposed(2, 0, 3, 1, 4)
            return (split[0], split[1], split[2])
        }

        fileprivate static func mergeHeads(_ x: MLXArray) -> MLXArray {
            let (batch, heads, length, headDim) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3))
            return x.transposed(0, 2, 1, 3).reshaped(batch, length, heads * headDim)
        }

        /// A pre-norm transformer layer along time, with rotary positions.
        struct TimeBlock {
            let norm1, norm2: LayerNorm
            let qkv, proj, ffn1, ffn2: Linear
            let heads: Int
            let exclusive: Bool

            init(_ w: WeightStore, _ prefix: String, heads: Int, exclusive: Bool) throws {
                norm1 = try w.layerNorm("\(prefix).norm1")
                norm2 = try w.layerNorm("\(prefix).norm2")
                qkv = try w.linear("\(prefix).attn.qkv")
                proj = try w.linear("\(prefix).attn.proj")
                ffn1 = try w.linear("\(prefix).ffn.0")
                ffn2 = try w.linear("\(prefix).ffn.3")
                self.heads = heads
                self.exclusive = exclusive
            }

            /// `x` is `[sequences, frames, width]`.
            func callAsFunction(_ x: MLXArray, rope: RotaryTables) -> MLXArray {
                let (query, key, value) = InworldNetwork.splitHeads(qkv(norm1(x)), heads: heads)
                let scale = 1 / Float(query.dim(-1)).squareRoot()
                var output = MLXFast.scaledDotProductAttention(
                    queries: rope.apply(query),
                    keys: rope.apply(key),
                    values: value,
                    scale: scale,
                    mask: nil
                )
                if exclusive {
                    output = InworldNetwork.makeExclusive(output, value)
                }
                let x = x + proj(mergeHeads(output))
                return x + ffn2(gelu(ffn1(norm2(x))))
            }
        }

        /// A pre-norm transformer layer across the bands of one frame.
        struct BandTransformer {
            let norm1, norm2: LayerNorm
            let inProj, outProj, linear1, linear2: Linear
            let heads: Int
            let exclusive: Bool

            init(_ w: WeightStore, _ prefix: String, heads: Int, exclusive: Bool) throws {
                norm1 = try w.layerNorm("\(prefix).norm1")
                norm2 = try w.layerNorm("\(prefix).norm2")
                inProj = Linear(
                    weight: try w("\(prefix).self_attn.in_proj_weight"),
                    bias: try w("\(prefix).self_attn.in_proj_bias")
                )
                outProj = try w.linear("\(prefix).self_attn.out_proj")
                linear1 = try w.linear("\(prefix).linear1")
                linear2 = try w.linear("\(prefix).linear2")
                self.heads = heads
                self.exclusive = exclusive
            }

            /// `x` is `[sequences, bands, width]`.
            func callAsFunction(_ x: MLXArray) -> MLXArray {
                let (query, key, value) = InworldNetwork.splitHeads(inProj(norm1(x)), heads: heads)
                let scale = 1 / Float(query.dim(-1)).squareRoot()
                var output = MLXFast.scaledDotProductAttention(
                    queries: query,
                    keys: key,
                    values: value,
                    scale: scale,
                    mask: nil
                )
                if exclusive {
                    output = InworldNetwork.makeExclusive(output, value)
                }
                let x = x + outProj(mergeHeads(output))
                return x + linear2(gelu(linear1(norm2(x))))
            }
        }

        /// Attention along time within each band, then across the bands of each frame.
        struct DualPathAttention {
            let time: TimeBlock
            let band: BandTransformer

            init(_ w: WeightStore, _ prefix: String, configuration: InworldConfiguration) throws {
                let onTime = configuration.exclusiveSelfAttention && configuration.exclusiveAxes == "time"
                time = try TimeBlock(
                    w,
                    "\(prefix).time_transformer",
                    heads: configuration.numHeads,
                    exclusive: onTime
                )
                band = try BandTransformer(
                    w,
                    "\(prefix).band_transformer",
                    heads: configuration.numHeads,
                    exclusive: false
                )
            }

            func callAsFunction(_ x: MLXArray, rope: RotaryTables) -> MLXArray {
                let (batch, bands, frames, width) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3))
                var x = time(x.reshaped(batch * bands, frames, width), rope: rope)
                x = x.reshaped(batch, bands, frames, width).transposed(0, 2, 1, 3).reshaped(
                    batch * frames,
                    bands,
                    width
                )
                x = band(x)
                return x.reshaped(batch, frames, bands, width).transposed(0, 2, 1, 3)
            }
        }

        /// One selective state-space layer.
        struct Mamba {
            let inProj, xProj, dtProj, outProj: Linear
            let convWeight: MLXArray  // [inner, kernel]
            let convBias: MLXArray
            let a: MLXArray
            let d: MLXArray
            let dtRank: Int
            let states: Int

            init(_ w: WeightStore, _ prefix: String, width: Int, states: Int) throws {
                inProj = try w.linear("\(prefix).in_proj", bias: false)
                xProj = try w.linear("\(prefix).x_proj", bias: false)
                dtProj = try w.linear("\(prefix).dt_proj")
                outProj = try w.linear("\(prefix).out_proj", bias: false)
                let conv = try w("\(prefix).conv1d.weight")
                convWeight = conv.reshaped(conv.dim(0), conv.dim(2))
                convBias = try w("\(prefix).conv1d.bias")
                a = -exp(try w("\(prefix).A_log"))
                d = try w("\(prefix).D")
                dtRank = (width + 15) / 16
                self.states = states
            }

            /// `x` is `[sequences, length, width]`.
            func callAsFunction(_ x: MLXArray) -> MLXArray {
                let length = x.dim(1)
                let xz = inProj(x)
                let inner = xz.dim(-1) / 2
                let u = xz[.ellipsis, ..<inner]
                let z = xz[.ellipsis, inner...]
                // A causal depthwise convolution: pad the past with zeros.
                let taps = convWeight.dim(1)
                let history = padded(u, widths: [0, .init((taps - 1, 0)), 0])
                var convolved = convBias + history[0..., 0 ..< length, 0...] * convWeight[0..., 0]
                for k in 1 ..< taps {
                    convolved = convolved + history[0..., k ..< (k + length), 0...] * convWeight[0..., k]
                }
                let v = silu(convolved)
                let projected = xProj(v)
                let dt = projected[.ellipsis, ..<dtRank]
                let b = projected[.ellipsis, dtRank ..< (dtRank + states)]
                let c = projected[.ellipsis, (dtRank + states)...]
                let delta = softplus(dtProj(dt))
                let y = InworldSelectiveScan.scan(u: v, delta: delta, a: a, b: b, c: c, d: d, z: z)
                return outProj(y)
            }
        }

        /// Forward and backward scans, projected together.
        struct BidirectionalMamba {
            let forward, backward: Mamba
            let outputProj: Linear
            let norm: LayerNorm

            init(_ w: WeightStore, _ prefix: String, configuration: InworldConfiguration) throws {
                let (width, states) = (configuration.width, configuration.mambaState)
                forward = try Mamba(w, "\(prefix).forward_blocks", width: width, states: states)
                backward = try Mamba(w, "\(prefix).backward_blocks", width: width, states: states)
                outputProj = try w.linear("\(prefix).output_proj")
                norm = try w.layerNorm("\(prefix).norm")
            }

            func callAsFunction(_ x: MLXArray) -> MLXArray {
                let reversed = x[0..., .stride(by: -1), 0...]
                let back = backward(reversed)[0..., .stride(by: -1), 0...]
                return norm(outputProj(concatenated([forward(x) + x, back + x], axis: -1)))
            }
        }

        /// Mamba along time within each band, then across the bands of each frame.
        struct DualPathMamba {
            let time, frequency: BidirectionalMamba

            init(_ w: WeightStore, _ prefix: String, configuration: InworldConfiguration) throws {
                time = try BidirectionalMamba(w, "\(prefix).time_mamba", configuration: configuration)
                frequency = try BidirectionalMamba(w, "\(prefix).freq_mamba", configuration: configuration)
            }

            func callAsFunction(_ x: MLXArray) -> MLXArray {
                let (batch, bands, frames, width) = (x.dim(0), x.dim(1), x.dim(2), x.dim(3))
                var t = x.reshaped(batch * bands, frames, width)
                t = t + time(t)
                var f = t.reshaped(batch, bands, frames, width).transposed(0, 2, 1, 3).reshaped(
                    batch * frames,
                    bands,
                    width
                )
                f = f + frequency(f)
                return f.reshaped(batch, frames, bands, width).transposed(0, 2, 1, 3)
            }
        }

        enum Block {
            case attention(DualPathAttention)
            case mamba(DualPathMamba)

            func callAsFunction(_ x: MLXArray, rope: RotaryTables) -> MLXArray {
                switch self {
                case .attention(let block): block(x, rope: rope)
                case .mamba(let block): block(x)
                }
            }
        }

        /// The per-band encoder: a layer norm and a projection of the band's bins.
        struct BandEncoder {
            let norm: LayerNorm
            let projection: Linear
        }

        /// A per-band head that predicts a complex mask and a residual for each bin.
        struct BandHead {
            let norm: LayerNorm
            let hidden: Linear
            let output: Linear

            func callAsFunction(_ x: MLXArray) -> MLXArray {
                output(gelu(hidden(norm(x))))
            }
        }
    }

    /// The offline network: band encoders, attention and Mamba blocks, and a decoder for each band.
    struct InworldNetwork {
        let configuration: InworldConfiguration
        let edges: [Range<Int>]
        let encoders: [BandEncoder]
        let bandEmbedding: MLXArray
        let blocks: [Block]
        let decoderScale: MLXArray
        let decoderShift: MLXArray
        let heads: [BandHead]
        let transform: InworldSpectralTransform

        init(configuration: InworldConfiguration, weights arrays: [String: MLXArray]) throws {
            try configuration.validate()
            let w = WeightStore(arrays: arrays)
            self.configuration = configuration
            edges = configuration.bandEdges
            encoders = try edges.indices.map { index in
                BandEncoder(
                    norm: try w.layerNorm("encoders.\(index).0"),
                    projection: try w.linear("encoders.\(index).1")
                )
            }
            bandEmbedding = try w("band_embedding")
            blocks = try configuration.blockTypes.enumerated().map { index, kind in
                kind == "transformer"
                    ? .attention(try DualPathAttention(w, "blocks.\(index)", configuration: configuration))
                    : .mamba(try DualPathMamba(w, "blocks.\(index)", configuration: configuration))
            }
            // The decoder's conditioning on its fixed controls [1, 0].
            let condition = try w.linear("denoise_decoder.condition")
            let scaleShift = condition(MLXArray([Float(1), 0]))
            decoderScale = 1 + scaleShift[..<configuration.width]
            decoderShift = scaleShift[configuration.width...]
            heads = try edges.indices.map { index in
                let prefix = "denoise_decoder.heads.\(index)"
                return BandHead(
                    norm: try w.layerNorm("\(prefix).0"),
                    hidden: try w.linear("\(prefix).1"),
                    output: try w.linear("\(prefix).3")
                )
            }
            transform = InworldSpectralTransform(nFFT: configuration.nFFT, hop: configuration.hopLength)
        }

        /// Band tokens `[batch, bands, frames, width]` of spectra `[batch, frames, bins]`.
        func encode(_ spectrum: MLXArray) -> MLXArray {
            // Interleave each bin's real and imaginary parts, as view_as_real does.
            let components = stacked([spectrum.realPart(), spectrum.imaginaryPart()], axis: -1)
            let (batch, frames) = (spectrum.dim(0), spectrum.dim(1))
            let tokens = zip(edges, encoders).map { edge, encoder in
                let band = components[0..., 0..., edge, 0...].reshaped(batch, frames, 2 * edge.count)
                return encoder.projection(encoder.norm(band))
            }
            return stacked(tokens, axis: 1) + bandEmbedding[.newAxis, 0..., .newAxis, 0...]
        }

        /// The decoder's output `[batch, bins, frames, 4]` for features `[batch, bands, frames, width]`.
        func decode(_ features: MLXArray) -> MLXArray {
            let (batch, frames) = (features.dim(0), features.dim(2))
            let features = features * decoderScale + decoderShift
            let outputs = zip(edges.enumerated(), heads).map { item, head in
                let (index, edge) = item
                return head(features[0..., index]).reshaped(batch, frames, edge.count, 4)
            }
            return concatenated(outputs, axis: 2).transposed(0, 2, 1, 3)
        }

        /// The complex change of the spectrum `[batch, frames, bins]` that the decoder's output encodes.
        func correction(_ raw: MLXArray, spectrum: MLXArray) -> MLXArray {
            // raw is [batch, bins, frames, 4]; work in [batch, frames, bins].
            let raw = raw.transposed(0, 2, 1, 3)
            let mask = 2 * tanh(raw[.ellipsis, 0 ..< 2])
            let components = tanh(raw[.ellipsis, 2 ..< 4])
            let norm = maximum(sqrt((components * components).sum(axis: -1, keepDims: true)), 1)
            let magnitude = abs(spectrum)
            let residual = components / norm * (configuration.correctionBound * magnitude)[.ellipsis, .newAxis]
            let (re, im) = (spectrum.realPart(), spectrum.imaginaryPart())
            let (mr, mi) = (mask[.ellipsis, 0], mask[.ellipsis, 1])
            let real = re * mr - im * mi + residual[.ellipsis, 0]
            let imaginary = re * mi + im * mr + residual[.ellipsis, 1]
            return real + imaginary.asImaginary()
        }

        /// The isolated voice `[batch, samples]` of equally long clips `[batch, samples]`.
        func callAsFunction(_ audio: MLXArray) -> MLXArray {
            let spectrum = transform.forward(audio)
            var features = encode(spectrum)
            let rope = RotaryTables(frames: spectrum.dim(1), headDim: configuration.width / configuration.numHeads)
            for block in blocks {
                features = block(features, rope: rope)
            }
            let raw = decode(features)
            let correction = correction(raw, spectrum: spectrum)
            return audio + transform.inverse(correction, length: audio.dim(1))
        }
    }

    extension MLXArray {
        /// This real array times the imaginary unit.
        fileprivate func asImaginary() -> MLXArray {
            self * MLXArray(real: 0, imaginary: 1)
        }
    }
#endif
