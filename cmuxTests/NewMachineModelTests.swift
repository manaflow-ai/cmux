import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The New Machine sheet's model: the CLI invocation it builds, the plan
/// ceilings it mirrors, and how a failed create is surfaced for retry.
@MainActor
final class NewMachineModelTests: XCTestCase {
    private struct LaunchRecorder {
        var arguments: [[String]] = []
        var pendingCompletion: (@MainActor (CloudVMActionLauncher.Completion) -> Void)?
    }

    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private func makeModel(
        mode: NewMachineModel.Mode = .newMachine,
        plan: MachinePlanSnapshot? = nil,
        imageKinds: [VMImageKindOption] = [],
        starts: Bool = true
    ) -> (NewMachineModel, Box<LaunchRecorder>) {
        let recorder = Box(LaunchRecorder())
        let model = NewMachineModel(mode: mode, plan: plan, imageKinds: imageKinds) { arguments, completion in
            recorder.value.arguments.append(arguments)
            recorder.value.pendingCompletion = completion
            return starts
        }
        return (model, recorder)
    }

    // MARK: Kind

    func testKindInferredFromImageWhenBackendOmitsIt() {
        XCTAssertEqual(VMMachineKind.inferred(fromImage: "sandbox/cmux-devbox:latest"), .desktop)
        XCTAssertEqual(VMMachineKind.inferred(fromImage: "blaxel/xfce-vnc:latest"), .desktop)
        XCTAssertEqual(VMMachineKind.inferred(fromImage: "blaxel/base-image:latest"), .base)
        XCTAssertEqual(VMMachineKind.inferred(fromImage: ""), .base)
    }

    func testResolvedKindPrefersBackendField() {
        XCTAssertEqual(VMMachineKind.resolved(kind: "base", image: "sandbox/cmux-devbox:latest"), .base)
        XCTAssertEqual(VMMachineKind.resolved(kind: "DESKTOP", image: "blaxel/base-image:latest"), .desktop)
        XCTAssertEqual(VMMachineKind.resolved(kind: "bogus", image: "blaxel/xfce-vnc:latest"), .desktop)
        XCTAssertEqual(VMMachineKind.resolved(kind: nil, image: nil), .base)
    }

    func testSummaryResolvedKindPrefersServerKindOverImageName() {
        var summary = VMSummary(
            id: "noble-wren",
            provider: "blaxel",
            status: "running",
            image: "sandbox/cmux-devbox:latest",
            createdAt: 0,
            base: nil
        )
        XCTAssertEqual(summary.resolvedKind, .desktop)
        summary.kind = .base
        XCTAssertEqual(summary.resolvedKind, .base)
        XCTAssertFalse(MachineSnapshotBuilder.snapshot(from: summary).isDesktop)
    }

    // MARK: CLI arguments

    func testDefaultInvocationRequestsDesktopByKindWithoutPinningAnImage() {
        let (model, _) = makeModel()
        XCTAssertEqual(model.cliArguments, ["vm", "new", "--desktop", "--size", "24576"])
        XCTAssertFalse(model.cliArguments.contains("--image"))
    }

    func testBaseKindSizeAndNameTravelAsFlags() {
        let (model, _) = makeModel(plan: MachinePlanSnapshot(activeCount: 1, maxActiveVms: 5, planId: "pro"))
        model.kind = .base
        model.memoryMb = 8192
        model.name = "  build box  "
        XCTAssertEqual(model.cliArguments, ["vm", "new", "--base", "--size", "8192", "--name", "build box"])
    }

    func testBlankNameIsNotSent() {
        let (model, _) = makeModel()
        model.name = "   "
        XCTAssertNil(model.trimmedName)
        XCTAssertFalse(model.cliArguments.contains("--name"))
    }

    func testBaseSetupOpensTheWorkspaceWithoutSizeOrName() {
        let workspaceID = UUID()
        let (model, _) = makeModel(mode: .base(workspaceID: workspaceID))
        XCTAssertFalse(model.supportsSize)
        XCTAssertFalse(model.supportsName)
        model.name = "ignored"
        model.kind = .base
        XCTAssertEqual(
            model.cliArguments,
            ["vm", "base", "open", "--workspace", workspaceID.uuidString, "--base"]
        )
    }

    // MARK: Plan ceilings

