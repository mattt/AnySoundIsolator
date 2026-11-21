#if MLX
    import Foundation
    import Synchronization

    /// Runs one operation for every caller that asks for it at the same time.
    ///
    /// Cancelling one caller ends that caller's wait.
    /// The operation is cancelled only when no caller still waits for it.
    /// A caller that arrives while a cancelled operation stops does not join it:
    /// it waits for that operation to end, and then new work starts for it.
    /// The type has the shape of AnySpeechRecognizer's `SharedPreparation`.
    ///
    /// The mutex guards the decisions only.
    /// The type cancels the task and resumes continuations after it releases the mutex,
    /// because each of those can run other code or take other locks.
    final class SharedWork<Value: Sendable>: Sendable {
        private typealias Waiter = CheckedContinuation<Value, any Error>
        private typealias Operation = @Sendable () async throws -> Value

        private struct State {
            var task: Task<Void, Never>?
            /// Whether the last caller left the task and the task was cancelled.
            /// Its result is for no caller.
            var isAbandoned = false
            var waiters: [UUID: Waiter] = [:]
            /// Callers that arrived while an abandoned task stops, and the operation to run for them.
            var next: [UUID: Waiter] = [:]
            var nextOperation: Operation?
        }

        private let state = Mutex(State())

        /// Whether the operation is running.
        var isRunning: Bool { state.withLock { $0.task != nil } }

        /// The number of callers that wait, for the operation or for new work.
        var callerCount: Int { state.withLock { $0.waiters.count + $0.next.count } }

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

        private func wait(operation: @escaping Operation) async throws -> Value {
            let id = UUID()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    let isCancelled = state.withLock { state in
                        // The handler sets the flag before it runs,
                        // so a caller that it did not find here sees the flag.
                        if Task.isCancelled { return true }
                        if state.task != nil, state.isAbandoned {
                            state.next[id] = continuation
                            if state.nextOperation == nil { state.nextOperation = operation }
                        } else {
                            state.waiters[id] = continuation
                            if state.task == nil { start(operation, in: &state) }
                        }
                        return false
                    }
                    if isCancelled { continuation.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                // The caller's continuation leaves the state under the mutex, so it has one owner.
                let (waiter, abandoned) = self.state.withLock { state -> (Waiter?, Task<Void, Never>?) in
                    if let waiter = state.next.removeValue(forKey: id) {
                        if state.next.isEmpty { state.nextOperation = nil }
                        return (waiter, nil)
                    }
                    guard let waiter = state.waiters.removeValue(forKey: id) else { return (nil, nil) }
                    guard state.waiters.isEmpty, let task = state.task else { return (waiter, nil) }
                    state.isAbandoned = true
                    return (waiter, task)
                }
                abandoned?.cancel()
                waiter?.resume(throwing: CancellationError())
            }
        }

        private func start(_ operation: @escaping Operation, in state: inout State) {
            state.isAbandoned = false
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

        private func complete(_ result: Result<Value, any Error>) {
            let waiters = state.withLock { state in
                state.task = nil
                state.isAbandoned = false
                let waiters = Array(state.waiters.values)
                state.waiters.removeAll()
                // The callers that waited for an abandoned task to stop get work of their own.
                if let operation = state.nextOperation {
                    state.waiters = state.next
                    state.next.removeAll()
                    state.nextOperation = nil
                    start(operation, in: &state)
                }
                return waiters
            }
            for waiter in waiters { waiter.resume(with: result) }
        }
    }
#endif
