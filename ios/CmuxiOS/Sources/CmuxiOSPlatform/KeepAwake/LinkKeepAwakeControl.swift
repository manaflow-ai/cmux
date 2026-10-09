import CmuxMobileLink
import CmuxMobileWire
import CmuxiOSFeatureKit
import Foundation

/// The live Keep Mac Awake seam over the per-Mac `cmux.mobile/1` link.
///
/// Status is read from the Mac on every device-registry snapshot, so a Mac
/// that goes offline cannot leave a stale toggle looking actionable. Mutations
/// use the link's idempotent op path and never queue while disconnected.
public actor LinkKeepAwakeControl: KeepAwakeControl {
    public typealias ClientLookup = @Sendable (HostID) async -> MobileLinkClient?

    private let registry: any DeviceRegistry
    private let client: ClientLookup

    public init(registry: any DeviceRegistry, client: @escaping ClientLookup) {
        self.registry = registry
        self.client = client
    }

    public func updates() async -> AsyncStream<SourceSnapshot<[HostID: KeepAwakeState]>> {
        let registryUpdates = await registry.updates()
        let (stream, continuation) = AsyncStream.makeStream(
            of: SourceSnapshot<[HostID: KeepAwakeState]>.self,
            bufferingPolicy: .bufferingNewest(1))
        let client = self.client
        let task = Task {
            for await snapshot in registryUpdates {
                guard !Task.isCancelled else { return }
                let hosts = Self.macHosts(snapshot.value)
                let values = await withTaskGroup(of: (HostID, KeepAwakeState?).self,
                                                 returning: [HostID: KeepAwakeState].self) { group in
                    for (host, _) in hosts {
                        group.addTask {
                            guard let link = await client(host) else { return (host, nil) }
                            do {
                                let hello = try await link.helloOK()
                                let status = try? await link.read("caffeine.status", params: .object([:]))
                                let supported = hello.caps.contains("caffeine") ||
                                    status?["supported"]?.boolValue == true
                                guard supported else { return (host, KeepAwakeState(isSupported: false, isEnabled: nil)) }
                                let enabled = status?["enabled"]?.boolValue
                                return (host, KeepAwakeState(isSupported: true, isEnabled: enabled))
                            } catch {
                                return (host, nil)
                            }
                        }
                    }
                    var result: [HostID: KeepAwakeState] = [:]
                    for await (host, state) in group {
                        if let state { result[host] = state }
                    }
                    return result
                }
                continuation.yield(SourceSnapshot(revision: snapshot.revision, value: values,
                                                  connection: snapshot.connection))
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    public func set(_ host: HostID, enabled: Bool, key: IntentKey) async throws -> IntentReceipt {
        guard let link = await client(host) else { throw LinkKeepAwakeError.offline }
        switch try await link.submit("caffeine.set", params: .object(["enabled": .bool(enabled)]),
                                     idempotencyKey: key.rawValue) {
        case .applied(_, let revision, _):
            return .committed(key: key, revision: revision)
        case .rejected(_, let message, _, _):
            return .refused(key: key, reason: message)
        }
    }

    private static func macHosts(_ records: [DeviceRecord]) -> [(HostID, String?)] {
        records.compactMap { record in
            guard record.platform == .mac, record.trust == .trusted, !record.isThisDevice,
                  let host = record.hostID else { return nil }
            return (HostID(host), record.name)
        }
    }
}

public enum LinkKeepAwakeError: Error, Sendable {
    case offline
}

private extension JSONValue {
    var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }
}
