import AnySoundIsolator
import ArgumentParser

struct Status: CancellableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check that the model can run and has its assets, without downloading."
    )

    @OptionGroup(title: "Model Options") var model: ModelOptions

    @concurrent func execute() async throws {
        let isolator = model.isolator()
        guard isolator.isAvailable else {
            print("unavailable")
            return
        }
        print(try await isolator.assetInstallationRequest() == nil ? "available" : "assets not installed")
    }
}
