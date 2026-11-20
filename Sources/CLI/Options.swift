import AnySoundIsolator
import ArgumentParser

enum Engine: String, CaseIterable, ExpressibleByArgument {
    case system
}

/// Options that select a sound isolation model.
struct ModelOptions: ParsableArguments {
    @Option(help: "The sound isolation model.")
    var model: Engine = .system

    @Option(help: "The quality of the system model.")
    var quality: SystemSoundIsolationModel.Quality = .high

    func isolator() -> SoundIsolator {
        switch model {
        case .system:
            SoundIsolator(model: SystemSoundIsolationModel(quality: quality))
        }
    }
}

extension SystemSoundIsolationModel.Quality: ExpressibleByArgument {}
