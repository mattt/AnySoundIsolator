#if MLX
    /// Places the windows of a stream and joins their output,
    /// with the result that `VoiceIsolatorNetwork.enhance` in Inworld's `model.py` gives for the whole clip.
    ///
    /// Inworld's offline render knows the length of the clip.
    /// It starts a full window at each multiple of the hop, which is the window minus the crossfade,
    /// and it ends the last window at the end of the clip.
    /// The last window reaches back over the window before it
    /// and fades in where that window fades out.
    /// A clip that is no longer than one window is one pass over the clip.
    ///
    /// A stream does not know its length, and the assembler does not need it:
    /// only the last crossfade of each window depends on what follows the window.
    /// The assembler runs a window as soon as the stream has its samples
    /// and releases the frames before the window's last crossfade.
    /// It holds the crossfade until the next window or the end of the stream.
    /// At the end, it places the last window as Inworld does.
    /// The frames are therefore the same as for the whole clip, and they arrive later:
    /// the first frames after one window of input, and the rest one hop at a time.
    ///
    /// The assembler does not run the network.
    /// The caller renders the windows that it asks for:
    ///
    /// ```swift
    /// assembler.append(samples)
    /// while let window = assembler.nextWindow() {
    ///     output += assembler.accept(render(window))
    /// }
    /// // After the last input:
    /// output += assembler.finish(assembler.lastWindow().map(render))
    /// ```
    struct InworldWindowAssembler {
        /// The number of samples in a window.
        let chunk: Int
        /// The number of samples in the crossfade between two windows.
        let overlap: Int
        /// The distance between the starts of two windows.
        private var hop: Int { chunk - overlap }

        /// The crossfade weights of a window's start and of a window's end.
        private let fadeIn: [Float]
        private let fadeOut: [Float]

        /// The input from `base` on.
        private var input: [Float] = []
        /// The position of `input[0]`, which is the start of the last window that the assembler gave out.
        private var base = 0
        /// The number of samples that the stream has supplied.
        private var received = 0
        /// The start of the next window.
        private var next = 0
        /// The last `overlap` samples of the last window's output, without weights,
        /// or `nil` before the first window.
        private var held: [Float]?

        /// Creates an assembler.
        ///
        /// - Parameters:
        ///   - chunk: The number of samples in a window.
        ///   - overlap: The number of samples in the crossfade, which is at most half of the window.
        init(chunk: Int, overlap: Int) {
            precondition(chunk > 0 && overlap >= 0 && overlap <= chunk / 2, "The crossfade is at most half a window.")
            self.chunk = chunk
            self.overlap = overlap
            fadeIn = Self.linspace(0, 1, overlap)
            fadeOut = Self.linspace(1, 0, overlap)
        }

        /// Adds the next samples of the stream.
        mutating func append(_ samples: [Float]) {
            input.append(contentsOf: samples)
            received += samples.count
        }

        /// Returns the input of the next window when the stream has all of its samples.
        ///
        /// Give the window's output to ``accept(_:)`` before you call this method again.
        mutating func nextWindow() -> [Float]? {
            guard received >= next + chunk else { return nil }
            input.removeFirst(next - base)
            base = next
            return Array(input[..<chunk])
        }

        /// Takes the output of the window that ``nextWindow()`` returned
        /// and returns the frames that no later window changes.
        mutating func accept(_ output: [Float]) -> [Float] {
            precondition(output.count == chunk, "A window's output has the window's length.")
            var ready: [Float] = []
            ready.reserveCapacity(hop)
            if let held {
                ready += crossfade(from: held, to: output[..<overlap])
                ready += output[overlap ..< hop]
            } else {
                ready += output[..<hop]
            }
            held = Array(output[hop...])
            next += hop
            return ready
        }

        /// Returns the input of the window that ends at the end of the stream,
        /// or `nil` when the windows so far already reach the end.
        ///
        /// Call this method after the last input, and give the output to ``finish(_:)``.
        /// For a stream shorter than one window, the input is the whole stream.
        func lastWindow() -> [Float]? {
            guard held != nil else { return input.isEmpty ? nil : input }
            guard received > base + chunk else { return nil }
            return Array(input[(received - chunk - base)...])
        }

        /// Takes the output of the window that ``lastWindow()`` returned and returns the rest of the frames.
        mutating func finish(_ output: [Float]?) -> [Float] {
            defer {
                input = []
                held = nil
            }
            guard let held else { return output ?? [] }
            // The last window that ran ends at the end of the stream, so it does not fade out.
            guard let output else { return held }
            precondition(output.count == chunk, "A window's output has the window's length.")
            // The last window has no weight before the crossfade of the window before it.
            let silent = base + hop - (received - chunk)
            return crossfade(from: held, to: output[silent ..< silent + overlap]) + output[(silent + overlap)...]
        }

        /// Joins the end of one window and the start of the next,
        /// with Inworld's arithmetic: the sum of the weighted outputs, divided by the sum of the weights.
        private func crossfade(from old: [Float], to new: ArraySlice<Float>) -> [Float] {
            var result = [Float](repeating: 0, count: overlap)
            for (index, sample) in new.enumerated() {
                let total = old[index] * fadeOut[index] + sample * fadeIn[index]
                result[index] = total / max(fadeOut[index] + fadeIn[index], 1e-6)
            }
            return result
        }

        /// Returns evenly spaced values as `torch.linspace` computes them in Float32:
        /// the first half counts up from the start, and the second half counts back from the end.
        static func linspace(_ start: Float, _ end: Float, _ steps: Int) -> [Float] {
            guard steps > 1 else { return steps == 1 ? [start] : [] }
            let step = (end - start) / Float(steps - 1)
            let half = steps / 2
            return (0 ..< steps).map { index in
                index < half ? start + step * Float(index) : end - step * Float(steps - 1 - index)
            }
        }
    }
#endif
