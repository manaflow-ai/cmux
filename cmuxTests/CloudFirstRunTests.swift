import CmuxFoundation
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The first-run tour's rules: where the key comes from, which repository and
/// machine it uses, the exact clone it runs, how it reads the clone's output,
/// and the timeline that measures "open to a running agent".
@Suite("Cloud first-run plan")
struct CloudFirstRunPlanTests {
    // MARK: Key

    @Test func vaultKeyWinsOverTheTeamRouter() {
        let source = CloudFirstRunKeySource.resolve(
            agent: .claude,
            vaultNames: ["GH_TOKEN", "ANTHROPIC_API_KEY"],
            activeTeamProviders: ["claude"],
            typedKey: ""
        )
        #expect(source == .vault(name: "ANTHROPIC_API_KEY"))
    }

    @Test func anyOfTheAgentsNamesCounts() {
        let source = CloudFirstRunKeySource.resolve(
            agent: .claude, vaultNames: ["CLAUDE_CODE_OAUTH_TOKEN"], activeTeamProviders: [], typedKey: ""
        )
        #expect(source == .vault(name: "CLAUDE_CODE_OAUTH_TOKEN"))
    }

    @Test func teamRouterIsTheZeroStepDefaultWithoutAKey() {
        let source = CloudFirstRunKeySource.resolve(
            agent: .codex, vaultNames: ["ANTHROPIC_API_KEY"], activeTeamProviders: ["codex"], typedKey: ""
        )
        #expect(source == .teamRouter)
        #expect(source.isReady)
    }

    @Test func anotherAgentsKeyDoesNotCount() {
        let source = CloudFirstRunKeySource.resolve(
            agent: .codex, vaultNames: ["ANTHROPIC_API_KEY"], activeTeamProviders: ["claude"], typedKey: ""
        )
        #expect(source == .missing)
        #expect(!source.isReady)
    }

    @Test func typedKeyMustLookLikeOne() {
        #expect(CloudFirstRunKeySource.isPlausibleKey("sk-ant-api03-abcdef"))
        #expect(CloudFirstRunKeySource.isPlausibleKey("  sk-ant-api03-abcdef\n"))
        #expect(!CloudFirstRunKeySource.isPlausibleKey("short"))
        #expect(!CloudFirstRunKeySource.isPlausibleKey("sk-ant two words"))
        let source = CloudFirstRunKeySource.resolve(
            agent: .claude, vaultNames: [], activeTeamProviders: [], typedKey: "sk-ant-api03-abcdef"
        )
        #expect(source == .typed)
    }

    // MARK: Repository

    @Test func repositoryFieldUsesOpenRepositoryRules() {
        #expect(CloudFirstRunRepo.reference("octocat/Spoon-Knife")?.cloneArgument == "octocat/Spoon-Knife")
        #expect(CloudFirstRunRepo.reference("  manaflow-ai/cmux  ")?.displayName == "manaflow-ai/cmux")
        let tree = CloudFirstRunRepo.reference("https://github.com/vercel/next.js/tree/canary")
        #expect(tree?.cloneArgument == "vercel/next.js")
        #expect(tree?.branch == "canary")
        #expect(CloudFirstRunRepo.reference("git@github.com:acme/api.git")?.displayName == "acme/api")
    }

    @Test func refusedRepositoryForms() {
        for raw in ["", ".", "owner", "https://user:pw@github.com/a/b"] {
            #expect(CloudFirstRunRepo.reference(raw) == nil, "\(raw)")
        }
    }

    @Test func sampleIsAcceptedAsIs() {
        #expect(CloudFirstRunRepo.reference(CloudFirstRunRepo.sample)?.cloneArgument == CloudFirstRunRepo.sample)
    }

    // MARK: Machine

    @Test func reusesTheNewestReadyMachineThenAPausedOne() {
        let rows: [(id: String, status: String, name: String, createdAt: Int64)] = [
            ("old", "running", "old-one", 1),
            ("new", "Running", "new-one", 5),
            ("gone", "running", "gone", 9),
            ("sleepy", "paused", "sleepy", 7),
        ]
        #expect(CloudFirstRunMachine.reusable(from: rows, hiddenIDs: ["gone"]) == CloudFirstRunMachine(id: "new", name: "new-one"))
        let paused = CloudFirstRunMachine.reusable(from: [("sleepy", "paused", "sleepy", 7), ("p", "provisioning", "p", 8)], hiddenIDs: [])
        #expect(paused == CloudFirstRunMachine(id: "sleepy", name: "sleepy", needsWake: true))
        #expect(CloudFirstRunMachine.reusable(from: [("p", "provisioning", "p", 8)], hiddenIDs: []) == nil)
    }

