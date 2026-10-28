import CMUXMobileCore
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation

public struct PersonalIrohDeviceRegistryDecorator: DeviceRegistryRefreshing {
    private let catalog: MobileIrohRouteCatalog
    private let knownRoutes: @Sendable (
        _ macDeviceID: String,
        _ instanceTag: String?
    ) async -> [CmxAttachRoute]?

    public init(
        catalog: MobileIrohRouteCatalog,
        knownRoutes: @escaping @Sendable (
            _ macDeviceID: String,
            _ instanceTag: String?
        ) async -> [CmxAttachRoute]?
    ) {
        self.catalog = catalog
        self.knownRoutes = knownRoutes
    }

    /// Merges personal and team routes only while the personal snapshot remains authorized.
    public func freshRoutes(forMacDeviceID macDeviceID: String, instanceTag: String?) async -> [CmxAttachRoute]? {
        guard let snapshot = await catalog.routeSnapshot(
            forKnownMacDeviceID: macDeviceID,
            instanceTag: instanceTag
        ) else { return nil }
        let personal = snapshot.routes
        guard !personal.isEmpty else { return nil }
        let local = await knownRoutes(macDeviceID, instanceTag) ?? []
        guard await catalog.isCurrentScope(snapshot.token) else { return nil }
        return Self.merged(personal: personal, team: local.filter { $0.kind != .iroh })
    }

    /// Lists discovered Macs only after revalidating the snapshot scope token.
    public func listDevices() async -> DeviceRegistryListOutcome {
        guard let snapshot = await catalog.liveMacCandidateSnapshot(preferredTag: "default"),
              await catalog.isCurrentScope(snapshot.token) else { return .ok([]) }
        return .ok(Self.registryDevices(from: snapshot.candidates))
    }

    private static func registryDevices(
        from candidates: [MobileDiscoveredIrohMac]
    ) -> [RegistryDevice] {
        Dictionary(grouping: candidates, by: \.deviceID)
            .map { deviceID, candidates in
                let ordered = candidates.sorted { left, right in
                    if left.lastSeenAt != right.lastSeenAt {
                        return left.lastSeenAt > right.lastSeenAt
                    }
                    return left.instanceTag < right.instanceTag
                }
                return RegistryDevice(
                    deviceId: deviceID,
                    platform: "mac",
                    displayName: ordered.compactMap(\.displayName).first,
                    lastSeenAt: ordered.map(\.lastSeenAt).max() ?? .distantPast,
                    instances: ordered.map {
                        RegistryAppInstance(
                            tag: $0.instanceTag,
                            routes: $0.routes,
                            lastSeenAt: $0.lastSeenAt
                        )
                    }
                )
            }
            .sorted { left, right in
                if left.lastSeenAt != right.lastSeenAt {
                    return left.lastSeenAt > right.lastSeenAt
                }
                return left.deviceId < right.deviceId
            }
    }

    static func merged(
        personal: [CmxAttachRoute],
        team: [CmxAttachRoute],
        now: Date = Date()
    ) -> [CmxAttachRoute] {
        let decoratedRoutes = CmxAttachRoute.addingIrohPrivatePaths(
            to: personal + team,
            observedAt: now
        )
        precondition(
            decoratedRoutes.count == personal.count + team.count,
            "Private-path decoration must preserve route count and order"
        )
        let personalWithPrivatePaths = Array(decoratedRoutes.prefix(personal.count))
        var merged = personalWithPrivatePaths
        var routeIDs = Set(personal.map(\.id))
        var peerIdentities = Set<CmxIrohPeerIdentity>(personal.compactMap { route in
            guard case let .peer(identity, _) = route.endpoint else { return nil }
            return identity
        })
        for route in team {
            guard routeIDs.insert(route.id).inserted else { continue }
            if case let .peer(identity, _) = route.endpoint,
               !peerIdentities.insert(identity).inserted {
                continue
            }
            merged.append(route)
        }
        return merged.sorted { left, right in
            if left.priority == right.priority { return left.id < right.id }
            return left.priority < right.priority
        }
    }
}