    func testFreePlanCapsSizeAtTwentyFourGigabytes() {
        let (model, _) = makeModel(plan: MachinePlanSnapshot(activeCount: 0, maxActiveVms: 1, planId: "free"))
        XCTAssertEqual(model.memoryOptions, [2048, 4096, 8192, 16384, 24576])
        XCTAssertEqual(model.memoryMb, 24576)
    }

    func testPaidPlanUnlocksThirtyTwoGigabytesButDefaultsToTwentyFour() {
        let (model, _) = makeModel(plan: MachinePlanSnapshot(activeCount: 2, maxActiveVms: 5, planId: "pro"))
        XCTAssertEqual(model.memoryOptions.last, 32768)
        XCTAssertEqual(model.memoryMb, 24576)
    }

    func testUnknownPlanUsesTheFreeCeiling() {
        let (model, _) = makeModel(plan: nil)
        XCTAssertEqual(model.memoryOptions.last, 24576)
        XCTAssertNil(model.planMeterText)
        XCTAssertNil(model.freeAccessNoteText)
    }

    func testPlanTextsMirrorTheMeterAndFreeWindow() {
        let free = MachinePlanSnapshot(activeCount: 0, maxActiveVms: 1, planId: "free", freeAccessWindowDays: 7)
        let (model, _) = makeModel(plan: free)
        XCTAssertEqual(model.planMeterText, "0 of 1 machine in use")
        XCTAssertEqual(model.freeAccessNoteText, "Free plan: this machine stays reachable for 7 days. Upgrade to keep it.")

        let pro = MachinePlanSnapshot(activeCount: 2, maxActiveVms: 5, planId: "pro", freeAccessWindowDays: 7)
        let (proModel, _) = makeModel(plan: pro)
        XCTAssertEqual(proModel.planMeterText, "2 of 5 machines in use")
        XCTAssertNil(proModel.freeAccessNoteText)
    }

    func testSelectedImageFollowsTheKind() {
        let kinds = [
            VMImageKindOption(kind: .desktop, image: "sandbox/cmux-devbox:latest"),
            VMImageKindOption(kind: .base, image: "blaxel/base-image:latest"),
        ]
        let (model, _) = makeModel(imageKinds: kinds)
        XCTAssertEqual(model.selectedImage, "sandbox/cmux-devbox:latest")
        model.kind = .base
        XCTAssertEqual(model.selectedImage, "blaxel/base-image:latest")
    }

    func testMemoryLabelsReadInGigabytes() {
        XCTAssertEqual(NewMachineModel.memoryLabel(mb: 24576), "24 GB")
        XCTAssertEqual(NewMachineModel.memoryLabel(mb: 3000), "3000 MB")
    }

    // MARK: Create lifecycle

    func testCreateLaunchesOnceAndFinishesOnSuccess() {
        let (model, recorder) = makeModel()
        var outcomes: [NewMachineModel.Outcome] = []
        model.onFinished = { outcomes.append($0) }

        model.create()
        XCTAssertTrue(model.isCreating)
        model.create()
        XCTAssertEqual(recorder.value.arguments.count, 1, "a second click while creating must not launch again")

        recorder.value.pendingCompletion?(CloudVMActionLauncher.Completion(terminationStatus: 0, output: "", workspaceId: nil))
        XCTAssertFalse(model.isCreating)
        XCTAssertEqual(model.outcome, .created)
        XCTAssertEqual(outcomes, [.created])
    }

    func testFailureShowsSafeCLIOutputAndAllowsRetry() {
        let (model, recorder) = makeModel()
        model.create()
        recorder.value.pendingCompletion?(CloudVMActionLauncher.Completion(
            terminationStatus: 1,
            output: "Cloud VM temporarily unavailable (HTTP 503: vm_image_config_error)\n\nWhat to do:\n  Retry without `image`.\n",
            workspaceId: nil
        ))
        XCTAssertFalse(model.isCreating)
        XCTAssertNil(model.outcome)
        XCTAssertEqual(
            model.errorText,
            "Cloud VM temporarily unavailable (HTTP 503: vm_image_config_error)\n\nWhat to do:\n  Retry without `image`."
        )

        model.create()
        XCTAssertNil(model.errorText, "a retry clears the previous error while it runs")
        XCTAssertEqual(recorder.value.arguments.count, 2)
    }

