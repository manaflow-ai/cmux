public import CmuxiOSFeatureKit
import Foundation

/// The create sheet's choices from the plan. The owner decides; locked sizes
/// show disabled with their reason, never hidden.
public struct CloudCreateOptions: Hashable, Sendable {
    public var sizes: [CloudSizeOption]
    public var hasPlan: Bool
    public var hasRoom: Bool

    public init(plan: CloudPlan?) {
        let locked = Set(plan?.limits.lockedMemoryOptionsMB ?? [])
        sizes = Set(plan?.limits.memoryOptionsMB ?? []).union(locked).sorted()
            .map { CloudSizeOption(memoryMB: $0, isLocked: locked.contains($0)) }
        hasPlan = plan?.hasPlan ?? false
        hasRoom = plan.map { CloudUsageSummary(plan: $0).hasRoom } ?? false
    }

    /// The smallest size the plan allows now.
    public var defaultOption: CloudSizeOption? { sizes.first { !$0.isLocked } }

    /// Create is offered with a plan that has room and an unlocked size.
    public var canCreate: Bool { hasPlan && hasRoom && defaultOption != nil }

    /// Trimmed name; empty means "let the owner name it".
    public static func normalizedName(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(80))
    }
}
