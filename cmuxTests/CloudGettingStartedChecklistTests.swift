import AppKit
import CmuxSurfaceCatalogModel
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The Cloud panel's "Get started" card: three steps that check themselves
/// from real state, one action on the current step, and no way to nag.
@Suite("Cloud getting started checklist")
struct CloudGettingStartedChecklistTests {
    private typealias Checklist = CloudGettingStartedChecklist

    private static func input(
        secretCount: Int? = 0,
        machineCount: Int = 0,
        hasCloudAgent: Bool = false,
        hasLoadedMachines: Bool = true,
        hasListProblem: Bool = false,
        isDismissed: Bool = false
    ) -> Checklist.Input {
        Checklist.Input(
            secretCount: secretCount,
            machineCount: machineCount,
            hasCloudAgent: hasCloudAgent,
            hasLoadedMachines: hasLoadedMachines,
            hasListProblem: hasListProblem,
            isDismissed: isDismissed
        )
    }

    @Test("a new account starts at API keys with all three steps open")
    func newAccountStartsAtKeys() {
        let checklist = Checklist(Self.input())
        #expect(checklist.steps == [.addKeys, .createMachine, .startAgent])
        #expect(checklist.current == .addKeys)
        #expect(checklist.completedCount == 0)
        #expect(checklist.totalCount == 3)
        #expect(checklist.isVisible)
    }

    @Test("each step checks itself from state, in order")
    func stepsAutoCheck() {
        let keys = Checklist(Self.input(secretCount: 2))
        #expect(keys.isDone(.addKeys))
        #expect(keys.current == .createMachine)

        let machine = Checklist(Self.input(secretCount: 1, machineCount: 1))
        #expect(machine.isDone(.createMachine))
        #expect(machine.current == .startAgent)
        #expect(machine.progress == 2.0 / 3.0)

        // A machine made before keys still checks, but keys stay current:
        // an agent on a machine without them stops at a login prompt.
        let outOfOrder = Checklist(Self.input(secretCount: 0, machineCount: 1))
        #expect(outOfOrder.isDone(.createMachine))
        #expect(outOfOrder.current == .addKeys)
    }

    @Test("finishing every step hides the card")
    func completeHides() {
        let done = Checklist(Self.input(secretCount: 3, machineCount: 1, hasCloudAgent: true))
        #expect(done.isComplete)
        #expect(done.current == nil)
        #expect(!done.isVisible)
    }

    @Test("a build without the secrets vault leaves the keys step out instead of never finishing")
    func unwiredVaultDropsKeysStep() {
        let checklist = Checklist(Self.input(secretCount: nil))
        #expect(checklist.steps == [.createMachine, .startAgent])
        #expect(checklist.current == .createMachine)
        #expect(checklist.totalCount == 2)
        let done = Checklist(Self.input(secretCount: nil, machineCount: 1, hasCloudAgent: true))
        #expect(done.isComplete)
        #expect(!done.isVisible)
    }

    @Test("the card waits for the first read, yields to list errors, and stays closed once dismissed")
    func neverNags() {
        #expect(!Checklist(Self.input(hasLoadedMachines: false)).isVisible)
        #expect(!Checklist(Self.input(hasListProblem: true)).isVisible)
        #expect(!Checklist(Self.input(isDismissed: true)).isVisible)
    }

    @Test("step 3 teaches the exact clone command")
    func startAgentCommand() {
        #expect(Checklist.startAgentCommand() == "cmux vm clone <repo> --agent claude")
        #expect(Checklist.startAgentCommand(repo: "  ") == "cmux vm clone <repo> --agent claude")
        #expect(Checklist.startAgentCommand(repo: "owner/repo", agent: "codex") == "cmux vm clone owner/repo --agent codex")
    }

    @Test("every step links to a Cloud docs page")
    func stepsLinkToDocs() {
        for step in Checklist.Step.allCases {
            #expect(step.learnMoreURL.host == "cmux.com")
            #expect(step.learnMoreURL.path.hasPrefix("/docs/cloud"))
            #expect(!step.title.isEmpty)
            #expect(!step.detail.isEmpty)
        }
    }

    @Test("only an agent on a Cloud machine completes step 3")
    func cloudAgentDetection() {
        func resource(_ machine: SurfaceMachineID, agent: SurfaceAgentBadge?) -> SurfaceResource {
            SurfaceResource(
                id: SurfaceResourceID(machine: machine, kind: .terminal, key: "t1"),
                title: "zsh",
                lifecycle: .running,
                agent: agent
            )
        }
        let badge = SurfaceAgentBadge(state: "working", agent: "claude")
        func snapshot(_ resources: [SurfaceResource]) -> SurfaceCatalogSnapshot {
            SurfaceCatalogSnapshot(machines: [], resources: resources, projections: [])
        }
        #expect(!Checklist.hasCloudAgent(in: .empty))
        #expect(!Checklist.hasCloudAgent(in: snapshot([resource(.local, agent: badge)])))
        #expect(!Checklist.hasCloudAgent(in: snapshot([resource(.cloud("vm-1"), agent: nil)])))
        #expect(Checklist.hasCloudAgent(in: snapshot([resource(.cloud("vm-1"), agent: badge)])))
    }
}

