import AppKit
import CmuxCloud
import CmuxSettingsUI
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The status item and the main-menu Cloud menu render one entry tree. These
/// tests pin what that tree offers in each account state and that each row
/// reaches the verb it names.
@MainActor
@Suite("Cloud menus")
struct CloudMenuContentTests {
    @Test("Cloud off shows no Cloud rows")
    func unavailableIsEmpty() {
        let recorder = Recorder()
        let context = CloudMenuContext(account: .unavailable)
        #expect(CloudMenuContent.entries(context, actions: recorder.actions, layout: .mainMenu).isEmpty)
        #expect(CloudMenuContent.entries(context, actions: recorder.actions, layout: .statusItem).isEmpty)
    }

    @Test("Signed out offers sign-in, and it reaches the account flow")
    func signedOutOffersSignIn() throws {
        let recorder = Recorder()
        let entries = CloudMenuContent.entries(
            CloudMenuContext(account: .signedOut(isSigningIn: false)),
            actions: recorder.actions,
            layout: .statusItem
        )
        #expect(entries.map(\.id) == ["cloud.title", "cloud.signIn"])
        try Self.perform("cloud.signIn", in: entries)
        #expect(recorder.log == ["signIn"])

        let signingIn = CloudMenuContent.entries(
            CloudMenuContext(account: .signedOut(isSigningIn: true)),
            actions: recorder.actions,
            layout: .mainMenu
        )
        #expect(Self.action("cloud.signIn", in: signingIn)?.isEnabled == false)
    }