    // MARK: Command

    @Test func cloneStartsTheAgentInteractivelyWithTheTask() throws {
        let repo = try #require(CloudFirstRunRepo.reference("octocat/Spoon-Knife"))
        let arguments = CloudFirstRunCommand.cloneArguments(
            repo: repo, machineID: "vm-1", agent: .claude, prompt: "  Explain it.  "
        )
        #expect(arguments == [
            "vm", "clone", "octocat/Spoon-Knife", "--machine", "vm-1", "--agent", "claude", "--focus", "--json",
            "--", "--", "Explain it.",
        ])
    }

    @Test func branchTravelsAsAFlagAndEmptyTaskSendsNoPrompt() throws {
        let repo = try #require(CloudFirstRunRepo.reference("https://github.com/a/b/tree/dev"))
        let arguments = CloudFirstRunCommand.cloneArguments(repo: repo, machineID: "vm-1", agent: .codex, prompt: " ")
        #expect(arguments == ["vm", "clone", "a/b", "--branch", "dev", "--machine", "vm-1", "--agent", "codex", "--focus", "--json"])
    }

    // MARK: Clone output

    @Test func progressCountsPhaseLinesAcrossChunks() {
        var progress = CloudFirstRunCloneProgress()
        progress.consume("[cmux vm clone] Machine 0.3s \u{2014} vivid\n[cmux vm clone] Sec")
        #expect(progress.finishedPhases == 1)
        progress.consume("rets 0.8s \u{2014} 2 synced\nnoise line\n")
        #expect(progress.finishedPhases == 2)
        progress.consume("[cmux vm clone] Clone 1.1s \u{2014} cloned\n")
        #expect(progress.finishedPhases == 3)
    }

    @Test func parsesTheJSONReceiptAmongStderrLines() {
        let output = """
        [cmux vm clone] Machine 0.3s \u{2014} vivid-newt
        [cmux vm clone] Agent 1.2s \u{2014} claude t-9
        {
          "agent_terminal_id" : "t-9",
          "workspace_id" : "ws-1",
          "missing_secrets" : [],
          "timings" : {
            "machine" : 0.3,
            "agent" : 1.2
          }
        }
        """
        let result = CloudFirstRunCloneResult.parse(output: output)
        #expect(result?.agentTerminalID == "t-9")
        #expect(result?.workspaceID == "ws-1")
        #expect(result?.timings == ["machine": 0.3, "agent": 1.2])
    }

    @Test func noReceiptIsNil() {
        #expect(CloudFirstRunCloneResult.parse(output: "Error: nope\n") == nil)
    }

    @Test func privateRepositoryFailureOffersAToken() {
        let failure = CloudFirstRunFailure.clone(output: "remote: Repository not found.\nfatal: could not read Username\n", status: 1)
        #expect(failure.recovery == .addGitHubToken)
    }

    @Test func otherFailuresQuoteTheLastLineAndRetry() {
        let failure = CloudFirstRunFailure.clone(
            output: "[cmux vm clone] Machine 0.3s \u{2014} x\nError: The machine did not answer.\n",
            status: 1
        )
        #expect(failure.reason == "The machine did not answer.")
        #expect(failure.recovery == .retryClone)
    }

    // MARK: Timeline

    @Test func timelineFreezesWhenTheAgentStarts() throws {
        let open = Date(timeIntervalSince1970: 1_000)
        var timeline = CloudFirstRunTimeline(openedAt: open)
        timeline.record(.machineReady, at: open.addingTimeInterval(14.2))
        timeline.record(.machineReady, at: open.addingTimeInterval(99))
        let machineMark = try #require(timeline.seconds(.machineReady))
        let runningDisplay = timeline.elapsed(now: open.addingTimeInterval(20))
        #expect(abs(machineMark - 14.2) < 0.001)
        #expect(abs(runningDisplay - 20) < 0.001)
        timeline.record(.agentStarted, at: open.addingTimeInterval(38.4))
        let frozenDisplay = timeline.elapsed(now: open.addingTimeInterval(500))
        #expect(abs(frozenDisplay - 38.4) < 0.001)
        #expect(timeline.isFinished)
        #expect(CloudFirstRunTimeline.clock(38.4) == "0:38")
        #expect(CloudFirstRunTimeline.clock(61) == "1:01")
    }

    @Test func logLineCarriesOnlyDurations() {
        let open = Date(timeIntervalSince1970: 0)
        var timeline = CloudFirstRunTimeline(openedAt: open)
        timeline.record(.keyReady, at: open)
        timeline.record(.agentStarted, at: open.addingTimeInterval(41.24))
        let line = timeline.logLine(cloneTimings: ["clone": 1.04, "agent": 2.0])
        #expect(line == "cloud.firstRun.timing key=0.0 agent=41.2 clone.agent=2.0 clone.clone=1.0")
    }
}

