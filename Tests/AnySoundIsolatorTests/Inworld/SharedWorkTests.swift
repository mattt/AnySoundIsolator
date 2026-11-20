#if MLX
    import Foundation
    import Synchronization
    import Testing

    @testable import AnySoundIsolator

    /// Tests of the work that the callers of one installation share.
    @Suite struct SharedWorkTests {
        /// An operation that waits until a test lets it continue, and that cancellation does not end.
        final class Gate: Sendable {
            private let state = Mutex<(isOpen: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))
            let (started, startedSignal) = AsyncStream<Void>.makeStream()

            func wait() async {
                startedSignal.yield()
                await withCheckedContinuation { continuation in
                    let isOpen = state.withLock { state in
                        if !state.isOpen { state.waiter = continuation }
                        return state.isOpen
                    }
                    if isOpen { continuation.resume() }
                }
            }

            func open() {
                let waiter = state.withLock { state in
                    state.isOpen = true
                    defer { state.waiter = nil }
                    return state.waiter
                }
                waiter?.resume()
            }
        }

        /// The first caller is cancelled, and its operation takes time to stop.
        /// A caller that arrives in that interval gets new work, not the cancellation of the first.
        @Test func callerDuringACancellationGetsNewWork() async throws {
            let work = SharedWork<Int>()
            let gate = Gate()
            let secondRuns = Mutex(0)
            let first = Task {
                try await work.value {
                    await gate.wait()
                    return 1
                }
            }
            var started = gate.started.makeAsyncIterator()
            _ = await started.next()
            first.cancel()
            // The first operation is cancelled and has not stopped.
            #expect(work.isRunning)

            let second = Task {
                try await work.value {
                    secondRuns.withLock { $0 += 1 }
                    return 2
                }
            }
            try await Task.sleep(for: .milliseconds(100))
            // The second caller waits for the first operation to stop.
            #expect(secondRuns.withLock { $0 } == 0)

            gate.open()
            #expect(try await second.value == 2)
            await #expect(throws: CancellationError.self) { try await first.value }
            #expect(secondRuns.withLock { $0 } == 1)
            #expect(!work.isRunning)
        }

        /// A caller that waits for new work and is cancelled starts none.
        @Test func cancelledCallerDuringACancellationStartsNoWork() async throws {
            let work = SharedWork<Int>()
            let gate = Gate()
            let secondRuns = Mutex(0)
            let first = Task {
                try await work.value {
                    await gate.wait()
                    return 1
                }
            }
            var started = gate.started.makeAsyncIterator()
            _ = await started.next()
            first.cancel()
            let second = Task {
                try await work.value {
                    secondRuns.withLock { $0 += 1 }
                    return 2
                }
            }
            try await Task.sleep(for: .milliseconds(100))
            second.cancel()

            // A cancelled caller returns after the operation stops, so that it leaves none running.
            gate.open()
            await #expect(throws: CancellationError.self) { try await second.value }
            await #expect(throws: CancellationError.self) { try await first.value }
            #expect(secondRuns.withLock { $0 } == 0)
            #expect(!work.isRunning)
        }

        @Test func callersAtTheSameTimeShareOneOperation() async throws {
            let work = SharedWork<Int>()
            let gate = Gate()
            let runs = Mutex(0)
            let operation: @Sendable () async throws -> Int = {
                runs.withLock { $0 += 1 }
                await gate.wait()
                return 7
            }
            async let first = work.value(operation: operation)
            var started = gate.started.makeAsyncIterator()
            _ = await started.next()
            async let second = work.value(operation: operation)
            try await Task.sleep(for: .milliseconds(50))
            gate.open()
            #expect(try await (first, second) == (7, 7))
            #expect(runs.withLock { $0 } == 1)
        }
    }
#endif
