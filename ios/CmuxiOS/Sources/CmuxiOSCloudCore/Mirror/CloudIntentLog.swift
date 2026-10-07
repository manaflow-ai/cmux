public import CmuxiOSFeatureKit

/// Intents sent and not answered yet, in send order. The visible state is
/// the mirror with these overlaid; an intent leaves on its reply.
public struct CloudIntentLog: Sendable {
    public private(set) var pending: [(key: IntentKey, intent: CloudIntent)] = []

    public init() {}

    public mutating func add(_ intent: CloudIntent, key: IntentKey) {
        pending.removeAll { $0.key == key }
        pending.append((key, intent))
    }

    public mutating func settle(_ key: IntentKey) { pending.removeAll { $0.key == key } }

    /// The machines as the user should see them: an in-flight start shows
    /// `starting`, a pause `pausing`, a delete `deleting`, a rename the new name.
    public func overlay(_ machines: [CloudMachine]) -> [CloudMachine] {
        guard !pending.isEmpty else { return machines }
        return machines.map { machine in
            var shown = machine
            for entry in pending where entry.intent.machine == machine.id {
                switch entry.intent {
                case .start: shown.status = .starting
                case .pause: shown.status = .pausing
                case .delete: shown.status = .deleting
                case .rename(_, let name): shown.name = name
                case .create: break
                }
            }
            return shown
        }
    }

    public var creating: [CloudPendingCreate] {
        pending.compactMap { entry in
            guard case .create(let name, let size) = entry.intent else { return nil }
            return CloudPendingCreate(id: entry.key, name: name, size: size)
        }
    }
}
