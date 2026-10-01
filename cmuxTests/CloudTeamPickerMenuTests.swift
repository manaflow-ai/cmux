import AppKit
import CmuxSettingsUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

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
            teams: teams, selectedTeamID: "team-long", isSwitching: false, pendingCreate: nil,
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
            teams: teams, selectedTeamID: "team-alpha", isSwitching: true, pendingCreate: nil,
            onSelect: { _ in }, onCreate: {}
        )
        let status = try #require(menu.items.first)
        #expect(status.identifier?.rawValue == CloudTeamPickerMenu.switchingStatusIdentifier)
        #expect(!status.isEnabled)
        #expect(item(menu, CloudTeamPickerMenu.teamIdentifier("team-alpha"))?.state == .on)
        #expect(menu.items.filter(\.isEnabled).isEmpty)
    }

    /// The coordinator lists the new team before it selects it, and the
    /// pending row stands for that team until the create returns.
    @Test func pendingCreateChecksTheNewTeamOnceAndDisablesEveryAction() throws {
        let pending = PendingTeamCreate(displayName: "Launch Crew", existingTeamIDs: ["team-long", "team-alpha"])
        let menu = CloudTeamPickerMenu.make(
            teams: teams + [AccountTeamSummary(id: "team-new", displayName: "Launch Crew")],
            selectedTeamID: "team-long", isSwitching: false, pendingCreate: pending,
            onSelect: { _ in }, onCreate: {}
        )
        let status = try #require(menu.items.first)
        #expect(status.identifier?.rawValue == CloudTeamPickerMenu.creatingStatusIdentifier)
        #expect(!status.isEnabled)
        #expect(item(menu, CloudTeamPickerMenu.switchingStatusIdentifier) == nil)
        #expect(item(menu, CloudTeamPickerMenu.teamIdentifier("team-long"))?.state == .off)
        #expect(item(menu, CloudTeamPickerMenu.teamIdentifier("team-new")) == nil)
        let pendingItem = try #require(item(menu, CloudTeamPickerMenu.pendingTeamIdentifier))
        #expect(pendingItem.title == "Launch Crew")
        #expect(pendingItem.state == .on)
        #expect(menu.items.filter { $0.title == "Launch Crew" }.count == 1)
        #expect(menu.items.filter(\.isEnabled).isEmpty)
    }

    @Test func pendingCreateWithNoTeamsListedSkipsLoading() {
        let menu = CloudTeamPickerMenu.make(
            teams: [], selectedTeamID: nil, isSwitching: false,
            pendingCreate: PendingTeamCreate(displayName: "Launch Crew", existingTeamIDs: []),
            onSelect: { _ in }, onCreate: {}
        )
        #expect(item(menu, CloudTeamPickerMenu.loadingTeamsIdentifier) == nil)
        #expect(item(menu, CloudTeamPickerMenu.pendingTeamIdentifier)?.state == .on)
    }

    @Test func noMembershipShowsLoadingAndStillOffersCreate() {
        let menu = CloudTeamPickerMenu.make(
            teams: [], selectedTeamID: nil, isSwitching: false, pendingCreate: nil,
            onSelect: { _ in }, onCreate: {}
        )
        #expect(item(menu, CloudTeamPickerMenu.loadingTeamsIdentifier)?.isEnabled == false)
        #expect(item(menu, CloudTeamPickerMenu.createTeamIdentifier)?.isEnabled == true)
    }

    @Test func itemsRunTheirActions() throws {
        var selected: [String] = []
        var createCount = 0
        let menu = CloudTeamPickerMenu.make(
            teams: teams, selectedTeamID: "team-long", isSwitching: false, pendingCreate: nil,
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
        anchor.makeMenu = { _ in
            menuCount += 1
            return NSMenu()
        }
        anchor.onDismiss = { dismissCount += 1 }
        anchor.isEnabled = false

        anchor.syncPresentation(true)
        await nextRunLoopTurn()
        anchor.isEnabled = true
        anchor.setFrameSize(NSSize(width: 140, height: 22))
        await nextRunLoopTurn()

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
        let probe = CloudTeamPickerMenuTrackingProbe()
        let anchor = CloudTeamPickerMenuAnchorView(
            frame: NSRect(x: 0, y: 0, width: 120, height: 22)
        )
        window.contentView?.addSubview(anchor)
        anchor.makeMenu = { _ in CloudTeamPickerTestMenu { _ in probe.track() } }

        await withCheckedContinuation { continuation in
            anchor.onDismiss = { continuation.resume() }
            anchor.syncPresentation(true)
        }

        #expect(anchor.window === window)
        #expect(probe.drainedWhileTracking == true, "The menu tracked inside a main-queue callout.")
    }

    /// An item's follow-up, such as Create Team…'s sheet, waits until the
    /// menu's tracking loop has returned. A stand-in tracking loop queues it.
    @Test func itemFollowUpRunsAfterTheMenuCloses() throws {
        var events: [String] = []
        let anchor = CloudTeamPickerMenuAnchorView(
            frame: NSRect(x: 0, y: 0, width: 120, height: 22)
        )
        anchor.makeMenu = { _ in
            CloudTeamPickerTestMenu { view in
                let anchor = view as? CloudTeamPickerMenuAnchorView
                anchor?.afterDismiss { events.append("follow-up") }
                events.append("tracking ended")
            }
        }
        anchor.onDismiss = { events.append("dismissed") }

        let click = try #require(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 1
        ))
        anchor.mouseDown(with: click)
        anchor.afterDismiss { events.append("closed menu") }

        #expect(events == ["tracking ended", "dismissed", "follow-up", "closed menu"])
    }

    /// Run-loop blocks run in FIFO order, so a scheduled open has run by the
    /// time this later block does.
    private func nextRunLoopTurn() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform(inModes: [.default]) { continuation.resume() }
        }
    }

    @Test func listsReceivedInvitationsWithJoinRowsAboveCreate() throws {
        var joined: [String] = []
        let menu = CloudTeamPickerMenu.make(
            teams: teams, selectedTeamID: "team-alpha", isSwitching: false, pendingCreate: nil,
            onSelect: { _ in }, onCreate: {},
            invitations: [.init(id: "inv-1", teamName: "Launch Crew")],
            onJoin: { joined.append($0.id) }
        )
        let header = try #require(item(menu, CloudTeamPickerMenu.invitedHeaderIdentifier))
        #expect(!header.isEnabled)
        let join = try #require(item(menu, CloudTeamPickerMenu.invitationIdentifier("inv-1")))
        #expect(join.title == "Join Launch Crew")
        #expect(join.isEnabled)
        _ = join.target?.perform(join.action, with: join)
        #expect(joined == ["inv-1"])
        let headerIndex = menu.items.firstIndex(of: header)!
        let createIndex = menu.items.firstIndex { $0.identifier?.rawValue == CloudTeamPickerMenu.createTeamIdentifier }!
        #expect(headerIndex < createIndex)
        let plain = CloudTeamPickerMenu.make(
            teams: teams, selectedTeamID: "team-alpha", isSwitching: false, pendingCreate: nil,
            onSelect: { _ in }, onCreate: {}
        )
        #expect(item(plain, CloudTeamPickerMenu.invitedHeaderIdentifier) == nil)
    }
}
