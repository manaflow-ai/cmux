public import CmuxiOSFeatureKit
public import CmuxLink
public import Observation

/// Devices & Macs: mirrors the account's device registry and the live link
/// badges while Settings is visible, and sends rename and removal intents.
/// Nothing queues: while the registry is not live, changes are refused.
@MainActor
@Observable
public final class DeviceSettingsModel {
    public private(set) var devices: [DeviceRecord] = []
    public private(set) var connection: SourceConnection = .connecting
    public private(set) var badges: [DeviceRecord.ID: PathBadge] = [:]
    /// The device a rename or removal is in flight for.
    public private(set) var pendingDeviceID: DeviceRecord.ID?
    /// The last failed action, for an alert; the screen clears it.
    public var actionError: DeviceActionError?
    @ObservationIgnored private let registry: any DeviceRegistry
    @ObservationIgnored private let links: (any LinkDiagnosticsSource)?
    @ObservationIgnored public let nameRule: DeviceNameRule

    public init(registry: any DeviceRegistry, links: (any LinkDiagnosticsSource)?,
                nameRule: DeviceNameRule = DeviceNameRule()) {
        self.registry = registry
        self.links = links
        self.nameRule = nameRule
    }

    public var sections: [DeviceListSection] { DeviceListProjection(devices: devices).sections }

    public func device(_ id: DeviceRecord.ID) -> DeviceRecord? {
        devices.first { $0.id == id && $0.trust != .revoked }
    }

    public func badge(for id: DeviceRecord.ID) -> PathBadge? { badges[id] }

    /// Mirrors the registry and the link badges until the calling task is
    /// cancelled (SwiftUI's `.task` cancels it when the screen goes away).
    public func observe() async {
        await withDiscardingTaskGroup { group in
            group.addTask { await self.observeDevices() }
            group.addTask { await self.observeLinks() }
        }
    }

    private func observeDevices() async {
        for await snapshot in await registry.updates() {
            devices = snapshot.value
            connection = snapshot.connection
        }
    }

    private func observeLinks() async {
        guard let links else { return }
        for await next in await links.updates() {
            badges = next
        }
    }

    /// Renames a device. Returns false and sets `actionError` on failure.
    @discardableResult
    public func rename(_ id: DeviceRecord.ID, to raw: String) async -> Bool {
        let name: String
        switch nameRule.validate(raw) {
        case .success(let valid): name = valid
        case .failure(let error): return fail(.invalidName(error.problem))
        }
        guard let device = device(id) else { return fail(.notFound) }
        guard device.name != name else { return true }
        return await send(id) { registry, key in try await registry.rename(id, to: name, key: key) }
    }

    /// Removes (revokes) a device. This device is removed by signing out.
    @discardableResult
    public func revoke(_ id: DeviceRecord.ID) async -> Bool {
        guard let device = device(id) else { return fail(.notFound) }
        guard !device.isThisDevice else { return fail(.cannotRemoveThisDevice) }
        return await send(id) { registry, key in try await registry.revoke(id, key: key) }
    }

    private func send(
        _ id: DeviceRecord.ID,
        _ intent: (any DeviceRegistry, IntentKey) async throws -> IntentReceipt
    ) async -> Bool {
        guard connection.isLive else { return fail(.offline) }
        guard pendingDeviceID == nil else { return false }
        pendingDeviceID = id
        defer { pendingDeviceID = nil }
        do {
            switch try await intent(registry, IntentKey()) {
            case .committed: return true
            case .refused(_, let reason): return fail(.refused(reason: reason))
            }
        } catch FeatureSourceError.notFound {
            return fail(.notFound)
        } catch {
            return fail(.offline)
        }
    }

    private func fail(_ error: DeviceActionError) -> Bool {
        actionError = error
        return false
    }
}
