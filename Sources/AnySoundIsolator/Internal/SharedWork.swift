#if MLX
    import Foundation
    import Synchronization

    /// Runs one operation for every caller that asks for it at the same time.
    ///
    /// Cancelling one caller ends that caller's wait.
    /// The operation is cancelled only when no caller still waits for it.
    /// The type has the shape of AnySpeechRecognizer's `SharedPreparation`.
    final class SharedWork<Value: Sendable>: Sendable {
        private struct State {
            var task: Task<Void, Never>?
            var waiters: [UUID: CheckedContinuation<Value, any Error>] = [:]
        }

        private let state = Mutex(State())

        /// Whether the operation is running.
        var isRunning: Bool { state.withLock { $0.task != nil } }

        /// Waits for the operation, and starts it when it is not running.
        func value(operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
            do {
                let value = try await wait(operation: operation)
                try Task.checkCancellation()
                return value
            } catch {
                // The last cancelled caller waits for the operation to stop,
                // so that it leaves no download running.
                let unused = state.withLock { state in
                    state.waiters.isEmpty ? state.task : nil
                }
                if Task.isCancelled { await unused?.value }
                throw error
            }
        }

        private func wait(operation: @escaping @Sendable () async throws -> Value) async throws -> Value {
            let id = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    state.withLock { state in
                        if Task.isCancelled {
                            continuation.resume(throwing: CancellationError())
                            return
                        }
                        state.waiters[id] = continuation
                        if state.task == nil {
                            state.task = Task {
                                let result: Result<Value, any Error>
                                do {
                                    let value = try await operation()
                                    try Task.checkCancellation()
                                    result = .success(value)
                                } catch {
                                    result = .failure(error)
                                }
                                self.complete(result)
                            }
                        }
                    }
                }
            } onCancel: {
                self.state.withLock { state in
                    if let waiter = state.waiters.removeValue(forKey: id) {
                        waiter.resume(throwing: CancellationError())
                    }
                    if state.waiters.isEmpty { state.task?.cancel() }
                }
            }
        }

        private func complete(_ result: Result<Value, any Error>) {
            state.withLock { state in
                state.task = nil
                let waiters = state.waiters.values
                state.waiters.removeAll()
                for waiter in waiters { waiter.resume(with: result) }
            }
        }
    }
#endif