/// The tour's flow with fake seams: parallel machine start, Go waiting for the
/// machine, saving a typed key first, and a recovery for every failure.
@MainActor
@Suite("Cloud first-run model")
struct CloudFirstRunModelTests {
    final class Fake {
        var vault: Set<String> = []
        /// Project-scoped names by project key.
        var projectVault: [String: Set<String>] = [:]
        var team: Set<String> = []
        var ready: CloudFirstRunMachine?
        var createCount = 0
        var createFinished: (@MainActor (Result<CloudFirstRunMachine, CloudFirstRunFailure>) -> Void)?
        var savedNames: [String] = []
        var saveError: Error?
        var cloneArguments: [[String]] = []
        var cloneOutput: (@MainActor (String) -> Void)?
        var cloneFinished: (@MainActor (Int32, String) -> Void)?
        var logs: [String] = []
        var deletedMachines: [String] = []
        var cancelCreateCount = 0
        var clock = Date(timeIntervalSince1970: 0)
    }

    struct SaveFailed: LocalizedError {
        var errorDescription: String? { "invalid name" }
    }

    private func makeModel(_ fake: Fake) -> CloudFirstRunModel {
        CloudFirstRunModel(backend: .init(
            vaultNames: { projectKey in
                fake.vault.union(projectKey.flatMap { fake.projectVault[$0] } ?? [])
            },
            activeTeamProviders: { fake.team },
            findReadyMachine: { fake.ready },
            createMachine: { finished in
                fake.createCount += 1
                fake.createFinished = finished
                return true
            },
            saveKey: { name, _ in
                if let error = fake.saveError { throw error }
                fake.savedNames.append(name)
                fake.vault.insert(name)
            },
            runClone: { arguments, output, finished in
                fake.cloneArguments.append(arguments)
                fake.cloneOutput = output
                fake.cloneFinished = finished
                return true
            },
            cancelCreate: { fake.cancelCreateCount += 1 },
            deleteMachine: { fake.deletedMachines.append($0) },
            log: { fake.logs.append($0) },
            now: { fake.clock }
        ))
    }

    private static let receipt = "{\"agent_terminal_id\": \"t-1\", \"timings\": {\"clone\": 0.5}}\n"

    @Test func reusesAReadyMachineWithoutCreating() async {
        let fake = Fake()
        fake.vault = ["ANTHROPIC_API_KEY"]
        fake.ready = CloudFirstRunMachine(id: "vm-1", name: "vivid")
        let model = makeModel(fake)
        model.start()
        await model.machineTask?.value
        #expect(model.state(of: .machine) == .done)
        #expect(model.state(of: .key) == .done)
        #expect(fake.createCount == 0)
    }

    @Test func goWaitsForTheMachineThenClones() async {
        let fake = Fake()
        fake.team = ["claude"]
        let model = makeModel(fake)
        model.start()
        await model.machineTask?.value
        #expect(fake.createCount == 1)
        #expect(model.state(of: .machine) == .working)
        model.useSampleRepo()
        #expect(model.canGo)
        fake.clock = Date(timeIntervalSince1970: 9)
        model.go()
        #expect(model.run == .waitingForMachine)
        #expect(fake.cloneArguments.isEmpty)
        fake.clock = Date(timeIntervalSince1970: 15)
        fake.createFinished?(.success(CloudFirstRunMachine(id: "vm-2", name: "new")))
        #expect(model.run == .cloning)
        #expect(fake.cloneArguments.first?.contains("vm-2") == true)
        fake.cloneOutput?("[cmux vm clone] Machine 0.1s \u{2014} new\n")
        #expect(model.progress.finishedPhases == 1)
        fake.clock = Date(timeIntervalSince1970: 31)
        fake.cloneFinished?(0, Self.receipt)
        #expect(model.state(of: .agent) == .done)
        #expect(model.timeline.seconds(.agentStarted) == 31)
        #expect(fake.logs.last?.hasPrefix("cloud.firstRun.timing key=0.0 machine=15.0 go=9.0 agent=31.0 clone.clone=0.5") == true)
    }

