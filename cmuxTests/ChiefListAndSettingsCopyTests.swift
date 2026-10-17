import AppKit
import CmuxChief
import CmuxHomeCore
import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The v3f copy fixes around Chief: the workspace sidebar drops a subtitle that only repeats the
/// title, Settings' Activity names the harness and prints no path, the memory sheet tells a
/// note Chief saved from one typed in a terminal, and a turn tells the CLI it is Chief's.
@MainActor @Suite struct ChiefListAndSettingsCopyTests {
    @Test func aSubtitleThatOnlyRepeatsTheTitleIsDropped() {
        let echo: [String] = SidebarWorkspaceSnapshotFactory.droppingTitleEcho(["~"], title: "~")
        #expect(echo.isEmpty)
        #expect(SidebarWorkspaceSnapshotFactory.droppingTitleEcho(["~"], title: "Build") == ["~"])
        #expect(SidebarWorkspaceSnapshotFactory.droppingTitleEcho(["~/src", "src"], title: "src") == ["~/src", "src"])
        let none: [String] = SidebarWorkspaceSnapshotFactory.droppingTitleEcho([], title: "~")
        #expect(none.isEmpty)
    }

    @Test func openingAnAttachedHomeConversationMarksItReadBeforeWindowFocus() {
        #expect(ChiefHomeView.shouldMarkRead(isActive: true, attached: true, hidden: false))
        #expect(!ChiefHomeView.shouldMarkRead(isActive: false, attached: true, hidden: false))
        #expect(!ChiefHomeView.shouldMarkRead(isActive: true, attached: false, hidden: false))
        #expect(!ChiefHomeView.shouldMarkRead(isActive: true, attached: true, hidden: true))
    }

