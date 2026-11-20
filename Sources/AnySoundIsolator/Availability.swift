/// Whether a sound isolation model is ready to use.
///
/// This type has the same shape as AnyLanguageModel's `Availability`,
/// so each model can report its own reasons for being unavailable.
public enum Availability<UnavailableReason> {
    /// The model is ready to isolate sound.
    case available

    /// The model is not ready, for the given reason.
    case unavailable(UnavailableReason)
}

extension Availability: Equatable where UnavailableReason: Equatable {}
extension Availability: Hashable where UnavailableReason: Hashable {}
extension Availability: Sendable where UnavailableReason: Sendable {}