    @Test func typedKeyIsSavedBeforeTheClone() async {
        let fake = Fake()
        fake.ready = CloudFirstRunMachine(id: "vm-1", name: "vivid")
        let model = makeModel(fake)
        model.start()
        await model.machineTask?.value
        model.repoText = "a/b"
        #expect(!model.canGo)
        model.typedKey = "sk-ant-api03-abcdef"
        #expect(model.keySource == .typed)
        model.go()
        await model.keyTask?.value
        #expect(fake.savedNames == ["ANTHROPIC_API_KEY"])
        #expect(model.typedKey.isEmpty)
        #expect(model.keySource == .vault(name: "ANTHROPIC_API_KEY"))
        #expect(fake.cloneArguments.count == 1)
    }

    @Test func projectScopedKeyForTheChosenRepositoryCounts() async {
        let fake = Fake()
        fake.ready = CloudFirstRunMachine(id: "vm-1", name: "vivid")
        fake.projectVault["github.com/a/b"] = ["ANTHROPIC_API_KEY"]
        let model = makeModel(fake)
        model.start()
        await model.machineTask?.value
        #expect(model.keySource == .missing)
        model.repoText = "https://github.com/A/B.git"
        #expect(model.keySource == .vault(name: "ANTHROPIC_API_KEY"))
        model.go()
        await model.keyTask?.value
        #expect(fake.savedNames.isEmpty)
        #expect(fake.cloneArguments.count == 1)
        model.repoText = "a/other"
        #expect(model.keySource == .missing)
    }

    @Test func keySaveFailureOffersFixTheKey() async {
        let fake = Fake()
        fake.ready = CloudFirstRunMachine(id: "vm-1", name: "vivid")
        fake.saveError = SaveFailed()
        let model = makeModel(fake)
        model.start()
        await model.machineTask?.value
        model.repoText = "a/b"
        model.typedKey = "sk-ant-api03-abcdef"
        model.go()
        await model.keyTask?.value
        #expect(model.state(of: .key) == .failed(CloudFirstRunFailure(reason: "invalid name", recovery: .editKey)))
        #expect(model.state(of: .agent) == .waiting)
        #expect(fake.cloneArguments.isEmpty)
        let focus = model.keyFocusRequest
        model.perform(.editKey)
        #expect(model.keyFocusRequest == focus + 1)
        #expect(model.run == .editing)
        #expect(fake.logs.last?.hasSuffix("outcome=failed recovery=editKey") == true)
    }

    @Test func machineFailureWhileWaitingRetriesIntoTheSameRun() async {
        let fake = Fake()
        fake.vault = ["OPENAI_API_KEY"]
        let model = makeModel(fake)
        model.agent = .codex
        model.start()
        await model.machineTask?.value
        model.repoText = "a/b"
        model.go()
        let failure = CloudFirstRunFailure(reason: "limit", recovery: .retryMachine)
        fake.createFinished?(.failure(failure))
        #expect(model.state(of: .machine) == .failed(failure))
        #expect(model.state(of: .agent) == .waiting)
        #expect(model.currentFailure == failure)
        model.perform(.retryMachine)
        #expect(model.run == .waitingForMachine)
        await model.machineTask?.value
        #expect(fake.createCount == 2)
        fake.createFinished?(.success(CloudFirstRunMachine(id: "vm-3", name: "x")))
        #expect(fake.cloneArguments.first?.contains("codex") == true)
    }

    @Test func cloneFailureShowsOnTheAgentStepAndRetries() async {
        let fake = Fake()
        fake.team = ["claude"]
        fake.ready = CloudFirstRunMachine(id: "vm-1", name: "vivid")
        let model = makeModel(fake)
        model.start()
        await model.machineTask?.value
        model.useSampleRepo()
        model.go()
        fake.cloneFinished?(1, "Error: The machine did not answer.\n")
        #expect(model.state(of: .agent) == .failed(CloudFirstRunFailure(reason: "The machine did not answer.", recovery: .retryClone)))
        #expect(model.canGo)
        model.perform(.retryClone)
        #expect(fake.cloneArguments.count == 2)
        fake.cloneFinished?(0, "no receipt\n")
        #expect(model.currentFailure?.recovery == .retryClone)
    }

