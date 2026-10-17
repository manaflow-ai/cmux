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

    @Test("finishing every step shows the finished card instead of vanishing")
    func completeShowsSetUp() {
        let done = Checklist(Self.input(secretCount: 3, machineCount: 1, hasCloudAgent: true))
        #expect(done.isComplete)
        #expect(done.current == nil)
        #expect(done.completedCount == 3)
        #expect(done.isVisible, "the person sees \"You're set up\" before the card retires")
        #expect(!Checklist.completedTitle.isEmpty)
        #expect(!Checklist.completedDetail.isEmpty)
    }

    @Test("a finished card retires on the next open after it was seen, never while on screen")
    func completionRetiresOnNextOpen() {
        let done = Checklist(Self.input(secretCount: 3, machineCount: 1, hasCloudAgent: true))
        let twoOfThree = Checklist(Self.input(secretCount: 3, machineCount: 1, hasCloudAgent: false))
        // Closing the panel on the finished card is what "seen" means.
        #expect(Checklist.marksCompletionSeen(done))
        #expect(!Checklist.marksCompletionSeen(twoOfThree), "a card at 2/3 is never marked finished")
        let dismissed = Checklist(Self.input(secretCount: 3, machineCount: 1, hasCloudAgent: true, isDismissed: true))
        #expect(!Checklist.marksCompletionSeen(dismissed), "a card that was not on screen was not seen")
        let loading = Checklist(Self.input(secretCount: 3, machineCount: 1, hasCloudAgent: true, hasLoadedMachines: false))
        #expect(!Checklist.marksCompletionSeen(loading))
        // The next open retires it; an unseen finished card shows once first.
        #expect(Checklist.retiresOnOpen(hasSeenCompletion: true))
        #expect(!Checklist.retiresOnOpen(hasSeenCompletion: false))
    }

    @Test("the machine step reads the tree's rows and the header's count, whichever is ahead")
    func machineStepMatchesTheHeader() {
        // The round-2 report: header at 1/5 while the fleet list had not
        // returned the machine yet. The header count alone checks the step.
        #expect(Checklist.machineCount(listedMachines: 0, headerActiveCount: 1, creatingCount: 0) == 1)
        // A catalog discovery the list has not returned, before the plan loads.
        #expect(Checklist.machineCount(listedMachines: 1, headerActiveCount: nil, creatingCount: 0) == 1)
        // A paused machine is listed but not counted by the header.
        #expect(Checklist.machineCount(listedMachines: 1, headerActiveCount: 0, creatingCount: 0) == 1)
        // A create in flight checks the step before its row exists.
        #expect(Checklist.machineCount(listedMachines: 0, headerActiveCount: 0, creatingCount: 1) == 1)
        #expect(Checklist.machineCount(listedMachines: 0, headerActiveCount: nil, creatingCount: 0) == 0)
        let checked = Checklist(Self.input(
            secretCount: 1,
            machineCount: Checklist.machineCount(listedMachines: 0, headerActiveCount: 1, creatingCount: 0)
        ))
        #expect(checked.isDone(.createMachine))
        #expect(checked.current == .startAgent)
    }

    @Test("a build without the secrets vault leaves the keys step out instead of never finishing")
    func unwiredVaultDropsKeysStep() {
        let checklist = Checklist(Self.input(secretCount: nil))
        #expect(checklist.steps == [.createMachine, .startAgent])
        #expect(checklist.current == .createMachine)
        #expect(checklist.totalCount == 2)
        let done = Checklist(Self.input(secretCount: nil, machineCount: 1, hasCloudAgent: true))
        #expect(done.isComplete)
        #expect(done.isVisible)
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

    @Test("a failed agent run never completes step 3; a running or clean run does")
    func failedAgentRunDoesNotCount() {
        let machine = SurfaceMachineID.cloud("vm-1")
        func terminal(lifecycle: SurfaceLifecycle, exitCode: Int? = nil, state: String = "working") -> SurfaceResource {
            var resource = SurfaceResource(
                id: SurfaceResourceID(machine: machine, kind: .terminal, key: "term_1"),
                title: "claude",
                lifecycle: lifecycle,
                agent: SurfaceAgentBadge(state: state, agent: "claude")
            )
            resource.exit = exitCode.map { SurfaceTerminalExit(kind: .exit, code: $0) }
            return resource
        }
        func snapshot(_ resource: SurfaceResource) -> SurfaceCatalogSnapshot {
            SurfaceCatalogSnapshot(machines: [], resources: [resource], projections: [])
        }
        #expect(Checklist.hasCloudAgent(in: snapshot(terminal(lifecycle: .running))))
        #expect(Checklist.hasCloudAgent(in: snapshot(terminal(lifecycle: .exited, exitCode: 0, state: "done"))),
                "an agent that finished cleanly counts")
        #expect(!Checklist.hasCloudAgent(in: snapshot(terminal(lifecycle: .exited, exitCode: 1))),
                "an agent whose process exited non-zero does not")
        // `vm clone` keeps a login shell after the agent, so the terminal
        // stays alive: only the agent's error notification shows the failure.
        let alive = snapshot(terminal(lifecycle: .running, state: "blocked"))
        #expect(!Checklist.hasCloudAgent(in: alive, unreadFailureTerminalIDs: ["vm-1": ["term_1"]]))
        #expect(Checklist.hasCloudAgent(in: alive, unreadFailureTerminalIDs: ["vm-2": ["term_1"]]),
                "a failure on another machine's terminal of the same id does not count against this one")
        let input = Self.input(
            secretCount: 1,
            machineCount: 1,
            hasCloudAgent: Checklist.hasCloudAgent(in: alive, unreadFailureTerminalIDs: ["vm-1": ["term_1"]])
        )
        let checklist = Checklist(input)
        #expect(!checklist.isComplete)
        #expect(checklist.current == .startAgent)
        #expect(!Checklist.marksCompletionSeen(checklist), "a failed run cannot retire the card")
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

    private static func host(
        _ input: CloudGettingStartedChecklist.Input,
        log: Log,
        wiresSecrets: Bool = true,
        wiresRepository: Bool = false,
        wiresTour: Bool = false
    ) -> Hosted {
        let view = NSHostingView(
            rootView: CloudGettingStartedCard(
                checklist: CloudGettingStartedChecklist(input),
                actions: CloudGettingStartedActions(
                    openSecrets: wiresSecrets ? { log.events.append("secrets") } : nil,
                    createMachine: { log.events.append("machine") },
                    openLocalAgent: { log.events.append("agent") },
                    dismiss: { log.events.append("dismiss") },
                    startFirstAgent: wiresTour ? { log.events.append("tour") } : nil,
                    openRepository: wiresRepository ? { log.events.append("repository") } : nil
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

    @Test("the finished card says so and offers no step action")
    func finishedCardShowsSetUp() {
        var input = Self.input(secretCount: 1, machineCount: 1)
        input.hasCloudAgent = true
        let hosted = Self.host(input, log: Log())
        #expect(Self.element("CloudGettingStartedCompleted", in: hosted) != nil)
        #expect(Self.element("CloudGettingStartedNewMachineButton", in: hosted) == nil)
        #expect(Self.element("CloudGettingStartedAddKeysButton", in: hosted) == nil)
        #expect(Self.element("CloudGettingStartedCopyCommandButton", in: hosted) == nil)
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

    @Test("the agent step's one primary action opens Open Repository, with the command and Claude Code as alternatives")
    func agentStepOpensRepository() throws {
        let log = Log()
        let hosted = Self.host(Self.input(secretCount: 1, machineCount: 1), log: log, wiresRepository: true)
        let open = try #require(Self.element("CloudGettingStartedOpenRepositoryButton", in: hosted))
        #expect(Self.element("CloudGettingStartedCopyCommandButton", in: hosted) != nil)
        #expect(Self.element("CloudGettingStartedAskClaudeButton", in: hosted) != nil)
        try #require(Self.press(open))
        #expect(log.events == ["repository"])
#if DEBUG
        // The debug socket's press_current presses the same button.
        let actions = CloudGettingStartedActions(
            openSecrets: nil, createMachine: {}, openLocalAgent: {}, dismiss: {}, openRepository: {}
        )
        #expect(CloudDebugGettingStartedProbe.press(for: .startAgent, actions: actions) == .openRepository)
#endif
    }

    @Test("Do all three at once shows only before any step is done")
    func allAtOnceOnlyAtStart() {
        let fresh = Self.host(Self.input(), log: Log(), wiresTour: true)
        #expect(Self.element("CloudGettingStartedAllAtOnceButton", in: fresh) != nil)
        let started = Self.host(Self.input(secretCount: 1), log: Log(), wiresTour: true)
        #expect(Self.element("CloudGettingStartedAllAtOnceButton", in: started) == nil)
    }

    @Test("the command keeps its <repo> placeholder whole")
    func commandPlaceholderStaysWhole() {
        let parts = CloudGettingStartedCard.commandParts(CloudGettingStartedChecklist.startAgentCommand())
        #expect(parts.map(\.text).joined() == "cmux vm clone <repo> --agent claude")
        #expect(parts.filter(\.isPlaceholder).map(\.text) == ["<repo>"])
        #expect(CloudGettingStartedCard.commandParts("cmux vm secrets import --from-shell").allSatisfy { !$0.isPlaceholder })
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
