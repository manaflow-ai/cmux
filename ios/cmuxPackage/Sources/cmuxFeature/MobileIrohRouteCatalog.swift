import CMUXMobileCore
import CmuxIrohTransport
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation

/// One bounded personal-account snapshot of authenticated Iroh Mac routes.
///
/// The catalog is deliberately separate from the team device registry. It only
/// supplies cached routes when the shell asks for an already-paired Mac,
/// while a separate live snapshot supplies zero-touch connection candidates.
/// A lifecycle scope prevents a delayed callback from a signed-out or prior
/// account runtime from repopulating either view.
public actor MobileIrohRouteCatalog {
    static let preferredRoutePriority = -10_000

    private var activeScope: UInt64?
    private var routesByMacDeviceID: [String: [String: [CmxAttachRoute]]] = [:]
    private var liveMacs: [MobileDiscoveredIrohMac] = []

    public init() {}

    /// Activates a fresh account-runtime scope and drops the prior snapshot.
    func activate(scope: UInt64) {
        activeScope = scope
        routesByMacDeviceID.removeAll(keepingCapacity: true)
        liveMacs.removeAll(keepingCapacity: true)
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
        guard activeScope == scope else { return }
        routesByMacDeviceID = Self.makeRoutesByMacDeviceID(
            from: discovery.bindings
        )
        liveMacs = Self.makeLiveMacs(from: discovery.bindings)
    }

    /// Replaces routes from device-only, cryptographically reverified cache rows.
    ///
    /// The caller has already scoped these rows to the current account, app,
    /// local identity, requested known Mac tuples, keyset, and unexpired grants.
    func replaceCachedBindings(
        _ bindings: [CmxIrohBrokerBinding],
        scope: UInt64
    ) {
        guard activeScope == scope else { return }
        routesByMacDeviceID = Self.makeRoutesByMacDeviceID(from: bindings)
        liveMacs.removeAll(keepingCapacity: false)
    }

    private static func makeRoutesByMacDeviceID(
        from bindings: [CmxIrohBrokerBinding]
    ) -> [String: [String: [CmxAttachRoute]]] {
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
        return replacement
    }

    private static func makeLiveMacs(
        from bindings: [CmxIrohBrokerBinding]
    ) -> [MobileDiscoveredIrohMac] {
        let pairableMacs = Array(bindings.filter {
            $0.platform == .mac && $0.pairingEnabled
        }.prefix(CmxIrohDiscoveryResponse.maximumBindingCount))
        let endpointCounts = Dictionary(
            grouping: pairableMacs,
            by: \CmxIrohBrokerBinding.endpointID
        ).mapValues(\.count)
        struct DeviceTag: Hashable {
            let deviceID: String
            let tag: String
        }
        let deviceTagCounts = Dictionary(grouping: pairableMacs) {
            DeviceTag(deviceID: $0.deviceID.lowercased(), tag: $0.tag)
        }.mapValues(\.count)

        return pairableMacs.compactMap { binding in
            let deviceTag = DeviceTag(
                deviceID: binding.deviceID.lowercased(),
                tag: binding.tag
            )
            guard endpointCounts[binding.endpointID] == 1,
                  deviceTagCounts[deviceTag] == 1,
                  let route = try? CmxAttachRoute(
                      id: "iroh-personal-\(binding.bindingID)",
                      kind: .iroh,
                      endpoint: .peer(identity: binding.endpointID, pathHints: []),
                      priority: preferredRoutePriority
                  ) else { return nil }
            return MobileDiscoveredIrohMac(
                deviceID: binding.deviceID.lowercased(),
                displayName: binding.displayName,
                instanceTag: binding.tag,
                routes: [route],
                lastSeenAt: parseTimestamp(binding.lastSeenAt)
            )
        }
    }

    /// Returns only candidates from the current live broker response.
    ///
    /// Cached bindings are intentionally excluded so an offline cache can never
    /// create a first pairing. The current build wins, followed by stable/default
    /// builds and then broker recency.
    public func liveMacCandidates(
        preferredTag: String
    ) -> [MobileDiscoveredIrohMac] {
        liveMacs.sorted { left, right in
            let leftRank = Self.tagRank(left.instanceTag, preferred: preferredTag)
            let rightRank = Self.tagRank(right.instanceTag, preferred: preferredTag)
            if leftRank != rightRank { return leftRank < rightRank }
            if left.lastSeenAt != right.lastSeenAt {
                return left.lastSeenAt > right.lastSeenAt
            }
            if left.deviceID != right.deviceID { return left.deviceID < right.deviceID }
            return left.instanceTag < right.instanceTag
        }
    }

    /// Drops live first-pair candidates without disturbing verified routes for
    /// already-paired Macs.
    func clearLiveMacCandidates(scope: UInt64) {
        guard activeScope == scope else { return }
        liveMacs.removeAll(keepingCapacity: false)
    }

    private static func tagRank(_ tag: String, preferred: String) -> Int {
        if tag == preferred { return 0 }
        if tag == "stable" || tag == "default" { return 1 }
        return 2
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
        liveMacs.removeAll(keepingCapacity: false)
    }

    /// Clears every scope during explicit local sign-out teardown.
    func clear() {
        activeScope = nil
        routesByMacDeviceID.removeAll(keepingCapacity: false)
        liveMacs.removeAll(keepingCapacity: false)
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

/// Adds broker-verified personal-account Iroh routes to paired-Mac refreshes and
/// live Mac candidates to the device list.
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
        let personal = await catalog.liveMacCandidates(preferredTag: "stable")
        let personalDevices = Self.registryDevices(from: personal)
        guard let base else {
            return personalDevices.isEmpty ? .transientFailure : .ok(personalDevices)
        }
        switch await base.listDevices() {
        case let .ok(devices):
            return .ok(Self.merged(personal: personalDevices, team: devices))
        case .authRejected:
            return personalDevices.isEmpty ? .authRejected : .ok(personalDevices)
        case .transientFailure:
            return personalDevices.isEmpty ? .transientFailure : .ok(personalDevices)
        }
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

    private static func merged(
        personal: [RegistryDevice],
        team: [RegistryDevice]
    ) -> [RegistryDevice] {
        var result = team
        for personalDevice in personal {
            guard let deviceIndex = result.firstIndex(where: {
                $0.deviceId.lowercased() == personalDevice.deviceId.lowercased()
            }) else {
                result.append(personalDevice)
                continue
            }
            for instance in personalDevice.instances {
                if let instanceIndex = result[deviceIndex].instances.firstIndex(where: {
                    $0.tag == instance.tag
                }) {
                    result[deviceIndex].instances[instanceIndex] = instance
                } else {
                    result[deviceIndex].instances.append(instance)
                }
            }
            result[deviceIndex].displayName = personalDevice.displayName
                ?? result[deviceIndex].displayName
            result[deviceIndex].lastSeenAt = max(
                result[deviceIndex].lastSeenAt,
                personalDevice.lastSeenAt
            )
            result[deviceIndex].instances.sort { $0.lastSeenAt > $1.lastSeenAt }
        }
        return result.sorted { left, right in
            if left.lastSeenAt != right.lastSeenAt { return left.lastSeenAt > right.lastSeenAt }
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
