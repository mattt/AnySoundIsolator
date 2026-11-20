import Foundation

/// An error in configuration, audio, assets, or a sound isolation engine.
///
/// Cancellation is reported as `CancellationError`, not as a `SoundIsolationError`.
/// An error that the input sequence of a stream throws is rethrown unchanged.
public enum SoundIsolationError: Error, Sendable {
    /// The model does not support the requested sound, audio format, or file type.
    case unsupportedConfiguration(String)

    /// The model cannot run on this device.
    case unavailableModel(String)

    /// The model's assets are absent; install them before you isolate sound.
    case missingAssets(String)

    /// A downloaded file does not match its expected size or digest.
    /// The message names the file.
    case assetVerificationFailed(String)

    /// The audio cannot be read, or its format changed during a stream.
    case invalidAudio(String)

    /// An engine returned audio that does not match its own description.
    case invalidResult(String)

    /// An engine or a system framework failed; the original error is kept.
    case backendFailure(underlying: any Error)
}

extension SoundIsolationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedConfiguration(let reason), .unavailableModel(let reason),
            .missingAssets(let reason), .assetVerificationFailed(let reason),
            .invalidAudio(let reason), .invalidResult(let reason):
            return reason
        case .backendFailure(let error):
            return "Sound isolation failed: \(error.localizedDescription)"
        }
    }
}

/// Wraps an engine's error, and keeps cancellation and package errors as they are.
func isolationError(_ error: any Error) -> any Error {
    if error is CancellationError || error is SoundIsolationError { return error }
    return SoundIsolationError.backendFailure(underlying: error)
}
