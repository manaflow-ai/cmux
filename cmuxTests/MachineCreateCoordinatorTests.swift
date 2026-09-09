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
        var progressHandlers: [@MainActor (String) -> Void] = []
        var completions: [@MainActor (CloudVMActionLauncher.Completion) -> Void] = []
        var starts = true
        var cancellations = 0

        var launch: MachineCreateCoordinator.Launch {
            { [self] arguments, progress, completion in
                self.arguments.append(arguments)
                guard starts else { return false }
                progressHandlers.append(progress)
                completions.append(completion)
                return true
            }
        }

        var cancellableLaunch: MachineCreateCoordinator.CancellableLaunch {
            { [self] arguments, progress, completion in
                self.arguments.append(arguments)
                guard starts else { return nil }
                progressHandlers.append(progress)
                completions.append(completion)
                return CloudVMActionLauncher.CancellationHandle {
                    self.cancellations += 1
                }
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
        let immediate: MachineCreateCoordinator.Launch = { _, _, completion in
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

    @Test func emittedMachineMarkerCorrelatesPendingRowBeforeCLIExits() {
        let (coordinator, launches, _, _, _) = makeCoordinator()
        coordinator.start(Self.newMachineRequest(), launch: launches.launch)
        #expect(coordinator.operations.first?.createdMachineID == nil)
        launches.progressHandlers[0]("Created Cloud VM calm-petrel\nOK machine=calm-petrel\n")
        #expect(coordinator.operations.first?.createdMachineID == "calm-petrel")
        let machine = MachineSnapshot(
            id: "calm-petrel", provider: "freestyle", image: "image", isDesktop: false,
            activity: .ready, createdAt: nil, label: nil
        )
        #expect(coordinator.operations.first?.isSuperseded(by: [machine], catalogMachines: []) == true)
    }

    @Test func markerAtTheStartOfALargeProgressCallbackIsNotDropped() {
        let (coordinator, launches, _, _, _) = makeCoordinator()
        coordinator.start(Self.newMachineRequest(), launch: launches.launch)
        let largeChunk = "OK machine=calm-petrel\n" + String(repeating: "progress ", count: 5_000)

        launches.progressHandlers[0](largeChunk)

        #expect(coordinator.operations.first?.createdMachineID == "calm-petrel")
    }

    @Test func launchRegistryDoesNotLetAStalePIDCallbackRemoveTheReplacement() {
        var registry = CloudVMActionLauncher.LaunchRegistry<String>()
        let oldLaunch = UUID()
        let replacementLaunch = UUID()
        registry.insert("old", processID: 42, launchID: oldLaunch)
        registry.insert("replacement", processID: 42, launchID: replacementLaunch)

        #expect(registry.remove(processID: 42, launchID: oldLaunch) == nil)
        #expect(registry.entry(processID: 42)?.value == "replacement")
        #expect(registry.remove(processID: 42, launchID: replacementLaunch) == "replacement")
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

    @Test func runningCreateCanBeCancelledAndLateCompletionCleansUpCreatedMachine() {
        let center = NotificationCenter()
        let launches = LaunchRecorder()
        let notices = NoticeRecorder()
        var cleanedMachineIDs: [String] = []
        let coordinator = MachineCreateCoordinator(
            notifier: { notices.notices.append($0) },
            notificationCenter: center,
            cancelCreatedMachine: { cleanedMachineIDs.append($0) }
        )
        let request = Self.newMachineRequest(name: "cancel me")

        #expect(coordinator.start(request, cancellableLaunch: launches.cancellableLaunch))
        let id = coordinator.operations[0].id
        launches.progressHandlers[0]("OK machine=calm-petrel\n")

        coordinator.cancel(id)

        #expect(coordinator.operations.isEmpty, "Cancel removes the pending row immediately")
        #expect(launches.cancellations == 1, "Cancel terminates the in-flight CLI")
        #expect(cleanedMachineIDs == ["calm-petrel"], "A machine announced before cancellation is destroyed")

        // A process can report its final bytes after the row is gone. They must not
        // recreate the row or post a misleading success notification.
        launches.completions[0](CloudVMActionLauncher.Completion(
            terminationStatus: 0,
            output: "OK machine=calm-petrel",
            workspaceId: nil,
            machineId: "calm-petrel"
        ))
        #expect(coordinator.operations.isEmpty)
        #expect(notices.notices.isEmpty)
        #expect(cleanedMachineIDs == ["calm-petrel"], "Late completion is reconciled exactly once")
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

    @Test func completionWithoutMachineIDUsesTheProgressMarker() {
        let (coordinator, launches, _, changes, _) = makeCoordinator()
        coordinator.start(Self.newMachineRequest(), launch: launches.launch)
        let id = coordinator.operations[0].id
        launches.progressHandlers[0]("OK machine=calm-petrel\n")

        launches.complete(status: 1, output: "Error: attach failed")

        #expect(coordinator.operations.isEmpty)
        #expect(changes.finished.first?.outcome == .createdButOpenFailed(
            machineID: "calm-petrel",
            output: "Error: attach failed"
        ))
        #expect(!coordinator.retry(id), "a machine already announced by progress must not be created again")
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
        launches.complete(status: 1, output: "Error: provider freestyle rejected the request token abc123")
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
        #expect(MachineCreateCoordinator.createdMachineID(fromOutput: "OK machine=calm-petrel") == "calm-petrel")
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

    @Test func signOutRetainsCreateTombstoneForLateMachineCleanup() {
        let center = NotificationCenter()
        let launches = LaunchRecorder()
        var cleanedMachineIDs: [String] = []
        let coordinator = MachineCreateCoordinator(
            notifier: { _ in },
            notificationCenter: center,
            cancelCreatedMachine: { cleanedMachineIDs.append($0) }
        )

        #expect(coordinator.start(Self.newMachineRequest(), cancellableLaunch: launches.cancellableLaunch))
        launches.progressHandlers[0]("OK machine=late-box\n")
        center.post(name: .cmuxCloudVMAccessDidEnd, object: nil)

        #expect(coordinator.operations.isEmpty)
        #expect(cleanedMachineIDs == ["late-box"], "known machine is cleaned before auth state is cleared")

        // The process can flush the same marker after sign-out. The retained
        // tombstone reconciles it without resurrecting a row or issuing a
        // duplicate delete.
        launches.completions[0](CloudVMActionLauncher.Completion(
            terminationStatus: 1,
            output: "OK machine=late-box",
            workspaceId: nil,
            machineId: "late-box"
        ))
        #expect(cleanedMachineIDs == ["late-box"])
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

    /// Regression: while `cmux vm new --name troll` was still opening its
    /// terminal, the fleet list (and, before it, the catalog) already showed
    /// "troll", so the panel listed "troll · Creating…" above "troll". The
    /// stand-in row exists only until the machine has a row of its own.
    @Test func pendingRowStepsAsideOnceItsMachineHasARow() {
        let started = Date(timeIntervalSince1970: 1_787_400_000)
        let named = MachineCreateOperation(
            id: UUID(),
            request: MachineCreateCoordinatorTests.newMachineRequest(name: "troll"),
            startedAt: started,
            createdMachineID: "vm-e0382b"
        )
        let unnamed = MachineCreateOperation(
            id: UUID(),
            request: MachineCreateCoordinatorTests.newMachineRequest(name: nil),
            startedAt: started,
            createdMachineID: "calm-petrel"
        )
        func machine(_ id: String, label: String?, createdAt: Date?) -> MachineSnapshot {
            MachineSnapshot(
                id: id, provider: "freestyle", image: "sh-08be343bf2b54b4bb0e5226b97eaa6c4",
                isDesktop: false, activity: .ready, createdAt: createdAt, label: label
            )
        }
        func rows(machines: [MachineSnapshot], catalog: [SurfaceMachineInfo] = [], pending: [MachineCreateOperation]) -> [String] {
            CloudTreeNodeBuilder.nodes(
                machines: machines,
                pendingCreates: pending,
                snapshot: SurfaceCatalogSnapshot(machines: catalog, resources: [], projections: []),
                localWorkspaces: []
            ).map(\.id)
        }
        let older = machine("old-hare", label: "troll", createdAt: started.addingTimeInterval(-3_600))
        let created = machine("vm-e0382b", label: "troll", createdAt: started.addingTimeInterval(20))
        let anonymous = machine("calm-petrel", label: nil, createdAt: started.addingTimeInterval(20))

        // The fleet list returned the named machine: its stand-in is gone; an
        // older machine that happens to share the label is not it.
        #expect(rows(machines: [older], pending: [named]) == ["pending-machine:\(named.id.uuidString)", "machine:old-hare"])
        #expect(rows(machines: [older, created], pending: [named]) == ["machine:old-hare", "machine:vm-e0382b"])
        // The catalog registered it (the CLI is opening it) before the fleet
        // list caught up: the catalog row is the machine's row.
        let catalogTroll = SurfaceMachineInfo(
            id: .cloud("vm-e0382b"), name: "troll", status: "running", image: nil, hasDesktop: false,
            memoryMb: nil, diskMb: nil, linkState: .connecting, linkError: nil, cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil
        )
        #expect(rows(machines: [], catalog: [catalogTroll], pending: [named]) == ["machine:vm-e0382b"])
        // An unnamed create is the machine that appeared after it started.
        #expect(rows(machines: [older], pending: [unnamed]) == ["pending-machine:\(unnamed.id.uuidString)", "machine:old-hare"])
        #expect(rows(machines: [anonymous], pending: [unnamed]) == ["machine:calm-petrel"])
        // A failed create keeps its row so it can be retried or dismissed.
        var failed = named
        failed.phase = .failed(output: "Error: quota")
        #expect(rows(machines: [created], pending: [failed]) == ["pending-machine:\(failed.id.uuidString)", "machine:vm-e0382b"])

        // A pending operation without its emitted machine id cannot safely be
        // matched by a label or timestamp, especially with concurrent creates.
        let uncorrelated = MachineCreateOperation(
            id: UUID(), request: MachineCreateCoordinatorTests.newMachineRequest(name: "troll"), startedAt: started
        )
        #expect(rows(machines: [created], pending: [uncorrelated]).first?.hasPrefix("pending-machine:") == true)

        // Two concurrent unnamed creates must not both disappear when one
        // newly observed machine has no matching authoritative id.
        let uncorrelatedOther = MachineCreateOperation(
            id: UUID(), request: MachineCreateCoordinatorTests.newMachineRequest(name: nil), startedAt: started
        )
        let concurrentRows = rows(machines: [anonymous], pending: [uncorrelated, uncorrelatedOther])
        #expect(concurrentRows.filter { $0.hasPrefix("pending-machine:") }.count == 2)
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
            provider: "freestyle",
            image: "sh-08be343bf2b54b4bb0e5226b97eaa6c4",
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
