import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The background machine create (#11397): a create outlives the sheet that
/// started it, shows as a pending row while it runs, resolves into the fleet
/// on success, and stays as a retriable error row on failure.
@MainActor
@Suite(.serialized)
struct MachineCreateCoordinatorTests {
    /// A launcher stand-in: records the CLI arguments and keeps the completion
    /// so a test can end the "CLI run" whenever it likes.
    @MainActor
    final class LaunchRecorder {
        var arguments: [[String]] = []
        var completions: [@MainActor (CloudVMActionLauncher.Completion) -> Void] = []
        var starts = true

        var launch: MachineCreateCoordinator.Launch {
            { [self] arguments, completion in
                self.arguments.append(arguments)
                guard starts else { return false }
                completions.append(completion)
                return true
            }
        }

        func complete(status: Int32, output: String, workspaceID: UUID? = nil, machineID: String? = nil) {
            let completion = completions.removeFirst()
            completion(CloudVMActionLauncher.Completion(
                terminationStatus: status,
                output: output,
                workspaceId: workspaceID,
                machineId: machineID
            ))
        }
    }

    @MainActor
    final class NoticeRecorder {
        var notices: [MachineCreateNotice] = []
    }

    @MainActor
    final class ChangeRecorder {
        private(set) var changes = 0
        private(set) var finished: [MachineCreateCoordinator.Finished] = []
        private var observer: NSObjectProtocol?
        private let center: NotificationCenter

        init(coordinator: MachineCreateCoordinator, center: NotificationCenter) {
            self.center = center
            observer = center.addObserver(
                forName: MachineCreateCoordinator.didChangeNotification,
                object: coordinator,
                queue: .main
            ) { [weak self] notification in
                let finished = notification.userInfo?[MachineCreateCoordinator.finishedUserInfoKey] as? MachineCreateCoordinator.Finished
                MainActor.assumeIsolated {
                    self?.changes += 1
                    if let finished { self?.finished.append(finished) }
                }
            }
        }

        deinit {
            if let observer { center.removeObserver(observer) }
        }
    }

    static func newMachineRequest(name: String? = nil, kind: VMMachineKind = .desktop) -> MachineCreateRequest {
        var arguments = ["vm", "new", kind == .desktop ? "--desktop" : "--base", "--size", "24576"]
        if let name { arguments += ["--name", name] }
        arguments += ["--focus", "false"]
        return MachineCreateRequest(mode: .newMachine, kind: kind, name: name, arguments: arguments)
    }

    static func baseRequest(workspaceID: UUID = UUID()) -> MachineCreateRequest {
        MachineCreateRequest(
            mode: .base(workspaceID: workspaceID),
            kind: .desktop,
            name: nil,
            arguments: ["vm", "base", "open", "--workspace", workspaceID.uuidString, "--desktop", "--focus", "false"]
        )
    }

    private func makeCoordinator() -> (MachineCreateCoordinator, LaunchRecorder, NoticeRecorder, ChangeRecorder, NotificationCenter) {
        let center = NotificationCenter()
        let launches = LaunchRecorder()
        let notices = NoticeRecorder()
        let clock = Date(timeIntervalSince1970: 1_787_400_000)
        let coordinator = MachineCreateCoordinator(
            notifier: { notices.notices.append($0) },
            now: { clock },
            notificationCenter: center
        )
        let changes = ChangeRecorder(coordinator: coordinator, center: center)
        return (coordinator, launches, notices, changes, center)
    }

    // MARK: Running

    @Test func startLaunchesTheCLIAndShowsAPendingRowWithTheSheetsWording() {
        let (coordinator, launches, notices, changes, _) = makeCoordinator()
        let request = Self.newMachineRequest(name: "build box")

        #expect(coordinator.start(request, launch: launches.launch))

        #expect(launches.arguments == [request.arguments])
        #expect(coordinator.operations.count == 1)
        let operation = try? #require(coordinator.operations.first)
        #expect(operation?.isRunning == true)
        #expect(operation?.request.displayName == "build box")
        #expect(operation?.statusLabel == "Creating…")
        #expect(coordinator.hasRunningOperations)
        #expect(changes.changes == 1)
        #expect(notices.notices.isEmpty, "nothing to say until the CLI exits")
    }

    @Test func baseSetupRowIsCalledBaseAndReadsSettingUp() {
        let (coordinator, launches, _, _, _) = makeCoordinator()
        coordinator.start(Self.baseRequest(), launch: launches.launch)
        let operation = coordinator.operations.first
        #expect(operation?.request.displayName == "Base")
        #expect(operation?.statusLabel == "Setting up Base…")
    }

    @Test func unnamedMachineRowIsCalledNewMachine() {
        #expect(Self.newMachineRequest().displayName == "New Machine")
    }

    @Test func refusedLaunchRecordsNothing() {
        let (coordinator, launches, notices, changes, _) = makeCoordinator()
        launches.starts = false
        #expect(!coordinator.start(Self.newMachineRequest(), launch: launches.launch))
        #expect(coordinator.operations.isEmpty)
        #expect(changes.changes == 2, "the provisional row is published and taken back down")
        #expect(notices.notices.isEmpty)
    }

    /// The operation must be registered before the launcher runs: a launcher
    /// whose completion fires synchronously still has to find its row, finish
    /// it, and notify — never leave a phantom pending row behind.
    @Test func synchronousCompletionStillResolvesTheOperation() {
        let (coordinator, _, notices, changes, _) = makeCoordinator()
        let immediate: MachineCreateCoordinator.Launch = { _, completion in
            completion(CloudVMActionLauncher.Completion(
                terminationStatus: 0,
                output: "",
                workspaceId: nil,
                machineId: "calm-petrel"
            ))
            return true
        }
        #expect(coordinator.start(Self.newMachineRequest(), launch: immediate))
        #expect(coordinator.operations.isEmpty, "the synchronous completion resolved the row")
        #expect(changes.finished.count == 1)
        #expect(notices.notices.first?.title == "calm-petrel is ready")
    }

    // MARK: Success

    @Test func successDropsTheRowAndTellsThePersonWhereTheMachineOpened() {
        let (coordinator, launches, notices, changes, _) = makeCoordinator()
        coordinator.start(Self.newMachineRequest(), launch: launches.launch)
        let workspaceID = UUID()

        launches.complete(status: 0, output: "Created Cloud VM calm-petrel\nOK workspace=\(workspaceID.uuidString) transport=cmux-remote\n", workspaceID: workspaceID)

        #expect(coordinator.operations.isEmpty, "the fleet row takes over")
        #expect(changes.finished.count == 1)
        #expect(changes.finished.first?.outcome == .created(machineID: "calm-petrel", workspaceID: workspaceID))
        #expect(coordinator.lastFinished?.outcome == .created(machineID: "calm-petrel", workspaceID: workspaceID))
        let notice = try? #require(notices.notices.first)
        #expect(notice?.title == "calm-petrel is ready")
        #expect(notice?.workspaceID == workspaceID, "the notification's click goes to the new workspace")
        #expect(notice?.isFailure == false)
    }

    @Test func successKeepsTheTypedLabelInTheNotification() {
        let (coordinator, launches, notices, _, _) = makeCoordinator()
        coordinator.start(Self.newMachineRequest(name: "build box"), launch: launches.launch)
        launches.complete(status: 0, output: "Created Cloud VM calm-petrel\n")
        #expect(notices.notices.first?.title == "build box is ready")
        #expect(notices.notices.first?.workspaceID == nil)
    }

    @Test func baseSuccessIsAnnouncedAsBase() {
        let (coordinator, launches, notices, _, _) = makeCoordinator()
        let workspaceID = UUID()
        coordinator.start(Self.baseRequest(workspaceID: workspaceID), launch: launches.launch)
        launches.complete(status: 0, output: "Opened Base base-1\n", workspaceID: workspaceID)
        #expect(notices.notices.first?.title == "Base is ready")
        #expect(notices.notices.first?.workspaceID == workspaceID)
    }

    // MARK: Failure

    @Test func failureKeepsTheRowWithTheCLIOutputAndOffersRetry() {
        let (coordinator, launches, notices, changes, _) = makeCoordinator()
        coordinator.start(Self.newMachineRequest(), launch: launches.launch)
        let id = coordinator.operations[0].id
        let output = "Cloud VM temporarily unavailable (HTTP 503: vm_image_config_error)\n\nWhat to do:\n  Retry without `image`.\n"

        launches.complete(status: 1, output: output)

        let operation = coordinator.operation(id: id)
        #expect(operation?.isRunning == false)
        #expect(operation?.failureOutput == output.trimmingCharacters(in: .whitespacesAndNewlines))
        #expect(operation?.statusLabel == "Couldn't create machine")
        #expect(operation?.summaryLine == "New Machine · Couldn't create machine · Cloud VM temporarily unavailable (HTTP 503: vm_image_config_error)")
        #expect(!coordinator.hasRunningOperations)
        #expect(changes.finished.count == 1)
        let notice = try? #require(notices.notices.first)
        #expect(notice?.isFailure == true)
        #expect(notice?.title == "Couldn't create machine")
        #expect(notice?.body.hasPrefix("Cloud VM temporarily unavailable") == true)

        // Retry relaunches the same invocation and the row runs again.
        #expect(coordinator.retry(id))
        #expect(launches.arguments.count == 2)
        #expect(launches.arguments[1] == launches.arguments[0])
        #expect(coordinator.operation(id: id)?.isRunning == true)

        launches.complete(status: 0, output: "Created Cloud VM noble-wren\n")
        #expect(coordinator.operations.isEmpty)
        #expect(notices.notices.count == 2)
    }

    @Test func emptyFailureOutputGetsAGenericMessage() {
        let (coordinator, launches, _, _, _) = makeCoordinator()
        coordinator.start(Self.newMachineRequest(), launch: launches.launch)
        launches.complete(status: 2, output: "  \n")
        #expect(coordinator.operations.first?.failureOutput == "The machine could not be created.")
    }

    @Test func dismissDropsAFailedRowButNeverARunningOne() {
        let (coordinator, launches, _, changes, _) = makeCoordinator()
        coordinator.start(Self.newMachineRequest(), launch: launches.launch)
        let id = coordinator.operations[0].id

        coordinator.dismiss(id)
        #expect(coordinator.operations.count == 1, "the CLI is still working; its outcome must reach the person")

        launches.complete(status: 1, output: "Error: boom")
        coordinator.dismiss(id)
        #expect(coordinator.operations.isEmpty)
        #expect(!coordinator.retry(id), "a dismissed row cannot be retried")
        #expect(changes.changes == 3, "start, failure, dismiss")
    }

    @Test func retryThatCannotLaunchReportsInline() {
        let (coordinator, launches, _, _, _) = makeCoordinator()
        coordinator.start(Self.newMachineRequest(), launch: launches.launch)
        let id = coordinator.operations[0].id
        launches.complete(status: 1, output: "Error: boom")
        launches.starts = false
        #expect(!coordinator.retry(id))
        #expect(coordinator.operation(id: id)?.isRunning == false)
        #expect(coordinator.operation(id: id)?.failureOutput?.contains("Sign in") == true)
    }

    // MARK: Created but opening failed

    @Test func createdButOpenFailedDropsTheRowAndNeverRetriesTheCreate() {
        let (coordinator, launches, notices, changes, _) = makeCoordinator()
        coordinator.start(Self.newMachineRequest(), launch: launches.launch)
        let id = coordinator.operations[0].id

        // The launcher's structured `machine=` token is the signal; the
        // progress and token lines are stripped from what the person sees.
        launches.complete(
            status: 1,
            output: "Created Cloud VM calm-petrel\nOK machine=calm-petrel\nError: attach failed (HTTP 502)",
            machineID: "calm-petrel"
        )

        #expect(coordinator.operations.isEmpty, "the machine exists; the fleet row is the truth now")
        #expect(!coordinator.retry(id), "a second create would mint a second machine")
        #expect(launches.arguments.count == 1)
        #expect(changes.finished.first?.outcome == .createdButOpenFailed(
            machineID: "calm-petrel",
            output: "Error: attach failed (HTTP 502)"
        ))
        let notice = try? #require(notices.notices.first)
        #expect(notice?.isFailure == true)
        #expect(notice?.title == "calm-petrel was created, but opening it failed")
        #expect(notice?.body == "attach failed (HTTP 502)\nOpen it from the Machines list.", "the reason, not the CLI's progress line, leads the body")
    }

    /// An older bundled CLI without the `machine=` token still classifies via
    /// the localized "Created Cloud VM" line.
    @Test func createdButOpenFailedFallsBackToTheLocalizedCreatedLine() {
        let (coordinator, launches, _, changes, _) = makeCoordinator()
        coordinator.start(Self.newMachineRequest(), launch: launches.launch)
        let id = coordinator.operations[0].id
        launches.complete(status: 1, output: "Created Cloud VM calm-petrel\nError: attach failed (HTTP 502)")
        #expect(coordinator.operations.isEmpty)
        #expect(!coordinator.retry(id))
        #expect(changes.finished.first?.outcome == .createdButOpenFailed(
            machineID: "calm-petrel",
            output: "Error: attach failed (HTTP 502)"
        ))
    }

    /// Transcripts that trip the app's redaction never reach the row, the
    /// notification, or the clipboard; the person still gets the placeholder.
    @Test func failureOutputIsRedactedBeforeItEntersSharedState() {
        let (coordinator, launches, notices, _, _) = makeCoordinator()
        coordinator.start(Self.newMachineRequest(), launch: launches.launch)
        launches.complete(status: 1, output: "Error: provider blaxel rejected the request token abc123")
        let stored = coordinator.operations.first?.failureOutput
        #expect(stored == CloudVMActionLauncher.hiddenOutputPlaceholder)
        #expect(stored?.contains("token") == false)
        #expect(notices.notices.first?.body.contains("abc123") == false)
    }

    @Test func headlineSkipsTheCreatedLineAndTheErrorPrefix() {
        #expect(MachineCreateOperation.headline(ofOutput: "Created Cloud VM calm-petrel\nError: No provider for machine calm-petrel.") == "No provider for machine calm-petrel.")
        #expect(MachineCreateOperation.headline(ofOutput: "\n  Error: quota exceeded\nWhat to do:\n") == "quota exceeded")
        #expect(MachineCreateOperation.headline(ofOutput: "Created Cloud VM calm-petrel") == nil)
        #expect(MachineCreateOperation.headline(ofOutput: "  \n") == nil)
    }

    @Test func baseSetupFailureIsNotMistakenForACreatedMachine() {
        let (coordinator, launches, _, _, _) = makeCoordinator()
        coordinator.start(Self.baseRequest(), launch: launches.launch)
        let id = coordinator.operations[0].id
        launches.complete(status: 1, output: "Created Cloud VM base-1\nError: attach failed", machineID: "base-1")
        #expect(coordinator.operation(id: id)?.isRunning == false, "Base setup stays retriable through the idempotent base open")
        #expect(coordinator.retry(id))
        #expect(launches.arguments.count == 2)
    }

    @Test func createdMachineIDIsParsedFromTheCLIsCreatedLine() {
        #expect(MachineCreateCoordinator.createdMachineID(fromOutput: "Created Cloud VM calm-petrel\nError: noProvider(calm-petrel)") == "calm-petrel")
        #expect(MachineCreateCoordinator.createdMachineID(fromOutput: "  Created Cloud VM noble_wren2  ") == "noble_wren2")
        #expect(MachineCreateCoordinator.createdMachineID(fromOutput: "Error: Creating Cloud VM (HTTP 502)") == nil)
        #expect(MachineCreateCoordinator.createdMachineID(fromOutput: "Created Cloud VM") == nil)
        #expect(MachineCreateCoordinator.createdMachineID(fromOutput: "") == nil)
    }

    // MARK: Sign-out

    @Test func signOutDropsEveryOperationAndIgnoresLateCompletions() {
        let (coordinator, launches, notices, _, center) = makeCoordinator()
        coordinator.start(Self.newMachineRequest(), launch: launches.launch)
        coordinator.start(Self.baseRequest(), launch: launches.launch)

        center.post(name: .cmuxCloudVMAccessDidEnd, object: nil)

        #expect(coordinator.operations.isEmpty)
        launches.complete(status: 1, output: "Error: killed")
        launches.complete(status: 0, output: "Opened Base base-1")
        #expect(coordinator.operations.isEmpty)
        #expect(notices.notices.isEmpty, "the account this belonged to is gone; nobody to tell")
    }
}

