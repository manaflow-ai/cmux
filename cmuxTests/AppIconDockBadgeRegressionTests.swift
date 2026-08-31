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
            setNativeDockBadgeLabel: { _ in },
            startAppearanceObservation: {},
            stopAppearanceObservation: {},
            notifyDockTilePlugin: { _ in }
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

    @Test("Launch transition clears the native badge after composing it into the runtime icon")
    func launchTransitionAvoidsDuplicateDockBadge() {
        let baseIcon = NSImage(size: NSSize(width: 64, height: 64))
        var isFinishedLaunching = false
        var nativeBadgeLabel: String? = "3"
        var receivedRuntimeIcon: NSImage?
        let environment = AppIconSettings.Environment(
            isApplicationFinishedLaunching: { isFinishedLaunching },
            imageForMode: { _ in baseIcon },
            setApplicationIconImage: { icon in
                receivedRuntimeIcon = icon
            },
            setNativeDockBadgeLabel: { label in
                nativeBadgeLabel = label
            },
            startAppearanceObservation: {},
            stopAppearanceObservation: {},
            notifyDockTilePlugin: { _ in }
        )

        AppIconSettings.resetLiveEnvironmentProviderForTesting()
        defer { AppIconSettings.resetLiveEnvironmentProviderForTesting() }

        #expect(AppIconSettings.updateRuntimeBadgeLabel("3", environment: environment) == false)
        #expect(nativeBadgeLabel == "3")

        isFinishedLaunching = true
        AppIconSettings.setRuntimeBaseIcon(baseIcon, environment: environment)

        #expect(receivedRuntimeIcon !== baseIcon)
        #expect(nativeBadgeLabel == nil)
    }

    @Test("Unchanged badge label does not recompose or renotify the runtime icon")
    func unchangedBadgeLabelSkipsRuntimeWork() {
        let baseIcon = NSImage(size: NSSize(width: 64, height: 64))
        var runtimeIconSetCount = 0
        var nativeBadgeSetCount = 0
        var dockTileNotificationCount = 0
        let environment = AppIconSettings.Environment(
            isApplicationFinishedLaunching: { true },
            imageForMode: { _ in baseIcon },
            setApplicationIconImage: { _ in runtimeIconSetCount += 1 },
            setNativeDockBadgeLabel: { _ in nativeBadgeSetCount += 1 },
            startAppearanceObservation: {},
            stopAppearanceObservation: {},
            notifyDockTilePlugin: { _ in dockTileNotificationCount += 1 }
        )

        AppIconSettings.resetLiveEnvironmentProviderForTesting()
        defer { AppIconSettings.resetLiveEnvironmentProviderForTesting() }

        AppIconSettings.setRuntimeBaseIcon(baseIcon, environment: environment)
        #expect(AppIconSettings.updateRuntimeBadgeLabel("3", environment: environment))
        #expect(AppIconSettings.updateRuntimeBadgeLabel("3", environment: environment))

        #expect(runtimeIconSetCount == 2)
        #expect(nativeBadgeSetCount == 2)
        #expect(dockTileNotificationCount == 2)
    }

    @Test("Composed badge icon stays scale-aware and exposes its unread value")
    func composedBadgeIconPreservesRenderingAndAccessibilitySemantics() {
        let baseIcon = NSImage(size: NSSize(width: 64, height: 64))
        let rendered = AppIconBadgeRenderer.image(baseIcon: baseIcon, badgeLabel: "3")

        #expect(rendered.representations.contains { $0 is NSCustomImageRep })
        #expect(rendered.accessibilityDescription == "3")
    }

    @Test("Dock plugin hides persisted unread count while cmux is not running")
    func dockPluginSuppressesStaleBadgeAfterUncleanExit() {
        #expect(AppIconBadgeRenderer.visibleBadgeLabel("3", isAppRunning: false) == nil)
        #expect(AppIconBadgeRenderer.visibleBadgeLabel("3", isAppRunning: true) == "3")
    }

    @Test("Persisted-label cleanup refreshes the Dock plugin before launch completes")
    func persistedLabelCleanupForcesDockPluginRefresh() {
        var dockTileLabels: [String?] = []
        let environment = AppIconSettings.Environment(
            isApplicationFinishedLaunching: { false },
            imageForMode: { _ in nil },
            setApplicationIconImage: { _ in },
            setNativeDockBadgeLabel: { _ in },
            startAppearanceObservation: {},
            stopAppearanceObservation: {},
            notifyDockTilePlugin: { dockTileLabels.append($0) }
        )

        AppIconSettings.resetLiveEnvironmentProviderForTesting()
        defer { AppIconSettings.resetLiveEnvironmentProviderForTesting() }

        #expect(
            AppIconSettings.updateRuntimeBadgeLabel(
                nil,
                forceDockTileRefresh: true,
                environment: environment
            ) == false
        )
        #expect(dockTileLabels.count == 1)
        #expect(dockTileLabels[0] == nil)
    }

    @Test("Native fallback suppresses plugin composition until a runtime icon exists")
    func nativeFallbackUsesOnlyOneBadgeRenderer() {
        var dockTileLabels: [String?] = []
        let environment = AppIconSettings.Environment(
            isApplicationFinishedLaunching: { true },
            imageForMode: { _ in nil },
            setApplicationIconImage: { _ in },
            setNativeDockBadgeLabel: { _ in },
            startAppearanceObservation: {},
            stopAppearanceObservation: {},
            notifyDockTilePlugin: { dockTileLabels.append($0) }
        )

        AppIconSettings.resetLiveEnvironmentProviderForTesting()
        defer { AppIconSettings.resetLiveEnvironmentProviderForTesting() }

        #expect(AppIconSettings.updateRuntimeBadgeLabel("3", environment: environment) == false)
        #expect(dockTileLabels.count == 1)
        #expect(dockTileLabels[0] == nil)
    }

    @Test("Persisted Dock badge label can be cleared before app termination")
    func persistedDockBadgeCanBeCleared() throws {
        let suiteName = "AppIconDockBadgeRegressionTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        #expect(NotificationBadgeSettings.persistDockBadgeLabel("3", defaults: defaults))
        #expect(defaults.string(forKey: NotificationBadgeSettings.dockBadgeLabelKey) == "3")
        #expect(NotificationBadgeSettings.persistDockBadgeLabel("3", defaults: defaults) == false)

        #expect(NotificationBadgeSettings.persistDockBadgeLabel(nil, defaults: defaults))
        #expect(defaults.string(forKey: NotificationBadgeSettings.dockBadgeLabelKey) == nil)
    }

    @Test("Native Dock badge is suppressed when the runtime icon already contains it")
    func nativeDockBadgeAvoidsDuplicateRendering() {
        #expect(
            NotificationBadgeSettings.nativeDockBadgeLabel(
                "3",
                runtimeIconIncludesBadge: true
            ) == nil
        )
        #expect(
            NotificationBadgeSettings.nativeDockBadgeLabel(
                "3",
                runtimeIconIncludesBadge: false
            ) == "3"
        )
    }
}