    @Test func selectedHomeConversationSuppressesTheStaleUnreadCount() {
        let selected = ConversationID("chief")
        let other = ConversationID("other")
        #expect(ChiefHomeView.unreadCount(rowID: selected, rowUnread: 3, selected: selected,
                                          selectedIsShown: true, visible: [], manuallyMarked: false) == 0)
        #expect(ChiefHomeView.unreadCount(rowID: other, rowUnread: 3, selected: selected,
                                          selectedIsShown: true, visible: [], manuallyMarked: false) == 3)
        #expect(ChiefHomeView.unreadCount(rowID: other, rowUnread: 0, selected: selected,
                                          selectedIsShown: true, visible: [], manuallyMarked: true) == 1)
        #expect(ChiefHomeView.unreadCount(rowID: other, rowUnread: 4, selected: selected,
                                          selectedIsShown: false, visible: [other], manuallyMarked: false) == 0)
    }

    @Test func deletingAConversationHidesItButKeepsTheChiefThreadAvailable() {
        let chief = ConversationID("chief")
        let other = ConversationID("other")
        let hidden: Set<String> = [other.rawValue]
        #expect(!ChiefHomeView.shouldShow(other, hidden: hidden, selected: chief, defaultID: chief))
        #expect(ChiefHomeView.shouldShow(chief, hidden: hidden, selected: chief, defaultID: chief))
        // A selected row remains during the transition while Home moves to Chief.
        #expect(ChiefHomeView.shouldShow(other, hidden: hidden, selected: other, defaultID: chief))
    }

    @Test func activityNamesTheHarnessAndPrintsNoPath() {
        #expect(ChiefSettingsStrings.harnessName("claude") == CmuxChief.ChiefHarness.claude.displayName)
        #expect(ChiefSettingsStrings.harnessName("codex") == CmuxChief.ChiefHarness.codex.displayName)
        #expect(ChiefSettingsStrings.harnessName("other") == "other")
        #expect(!ChiefSettingsStrings.runsOnThisMac(temporary: false).contains("/"))
        #expect(!ChiefSettingsStrings.runsOnThisMac(temporary: true).contains("/"))
        #expect(ChiefSettingsStrings.runsOnThisMac(temporary: true) != ChiefSettingsStrings.runsOnThisMac(temporary: false))
    }

    @Test func unknownChiefModelsDoNotCarryAStaleEffortFlag() {
        let settings = ChiefEngineSettings(harness: "claude", model: "claude-future-6", effort: "max", dangerouslySkipPermissions: false)
        #expect(settings.normalized.effort.isEmpty)
        #expect(ChiefEngineSettings(harness: "codex", model: "gpt-5.5", effort: "max", dangerouslySkipPermissions: false).normalized.effort.isEmpty)
        #expect(ChiefEngineSettings(harness: "codex", model: "gpt-5.5", effort: "xhigh", dangerouslySkipPermissions: false).normalized.effort == "xhigh")
    }

    @Test func dangerousPermissionBypassDefaultsOffAndPersistsOnlyWhenEnabled() {
        let suiteName = "cmux.chief.permissions.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let access = ChiefSettingsAccess(defaults: defaults)
        #expect(!access.current.dangerouslySkipPermissions)

        var enabled = access.current
        enabled.dangerouslySkipPermissions = true
        access.write(enabled)
        #expect(access.current.dangerouslySkipPermissions)

        var disabled = access.current
        disabled.dangerouslySkipPermissions = false
        access.write(disabled)
        #expect(!access.current.dangerouslySkipPermissions)
        #expect(defaults.object(forKey: ChiefSettingsAccess.dangerouslySkipPermissionsKey) == nil)
    }

    @Test func memorySourcesTellChiefFromTheCommandLine() {
        #expect(ChiefMemoryStrings.source("chief") != ChiefMemoryStrings.source("cli"))
        #expect(ChiefMemoryStrings.source("cli") != "cli")
        #expect(ChiefMemoryStrings.source("app") != ChiefMemoryStrings.source("chief"))
        #expect(ChiefMemoryStrings.source("plugin") == "plugin")
    }

    @Test func aTurnTellsTheCLIItIsChiefs() {
        let home = ChiefHome(root: URL(fileURLWithPath: "/tmp/chief-home", isDirectory: true))
        let workspaceID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let surfaceID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let environment = ChiefTurnContextBuilder.environment(socketPath: "/tmp/cmux.sock", home: home,
                                                              workspaceID: workspaceID, surfaceID: surfaceID, base: [:])
        #expect(environment["CMUX_CHIEF_TURN"] == "1")
        #expect(environment["CMUX_WORKSPACE_ID"] == workspaceID.uuidString)
        #expect(environment["CMUX_SURFACE_ID"] == surfaceID.uuidString)
    }

    @Test func theFirstRunPanelSaysWhatChiefDoes() throws {
        let panel = ChiefFirstRunView(frame: NSRect(x: 0, y: 0, width: 520, height: 720))
        panel.setShowsActions(true)
        panel.needsLayout = true
        panel.layoutSubtreeIfNeeded()
        #expect(panel.introTitle.stringValue == ChiefStrings.firstRunIntroTitle)
        #expect(panel.introBody.stringValue == ChiefStrings.firstRunIntroBody)
        #expect(!panel.introTitle.isHidden && !panel.introBody.isHidden)
        // Title, then body, then the action rows, with no overlap.
        let firstAction = try #require(panel.actionRows.first?.frame)
        #expect(panel.introTitle.frame.maxY <= panel.introBody.frame.minY)
        #expect(panel.introBody.frame.maxY <= firstAction.minY)
        // The body wraps to its full height instead of being cut to one line.
        let cell = try #require(panel.introBody.cell)
        let needed = cell.cellSize(forBounds: NSRect(x: 0, y: 0, width: panel.introBody.frame.width,
                                                     height: .greatestFiniteMagnitude)).height
        #expect(panel.introBody.frame.height >= floor(needed))
        #expect(needed > ceil(cell.cellSize.height))
    }

    @Test func aShortPanelDropsTheIntroBeforeTheActions() {
        let panel = ChiefFirstRunView(frame: NSRect(x: 0, y: 0, width: 520, height: 150))
        panel.setShowsActions(true)
        panel.needsLayout = true
        panel.layoutSubtreeIfNeeded()
        #expect(panel.introTitle.isHidden)
        #expect(panel.actionRows.contains { !$0.isHidden })
    }

    @Test func aTurnFindsToolsOnTheLoginShellPath() {
        let home = ChiefHome(root: URL(fileURLWithPath: "/tmp/chief-home", isDirectory: true))
        let environment = ChiefTurnContextBuilder.environment(socketPath: "/tmp/cmux.sock", home: home,
                                                              loginShellPath: "/custom/tools:/usr/bin",
                                                              base: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
        let path = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        #expect(path.contains("/custom/tools"))
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(path.contains("/usr/sbin"))
        if let cli = ChiefTurnContextBuilder.bundledCLI {
            #expect(path.first == cli.deletingLastPathComponent().path)
        }
    }
}