/// The mounted card shows one action, on the current step, wired to its path.
@MainActor
@Suite("Cloud getting started card", .serialized)
struct CloudGettingStartedCardTests {
    @MainActor
    private final class Log {
        var events: [String] = []
    }

    private struct Hosted {
        let window: NSWindow
        let view: NSView
    }

    private static func host(_ input: CloudGettingStartedChecklist.Input, log: Log, wiresSecrets: Bool = true) -> Hosted {
        let view = NSHostingView(
            rootView: CloudGettingStartedCard(
                checklist: CloudGettingStartedChecklist(input),
                actions: CloudGettingStartedActions(
                    openSecrets: wiresSecrets ? { log.events.append("secrets") } : nil,
                    createMachine: { log.events.append("machine") },
                    openLocalAgent: { log.events.append("agent") },
                    dismiss: { log.events.append("dismiss") }
                )
            )
            // In-process there is no assistive client to switch SwiftUI's
            // accessibility output on (see MachinesListStatusToolbarRowTests).
            .environment(\.accessibilityEnabled, true)
        )
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 260)
        let window = NSWindow(contentRect: view.frame, styleMask: [], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        return Hosted(window: window, view: view)
    }

    private static func element(_ identifier: String, in hosted: Hosted) -> NSObject? {
        CloudTreeHeaderActionsTests.accessibilityElement(identifier, in: hosted.view)
    }

    private static func press(_ element: NSObject) -> Bool {
        let modern = NSSelectorFromString("accessibilityPerformPress")
        if element.responds(to: modern) {
            _ = element.perform(modern)
            return true
        }
        let legacy = NSSelectorFromString("accessibilityPerformAction:")
        guard element.responds(to: legacy) else { return false }
        _ = element.perform(legacy, with: NSAccessibility.Action.press.rawValue)
        return true
    }

    private static func input(secretCount: Int? = 0, machineCount: Int = 0) -> CloudGettingStartedChecklist.Input {
        .init(
            secretCount: secretCount,
            machineCount: machineCount,
            hasCloudAgent: false,
            hasLoadedMachines: true,
            hasListProblem: false,
            isDismissed: false
        )
    }

    @Test("the keys step opens Cloud Secrets and offers nothing else yet")
    func keysStepOpensSecrets() throws {
        let log = Log()
        let hosted = Self.host(Self.input(), log: log)
        #expect(Self.element("CloudGettingStartedNewMachineButton", in: hosted) == nil)
        let button = try #require(Self.element("CloudGettingStartedAddKeysButton", in: hosted))
        try #require(Self.press(button))
        #expect(log.events == ["secrets"])
    }

    @Test("without the secrets sheet the keys step teaches the CLI import")
    func keysStepFallsBackToCommand() {
        let hosted = Self.host(Self.input(), log: Log(), wiresSecrets: false)
        #expect(Self.element("CloudGettingStartedAddKeysButton", in: hosted) == nil)
        #expect(Self.element("CloudGettingStartedCopyCommandButton", in: hosted) != nil)
    }

    @Test("the machine step runs the New Cloud Machine action")
    func machineStepCreates() throws {
        let log = Log()
        let hosted = Self.host(Self.input(secretCount: 1), log: log)
        let button = try #require(Self.element("CloudGettingStartedNewMachineButton", in: hosted))
        try #require(Self.press(button))
        #expect(log.events == ["machine"])
    }

    @Test("the agent step shows the command and the local agent shortcut")
    func agentStepOffersCommandAndAgent() throws {
        let log = Log()
        let hosted = Self.host(Self.input(secretCount: 1, machineCount: 1), log: log)
        #expect(Self.element("CloudGettingStartedCopyCommandButton", in: hosted) != nil)
        let ask = try #require(Self.element("CloudGettingStartedAskClaudeButton", in: hosted))
        try #require(Self.press(ask))
        #expect(log.events == ["agent"])
    }
}

@MainActor
@Suite("Cloud list failures point somewhere when Retry may not be enough")
struct MachineListStatusHelpURLTests {
    @Test("only an unreachable list links to troubleshooting")
    func helpURLs() {
        #expect(MachineListStatusPresentation(.failed(.unreachable)).helpURL == CloudDocsLinks.troubleshooting)
        #expect(MachineListStatusPresentation(.failed(.sessionRejected)).helpURL == nil)
        #expect(MachineListStatusPresentation(.failed(.requiresPro)).helpURL == nil)
        #expect(MachineListStatusPresentation(.waitingForNetwork).helpURL == nil)
        #expect(MachineListStatusPresentation(.reconnecting).helpURL == nil)
    }
}
