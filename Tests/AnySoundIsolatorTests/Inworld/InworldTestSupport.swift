#if MLX
    import CryptoKit
    import Foundation
    import HuggingFace
    import MLX
    import Synchronization

    @testable import AnySoundIsolator

    /// Whether the tests that compute on the GPU run. Set `ENABLE_MLX_TESTS=1` to run them.
    /// They need a Mac with Apple silicon, and they download nothing.
    let shouldRunMLXTests = ProcessInfo.processInfo.environment["ENABLE_MLX_TESTS"] == "1"

    /// Whether the tests that load Inworld's checkpoint run. Set `ENABLE_INWORLD_TESTS=1` to run them.
    /// They download the checkpoint (256 MB) unless it is in the Hugging Face cache.
    let shouldRunInworldTests = ProcessInfo.processInfo.environment["ENABLE_INWORLD_TESTS"] == "1"

    /// An in-memory Hugging Face host that `URLProtocol` reaches, with a host name of its own.
    ///
    /// Like the Hub, it answers `HEAD` with the commit and ETag headers that the cache uses,
    /// and it serves each file as an LFS file whose ETag is its SHA-256 digest.
    final class StubModelServer: Sendable {
        struct Request: Sendable, Equatable {
            let method: String
            let path: String
        }

        private struct State {
            var files: [String: Data]
            var requests: [Request] = []
        }

        private static let servers = Mutex<[String: StubModelServer]>([:])
        let host = "stub-\(UUID().uuidString.lowercased()).test"
        private let state: Mutex<State>

        init(files: [String: Data]) {
            state = Mutex(State(files: files))
            Self.servers.withLock { $0[host] = self }
        }

        static func server(for host: String?) -> StubModelServer? {
            servers.withLock { servers in host.flatMap { servers[$0] } }
        }

        var requests: [Request] { state.withLock { $0.requests } }

        /// The number of `GET` requests for a file.
        func downloadCount(of path: String) -> Int {
            requests.count { $0.method == "GET" && $0.path == path }
        }

        func setFile(_ path: String, _ data: Data) { state.withLock { $0.files[path] = data } }

        /// Creates a store that downloads from this server into a cache under `root`.
        ///
        /// - Parameters:
        ///   - root: The directory for the cache and the markers.
        ///   - markers: The name of the marker directory. A store with another name sees no file as verified.
        func makeStore(root: URL, markers: String = "verified") -> InworldAssetStore {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [StubModelProtocol.self]
            return InworldAssetStore(
                cacheDirectory: root.appending(path: "hub"),
                markerDirectory: root.appending(path: markers),
                session: URLSession(configuration: configuration),
                host: URL(string: "https://\(host)")!
            )
        }

        fileprivate func handle(_ request: URLRequest, with stub: StubModelProtocol) {
            let method = request.httpMethod ?? "GET"
            // The path is /<owner>/<name>/resolve/<revision>/<path>.
            let components = request.url?.pathComponents.filter { $0 != "/" } ?? []
            guard let index = components.firstIndex(of: "resolve"), components.count > index + 2 else {
                stub.send(status: 404, headers: [:], body: Data())
                return
            }
            let path = components[(index + 2)...].joined(separator: "/")
            let data = state.withLock { state in
                state.requests.append(Request(method: method, path: path))
                return state.files[path]
            }
            guard let data else {
                stub.send(status: 404, headers: [:], body: Data())
                return
            }
            let headers = [
                "Content-Type": "application/octet-stream",
                "X-Repo-Commit": components[index + 1],
                "X-Linked-Etag": "\"\(InworldFixture.sha256(data))\"",
                "X-Linked-Size": "\(data.count)",
            ]
            stub.send(status: 200, headers: headers, body: method == "HEAD" ? Data() : data)
        }
    }

    final class StubModelProtocol: URLProtocol, @unchecked Sendable {
        private let stopped = Mutex(false)

        override class func canInit(with request: URLRequest) -> Bool {
            StubModelServer.server(for: request.url?.host()) != nil
        }

        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let server = StubModelServer.server(for: request.url?.host()) else {
                client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
                return
            }
            server.handle(request, with: self)
        }

        override func stopLoading() { stopped.withLock { $0 = true } }

        fileprivate func send(status: Int, headers: [String: String], body: Data) {
            guard stopped.withLock({ !$0 }), let url = request.url,
                let response = HTTPURLResponse(
                    url: url,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: headers
                )
            else { return }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    enum InworldFixture {
        static let path = "denoiser.safetensors"

        /// Bytes that stand in for a checkpoint file. They are not a checkpoint.
        static func bytes(_ count: Int, seed: UInt8 = 1) -> Data {
            Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
        }

        static func sha256(_ data: Data) -> String {
            SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }

        /// A checkpoint record for a file's contents.
        static func checkpoint(for data: Data) -> InworldCheckpoint {
            InworldCheckpoint(
                repository: "example/voice-isolator-test",
                revision: "0123456789abcdef0123456789abcdef01234567",
                path: path,
                size: Int64(data.count),
                sha256: sha256(data)
            )
        }

        /// The configuration of the released offline checkpoint, as its file's metadata holds it.
        static let offlineConfiguration = """
            {"band_plan": [[100, 1000], [250, 4000], [500, 8000], [1000, 16000], [2000, 24000]],
             "block_types": ["transformer", "mamba", "transformer", "mamba", "transformer", "mamba", "transformer"],
             "causal": false, "chunk_seconds": 8.0, "correction_bound": 0.5, "dual_mode": false,
             "exclusive_axes": "time", "exclusive_self_attention": true, "hop_length": 480,
             "lookahead_frames": 0, "lookahead_frames_choices": [], "mamba_conv": 4, "mamba_expand": 2,
             "mamba_state": 16, "mode_film": false, "n_fft": 2048, "num_heads": 8, "overlap_seconds": 2.0,
             "sample_rate": 48000, "width": 512}
            """

        /// The configuration of a small network with the released checkpoint's structure:
        /// windows of 4,800 samples that overlap by 1,200, and one block of each kind.
        static let smallConfiguration = """
            {"band_plan": [[1500, 6000], [3000, 24000]],
             "block_types": ["transformer", "mamba"],
             "causal": false, "chunk_seconds": 0.1, "correction_bound": 0.5, "dual_mode": false,
             "exclusive_axes": "time", "exclusive_self_attention": true, "hop_length": 32,
             "lookahead_frames": 0, "lookahead_frames_choices": [], "mamba_conv": 4, "mamba_expand": 2,
             "mamba_state": 4, "mode_film": false, "n_fft": 128, "num_heads": 2, "overlap_seconds": 0.025,
             "sample_rate": 48000, "width": 16}
            """

        static func configuration(_ json: String) throws -> InworldConfiguration {
            try JSONDecoder().decode(InworldConfiguration.self, from: Data(json.utf8))
        }

        /// Writes a checkpoint file with random weights for the small configuration.
        ///
        /// The network isolates nothing; the file tests loading, shapes, and window placement
        /// without a download.
        static func writeSmallCheckpoint(
            to url: URL,
            changing change: (inout [String: MLXArray]) -> Void = { _ in }
        ) throws {
            let configuration = try configuration(smallConfiguration)
            let width = configuration.width
            let inner = configuration.mambaExpand * width
            let states = configuration.mambaState
            let rank = (width + 15) / 16
            var arrays: [String: MLXArray] = [:]
            MLXRandom.seed(7)
            func weight(_ name: String, _ shape: [Int], scale: Float = 0.2) {
                arrays[name] = MLXRandom.normal(shape) * scale
            }
            func linear(_ prefix: String, _ output: Int, _ input: Int, bias: Bool = true) {
                weight("\(prefix).weight", [output, input])
                if bias { weight("\(prefix).bias", [output]) }
            }
            func layerNorm(_ prefix: String, _ size: Int) {
                arrays["\(prefix).weight"] = MLXArray.ones([size])
                weight("\(prefix).bias", [size], scale: 0.05)
            }
            for (index, edge) in configuration.bandEdges.enumerated() {
                layerNorm("encoders.\(index).0", 2 * edge.count)
                linear("encoders.\(index).1", width, 2 * edge.count)
                layerNorm("denoise_decoder.heads.\(index).0", width)
                linear("denoise_decoder.heads.\(index).1", 2 * width, width)
                linear("denoise_decoder.heads.\(index).3", 4 * edge.count, 2 * width)
            }
            weight("band_embedding", [configuration.bandEdges.count, width])
            linear("denoise_decoder.condition", 2 * width, 2)
            for (index, kind) in configuration.blockTypes.enumerated() {
                let block = "blocks.\(index)"
                if kind == "transformer" {
                    let time = "\(block).time_transformer"
                    layerNorm("\(time).norm1", width)
                    layerNorm("\(time).norm2", width)
                    linear("\(time).attn.qkv", 3 * width, width)
                    linear("\(time).attn.proj", width, width)
                    linear("\(time).ffn.0", 4 * width, width)
                    linear("\(time).ffn.3", width, 4 * width)
                    let band = "\(block).band_transformer"
                    layerNorm("\(band).norm1", width)
                    layerNorm("\(band).norm2", width)
                    weight("\(band).self_attn.in_proj_weight", [3 * width, width])
                    weight("\(band).self_attn.in_proj_bias", [3 * width])
                    linear("\(band).self_attn.out_proj", width, width)
                    linear("\(band).linear1", 4 * width, width)
                    linear("\(band).linear2", width, 4 * width)
                } else {
                    for path in ["time_mamba", "freq_mamba"] {
                        for direction in ["forward_blocks", "backward_blocks"] {
                            let mamba = "\(block).\(path).\(direction)"
                            linear("\(mamba).in_proj", 2 * inner, width, bias: false)
                            linear("\(mamba).x_proj", rank + 2 * states, inner, bias: false)
                            linear("\(mamba).dt_proj", inner, rank)
                            linear("\(mamba).out_proj", width, inner, bias: false)
                            weight("\(mamba).conv1d.weight", [inner, 1, configuration.mambaConv])
                            weight("\(mamba).conv1d.bias", [inner])
                            weight("\(mamba).A_log", [inner, states])
                            weight("\(mamba).D", [inner])
                        }
                        linear("\(block).\(path).output_proj", width, 2 * width)
                        layerNorm("\(block).\(path).norm", width)
                    }
                }
            }
            change(&arrays)
            try save(arrays: arrays, metadata: ["config": smallConfiguration], url: url)
        }
    }

    /// Runs a test body with a directory that is removed afterward.
    func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
        let url = try TestAudio.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(url)
    }
#endif
