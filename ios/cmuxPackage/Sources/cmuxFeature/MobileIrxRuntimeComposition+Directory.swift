import CmuxAuthRuntime
public import CmuxIrxTransport
import CmuxMobilePairedMac
import CmuxMobileShellModel
import Foundation

extension MobileIrxRuntimeComposition {
    /// Keeps each Mac build's version evidence attached to its exact device record.
    nonisolated static func macListAuthEntries(
        from directory: V2Directory,
        now: Date = .now
    ) -> [MobileMacListAuthState.Identity: MobileMacListAuthState.Entry] {
        let fresh = directory.permissionExpiresAt > Int(now.timeIntervalSince1970)
        var entries: [MobileMacListAuthState.Identity: MobileMacListAuthState.Entry] = [:]
        for record in directory.devices where record.descriptor.metadata.platform == .mac {
            let descriptor = record.descriptor
            let identity = MobileMacListAuthState.Identity(
                pairingID: MobilePairedMac.pairingID(
                    macDeviceID: descriptor.identity.deviceID,
                    instanceTag: descriptor.identity.buildTag
                ),
                endpointIDHex: descriptor.endpointID,
                bindingID: record.deviceRecordID,
                identityGeneration: descriptor.identityGeneration
            )
            entries[identity] = MobileMacListAuthState.Entry(
                status: record.revoked ? "revoked" : "active",
                revoked: record.revoked,
                isFresh: fresh,
                appVersion: descriptor.metadata.appVersion,
                releaseTrack: descriptor.identity.buildTag == "nightly" ? "nightly" : "stable"
            )
        }
        return entries
    }

    func projectDirectoryForUI(_ directory: V2Directory, scope: AuthenticatedTeamScope) async {
        let entries = Self.macListAuthEntries(from: directory)
        guard let auth else { return }
        await MainActor.run {
            guard auth.isAuthenticatedTeamScopeCurrent(scope) else { return }
            MobileMacListAuthState.shared.replace(entriesByIdentity: entries)
        }
    }

    func directoryScopeID() async -> String? {
        guard let scope = activeScope, (try? await assertScope(scope, epoch: epoch)) != nil else { return nil }
        return "\(scope.session.accountID):\(scope.teamID):\(scope.generation):\(epoch)"
    }

    /// Uses a current cached list immediately. Initial enrollment waits for its first complete directory.
    public func freshLiveDiscovery() async -> V2Directory? {
        if let directory = await currentDirectory() { return directory }
        return await withTaskGroup(of: V2Directory?.self) { group in
            group.addTask { [weak self] in
                guard let self else { return nil }
                for await _ in await self.changes() {
                    guard !Task.isCancelled else { return nil }
                    if let directory = await self.currentDirectory() { return directory }
                }
                return nil
            }
            group.addTask { try? await Task.sleep(for: .seconds(20)); return nil }
            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    func currentDirectory() async -> V2Directory? {
        guard let scope = activeScope, let directory = cache?.directory,
              cache?.authorityRevoked == false, directory.teamID == scope.teamID,
              directory.permissionExpiresAt > Int(Date().timeIntervalSince1970),
              (try? await assertScope(scope, epoch: epoch)) != nil else { return nil }
        return directory
    }

    /// Explicit user refresh delegates to the one control service request owner.
    public func invalidateDiscoverySnapshot() async {
        guard let scope = activeScope, let service = control else { return }
        let currentEpoch = epoch
        guard (try? await assertScope(scope, epoch: currentEpoch)) != nil else { return }
        _ = try? await service.refreshDirectory()
    }

    /// Revocation remains server-authorized for the current team/account.
    public func revokeBinding(_ deviceRecordID: String) async throws {
        guard let scope = activeScope, let service = control else { throw CompositionError.notSignedIn }
        let currentEpoch = epoch
        try await assertScope(scope, epoch: currentEpoch)
        _ = try await service.revokeDevice(deviceRecordID)
        try await assertScope(scope, epoch: currentEpoch)
    }

    public func authenticatedAccountID() async -> String? {
        guard let scope = activeScope, (try? await assertScope(scope, epoch: epoch)) != nil else { return nil }
        return scope.session.accountID
    }
}
