import Foundation

public enum OnboardingMode: String, Hashable, Sendable {
    /// The first run: persisted, resumable, ends in the shell.
    case firstRun
    /// Replayed from Settings: in memory only, closes back to Settings.
    case replay
}
