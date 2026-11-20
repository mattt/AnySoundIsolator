import AnySoundIsolator
import ArgumentParser

enum Engine: String, CaseIterable, ExpressibleByArgument {
    case system
    #if MLX
        case inworld
    #endif
}

/// Options that select a sound isolation model.
struct ModelOptions: ParsableArguments {
    #if MLX
        @Option(help: "The sound isolation model. Install the inworld model's file with the prepare subcommand.")
        var model: Engine = .system
    #else
        @Option(help: "The sound isolation model. A build with the MLX trait adds the inworld model.")
        var model: Engine = .system
    #endif

    @Option(help: "The quality of the system model.")
    var quality: SystemSoundIsolationModel.Quality = .high

    func isolator() -> SoundIsolator {
        switch model {
        case .system:
            SoundIsolator(model: SystemSoundIsolationModel(quality: quality))
        #if MLX
            case .inworld:
                SoundIsolator(model: InworldSoundIsolationModel())
        #endif
        }
    }
}

extension SystemSoundIsolationModel.Quality: ExpressibleByArgument {}
extension IsolationOptions.ChannelPolicy: ExpressibleByArgument {}