    @Test("Main menu lists the account, create verbs, every machine, tools and sign-out")
    func mainMenuLayout() throws {
        let recorder = Recorder()
        let machines = (0..<12).map { Self.machine("m\($0)") }
        let entries = CloudMenuContent.entries(
            CloudMenuContext(account: .signedIn(Self.account(teams: 1)), machines: machines, loadState: .loaded),
            actions: recorder.actions,
            layout: .mainMenu
        )
        let ids = entries.filter { if case .separator = $0 { return false } else { return true } }.map(\.id)
        #expect(ids == ["cloud.account", "cloud.newWorkspace", "cloud.newMachine", "cloud.machines.title"]
            + machines.map { "machine.\($0.id)" }
            + ["cloud.showMachines", "cloud.dashboard", "cloud.diagnostics", "cloud.signOut"])
        try Self.perform("cloud.newWorkspace", in: entries)
        try Self.perform("cloud.newMachine", in: entries)
        try Self.perform("cloud.signOut", in: entries)
        #expect(recorder.log == ["newWorkspace", "newMachine", "signOut"])
    }

    @Test("Status item caps inline machines and links the rest to the sidebar")
    func statusItemCapsMachines() throws {
        let recorder = Recorder()
        let machines = (0..<12).map { Self.machine("m\($0)") }
        let entries = CloudMenuContent.entries(
            CloudMenuContext(account: .signedIn(Self.account(teams: 1)), machines: machines, loadState: .loaded),
            actions: recorder.actions,
            layout: .statusItem
        )
        let machineRows = entries.filter { $0.id.hasPrefix("machine.") }
        #expect(machineRows.count == CloudMenuContent.statusItemMachineLimit)
        try Self.perform("cloud.machines.showAll", in: entries)
        #expect(recorder.log == ["showMachines"])
        // Account, team and tools live under More Cloud, not inline.
        let more = try #require(Self.submenu("cloud.more", in: entries))
        #expect(more.children.contains { $0.id == "cloud.signOut" })
        #expect(!entries.contains { $0.id == "cloud.signOut" })
    }

    @Test("Teams appear with the active one checked, and switching calls the account flow")
    func teamSubmenu() throws {
        let recorder = Recorder()
        let entries = CloudMenuContent.entries(
            CloudMenuContext(account: .signedIn(Self.account(teams: 2)), loadState: .loaded),
            actions: recorder.actions,
            layout: .mainMenu
        )
        let team = try #require(Self.submenu("cloud.team", in: entries))
        #expect(team.detail == "Team 0")
        #expect(Self.action("cloud.team.t0", in: team.children)?.isChecked == true)
        #expect(Self.action("cloud.team.t1", in: team.children)?.isChecked == false)
        try Self.perform("cloud.team.t1", in: team.children)
        #expect(recorder.log == ["team:t1"])
    }

    @Test("A failed read says why and offers the matching fix")
    func failedReadOffersFix() throws {
        let recorder = Recorder()
        func entries(_ problem: MachinesPanelViewModel.CloudListProblem) -> [CloudMenuEntry] {
            CloudMenuContent.entries(
                CloudMenuContext(account: .signedIn(Self.account(teams: 1)), loadState: .failed(problem)),
                actions: recorder.actions,
                layout: .mainMenu
            )
        }
        try Self.perform("cloud.problem.signIn", in: entries(.sessionRejected))
        try Self.perform("cloud.problem.upgrade", in: entries(.requiresPro))
        try Self.perform("cloud.problem.retry", in: entries(.unreachable))
        #expect(recorder.log == ["signIn", "upgrade", "retry"])
    }

    @Test("A loaded empty fleet says so; a first load says Loading")
    func emptyAndLoading() {
        let recorder = Recorder()
        let empty = CloudMenuContent.entries(
            CloudMenuContext(account: .signedIn(Self.account(teams: 1)), loadState: .loaded),
            actions: recorder.actions,
            layout: .mainMenu
        )
        #expect(empty.contains { $0.id == "cloud.machines.empty" })
        let loading = CloudMenuContext(account: .signedIn(Self.account(teams: 1)), loadState: .loading)
        #expect(CloudMenuContent.machinesTitle(loading).contains("\u{2026}"))
        #expect(!CloudMenuContent.entries(loading, actions: recorder.actions, layout: .mainMenu).contains { $0.id == "cloud.machines.empty" })
    }

    @Test("Machine submenu offers only verbs the machine honors")
    func machineVerbs() throws {
        let recorder = Recorder()
        var limited = Self.machine("plain")
        limited.capabilities.snapshot = false
        limited.capabilities.fork = false
        let plainIDs = recorder.actions.machine.submenuEntries(limited).compactMap(Self.actionID)
        #expect(plainIDs == ["machine.plain.openShell", "machine.plain.newWorkspace", "machine.plain.openFullClient",
                             "machine.plain.rename", "machine.plain.status", "machine.plain.delete"])

        var desktop = Self.machine("desk", isDesktop: true)
        desktop.privateAddress = "100.64.0.9"
        let desktopEntries = recorder.actions.machine.submenuEntries(desktop)
        #expect(desktopEntries.contains { $0.id == "machine.desk.openDesktop" })
        try Self.perform("machine.desk.copyIP", in: desktopEntries)
        try Self.perform("machine.desk.checkpoint", in: desktopEntries)
        try Self.perform("machine.desk.newWorkspace", in: desktopEntries)
        // Fork goes to the shared create coordinator (pending row), never a raw CLI launch.
        try Self.perform("machine.desk.fork", in: desktopEntries)
        #expect(recorder.log == ["copy:100.64.0.9", "run:desk:vm snapshot", "newWorkspace:desk", "fork:desk"])

        var expired = Self.machine("locked")
        expired.freeAccess = .expired
        let openIDs = recorder.actions.machine.openEntries(expired).compactMap(Self.actionID)
        #expect(openIDs == ["machine.locked.upgrade"])
        #expect(CloudMenuTone(expired) == .locked)
    }

    @Test("Delete routes the current machine display name, including after a rename")
    func deleteMenuUsesCurrentDisplayName() throws {
        var confirmedIDs: [String] = []
        var confirmedNames: [String] = []
        let verbs = CloudMachineMenuVerbs(
            openShell: { _ in }, newWorkspace: { _ in }, openDesktop: { _ in },
            runCommand: { _, _ in }, promptRename: { _ in }, copyToPasteboard: { _ in },
            confirmDelete: {
                confirmedIDs.append($0.id)
                confirmedNames.append($0.displayName)
            }, promptUpgrade: {}
        )
        let initial = MachineSnapshot(id: "vm-opaque-16336", provider: "freestyle", image: "cmux-devbox", isDesktop: false, activity: .ready, slug: "crisp-rose-piglet")
        let renamed = MachineSnapshot(id: initial.id, provider: initial.provider, image: initial.image, isDesktop: false, activity: .ready, label: "new-cloud-name", slug: initial.slug)
        for machine in [initial, renamed] {
            let entry = try #require(verbs.deleteEntries(machine).first)
            guard case .action(let action) = entry else { Issue.record("Delete entry should be an action"); return }
            action.perform()
        }
        #expect(confirmedIDs == [initial.id, renamed.id])
        #expect(confirmedNames == [initial.displayName, renamed.displayName])
    }

    @Test("Delete title uses a named machine and falls back for a blank name")
    func deleteConfirmationTitleUsesReadableName() {
        let format = String(localized: "machines.delete.title", defaultValue: "Delete machine “%@”?")
        let named = MachineSnapshot(
            id: "vm-opaque-16336",
            provider: "freestyle",
            image: "cmux-devbox",
            isDesktop: false,
            activity: .ready,
            slug: "crisp-rose-piglet"
        )
        #expect(MachineRowActions.deleteConfirmationTitle(for: named) == String(format: format, "crisp-rose-piglet"))

        let blank = MachineSnapshot(
            id: named.id,
            provider: named.provider,
            image: named.image,
            isDesktop: named.isDesktop,
            activity: named.activity,
            label: " ",
            slug: "\t"
        )
        #expect(MachineRowActions.deleteConfirmationTitle(for: blank) == String(format: format, "vm-opaque-16336"))
    }

    @Test("Status item renders machines with a status dot and dimmed state")
    func appKitRendering() throws {
        let recorder = Recorder()
        let entries = CloudMenuContent.entries(
            CloudMenuContext(account: .signedIn(Self.account(teams: 1)), machines: [Self.machine("m0")], loadState: .loaded),
            actions: recorder.actions,
            layout: .statusItem
        )
        let items = CloudMenuAppKitRenderer.items(entries)
        let row = try #require(items.first { $0.identifier?.rawValue == "machine.m0" })
        #expect(row.image != nil)
        #expect(row.attributedTitle?.string.hasPrefix("m0") == true)
        let open = try #require(row.submenu?.items.first { $0.identifier?.rawValue == "machine.m0.openShell" })
        let target = try #require(open.target as? NSObject)
        _ = target.perform(open.action, with: open)
        #expect(recorder.log == ["shell:m0"])
    }

    @Test("Opening a menu reuses a fresh fleet, and a team switch drops it")
    func modelRefreshPolicy() async throws {
        let center = NotificationCenter()
        let reads = ReadCounter()
        let model = CloudMenuModel(
            center: center,
            listMachines: {
                reads.count += 1
                return VMListPage(vms: [VMSummary(id: "vm-\(reads.count)", provider: "freestyle", status: "running", image: "cmux-devbox", createdAt: 0, base: nil)])
            },
            isAvailable: { true },
            pinStore: { nil },
            isFeatureEnabled: { true },
            mainMenu: { nil }
        )
        model.menuWillOpen()
        try await Self.waitUntil { model.loadState == .loaded }
        #expect(model.machines.map(\.id) == ["vm-1"])
        model.menuWillOpen()
        #expect(reads.count == 1)

        center.post(name: .cmuxCloudTeamScopeDidChange, object: nil)
        #expect(model.machines.isEmpty)
        #expect(model.loadState == .idle)
        model.menuWillOpen()
        try await Self.waitUntil { model.loadState == .loaded }
        #expect(model.machines.map(\.id) == ["vm-2"])
    }

    @Test("A read that lands after a scope change does not leave the menu loading")
    func scopeChangeDuringReadRecovers() async throws {
        let reads = ReadCounter()
        let scope = ScopeBox(value: "team:personal")
        let model = CloudMenuModel(
            center: NotificationCenter(),
            listMachines: {
                reads.count += 1
                // The team is confirmed while the first read is in flight.
                if reads.count == 1 { scope.value = "team:confirmed" }
                return VMListPage(vms: [VMSummary(id: "vm-\(reads.count)", provider: "freestyle", status: "running", image: "cmux-devbox", createdAt: 0, base: nil)])
            },
            isAvailable: { true },
            pinStore: { nil },
            scope: { scope.value },
            isFeatureEnabled: { true },
            mainMenu: { nil }
        )
        model.menuWillOpen()
        try await Self.waitUntil { model.loadState == .loaded }
        #expect(model.machines.map(\.id) == ["vm-2"])
    }

    @Test("An identical rebuild keeps the status item's rows; a visible change replaces them")
    func signatureTracksVisibleChanges() {
        let recorder = Recorder()
        func entries(_ machines: [MachineSnapshot]) -> [CloudMenuEntry] {
            CloudMenuContent.entries(
                CloudMenuContext(account: .signedIn(Self.account(teams: 1)), machines: machines, loadState: .loaded),
                actions: recorder.actions,
                layout: .statusItem
            )
        }
        let same = CloudMenuEntry.signature(entries([Self.machine("m0")]))
        #expect(same == CloudMenuEntry.signature(entries([Self.machine("m0")])))
        let renamed = MachineSnapshot(id: "m0", provider: "freestyle", image: "cmux-devbox", isDesktop: false, activity: .pending, label: "renamed")
        #expect(same != CloudMenuEntry.signature(entries([renamed])))
    }

    // MARK: Fixtures

    @MainActor
    final class ReadCounter { var count = 0 }

    @MainActor
    final class ScopeBox {
        var value: String?
        init(value: String?) { self.value = value }
    }

    @MainActor
    final class Recorder {
        var log: [String] = []

        var actions: CloudMenuActions {
            CloudMenuActions(
                signIn: { self.log.append("signIn") },
                signOut: { self.log.append("signOut") },
                selectTeam: { self.log.append("team:\($0)") },
                newWorkspace: { self.log.append("newWorkspace") },
                newMachine: { self.log.append("newMachine") },
                showMachines: { self.log.append("showMachines") },
                openDashboard: { self.log.append("dashboard") },
                showDiagnostics: { self.log.append("diagnostics") },
                upgrade: { self.log.append("upgrade") },
                retry: { self.log.append("retry") },
                machine: CloudMachineMenuVerbs(
                    openShell: { self.log.append("shell:\($0)") },
                    newWorkspace: { self.log.append("newWorkspace:\($0)") },
                    openDesktop: { self.log.append("desktop:\($0)") },
                    runCommand: { self.log.append("run:\($0):\($1.joined(separator: " "))") },
                    promptRename: { machine in self.log.append("rename:\(machine.id)") },
                    copyToPasteboard: { self.log.append("copy:\($0)") },
                    confirmDelete: { self.log.append("delete:\($0.id)") },
                    promptUpgrade: { self.log.append("upgradeMachine") },
                    fork: { self.log.append("fork:\($0.id)") }
                )
            )
        }
    }

    static func account(teams: Int) -> CloudMenuAccount {
        CloudMenuAccount(
            email: "dev@example.com",
            teams: (0..<teams).map { AccountTeamSummary(id: "t\($0)", displayName: "Team \($0)") },
            selectedTeamID: "t0"
        )
    }

    static func machine(_ id: String, isDesktop: Bool = false) -> MachineSnapshot {
        MachineSnapshot(id: id, provider: "freestyle", image: "cmux-devbox", isDesktop: isDesktop, activity: .ready)
    }

    static func actionID(_ entry: CloudMenuEntry) -> String? {
        if case .action(let action) = entry { return action.id }
        return nil
    }

    static func action(_ id: String, in entries: [CloudMenuEntry]) -> CloudMenuAction? {
        for entry in entries {
            switch entry {
            case .action(let action) where action.id == id: return action
            case .submenu(let submenu): if let found = action(id, in: submenu.children) { return found }
            default: continue
            }
        }
        return nil
    }

    static func submenu(_ id: String, in entries: [CloudMenuEntry]) -> CloudMenuSubmenu? {
        for entry in entries {
            if case .submenu(let submenu) = entry {
                if submenu.id == id { return submenu }
                if let found = self.submenu(id, in: submenu.children) { return found }
            }
        }
        return nil
    }

    static func perform(_ id: String, in entries: [CloudMenuEntry]) throws {
        try #require(action(id, in: entries)).perform()
    }

    /// Polls until the predicate holds; the deadline only bounds a real failure.
    static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(condition())
    }
}
