public import CmuxiOSFeatureKit
import Foundation

/// Onboarding's "create your first machine": waits for the live plan,
/// picks the smallest unlocked size and sends one create with one key.
public struct CloudFirstMachine: Sendable {
    public let source: any CloudMachineSource
    public let name: String?

    public init(source: any CloudMachineSource, name: String? = nil) {
        self.source = source
        self.name = name
    }

    public func create(key: IntentKey = IntentKey()) async -> CloudFirstMachineOutcome {
        // The subscription stays open until the create is answered: the real
        // source refuses intents while nobody keeps its connection up.
        let updates = await source.updates()
        defer { withExtendedLifetime(updates) {} }
        var plan: CloudPlan?
        for await snapshot in updates {
            if case .offline = snapshot.connection { return .offline }
            if snapshot.connection.isLive, let current = snapshot.value.plan {
                plan = current
                break
            }
        }
        guard let plan else { return .offline }
        let options = CloudCreateOptions(plan: plan)
        guard plan.hasPlan else { return .refused(code: "cloud.plan.required") }
        guard options.hasRoom else { return .refused(code: "cloud.quota.exceeded") }
        guard let size = options.defaultOption else { return .refused(code: "cloud.size.locked") }
        do {
            switch try await source.perform(.create(name: name, size: size.size), key: key) {
            case .committed: return .created
            case .refused(_, let reason): return .refused(code: reason)
            }
        } catch {
            return .offline
        }
    }
}
