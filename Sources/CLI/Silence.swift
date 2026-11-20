import ArgumentParser
import Darwin
import Foundation

@main
struct Silence: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "silence",
        abstract: "Isolate a sound, such as a voice, in a local audio file.",
        discussion: "SIGINT and SIGTERM cancel the operation and remove unfinished output files.",
        subcommands: [Isolate.self, Prepare.self, Status.self],
        defaultSubcommand: Isolate.self
    )
}

/// A subcommand whose operation SIGINT and SIGTERM cancel.
///
/// Cancellation prints "Cancelled." and exits with status 130;
/// other errors print `error: <description>` and exit with status 1.
protocol CancellableCommand: AsyncParsableCommand, Sendable {
    func execute() async throws
}

extension CancellableCommand {
    mutating func run() async throws {
        let command = self
        let operation = Task { try await command.execute() }
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        let signals = [SIGINT, SIGTERM].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { @Sendable in operation.cancel() }
            source.activate()
            return source
        }
        defer { for source in signals { source.cancel() } }
        do {
            try await operation.value
        } catch is CancellationError {
            FileHandle.standardError.write(Data("Cancelled.\n".utf8))
            throw ExitCode(130)
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            throw ExitCode.failure
        }
    }
}