    func testCreatedMachineIDIsParsedFromTheCLIsCreatedLine() {
        XCTAssertEqual(
            NewMachineModel.createdMachineID(fromOutput: "Created Cloud VM calm-petrel\nError: noProvider(calm-petrel)"),
            "calm-petrel"
        )
        XCTAssertEqual(NewMachineModel.createdMachineID(fromOutput: "  Created Cloud VM noble_wren2  "), "noble_wren2")
        XCTAssertNil(NewMachineModel.createdMachineID(fromOutput: "Error: Creating Cloud VM (HTTP 502)"))
        XCTAssertNil(NewMachineModel.createdMachineID(fromOutput: "Created Cloud VM"))
        XCTAssertNil(NewMachineModel.createdMachineID(fromOutput: ""))
    }

    func testCreatedButOpenFailedNeverRetriesTheCreate() {
        let (model, recorder) = makeModel()
        model.create()
        XCTAssertEqual(recorder.value.arguments.count, 1)
        recorder.value.pendingCompletion?(CloudVMActionLauncher.Completion(
            terminationStatus: 1,
            output: "Created Cloud VM calm-petrel\nError: No provider for machine calm-petrel.",
            workspaceId: nil
        ))
        XCTAssertEqual(model.createdMachineID, "calm-petrel")
        XCTAssertNil(model.outcome, "the sheet stays up so the person sees why the open failed")
        XCTAssertFalse(model.isCreating)
        XCTAssertTrue(model.errorText?.contains("calm-petrel") == true)
        XCTAssertFalse(model.errorText?.contains("No provider") == true, "provider diagnostics must not reach the sheet")

        // The primary button is now "Done": it closes the sheet without launching again.
        model.create()
        XCTAssertEqual(recorder.value.arguments.count, 1, "a second create would mint a second machine")
        XCTAssertEqual(model.outcome, .created)
    }

    func testFailureDoesNotRenderProviderSecretsOrTerminalControls() {
        let (model, recorder) = makeModel()
        model.create()
        let secret = "bearer super-secret-token"
        recorder.value.pendingCompletion?(CloudVMActionLauncher.Completion(
            terminationStatus: 1,
            output: "Error: provider failed at /home/alice/private\n\u{1B}[31m\(secret)\u{1B}[0m\n",
            workspaceId: nil
        ))

        XCTAssertEqual(model.errorText, "The machine could not be created.")
        XCTAssertFalse(model.errorText?.contains(secret) == true)
        XCTAssertFalse(model.errorText?.contains("/home/alice/private") == true)
        XCTAssertFalse(model.errorText?.contains("\u{1B}") == true)
    }

    func testBaseSetupFailureIsNotMistakenForACreatedMachine() {
        let (model, recorder) = makeModel(mode: .base(workspaceID: UUID()))
        model.create()
        recorder.value.pendingCompletion?(CloudVMActionLauncher.Completion(
            terminationStatus: 1,
            output: "Created Cloud VM base-1\nError: attach failed",
            workspaceId: nil
        ))
        XCTAssertNil(model.createdMachineID)
        XCTAssertNil(model.outcome)
        model.create()
        XCTAssertEqual(recorder.value.arguments.count, 2, "Base setup retries through the idempotent base open")
    }

    func testEmptyFailureOutputGetsAGenericMessage() {
        let (model, recorder) = makeModel()
        model.create()
        recorder.value.pendingCompletion?(CloudVMActionLauncher.Completion(terminationStatus: 2, output: "  \n", workspaceId: nil))
        XCTAssertEqual(model.errorText, "The machine could not be created.")
    }

    func testLaunchRefusalIsReportedWithoutFinishing() {
        let (model, _) = makeModel(starts: false)
        var outcomes: [NewMachineModel.Outcome] = []
        model.onFinished = { outcomes.append($0) }
        model.create()
        XCTAssertFalse(model.isCreating)
        XCTAssertNotNil(model.errorText)
        XCTAssertTrue(outcomes.isEmpty)
    }

    func testCancelFinishesOnceAndBlocksLaterCreate() {
        let (model, recorder) = makeModel()
        var outcomes: [NewMachineModel.Outcome] = []
        model.onFinished = { outcomes.append($0) }
        model.cancel()
        model.cancel()
        model.create()
        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertTrue(recorder.value.arguments.isEmpty)
    }
}
