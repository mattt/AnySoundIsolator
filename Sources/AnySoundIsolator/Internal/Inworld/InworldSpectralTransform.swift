// This file is adapted from Inworld Voice Isolator (https://github.com/inworld-ai/voice-isolator),
// Copyright 2026 Inworld AI, licensed under the Apache License, Version 2.0.
// It adapts the transforms that `src/inworld/voice_isolation/model.py` uses.
// This file was changed from the original:
// the code is rewritten from Python for PyTorch to Swift for MLX,
// with the short-time Fourier transform and its inverse written out.
// See the NOTICE file.

#if MLX
    import Foundation
    import MLX

    /// The short-time Fourier transform and its inverse,
    /// as `torch.stft` and `torch.istft` compute them with `center=True` and a periodic Hann window.
    struct InworldSpectralTransform {
        let nFFT: Int
        let hop: Int
        private let windowValues: [Float]
        private let window: MLXArray

        init(nFFT: Int, hop: Int) {
            self.nFFT = nFFT
            self.hop = hop
            windowValues = (0 ..< nFFT).map { n in
                Float(0.5 - 0.5 * cos(2 * Double.pi * Double(n) / Double(nFFT)))
            }
            window = MLXArray(windowValues)
        }

        /// The number of frames in the spectrum of a signal.
        func frameCount(samples: Int) -> Int { 1 + samples / hop }

        /// Returns the complex spectra `[batch, frames, bins]` of audio `[batch, samples]`.
        ///
        /// The signal is padded by half a window on each side: by reflection,
        /// or with zeros when it is no longer than half a window, as Inworld's model does.
        func forward(_ audio: MLXArray) -> MLXArray {
            let (batch, samples) = (audio.dim(0), audio.dim(1))
            let frames = frameCount(samples: samples)
            let pad = nFFT / 2
            let reflect = samples > pad
            var indices = [Int32](repeating: 0, count: frames * nFFT)
            for frame in 0 ..< frames {
                for k in 0 ..< nFFT {
                    let p = frame * hop + k - pad
                    let index: Int
                    if reflect {
                        index = p < 0 ? -p : (p >= samples ? 2 * (samples - 1) - p : p)
                    } else {
                        // The extra zero sample at the end stands in for the padding.
                        index = (0 ..< samples).contains(p) ? p : samples
                    }
                    indices[frame * nFFT + k] = Int32(index)
                }
            }
            let source = reflect ? audio : concatenated([audio, zeros([batch, 1])], axis: 1)
            let framed = take(source, MLXArray(indices), axis: 1).reshaped(batch, frames, nFFT)
            return rfft(framed * window, axis: -1)
        }

        /// Returns audio `[batch, length]` from complex spectra `[batch, frames, bins]`.
        ///
        /// The hop must be shorter than the window,
        /// so that the windows' envelope is above zero at every sample that they cover.
        func inverse(_ spectrum: MLXArray, length: Int) -> MLXArray {
            let (batch, frames) = (spectrum.dim(0), spectrum.dim(1))
            let span = (nFFT + hop - 1) / hop
            var y = irfft(spectrum, n: nFFT, axis: -1) * window
            // Overlap-add: split each frame into `span` hops,
            // and add hop r of frame f to output hop f + r.
            y = padded(y, widths: [0, 0, .init((0, span * hop - nFFT))]).reshaped(batch, frames, span, hop)
            var sum = MLXArray.zeros([batch, frames + span - 1, hop])
            for r in 0 ..< span {
                sum = sum + padded(y[0..., 0..., r, 0...], widths: [0, .init((r, span - 1 - r)), 0])
            }
            let total = (frames + span - 1) * hop
            var signal = sum.reshaped(batch, total)
            let start = nFFT / 2
            // As `torch.istft` does, keep the samples that the windows cover, which the envelope has,
            // and pad the rest of the length with zeros.
            // Only a hop larger than about half the window leaves such a rest.
            let covered = (frames - 1) * hop + nFFT
            let available = min(length, covered - start)
            signal =
                signal[0..., start ..< (start + available)]
                / envelope(frames: frames, start: start, count: available)
            if available < length {
                signal = padded(signal, widths: [0, .init((0, length - available))])
            }
            return signal
        }

        /// The sum of the squared windows at each sample, which the inverse divides by.
        private func envelope(frames: Int, start: Int, count: Int) -> MLXArray {
            var values = [Float](repeating: 0, count: (frames - 1) * hop + nFFT)
            for frame in 0 ..< frames {
                for k in 0 ..< nFFT {
                    values[frame * hop + k] += windowValues[k] * windowValues[k]
                }
            }
            return MLXArray(Array(values[start ..< (start + count)]))
        }
    }
#endif
