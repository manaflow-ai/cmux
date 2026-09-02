import Testing
import AppKit
import Foundation

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized) struct TerminalUploadFailureNotificationTests {
    private func endpoint() -> TerminalCustomUploadRunner.Endpoint {
        TerminalCustomUploadRunner.Endpoint(
            destination: "me@host.example.com",
            port: nil,
            identityFile: nil,
            sshOptions: []
        )
    }

    /// The whole point of the change: what a failing upload command wrote to
    /// stderr is what the user ends up reading. Driven through the real
    /// `/bin/sh` spawn so the capture, the error text, and the notification
    /// body are all the shipping path.
    @Test func aFailingCommandsStderrReachesTheNotificationBody() {
        let result = TerminalCustomUploadRunner().runSync(
            fileURLs: [URL(fileURLWithPath: "/tmp/a.png")],
            endpoint: endpoint(),
            command: "echo 'ssh ProxyCommand not found' >&2; exit 1",
            operation: TerminalImageTransferOperation()
        )
        guard case .failure(let error) = result else {
            Issue.record("a non-zero exit must fail, got \(result)")
            return
        }
        let payload = TerminalUploadFailureNotification.payload(for: error, surfaceId: nil)
        #expect(payload?.body.contains("ssh ProxyCommand not found") == true)
    }

    /// Posting reaches the store, and the reason survives as the body. Without
    /// this the payload could be correct and never delivered.
    @Test func postingRecordsTheReasonInTheStore() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalStore = appDelegate.notificationStore
        let originalNotifications = store.notifications
        let originalSelectedTabId = manager.selectedTabId
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        store.replaceNotificationsForTesting([])

        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            if let originalSelectedTabId,
               manager.tabs.contains(where: { $0.id == originalSelectedTabId }) {
                manager.selectedTabId = originalSelectedTabId
            }
            store.replaceNotificationsForTesting(originalNotifications)
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalStore
        }

        let error = NSError(
            domain: "cmux.upload.command",
            code: 1,
            userInfo: [
                NSLocalizedDescriptionKey: "Upload command failed: ssh ProxyCommand not found",
            ]
        )
        let outcome = TerminalUploadFailureNotification.post(
            error: error,
            surfaceId: workspace.focusedPanelId
        )

        #expect(outcome == .posted)
        let recorded = store.notifications.first {
            $0.body.contains("ssh ProxyCommand not found")
        }
        #expect(recorded != nil, "the failure reason must reach the store as a notification body")
        #expect(recorded?.tabId == workspace.id)

        // The same surface failing again inside the cooldown window is swallowed
        // by the store; the caller must learn that so it can fall back to a beep.
        let countBefore = store.notifications.count
        let repeated = TerminalUploadFailureNotification.post(
            error: error,
            surfaceId: workspace.focusedPanelId
        )
        #expect(repeated == .unavailable)
        #expect(store.notifications.count == countBefore)
    }

    /// The built-in scp transport captures scp's stderr and used to replace it
    /// with a generic "check that the remote host is reachable", which actively
    /// misdirects for the common case: a host whose 2FA this transport cannot
    /// answer, where the host is perfectly reachable.
    @Test func theBuiltInTransportKeepsScpsReason() throws {
        let session = DetectedSSHSession(
            destination: "localhost",
            port: nil,
            identityFile: nil,
            configFile: nil,
            jumpHost: nil,
            controlPath: nil,
            useIPv4: false,
            useIPv6: false,
            forwardAgent: false,
            compressionEnabled: false,
            sshOptions: ["HostName=host1.example.com"]
        )
        DetectedSSHSession.runProcessOverrideForTesting = { _, _, _, _ in
            (status: 255, stdout: "", stderr: "host1.example.com: Permission denied (keyboard-interactive).")
        }
        defer { DetectedSSHSession.runProcessOverrideForTesting = nil }

        do {
            _ = try session.uploadDroppedFilesSyncForTesting([URL(fileURLWithPath: "/tmp/a.png")])
            Issue.record("a non-zero scp must fail")
        } catch {
            let detail = TerminalUploadFailureNotification.detail(for: error)
            #expect(detail?.contains("Permission denied (keyboard-interactive)") == true)
            #expect(detail?.contains("reachable") == false)
        }
    }

    /// Cancelling is the user's own doing; reporting it back to them is noise,
    /// and nothing may be posted for it.
    @Test func cancellationIsNotWorthANotification() {
        #expect(TerminalUploadFailureNotification.detail(for: CancellationError()) == nil)
        #expect(
            TerminalUploadFailureNotification.detail(
                for: TerminalImageTransferExecutionError.cancelled
            ) == nil
        )
        #expect(
            TerminalUploadFailureNotification.payload(
                for: CancellationError(),
                surfaceId: UUID()
            ) == nil
        )
        #expect(
            TerminalUploadFailureNotification.post(
                error: CancellationError(),
                surfaceId: UUID()
            ) == .suppressed
        )
    }

    /// A command that fails without saying anything still produces a reason, so
    /// the notification is never posted with an empty body.
    @Test func aSilentFailureStillProducesAReason() {
        let result = TerminalCustomUploadRunner().runSync(
            fileURLs: [URL(fileURLWithPath: "/tmp/a.png")],
            endpoint: endpoint(),
            command: "exit 3",
            operation: TerminalImageTransferOperation()
        )
        guard case .failure(let error) = result else {
            Issue.record("a non-zero exit must fail, got \(result)")
            return
        }
        let detail = TerminalUploadFailureNotification.detail(for: error)
        #expect(detail?.isEmpty == false)
        #expect(detail?.contains("3") == true)
    }

    @Test func anErrorWithNothingToSayIsNotWorthANotification() {
        let blank = NSError(
            domain: "test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "   \n  "]
        )
        #expect(TerminalUploadFailureNotification.detail(for: blank) == nil)
    }

    /// Failures in different panes must not silence each other during the
    /// cooldown window.
    @Test func theCooldownIsScopedToTheSurface() {
        let error = NSError(
            domain: "test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "boom"]
        )
        let first = TerminalUploadFailureNotification.payload(for: error, surfaceId: UUID())
        let second = TerminalUploadFailureNotification.payload(for: error, surfaceId: UUID())
        #expect(first?.cooldownKey != second?.cooldownKey)
    }

    /// A command can produce far more stderr than belongs in a notification.
    @Test func anOverlongReasonIsTrimmedAndMarked() {
        let limit = TerminalUploadFailureNotification.maximumDetailScalars
        let long = String(repeating: "x", count: limit + 50)
        let trimmed = TerminalUploadFailureNotification.truncated(long)
        #expect(trimmed.unicodeScalars.count == limit)
        #expect(trimmed.hasSuffix("…"))
    }

    /// A Character is a grapheme cluster, so a Character-based cap would let one
    /// base character plus thousands of combining marks through as "length 1".
    @Test func combiningMarksCannotSlipPastTheCap() {
        let limit = TerminalUploadFailureNotification.maximumDetailScalars
        let oneClusterManyScalars = "a" + String(repeating: "\u{0301}", count: 5_000)
        #expect(oneClusterManyScalars.count == 1)
        let trimmed = TerminalUploadFailureNotification.truncated(oneClusterManyScalars)
        #expect(trimmed.unicodeScalars.count == limit)
    }

    /// stderr can carry terminal escape sequences; none of them belong in a
    /// notification body.
    @Test func controlCharactersAreStrippedFromTheReason() {
        let error = NSError(
            domain: "test",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "line one\u{1b}[31m red\u{07}\nline two"]
        )
        let detail = TerminalUploadFailureNotification.detail(for: error)
        #expect(detail?.contains("\u{1b}") == false)
        #expect(detail?.contains("\u{07}") == false)
        #expect(detail?.contains("\n") == false)
        #expect(detail?.contains("line one") == true)
        #expect(detail?.contains("line two") == true)
    }

    @Test func aReasonThatFitsIsLeftAlone() {
        let short = "scp: no such file"
        #expect(TerminalUploadFailureNotification.truncated(short) == short)
    }
}
