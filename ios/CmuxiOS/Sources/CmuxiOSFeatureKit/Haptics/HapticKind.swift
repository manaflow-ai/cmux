/// The haptics cmux plays. Each maps to one system feedback generator.
public enum HapticKind: Hashable, Sendable, CaseIterable {
    case selection
    case lightImpact
    case success
    case warning
    case error
}
