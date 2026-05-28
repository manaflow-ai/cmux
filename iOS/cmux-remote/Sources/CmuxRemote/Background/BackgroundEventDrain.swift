import Foundation
import CmuxKit
import UserNotifications
import Logging
import UIKit
import LocalAuthentication
import Security
import WidgetKit

/// Background task that opens a one-shot SSH session, refreshes the
/// notification list, and posts any locally-missed notifications. Bounded by
/// the system's BGTask budget (~25 s for refresh, ~60 s for processing).
@MainActor
final class BackgroundEventDrain {
    private var cancelled = false
    private let log = CmuxLog.make("bg.drain")

    func cancel() { cancelled = true }

    func run(maxDuration: Duration) async -> Bool {
        cancelled = false
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: maxDuration)
        func shouldStop() -> Bool {
            cancelled || Task.isCancelled || clock.now >= deadline
        }

        guard let host = HostStore.shared.activeHost else {
            log.notice("no active host, skipping background drain")
            return true
        }
        do {
            guard !shouldStop() else { throw CmuxError.cancelled }
            // Refuse to unlock credentials before we know this host is
            // pinned. Background has no TOFU UI, so unpinned hosts fail
            // closed before Keychain access.
            guard let pin = host.serverFingerprintPin else {
                log.notice("background drain skipped: no pinned fingerprint yet")
                return true
            }
            let credential: CmuxResolvedCredential
            do {
                credential = try await CmuxCredentialStore.shared.resolve(
                    host: host,
                    reason: L10n.string("auth.background_sync.reason", defaultValue: "Background sync")
                )
            } catch {
                if Self.isCredentialUnavailableWhileBackgrounded(error) {
                    log.notice("background drain skipped: credential unavailable while device is locked")
                    return true
                }
                throw error
            }
            guard !shouldStop() else { throw CmuxError.cancelled }
            let transport = try CitadelSSHTransport(
                host: host.hostname,
                port: host.port,
                username: host.username,
                credential: credential,
                hostKeyPolicy: .pinFingerprintSHA256(pin),
                connectTimeoutSeconds: 8
            )
            guard !shouldStop() else {
                await transport.close()
                throw CmuxError.cancelled
            }
            let client = CMUXClient(transport: transport, cmuxBinaryPath: host.cmuxBinaryPath)
            let supportsRemoteDecisionResolution: Bool
            do {
                supportsRemoteDecisionResolution = try await client.capabilities().supportsRemoteDecisionResolution
            } catch {
                log.warning("background drain could not read capabilities; remote decisions disabled", metadata: [
                    "error": .string(error.localizedDescription)
                ])
                supportsRemoteDecisionResolution = false
            }
            let notifications: [CmuxNotification]
            let decisions: [AgentDecision]
            do {
                notifications = try await client.listNotifications()
                decisions = supportsRemoteDecisionResolution
                    ? try await client.listPendingAgentDecisions()
                    : []
            } catch {
                await transport.close()
                throw error
            }
            guard !shouldStop() else {
                await transport.close()
                throw CmuxError.cancelled
            }
            await updateWidgetState(host: host, notifications: notifications)
            await deliver(notifications: notifications, host: host)
            await deliver(decisions: decisions, host: host, resolverClient: client)
            await transport.close()
            return true
        } catch CmuxError.cancelled {
            log.notice("background drain cancelled or exceeded budget")
            return false
        } catch {
            log.warning("background drain failed: \(error.localizedDescription)")
            return false
        }
    }

    private func deliver(notifications: [CmuxNotification], host: CmuxHost) async {
        let center = UNUserNotificationCenter.current()
        let delivered = await center.deliveredNotifications().map(\.request.identifier)
        let knownPending = Set(delivered)
        for n in notifications where !n.isRead && !knownPending.contains(n.id.raw) {
            if cancelled || Task.isCancelled { return }
            let content = UNMutableNotificationContent()
            content.title = CmuxNotificationPresentation.title(for: n)
            content.subtitle = CmuxNotificationPresentation.subtitle(for: n)
            content.body = CmuxNotificationPresentation.body(for: n)
            content.categoryIdentifier = NotificationCategories.surfaceCategory
            content.interruptionLevel = .timeSensitive
            content.threadIdentifier = n.workspaceID.map { "workspace:\($0.raw)" } ?? "cmux"
            content.userInfo["notification_id"] = n.id.raw
            content.userInfo["host_id"] = host.id.uuidString
            if let id = n.workspaceID { content.userInfo["workspace_id"] = id.raw }
            if let id = n.surfaceID { content.userInfo["surface_id"] = id.raw }
            let request = UNNotificationRequest(identifier: n.id.raw, content: content, trigger: nil)
            do {
                try await center.add(request)
            } catch {
                log.warning("background notification delivery failed", metadata: [
                    "notification_id": .string(n.id.raw),
                    "error": .string(error.localizedDescription)
                ])
            }
        }
        try? await center.setBadgeCount(notifications.filter { !$0.isRead }.count)
    }

    private func deliver(decisions: [AgentDecision], host: CmuxHost, resolverClient: CMUXClient) async {
        for decision in decisions {
            if cancelled || Task.isCancelled { return }
            do {
                try await NotificationCenterBridge.shared.observeAgentDecision(
                    decision.scoped(to: host.id),
                    resolverClient: resolverClient
                )
            } catch {
                log.warning("background decision delivery failed: \(error.localizedDescription)")
                await NotificationCenterBridge.shared.postDecisionDeliveryFailure(
                    decisionID: decision.id,
                    reason: error.localizedDescription
                )
            }
        }
    }

    private func updateWidgetState(host: CmuxHost, notifications: [CmuxNotification]) async {
        let unread = notifications.filter { !$0.isRead }
        let entry = CmuxWidgetEntry(
            date: Date(),
            workspaceTitle: L10n.string("live_activity.workspace.generic", defaultValue: "cmux workspace"),
            branch: nil,
            unread: unread.count,
            host: L10n.string("widget.host.generic", defaultValue: "cmux")
        )
        await Task.detached(priority: .utility) {
            CmuxWidgetStateStore.shared.write(entry)
        }.value
        WidgetCenter.shared.reloadAllTimelines()
    }

    private static func isCredentialUnavailableWhileBackgrounded(_ error: any Error) -> Bool {
        var current: NSError? = error as NSError
        while let nsError = current {
            if nsError.domain == LAError.errorDomain,
               let code = LAError.Code(rawValue: nsError.code) {
                let backgroundUnavailableCodes: [LAError.Code] = [
                    .authenticationFailed,
                    .userCancel,
                    .userFallback,
                    .systemCancel,
                    .passcodeNotSet,
                    .biometryNotAvailable,
                    .biometryNotEnrolled,
                    .biometryLockout,
                    .appCancel,
                    .invalidContext,
                    .notInteractive,
                    .companionNotAvailable
                ]
                if backgroundUnavailableCodes.contains(code) {
                    return true
                }
            }
            if nsError.domain == NSOSStatusErrorDomain,
               nsError.code == Int(errSecInteractionNotAllowed) {
                return true
            }
            let lowerDescription = nsError.localizedDescription.lowercased()
            if lowerDescription.contains("interaction not allowed")
                || lowerDescription.contains("user interaction is not allowed")
                || lowerDescription.contains("not interactive") {
                return true
            }
            current = nsError.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return false
    }
}
