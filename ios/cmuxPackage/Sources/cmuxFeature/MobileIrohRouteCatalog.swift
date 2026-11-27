import CMUXMobileCore
import CmuxIrohTransport
import CmuxIrxTransport
import CmuxMobileShell
import CmuxMobileShellModel
import Foundation

/// Local projection of the permission-filtered team directory into attach routes.
public actor MobileIrohRouteCatalog {
    static let preferredRoutePriority = -10_000
    private var activeScope: UInt64?
    private var routesByMacDeviceID: [String: [String: [CmxAttachRoute]]] = [:]
    private var liveMacs: [MobileDiscoveredIrohMac] = []
    public init() {}

    func activate(scope: UInt64) {
        guard activeScope != scope else { return }
        activeScope = scope
        routesByMacDeviceID.removeAll()
        liveMacs.removeAll()
    }

    @discardableResult
    func replace(with directory: V2Directory, scope: UInt64) -> Bool {
        guard activeScope == scope else { return false }
        let pairable = directory.devices.filter {
            !$0.revoked && $0.descriptor.metadata.platform == .mac && $0.descriptor.metadata.pairingEnabled
        }
        let counts = Dictionary(grouping: pairable, by: { $0.descriptor.endpointID }).mapValues(\.count)
        var routes: [String: [String: [CmxAttachRoute]]] = [:]
        var candidates: [MobileDiscoveredIrohMac] = []
        for record in pairable {
            let descriptor = record.descriptor
            guard counts[descriptor.endpointID] == 1,
                  let endpoint = try? CmxIrohPeerIdentity(endpointID: descriptor.endpointID),
                  let route = try? CmxAttachRoute(id: "iroh-v2-" + record.deviceRecordID, kind: .iroh,
                    endpoint: .peer(identity: endpoint, pathHints: []), priority: Self.preferredRoutePriority) else { continue }
            let identity = CmxMacAppInstanceIdentity(macDeviceID: descriptor.identity.deviceID,
                                                   instanceTag: descriptor.identity.buildTag)
            let tag = identity.instanceTag ?? ""
            routes[identity.macDeviceID, default: [:]][tag, default: []].append(route)
            candidates.append(MobileDiscoveredIrohMac(deviceID: identity.macDeviceID,
                displayName: descriptor.metadata.displayName, instanceTag: tag, routes: [route],
                lastSeenAt: Date(timeIntervalSince1970: Double(directory.issuedAt)),
                capabilities: descriptor.metadata.capabilities, clientNamespace: descriptor.identity.appNamespace.hasPrefix("mac:")
                    ? descriptor.identity.appNamespace : "mac:" + descriptor.identity.appNamespace))
        }
        routesByMacDeviceID = routes
        liveMacs = candidates
        return true
    }
    /// Returns permitted Macs from the current v2 directory.
    ///
    /// IROH admission establishes reachability. The current build sorts first.
    public func liveMacCandidates(
        preferredTag: String,
        compatibleWith policy: MobileMacBuildCompatibilityPolicy? = nil,
        limit: Int? = nil
    ) -> [MobileDiscoveredIrohMac] {
        guard let limit else {
            return liveMacs
                .filter {
                    policy?.allows(
                        instanceTag: $0.instanceTag,
                        clientNamespace: $0.clientNamespace
                    ) ?? true
                }
                .sorted { Self.candidateSortsBefore($0, $1, preferredTag: preferredTag) }
        }
        guard limit > 0 else { return [] }

        // Automatic admission only needs the best few candidates. Keep a
        // bounded ordered buffer so a large authenticated fleet costs O(n*k)
        // instead of sorting every row at O(n log n), where k is the limit.
        var best: [MobileDiscoveredIrohMac] = []
        best.reserveCapacity(min(limit, liveMacs.count))
        for candidate in liveMacs
            where policy?.allows(
                instanceTag: candidate.instanceTag,
                clientNamespace: candidate.clientNamespace
            ) ?? true {
            let insertionIndex = best.firstIndex {
                Self.candidateSortsBefore(candidate, $0, preferredTag: preferredTag)
            } ?? best.endIndex
            guard insertionIndex < limit || best.count < limit else { continue }
            best.insert(candidate, at: insertionIndex)
            if best.count > limit { best.removeLast() }
        }
        return best
    }

    private static func candidateSortsBefore(
        _ left: MobileDiscoveredIrohMac,
        _ right: MobileDiscoveredIrohMac,
        preferredTag: String
    ) -> Bool {
        let leftRank = tagRank(left.instanceTag, preferred: preferredTag)
        let rightRank = tagRank(right.instanceTag, preferred: preferredTag)
        if leftRank != rightRank { return leftRank < rightRank }
        if left.lastSeenAt != right.lastSeenAt {
            return left.lastSeenAt > right.lastSeenAt
        }
        if left.deviceID != right.deviceID { return left.deviceID < right.deviceID }
        return left.instanceTag < right.instanceTag
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
        guard let routesByTag = routesByMacDeviceID[cmxCanonicalDeviceID(macDeviceID)] else {
            return []
        }
        if let instanceTag {
            let canonicalTag = CmxMacAppInstanceIdentity(
                macDeviceID: macDeviceID,
                instanceTag: instanceTag
            ).instanceTag ?? ""
            return routesByTag[canonicalTag] ?? []
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

}
