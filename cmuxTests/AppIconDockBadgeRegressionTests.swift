import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
@MainActor
struct AppIconDockBadgeRegressionTests {
    @Test("Unread notification updates the runtime app icon with a badge")
    func unreadNotificationUpdatesRuntimeAppIcon() {
        let baseIcon = NSImage(size: NSSize(width: 64, height: 64))
        baseIcon.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: baseIcon.size)).fill()
        baseIcon.unlockFocus()

        var receivedRuntimeIcon: NSImage?
        let store = TerminalNotificationStore.shared
        let previousBadgeLabel = NSApplication.shared.dockTile.badgeLabel
        let environment = AppIconSettings.Environment(
            isApplicationFinishedLaunching: { true },
            imageForMode: { mode in
                #expect(mode == .dark)
                return baseIcon
            },
            setApplicationIconImage: { icon in
                receivedRuntimeIcon = icon
            },
            startAppearanceObservation: {},
            stopAppearanceObservation: {},
            notifyDockTilePlugin: {}
        )

        store.replaceNotificationsForTesting([])
        AppIconSettings.resetLiveEnvironmentProviderForTesting()
        AppIconSettings.setLiveEnvironmentProviderForTesting { environment }
        defer {
            store.replaceNotificationsForTesting([])
            NSApplication.shared.dockTile.badgeLabel = previousBadgeLabel
            AppIconSettings.resetLiveEnvironmentProviderForTesting()
        }

        AppIconSettings.applyIcon(.dark, environment: environment)
        #expect(receivedRuntimeIcon === baseIcon)

        store.replaceNotificationsForTesting([
            TerminalNotification(
                id: UUID(),
                tabId: UUID(),
                surfaceId: nil,
                title: "Done",
                subtitle: "",
                body: "Needs attention",
                createdAt: Date(),
                isRead: false
            )
        ])

        #expect(receivedRuntimeIcon != nil)
        #expect(
            receivedRuntimeIcon !== baseIcon,
            "The runtime app icon must include the unread count instead of reusing the unbadged base icon"
        )
    }
}
