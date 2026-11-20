#if MLX
    import MLX

    /// The selective state-space scan of the network's Mamba layers.
    ///
    /// The recurrence `h[t] = exp(delta[t] a) h[t-1] + delta[t] b[t] u[t]`
    /// and its readout `y[t] = (c[t] . h[t] + d u[t]) silu(z[t])` run frame by frame in Float32.
    /// One Metal kernel runs the whole scan,
    /// and each GPU thread keeps the state of one channel in registers.
    ///
    /// The kernel is adapted from `_METAL_SOURCE` in `scan.py` of Inworld's Voice Isolator,
    /// which is under the Apache License, Version 2.0; see the NOTICE file.
    /// This version reads its sizes from the shapes of its inputs,
    /// always applies the gate, and carries no state between calls.
    enum InworldSelectiveScan {
        /// The largest state size that the kernel holds in registers.
        static let maximumStates = 16

        private static let source = """
            const uint index = thread_position_in_grid.x;
            const uint rows = u_shape[0];
            const uint frames = u_shape[1];
            const uint channels = u_shape[2];
            if (index >= rows * channels) {
                return;
            }
            const uint row = index / channels;
            const uint channel = index % channels;
            float h[STATES];
            float rate[STATES];
            for (uint n = 0; n < STATES; ++n) {
                rate[n] = a[channel * STATES + n];
                h[n] = 0.0f;
            }
            const float skip = d[channel];
            for (uint t = 0; t < frames; ++t) {
                const uint at = (row * frames + t) * channels + channel;
                const uint bt = (row * frames + t) * STATES;
                const float step = delta[at];
                const float x = u[at];
                const float drive = step * x;
                float out = 0.0f;
                for (uint n = 0; n < STATES; ++n) {
                    h[n] = metal::precise::exp(step * rate[n]) * h[n] + drive * b[bt + n];
                    out += h[n] * c[bt + n];
                }
                out += x * skip;
                const float g = z[at];
                out *= metal::precise::divide(g, 1.0f + metal::precise::exp(-g));
                y[at] = out;
            }
            """

        private static let kernel = MLXFast.metalKernel(
            name: "inworld_selective_scan",
            inputNames: ["u", "delta", "a", "b", "c", "d", "z"],
            outputNames: ["y"],
            source: source
        )

        /// Runs the scan on the GPU.
        ///
        /// - Parameters:
        ///   - u: Inputs `[rows, frames, channels]`.
        ///   - delta: Step sizes `[rows, frames, channels]`, which are positive.
        ///   - a: Decay rates `[channels, states]`, which are negative.
        ///   - b: Input projections `[rows, frames, states]`.
        ///   - c: Output projections `[rows, frames, states]`.
        ///   - d: Skip gains `[channels]`.
        ///   - z: The gate `[rows, frames, channels]`; the kernel multiplies the output by its SiLU.
        /// - Returns: The output `[rows, frames, channels]`.
        static func scan(
            u: MLXArray,
            delta: MLXArray,
            a: MLXArray,
            b: MLXArray,
            c: MLXArray,
            d: MLXArray,
            z: MLXArray
        ) -> MLXArray {
            let (rows, frames, channels) = (u.dim(0), u.dim(1), u.dim(2))
            let states = a.dim(1)
            precondition(states <= maximumStates, "The scan kernel holds at most \(maximumStates) states.")
            let threads = rows * channels
            return kernel(
                [u, delta, a, b, c, d, z],
                template: [("STATES", states)],
                grid: (threads, 1, 1),
                threadGroup: (min(256, threads), 1, 1),
                outputShapes: [[rows, frames, channels]],
                outputDTypes: [.float32]
            )[0]
        }
    }
#endif
