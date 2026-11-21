import AnySoundIsolator
import ArgumentParser
import Foundation

struct Prepare: CancellableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Download and verify the files that the model needs.",
        discussion: """
            The system model needs no files. \
            The inworld model needs one file of 256 MB, which goes into the Hugging Face cache. \
            A file that is already in the cache is verified and not downloaded again.
            """
    )

    @OptionGroup(title: "Model Options") var model: ModelOptions

    @concurrent func execute() async throws {
        let isolator = model.isolator()
        guard let request = try await isolator.assetInstallationRequest() else {
            print(isolator.isAvailable ? "available" : "unavailable")
            return
        }
        // The report is a child task, so it ends with the installation,
        // and a cancellation of this task reaches the installation directly.
        try await withThrowingDiscardingTaskGroup { group in
            group.addTask {
                // Report only while the count changes, so a file from the cache prints nothing.
                var reported: Int64 = 0
                while (try? await Task.sleep(for: .seconds(1))) != nil {
                    let completed = request.progress.completedUnitCount
                    guard completed != reported else { continue }
                    reported = completed
                    let megabytes = (completed / 1_000_000, request.progress.totalUnitCount / 1_000_000)
                    FileHandle.standardError.write(Data("Downloaded \(megabytes.0) of \(megabytes.1) MB\n".utf8))
                }
            }
            try await request.downloadAndInstall()
            group.cancelAll()
        }
        print(isolator.isAvailable ? "available" : "unavailable")
    }
}
