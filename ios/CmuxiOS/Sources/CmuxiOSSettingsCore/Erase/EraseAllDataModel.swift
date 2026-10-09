public import Observation

/// Settings > Erase All Data: the typed confirmation and the run. The app
/// supplies `perform` (sign out, stop sessions, wipe, then the final screen).
@MainActor
@Observable
public final class EraseAllDataModel {
    public enum Phase: Hashable, Sendable {
        case idle
        case erasing
        case finished(EraseReport)
    }

    public var typed = ""
    public private(set) var phase: Phase = .idle
    public let rule: EraseConfirmationRule
    @ObservationIgnored private let perform: @MainActor () async -> EraseReport

    public init(rule: EraseConfirmationRule, perform: @escaping @MainActor () async -> EraseReport) {
        self.rule = rule
        self.perform = perform
    }

    public var canErase: Bool { phase == .idle && rule.matches(typed) }

    public func erase() async {
        guard canErase else { return }
        phase = .erasing
        phase = .finished(await perform())
    }
}
