import Foundation

/// How the composer's Send reaches the program (Codex QA F1). The draft goes
/// as one paste (bracketed when the program turned bracketed paste on, as
/// Codex, zsh and vim do), and Return goes as its own keystroke after the
/// paste was written. Sent back to back as typed text plus Enter, Codex's
/// paste-burst detection took the Enter for a newline inside the burst: the
/// prompt stayed a draft until a second, empty Send. Portable, unit tested.
public struct ComposerSubmit: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        /// The whole draft, one paste (several lines stay one paste).
        case paste(String)
        /// Return, as a separate write once the paste is out.
        case enter
    }

    /// Time between the paste and its Return: the paste leaves in its own
    /// write and a program reading in bursts sees Return after it, not in it.
    public static let enterDelay: Duration = .milliseconds(60)

    public let steps: [Step]

    public init(text: String, pressReturn: Bool) {
        var steps: [Step] = []
        if !text.isEmpty { steps.append(.paste(text)) }
        if pressReturn { steps.append(.enter) }
        self.steps = steps
    }

    /// Whether Return waits for `enterDelay` (it follows a paste).
    public var delaysEnter: Bool {
        steps.first.map { if case .paste = $0 { true } else { false } } ?? false
    }
}