/// The Machines panel mirrors the coordinator: pending rows above the fleet,
/// a completion re-reads the fleet, and a created-but-unopened machine's
/// reason lands in the control bar.
@MainActor
@Suite(.serialized)
struct MachinesPanelPendingCreateTests {
    @Test func viewModelMirrorsPendingCreatesAndNotesCreatedButOpenFailed() {
        let center = NotificationCenter.default
        let launches = MachineCreateCoordinatorTests.LaunchRecorder()
        let coordinator = MachineCreateCoordinator(notifier: { _ in }, notificationCenter: center)
        let viewModel = MachinesPanelViewModel(createCoordinator: coordinator)
        viewModel.localWorkspacesProvider = { [] }
        #expect(viewModel.pendingCreates.isEmpty)

        coordinator.start(MachineCreateCoordinatorTests.newMachineRequest(name: "ci"), launch: launches.launch)
        #expect(viewModel.pendingCreates.map(\.request.displayName) == ["ci"])
        #expect(viewModel.pendingCreates.first?.isRunning == true)

        launches.complete(status: 1, output: "Created Cloud VM calm-petrel\nError: attach failed (HTTP 502)", machineID: "calm-petrel")
        #expect(viewModel.pendingCreates.isEmpty)
        #expect(viewModel.treeErrorDescription?.contains("calm-petrel") == true)
        #expect(viewModel.treeErrorDescription?.contains("attach failed (HTTP 502)") == true)

        viewModel.resetForAuthTransition()
        #expect(viewModel.pendingCreates.isEmpty)
    }

