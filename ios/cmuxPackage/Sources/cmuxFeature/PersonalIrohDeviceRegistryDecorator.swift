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

    public func freshRoutes(forMacDeviceID macDeviceID: String, instanceTag: String?) async -> [CmxAttachRoute]? {
        let personal = await catalog.routes(forKnownMacDeviceID: macDeviceID, instanceTag: instanceTag)
        guard !personal.isEmpty else { return nil }
        let local = await knownRoutes(macDeviceID, instanceTag) ?? []
        return Self.merged(personal: personal, team: local.filter { $0.kind != .iroh })
    }

    public func listDevices() async -> DeviceRegistryListOutcome {
        .ok(Self.registryDevices(from: await catalog.liveMacCandidates(preferredTag: "default")))
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
