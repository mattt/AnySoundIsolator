import AnySoundIsolator
import ArgumentParser
import Foundation

struct Isolate: CancellableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Isolate the voice in one local file and write it to another.",
        discussion: """
            The output has the input's sample rate, channel count, and length. \
            Its extension selects its type: wav and caf are exact, and m4a is AAC.
            """
    )

    @Argument(help: "A local audio file.")
    var input: String

    @Argument(help: "Where to write the isolated voice (wav, caf, or m4a).")
    var output: String

    @Option(
        help: ArgumentHelp(
            "Also write the sound that was removed, which is the input minus the voice.",
            valueName: "path"
        )
    )
    var background: String?

    @OptionGroup(title: "Model Options") var model: ModelOptions

    @concurrent func execute() async throws {
        let progress = Progress()
        let clock = ContinuousClock()
        let started = clock.now
        try await model.isolator().isolate(
            contentsOf: URL(fileURLWithPath: input),
            to: URL(fileURLWithPath: output),
            background: background.map { URL(fileURLWithPath: $0) },
            progress: progress
        )
        let elapsed = clock.now - started
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let message = String(format: "Isolated %lld frames in %.2f s.\n", progress.completedUnitCount, seconds)
        FileHandle.standardError.write(Data(message.utf8))
    }
}
