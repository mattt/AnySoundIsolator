import Foundation

/// A request to download and install the assets that a model needs.
///
/// A request is the only place where the package uses the network for a local model.
/// Creating a request does not start a download;
/// call ``downloadAndInstall()`` to start it.
/// The type has the same shape as AnySpeechRecognizer's `AssetInstallationRequest`.
public final class AssetInstallationRequest: NSObject, ProgressReporting, Sendable {
    /// The progress of the download.
    public let progress: Progress

    private let install: @Sendable () async throws -> Void

    /// Creates a request for a model's assets.
    ///
    /// - Parameters:
    ///   - progress: A progress object that the operation updates.
    ///   - downloadAndInstall: The operation to run when the caller asks for the installation.
    public init(progress: Progress, downloadAndInstall: @escaping @Sendable () async throws -> Void) {
        self.progress = progress
        self.install = downloadAndInstall
    }

    /// Downloads and installs the assets.
    ///
    /// - Throws: A ``SoundIsolationError``, or `CancellationError`.
    public func downloadAndInstall() async throws {
        try Task.checkCancellation()
        do {
            try await install()
            try Task.checkCancellation()
        } catch {
            throw isolationError(error)
        }
    }
}
