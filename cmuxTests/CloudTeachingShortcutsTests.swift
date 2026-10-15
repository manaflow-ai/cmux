import CmuxCloud
import CmuxCloudBannerCore
import enum CmuxSettings.ShortcutAction
import CmuxSurfaceCatalogModel
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Cloud teaching layer: the new Cloud shortcuts (catalog, defaults,
/// palette hints, Cloud menu), the "What can I do here?" rows, and the facts
/// that earn a contextual tip.
@MainActor
struct CloudTeachingShortcutsTests {
    private static let teachingActions: [KeyboardShortcutSettings.Action] = [
        .openRepositoryInCloud, .openCloudSecrets, .toggleCloudPanel,
    ]

    // MARK: Shortcuts

    @Test func newCloudShortcutsArePublicCustomizableAndInTheSharedCatalog() {
        for action in Self.teachingActions {
            #expect(action.isPublicShortcutAction, "\(action) must show in Settings and the shortcuts overlay")
            #expect(KeyboardShortcutSettings.settingsVisibleActions.contains(action))
            let shared = ShortcutAction(rawValue: action.rawValue)
            #expect(shared != nil, "\(action) must be a cmux.json shortcuts.bindings key")
            #expect(shared?.group == .workspace)
            #expect(shared?.defaultStroke != nil)
        }
    }

    @Test func newCloudShortcutDefaultsStayInTheYFamilyAndCollideWithNothing() {
        let expected: [KeyboardShortcutSettings.Action: StoredShortcut] = [
            .openRepositoryInCloud: StoredShortcut(key: "y", command: true, shift: false, option: true, control: false),
            .openCloudSecrets: StoredShortcut(key: "y", command: true, shift: true, option: true, control: false),
            .toggleCloudPanel: StoredShortcut(key: "y", command: true, shift: false, option: false, control: true),
        ]
        for action in Self.teachingActions {
            #expect(action.defaultShortcut == expected[action])
            let others = KeyboardShortcutSettings.Action.allCases.filter {
                $0 != action && $0.defaultShortcut == action.defaultShortcut
            }
            #expect(others.isEmpty, "\(action) default collides with \(others)")
        }
    }

    @Test func appAndPackageDefaultsAgree() {
        for action in Self.teachingActions {
            let stroke = ShortcutAction(rawValue: action.rawValue)?.defaultStroke
            let app = action.defaultShortcut
            #expect(stroke?.key == app.key)
            #expect(stroke?.command == app.command)
            #expect(stroke?.shift == app.shift)
            #expect(stroke?.option == app.option)
            #expect(stroke?.control == app.control)
        }
    }

    @Test func paletteCommandsShowTheirShortcut() {
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: ContentView.commandPaletteCloudSecretsCommandId) == .openCloudSecrets)
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: ContentView.commandPaletteCloudToggleSidebarCommandId) == .toggleCloudPanel)
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: ContentView.commandPaletteCloudOpenRepositoryCommandId) == .openRepositoryInCloud)
        #expect(ContentView.commandPaletteShortcutAction(forCommandID: ContentView.commandPaletteCloudHelpCommandId) == nil)
    }

    @Test func signedOutPaletteOffersOnlyTheSidebarToggle() {
        let signedOut = ContentView.commandPaletteCloudTeachingContributions(isAuthenticated: false).map(\.commandId)
        let signedIn = ContentView.commandPaletteCloudTeachingContributions(isAuthenticated: true).map(\.commandId)
        guard CloudMachinesFeature.isEnabled else {
            #expect(signedOut.isEmpty && signedIn.isEmpty)
            return
        }
        #expect(signedOut == [ContentView.commandPaletteCloudToggleSidebarCommandId])
        #expect(Set(signedIn) == [
            ContentView.commandPaletteCloudToggleSidebarCommandId,
            ContentView.commandPaletteCloudSecretsCommandId,
            ContentView.commandPaletteCloudHelpCommandId,
        ])
    }

    @Test func cloudMenuShowsTheShortcutsItOwns() {
        for action in Self.teachingActions { #expect(action.isCloudMenuOwnedShortcut) }
        // ⌘Y and ⇧⌘Y keep their key equivalents in the File menu only.
        #expect(!KeyboardShortcutSettings.Action.newCloudWorkspace.isCloudMenuOwnedShortcut)
        #expect(!KeyboardShortcutSettings.Action.newCloudMachine.isCloudMenuOwnedShortcut)
    }

    // MARK: "What can I do here?"

    @Test func popoverListsEveryActionOnceWithACLICommand() {
        let rows = CloudTeachingAction.primary + CloudTeachingAction.secondary
        #expect(Set(rows) == Set(CloudTeachingAction.allCases))
        #expect(rows.count == CloudTeachingAction.allCases.count)
        for action in rows {
            #expect(action.cliCommand(machine: nil).hasPrefix("cmux "))
            #expect(!action.title.isEmpty)
        }
    }

    @Test func machineRowsNameTheRealMachineSoTheCommandRunsAsIs() {
        #expect(CloudTeachingAction.openTerminal.cliCommand(machine: "brave-otter") == "cmux vm open brave-otter")
        #expect(CloudTeachingAction.syncSecrets.cliCommand(machine: "brave-otter") == "cmux vm secrets sync brave-otter")
        #expect(CloudTeachingAction.openTerminal.cliCommand(machine: nil) == "cmux vm open <machine>")
        #expect(CloudTeachingAction.openTerminal.cliCommand(machine: "Austin's box") == "cmux vm open 'Austin'\\''s box'")
        #expect(CloudTeachingAction.newMachine.cliCommand(machine: "brave-otter") == "cmux vm new")
    }

    @Test func rowsWithShortcutsUseTheConfigurableActions() {
        #expect(CloudTeachingAction.newMachine.shortcutAction == .newCloudMachine)
        #expect(CloudTeachingAction.openRepository.shortcutAction == .openRepositoryInCloud)
        #expect(CloudTeachingAction.secrets.shortcutAction == .openCloudSecrets)
        #expect(CloudTeachingAction.openTerminal.shortcutAction == .newCloudWorkspace)
        #expect(CloudTeachingAction.allCases.filter(\.needsMachine) == [.openTerminal, .syncSecrets, .sharePort])
    }

    // MARK: Tips

    private func machine(_ id: String, label: String? = nil, activity: MachineSnapshot.Activity = .ready) -> MachineSnapshot {
        MachineSnapshot(id: id, provider: "freestyle", image: "devbox", isDesktop: false, activity: activity, label: label)
    }

    private func portResource(machine: String, port: Int) -> SurfaceResource {
        SurfaceResource(
            id: SurfaceResourceID(machine: .cloud(machine), kind: .browser, key: "port:\(port)"),
            title: ":\(port)", detail: nil, lifecycle: .running, agent: nil, remoteWorkspace: nil, port: port, url: nil
        )
    }

    @Test func factsNameTheFirstReadyMachineAndForwardedPort() {
        let facts = CloudHintsPanelSection.facts(
            machines: [machine("vm-a", activity: .pending), machine("vm-b", label: "brave-otter")],
            catalog: SurfaceCatalogSnapshot(machines: [], resources: [portResource(machine: "vm-b", port: 3000)], projections: []),
            unreadFailureTerminalIDs: [:],
            secretNames: []
        )
        #expect(facts.readyMachine == .init(id: "vm-b", label: "brave-otter"))
        #expect(facts.forwardedPort == .init(machineID: "vm-b", machineLabel: "brave-otter", port: 3000))
        #expect(!facts.hasUnreadAgentFailure)
    }

    @Test func aPortOnAnUnlistedMachineEarnsNoTip() {
        let facts = CloudHintsPanelSection.facts(
            machines: [machine("vm-b")],
            catalog: SurfaceCatalogSnapshot(machines: [], resources: [portResource(machine: "vm-gone", port: 3000)], projections: []),
            unreadFailureTerminalIDs: [:],
            secretNames: nil
        )
        #expect(facts.forwardedPort == nil)
    }

    @Test func keyTipNeedsAFailureAndNoAgentKey() {
        func facts(names: [String]?, failures: [String: Set<String>]) -> CloudHintsCenter.Facts {
            CloudHintsPanelSection.facts(machines: [], catalog: .empty, unreadFailureTerminalIDs: failures, secretNames: names)
        }
        let failure = ["vm-a": Set(["term_1"])]
        #expect(facts(names: [], failures: failure).hasUnreadAgentFailure)
        #expect(!facts(names: [], failures: failure).hasAgentKey)
        #expect(facts(names: ["ANTHROPIC_API_KEY"], failures: failure).hasAgentKey)
        #expect(facts(names: ["CLAUDE_CODE_OAUTH_TOKEN"], failures: failure).hasAgentKey)
        // A GitHub token is not what an agent signs in with.
        #expect(!facts(names: ["GH_TOKEN"], failures: failure).hasAgentKey)
        // Before the vault loads the answer is unknown, and unknown never nags.
        #expect(facts(names: nil, failures: failure).hasAgentKey)
        #expect(!facts(names: [], failures: ["vm-a": []]).hasUnreadAgentFailure)
    }

    private func isolatedCenter() -> (CloudHintsCenter, () -> Void) {
        let suite = "cloud-hints-center-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let center = CloudHintsCenter(queue: CloudHintsQueue(dismissals: CloudBannerDismissalStore(defaults: defaults)))
        return (center, { defaults.removePersistentDomain(forName: suite) })
    }

    @Test func centerShowsTheFailureTipFirstAndWithdrawsItWhenAKeyArrives() {
        let (center, cleanup) = isolatedCenter()
        defer { cleanup() }
        var facts = CloudHintsCenter.Facts()
        facts.readyMachine = .init(id: "vm-b", label: "brave-otter")
        facts.hasUnreadAgentFailure = true
        center.update(facts)
        #expect(center.queue.current(isBlocked: false)?.id == CloudHintsCenter.Kind.agentKey.rawValue)

        facts.hasAgentKey = true
        center.update(facts)
        let current = center.queue.current(isBlocked: false)
        #expect(current?.id == CloudHintsCenter.Kind.machineTerminal.rawValue)
        #expect(current?.subject == "brave-otter")
        #expect(!center.queue.isRetired(CloudHintsCenter.Kind.agentKey.rawValue))
    }

    @Test func openingCloudSecretsRetiresTheKeyTip() {
        let (center, cleanup) = isolatedCenter()
        defer { cleanup() }
        center.noteSecretsOpened()
        var facts = CloudHintsCenter.Facts()
        facts.hasUnreadAgentFailure = true
        center.update(facts)
        #expect(center.queue.current(isBlocked: false) == nil)
    }

    @Test func everyTipHasCopyForItsFacts() throws {
        let (center, cleanup) = isolatedCenter()
        defer { cleanup() }
        var facts = CloudHintsCenter.Facts()
        facts.readyMachine = .init(id: "vm-b", label: "brave-otter")
        facts.forwardedPort = .init(machineID: "vm-b", machineLabel: "brave-otter", port: 3000)
        facts.hasUnreadAgentFailure = true
        center.update(facts)
        for kind in CloudHintsCenter.Kind.allCases {
            let hint = try #require(center.queue.pending.first { $0.id == kind.rawValue })
            let presentation = try #require(center.presentation(for: hint))
            #expect(!presentation.title.isEmpty && !presentation.detail.isEmpty)
        }
        let machineTip = try #require(center.queue.pending.first { $0.id == CloudHintsCenter.Kind.machineTerminal.rawValue })
        #expect(center.presentation(for: machineTip)?.title.contains("brave-otter") == true)
        #expect(center.presentation(for: machineTip)?.perform != nil)
    }
}
