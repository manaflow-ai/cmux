import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileShell
import Foundation

/// One bounded personal-account snapshot of authenticated Iroh Mac routes.
///
/// The catalog is deliberately separate from the team device registry. It only
/// supplies routes when the shell asks for an already-paired Mac device ID; it
/// never contributes device-list rows and therefore cannot auto-pair a newly
/// discovered device. A lifecycle scope prevents a delayed callback from a
/// signed-out or prior account runtime from repopulating the current catalog.
public actor MobileIrohRouteCatalog {
    static let preferredRoutePriority = -10_000

    private var activeScope: UInt64?
    private var routesByMacDeviceID: [String: [String: [CmxAttachRoute]]] = [:]

    public init() {}

    /// Activates a fresh account-runtime scope and drops the prior snapshot.
    func activate(scope: UInt64) {
        activeScope = scope
        routesByMacDeviceID.removeAll(keepingCapacity: true)
    }

    /// Replaces the catalog from one authenticated, runtime-verified discovery.
    ///
    /// Only pairable Mac bindings are retained. Broker routes intentionally
    /// contain no private path hints. The registry decorator may later attach a
    /// locally known Tailscale address as a fallback, while dial-time discovery
    /// supplies current authenticated public paths.
    func replace(
        with discovery: CmxIrohDiscoveryResponse,
        scope: UInt64
    ) {
        replace(with: discovery.bindings, scope: scope)
    }

    /// Replaces routes from device-only, cryptographically reverified cache rows.
    ///
    /// The caller has already scoped these rows to the current account, app,
    /// local identity, requested known Mac tuples, keyset, and unexpired grants.
    func replaceCachedBindings(
        _ bindings: [CmxIrohBrokerBinding],
        scope: UInt64
    ) {
        replace(with: bindings, scope: scope)
    }

    private func replace(
        with bindings: [CmxIrohBrokerBinding],
        scope: UInt64
    ) {
        guard activeScope == scope else { return }

        let pairableMacs = bindings.filter {
            $0.platform == .mac && $0.pairingEnabled
        }.prefix(CmxIrohDiscoveryResponse.maximumBindingCount)
        let endpointCounts = Dictionary(
            grouping: pairableMacs,
            by: \CmxIrohBrokerBinding.endpointID
        ).mapValues(\.count)
        let unambiguousMacs = pairableMacs.filter {
            endpointCounts[$0.endpointID] == 1
        }
        let grouped = Dictionary(grouping: unambiguousMacs) {
            $0.deviceID.lowercased()
        }

        var replacement: [String: [String: [CmxAttachRoute]]] = [:]
        replacement.reserveCapacity(grouped.count)
        for (deviceID, bindings) in grouped {
            let bindingsByTag = Dictionary(grouping: bindings, by: \.tag)
            var routesByTag: [String: [CmxAttachRoute]] = [:]
            for (tag, taggedBindings) in bindingsByTag {
                let ordered = taggedBindings.sorted(by: Self.bindingSortsBefore)
                let routes = ordered.enumerated().compactMap { index, binding in
                    try? CmxAttachRoute(
                        id: "iroh-personal-\(binding.bindingID)",
                        kind: .iroh,
                        endpoint: .peer(identity: binding.endpointID, pathHints: []),
                        priority: Self.preferredRoutePriority + index
                    )
                }
                if !routes.isEmpty {
                    routesByTag[tag] = routes
                }
            }
            if !routesByTag.isEmpty {
                replacement[deviceID] = routesByTag
            }
        }
        routesByMacDeviceID = replacement
    }

    /// Returns authenticated personal-account routes for an already-known Mac.
    public func routes(
        forKnownMacDeviceID macDeviceID: String,
        instanceTag: String?
    ) -> [CmxAttachRoute] {
        guard let routesByTag = routesByMacDeviceID[macDeviceID.lowercased()] else {
            return []
        }
        if let instanceTag {
            return routesByTag[instanceTag] ?? []
        }
        guard routesByTag.count == 1 else { return [] }
        return routesByTag.values.first ?? []
    }

    /// Clears this exact lifecycle scope, ignoring stale teardown callbacks.
    func deactivate(scope: UInt64) {
        guard activeScope == scope else { return }
        activeScope = nil
        routesByMacDeviceID.removeAll(keepingCapacity: false)
    }

    /// Clears every scope during explicit local sign-out teardown.
    func clear() {
        activeScope = nil
        routesByMacDeviceID.removeAll(keepingCapacity: false)
    }

    private static func bindingSortsBefore(
        _ left: CmxIrohBrokerBinding,
        _ right: CmxIrohBrokerBinding
    ) -> Bool {
        let leftDate = parseTimestamp(left.lastSeenAt)
        let rightDate = parseTimestamp(right.lastSeenAt)
        if leftDate == rightDate {
            return left.bindingID < right.bindingID
        }
        return leftDate > rightDate
    }

    private static func parseTimestamp(_ value: String) -> Date {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value)
            ?? ISO8601DateFormatter().date(from: value)
            ?? .distantPast
    }
}

/// Adds personal-account Iroh routes to paired-Mac refreshes without changing
/// the team-scoped device list or its authorization semantics.
public struct PersonalIrohDeviceRegistryDecorator: DeviceRegistryRefreshing {
    private let base: (any DeviceRegistryRefreshing)?
    private let catalog: MobileIrohRouteCatalog
    private let knownRoutes: @Sendable (
        _ macDeviceID: String,
        _ instanceTag: String?
    ) async -> [CmxAttachRoute]?

    public init(
        base: (any DeviceRegistryRefreshing)?,
        catalog: MobileIrohRouteCatalog,
        knownRoutes: @escaping @Sendable (
            _ macDeviceID: String,
            _ instanceTag: String?
        ) async -> [CmxAttachRoute]?
    ) {
        self.base = base
        self.catalog = catalog
        self.knownRoutes = knownRoutes
    }

    public func freshRoutes(
        forMacDeviceID macDeviceID: String,
        instanceTag: String?
    ) async -> [CmxAttachRoute]? {
        async let baseRoutes = base?.freshRoutes(
            forMacDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        guard let localRoutes = await knownRoutes(macDeviceID, instanceTag) else {
            return await baseRoutes
        }
        let personalRoutes = await catalog.routes(
            forKnownMacDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        let teamRoutes = await baseRoutes
        guard !personalRoutes.isEmpty else { return teamRoutes }
        let networkRoutes: [CmxAttachRoute]
        if let teamRoutes, !teamRoutes.isEmpty {
            networkRoutes = teamRoutes
        } else {
            networkRoutes = localRoutes
        }
        return Self.merged(personal: personalRoutes, team: networkRoutes)
    }

    public func listDevices() async -> DeviceRegistryListOutcome {
        guard let base else { return .transientFailure }
        return await base.listDevices()
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
