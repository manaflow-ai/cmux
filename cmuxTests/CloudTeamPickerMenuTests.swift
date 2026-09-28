import AppKit
import CmuxSettingsUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Stands in for the team menu's tracking loop: a nested run loop, like
/// `NSMenu.popUp`, that records whether main-queue work ran while it spun.
@MainActor
private final class MenuTrackingProbe {
    private var queueDrained = false
    private(set) var drainedWhileTracking: Bool?

    func track() {
        queueDrained = false
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.queueDrained = true }
        }
        let deadline = Date().addingTimeInterval(1)
        while !queueDrained, Date() < deadline {
            _ = RunLoop.current.run(mode: .default, before: deadline)
        }
        drainedWhileTracking = queueDrained
    }
}

@MainActor
@Suite("Cloud team picker menu")
struct CloudTeamPickerMenuTests {
    private let teams = [
        AccountTeamSummary(id: "team-long", displayName: "Benjamin Swerdlow's Team With A Long Name"),
        AccountTeamSummary(id: "team-alpha", displayName: "Alpha Squad"),
    ]

    private func item(_ menu: NSMenu, _ identifier: String) -> NSMenuItem? {
        menu.items.first { $0.identifier?.rawValue == identifier }
    }

    @Test func checksTheActiveTeamAndKeepsFullNames() throws {
        let menu = CloudTeamPickerMenu.make(
            teams: teams, selectedTeamID: "team-long", isSwitching: false,
            onSelect: { _ in }, onCreate: {}
        )
        let long = try #require(item(menu, CloudTeamPickerMenu.teamIdentifier("team-long")))
        let alpha = try #require(item(menu, CloudTeamPickerMenu.teamIdentifier("team-alpha")))
        #expect(long.title == "Benjamin Swerdlow's Team With A Long Name")
        #expect(long.state == .on)
        #expect(alpha.state == .off)
        #expect(long.isEnabled && alpha.isEnabled)
        #expect(item(menu, CloudTeamPickerMenu.createTeamIdentifier)?.isEnabled == true)
        #expect(item(menu, CloudTeamPickerMenu.switchingStatusIdentifier) == nil)
        #expect(menu.items.last?.identifier?.rawValue == CloudTeamPickerMenu.createTeamIdentifier)
    }

    @Test func pendingSwitchShowsStatusAndDisablesEveryAction() throws {
        let menu = CloudTeamPickerMenu.make(
            teams: teams, selectedTeamID: "team-alpha", isSwitching: true,
            onSelect: { _ in }, onCreate: {}
        )
        let status = try #require(menu.items.first)
        #expect(status.identifier?.rawValue == CloudTeamPickerMenu.switchingStatusIdentifier)
        #expect(!status.isEnabled)
        #expect(item(menu, CloudTeamPickerMenu.teamIdentifier("team-alpha"))?.state == .on)
        #expect(menu.items.filter(\.isEnabled).isEmpty)
    }

    @Test func noMembershipShowsLoadingAndStillOffersCreate() {
        let menu = CloudTeamPickerMenu.make(
            teams: [], selectedTeamID: nil, isSwitching: false,
            onSelect: { _ in }, onCreate: {}
        )
        #expect(item(menu, CloudTeamPickerMenu.loadingTeamsIdentifier)?.isEnabled == false)
        #expect(item(menu, CloudTeamPickerMenu.createTeamIdentifier)?.isEnabled == true)
    }

    @Test func itemsRunTheirActions() throws {
        var selected: [String] = []
        var createCount = 0
        let menu = CloudTeamPickerMenu.make(
            teams: teams, selectedTeamID: "team-long", isSwitching: false,
            onSelect: { selected.append($0.id) }, onCreate: { createCount += 1 }
        )
        let alpha = try #require(item(menu, CloudTeamPickerMenu.teamIdentifier("team-alpha")))
        menu.performActionForItem(at: menu.index(of: alpha))
        let create = try #require(item(menu, CloudTeamPickerMenu.createTeamIdentifier))
        menu.performActionForItem(at: menu.index(of: create))
        #expect(selected == ["team-alpha"])
        #expect(createCount == 1)
    }

    /// A palette or shortcut request while sign-in work disables the trigger is
    /// dropped, not held until the trigger is enabled again.
    @Test func disabledTriggerDropsProgrammaticOpen() async {
        let anchor = CloudTeamPickerMenuAnchorView(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        var menuCount = 0
        var dismissCount = 0
        anchor.makeMenu = {
            menuCount += 1
            return NSMenu()
        }
        anchor.onDismiss = { dismissCount += 1 }
        anchor.isEnabled = false

        anchor.syncPresentation(true)
        await nextMainQueueTurn()
        anchor.isEnabled = true
        anchor.setFrameSize(NSSize(width: 140, height: 22))
        await nextMainQueueTurn()

        #expect(dismissCount == 1)
        #expect(menuCount == 0)
    }

    /// A palette or shortcut open must not run the menu's tracking loop inside
    /// a main-queue callout. A nested loop there cannot drain the main queue, so
    /// every main-queue and main-actor job would wait until the menu closed
    /// (the starvation #10788 hit with a nested terminate loop).
    @Test func programmaticOpenKeepsTheMainQueueRunningWhileTracking() async throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )
        window.isReleasedWhenClosed = false
        let anchor = CloudTeamPickerMenuAnchorView(frame: NSRect(x: 0, y: 0, width: 120, height: 22))
        window.contentView?.addSubview(anchor)
        let probe = MenuTrackingProbe()
        anchor.makeMenu = { NSMenu() }
        anchor.trackMenu = { _, _, _ in probe.track() }

        anchor.syncPresentation(true)
        for _ in 0..<300 where probe.drainedWhileTracking == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        #expect(anchor.window === window)
        #expect(probe.drainedWhileTracking == true, "The menu tracked inside a main-queue callout.")
    }

    private func nextMainQueueTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
