import AppKit
import CmuxTerminalCore
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Terminal configuration presentation metrics")
@MainActor
struct TerminalConfigurationPresentationMetricsTests {
    @Test
    func capturesFontSizesFromTheProvidedSnapshot() {
        var configuration = GhosttyConfig()
        configuration.fontSize = 19
        configuration.surfaceTabBarFontSize = 15
        configuration.sidebarFontSize = 17
        let metrics = capture(configuration)

        configuration.fontSize = 24
        configuration.surfaceTabBarFontSize = 20
        configuration.sidebarFontSize = 22

        #expect(metrics.terminalFontSize == 19)
        #expect(metrics.surfaceTabBarFontSize == 15)
        #expect(metrics.sidebarFontSize == 17)
        #expect(metrics != capture(configuration))
    }

    @Test
    func firstSnapshotDoesNotInvalidateChrome() async {
        await expectNotifications([], from: capture(GhosttyConfig()), comparedTo: nil)
    }

    @Test
    func identicalSnapshotsDoNotInvalidateChrome() async {
        let configuration = GhosttyConfig()
        await expectNotifications(
            [], from: capture(configuration), comparedTo: capture(configuration)
        )
    }

    @Test(arguments: Change.allCases)
    func publishesOnlyAffectedPresentationNotifications(change: Change) async {
        let baseline = GhosttyConfig()
        var changed = baseline
        change.apply(to: &changed)

        await expectNotifications(
            change.notifications,
            from: capture(changed),
            comparedTo: capture(baseline)
        )
    }

    @Test
    func hostBackgroundOwnershipInvalidatesOnlyChrome() async {
        let configuration = GhosttyConfig()
        await expectNotifications(
            [.ghosttyChromeConfigurationDidChange],
            from: .capture(configuration: configuration, usesHostLayerBackground: true),
            comparedTo: capture(configuration)
        )
    }

    @Test
    func simultaneousFontAndThemeChangesPublishEachNotificationOnce() async {
        let baseline = GhosttyConfig()
        var changed = baseline
        changed.fontSize += 1
        changed.surfaceTabBarFontSize += 1
        changed.sidebarFontSize += 1
        changed.backgroundColor = .red
        changed.foregroundColor = .blue

        await expectNotifications(
            [
                .ghosttyTerminalFontSizeDidChange,
                .ghosttySurfaceTabBarFontSizeDidChange,
                .ghosttySidebarFontSizeDidChange,
                .ghosttyChromeConfigurationDidChange,
            ],
            from: capture(changed),
            comparedTo: capture(baseline)
        )
    }

    enum Change: String, CaseIterable {
        case terminalFont, tabBarFont, sidebarFont
        case background, foreground, backgroundOpacity
        case unfocusedOpacity, unfocusedFill, divider
        case command, scrollback, cursor, selection

        var notifications: Set<Notification.Name> {
            switch self {
            case .terminalFont: [.ghosttyTerminalFontSizeDidChange]
            case .tabBarFont: [
                .ghosttySurfaceTabBarFontSizeDidChange, .ghosttyChromeConfigurationDidChange,
            ]
            case .sidebarFont: [.ghosttySidebarFontSizeDidChange]
            case .background, .foreground, .backgroundOpacity,
                 .unfocusedOpacity, .unfocusedFill, .divider:
                [.ghosttyChromeConfigurationDidChange]
            case .command, .scrollback, .cursor, .selection: []
            }
        }

        func apply(to configuration: inout GhosttyConfig) {
            switch self {
            case .terminalFont: configuration.fontSize += 1
            case .tabBarFont: configuration.surfaceTabBarFontSize += 1
            case .sidebarFont: configuration.sidebarFontSize += 1
            case .background: configuration.backgroundColor = .red
            case .foreground: configuration.foregroundColor = .blue
            case .backgroundOpacity: configuration.backgroundOpacity = 0.5
            case .unfocusedOpacity: configuration.unfocusedSplitOpacity = 0.4
            case .unfocusedFill: configuration.unfocusedSplitFill = .green
            case .divider: configuration.splitDividerColor = .yellow
            case .command: configuration.command = "/bin/sh"
            case .scrollback: configuration.scrollbackLimit += 1
            case .cursor: configuration.cursorColor = .red
            case .selection: configuration.selectionBackground = .blue
            }
        }
    }

    private func capture(_ configuration: GhosttyConfig) -> TerminalConfigurationPresentationMetrics {
        .capture(configuration: configuration, usesHostLayerBackground: false)
    }

    private func expectNotifications(
        _ expected: Set<Notification.Name>,
        from next: TerminalConfigurationPresentationMetrics,
        comparedTo previous: TerminalConfigurationPresentationMetrics?
    ) async {
        // Each probe uses an isolated center; observing one name per invocation
        // catches duplicate or missing events without mutable callback storage.
        let center = NotificationCenter()
        let names: [Notification.Name] = [
            .ghosttyTerminalFontSizeDidChange,
            .ghosttySurfaceTabBarFontSizeDidChange,
            .ghosttySidebarFontSizeDidChange,
            .ghosttyChromeConfigurationDidChange,
            .ghosttyDefaultBackgroundDidChange,
            .ghosttyConfigDidReload,
        ]
        for name in names {
            await confirmation("\(name.rawValue)", expectedCount: expected.contains(name) ? 1 : 0) { event in
                let observer = center.addObserver(forName: name, object: nil, queue: nil) { notification in
                    #expect(notification.object == nil)
                    #expect(notification.userInfo == nil)
                    event()
                }
                defer { center.removeObserver(observer) }
                next.publishChanges(comparedTo: previous, notificationCenter: center)
            }
        }
    }
}