    @Test func startedRunCallsBackOnce() async {
        let fake = Fake()
        fake.team = ["claude"]
        fake.ready = CloudFirstRunMachine(id: "vm-1", name: "vivid")
        let model = makeModel(fake)
        var started: [CloudFirstRunCloneResult] = []
        model.onStarted = { started.append($0) }
        model.start()
        model.start()
        await model.machineTask?.value
        model.useSampleRepo()
        model.go()
        fake.cloneFinished?(0, Self.receipt)
        #expect(started.map(\.agentTerminalID) == ["t-1"])
        #expect(!model.canGo)
    }

    // MARK: Cancel never leaves a surprise machine

    @Test func cancelDeletesTheMachineTheTourStarted() async {
        let fake = Fake()
        let model = makeModel(fake)
        model.start()
        await model.machineTask?.value
        #expect(model.origin == .provisioning)
        #expect(model.cancelDeletesMachine)
        fake.createFinished?(.success(CloudFirstRunMachine(id: "vm-new", name: "new")))
        #expect(model.origin == .provisioned(machineID: "vm-new"))
        #expect(model.cancelDeletesMachine)
        model.cancel()
        #expect(fake.deletedMachines == ["vm-new"])
        #expect(model.lastCleanup == .deleted)
        #expect(model.origin == .none)
        #expect(!model.cancelDeletesMachine)
        #expect(fake.logs.last?.hasSuffix("outcome=cancelled cleanup=deleted") == true)
    }

    @Test func cancelNeverTouchesAReusedMachine() async {
        let fake = Fake()
        fake.ready = CloudFirstRunMachine(id: "vm-mine", name: "mine")
        let model = makeModel(fake)
        model.start()
        await model.machineTask?.value
        #expect(model.origin == .reused)
        #expect(!model.cancelDeletesMachine)
        model.cancel()
        #expect(fake.deletedMachines.isEmpty)
        #expect(fake.cancelCreateCount == 0)
        #expect(model.lastCleanup == .none)
    }

    @Test func createInFlightAtCancelIsDeletedWhenItsIdArrives() async {
        let fake = Fake()
        let model = makeModel(fake)
        model.start()
        await model.machineTask?.value
        model.cancel()
        #expect(fake.cancelCreateCount == 1)
        #expect(model.lastCleanup == .cancellingCreate)
        #expect(fake.deletedMachines.isEmpty)
        // The provider finished anyway: the late machine goes, and the tour
        // does not adopt it.
        fake.createFinished?(.success(CloudFirstRunMachine(id: "vm-late", name: "late")))
        #expect(fake.deletedMachines == ["vm-late"])
        #expect(model.lastCleanup == .deleted)
        #expect(model.readyMachine == nil)
    }

    @Test func lookupFinishingAfterCancelStartsNothing() async {
        let fake = Fake()
        let model = makeModel(fake)
        model.start()
        let lookup = model.machineTask
        model.cancel()
        await lookup?.value
        #expect(fake.createCount == 0)
        #expect(model.origin == .none)
    }

    @Test func machineIsKeptOnceTheAgentStarted() async {
        let fake = Fake()
        fake.team = ["claude"]
        let model = makeModel(fake)
        model.start()
        await model.machineTask?.value
        fake.createFinished?(.success(CloudFirstRunMachine(id: "vm-new", name: "new")))
        model.useSampleRepo()
        model.go()
        fake.cloneFinished?(0, Self.receipt)
        #expect(!model.cancelDeletesMachine)
        model.cancel()
        #expect(fake.deletedMachines.isEmpty)
    }

    @Test func cancelWhileGoIsRunningIsHideAndKeepsTheMachine() async {
        let fake = Fake()
        fake.team = ["claude"]
        let model = makeModel(fake)
        model.start()
        await model.machineTask?.value
        model.useSampleRepo()
        model.go()
        #expect(model.run == .waitingForMachine)
        model.cancel()
        #expect(fake.cancelCreateCount == 0)
        fake.createFinished?(.success(CloudFirstRunMachine(id: "vm-new", name: "new")))
        #expect(model.run == .cloning)
        #expect(fake.deletedMachines.isEmpty)
    }

    @Test func reopeningAfterCancelStartsTheMachineAgain() async {
        let fake = Fake()
        let model = makeModel(fake)
        model.start()
        await model.machineTask?.value
        model.cancel()
        model.start()
        await model.machineTask?.value
        #expect(fake.createCount == 2)
        #expect(model.origin == .provisioning)
    }
}