    @Test func viewModelStartsWithTheCoordinatorsExistingOperations() {
        let launches = MachineCreateCoordinatorTests.LaunchRecorder()
        let coordinator = MachineCreateCoordinator(notifier: { _ in })
        coordinator.start(MachineCreateCoordinatorTests.baseRequest(), launch: launches.launch)
        // A panel mounted after the create started (another window, the tab
        // reopened) still shows the row.
        let viewModel = MachinesPanelViewModel(createCoordinator: coordinator)
        #expect(viewModel.pendingCreates.count == 1)
        launches.complete(status: 0, output: "Opened Base base-1")
        #expect(viewModel.pendingCreates.isEmpty)
    }

    @Test func treeShowsPendingRowsFirstAndIsNotEmptyWhileOneRuns() {
        let running = MachineCreateOperation(
            id: UUID(),
            request: MachineCreateCoordinatorTests.newMachineRequest(name: "ci"),
            startedAt: Date(timeIntervalSince1970: 1_787_400_000)
        )
        var failed = MachineCreateOperation(
            id: UUID(),
            request: MachineCreateCoordinatorTests.baseRequest(),
            startedAt: Date(timeIntervalSince1970: 1_787_400_060)
        )
        failed.phase = .failed(output: "Error: quota")
        let machine = MachineSnapshot(
            id: "noble-wren",
            provider: "blaxel",
            image: "blaxel/base-image:latest",
            isDesktop: false,
            activity: .ready,
            createdAt: nil,
            label: nil
        )

        let nodes = CloudTreeNodeBuilder.nodes(
            machines: [machine],
            pendingCreates: [running, failed],
            snapshot: .empty,
            localWorkspaces: []
        )
        #expect(nodes.map(\.id) == [
            "pending-machine:\(running.id.uuidString)",
            "pending-machine:\(failed.id.uuidString)",
            "machine:noble-wren",
        ])
        #expect(nodes[0].isExpandable == false)
        #expect(nodes[0].isDragSource == false)
        #expect(nodes[0].isMachineRow)
        #expect(nodes[0].searchableTitle == "ci")
        #expect(nodes[1].searchableTitle == "Base")
        if case .pendingMachine(let operation) = nodes[1].kind {
            #expect(operation.statusLabel == "Couldn't set up Base")
        } else {
            Issue.record("expected a pending machine row")
        }

        #expect(!CloudTreeNodeBuilder.isEmpty(machines: [], pendingCreates: [running], snapshot: .empty))
        #expect(CloudTreeNodeBuilder.isEmpty(machines: [], pendingCreates: [], snapshot: .empty))

        // A failed row changes the tree's content signature (the row turns red in
        // place); a phase change never needs a structural reload.
        var recovered = failed
        recovered.phase = .running
        let before = CloudTreeNodeBuilder.nodes(machines: [], pendingCreates: [failed], snapshot: .empty, localWorkspaces: [])
        let after = CloudTreeNodeBuilder.nodes(machines: [], pendingCreates: [recovered], snapshot: .empty, localWorkspaces: [])
        #expect(CloudTreeNodeBuilder.structureSignature(before) == CloudTreeNodeBuilder.structureSignature(after))
        #expect(CloudTreeNodeBuilder.contentSignature(before) != CloudTreeNodeBuilder.contentSignature(after))
    }
}
