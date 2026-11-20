import AnySoundIsolator
import ArgumentParser

struct Status: CancellableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check that the model can run and has its assets, without downloading."
    )

    @OptionGroup(title: "Model Options") var model: ModelOptions

    @concurrent func execute() async throws {
        let isolator = model.isolator()
        // A model without its files is unavailable, and it returns a request for them.
        if try await isolator.assetInstallationRequest() != nil {
            print("assets not installed")
        } else {
            print(isolator.isAvailable ? "available" : "unavailable")
        }
    }
}
