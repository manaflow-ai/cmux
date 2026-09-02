import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The New Machine sheet's model: the CLI invocation it builds, the plan
/// ceilings it mirrors, and how a failed create is surfaced for retry.
@Suite("New machine model")
@MainActor
struct NewMachineModelTests {
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

    @Test func testKindInferredFromImageWhenBackendOmitsIt() {
        #expect(VMMachineKind.inferred(fromImage: "cmux-xfce-vnc:latest") == .desktop)
        #expect(VMMachineKind.inferred(fromImage: "cmuxd-ws:tooling-20260509f") == .base)
        #expect(VMMachineKind.inferred(fromImage: "") == .base)
    }

    /// Regression: `devbox` used to imply a desktop because one provider's
    /// devbox image bundled xfce + noVNC. The shared devbox image every
    /// remaining provider boots is shell-only, so inferring a desktop from the
    /// name published a Desktop surface for a machine with no screen.
    @Test func testSharedDevboxImageIsNotInferredAsDesktop() {
        #expect(VMMachineKind.inferred(fromImage: "cmux-devbox:devbox-20260828b") == .base)
        #expect(VMMachineKind.inferred(fromImage: "cmux-devbox-20260828b") == .base)
    }

    @Test func testResolvedKindPrefersBackendField() {
        #expect(VMMachineKind.resolved(kind: "base", image: "cmux-devbox:devbox-20260828b") == .base)
        #expect(VMMachineKind.resolved(kind: "DESKTOP", image: "cmuxd-ws:tooling-20260509f") == .desktop)
        #expect(VMMachineKind.resolved(kind: "bogus", image: "cmux-xfce-vnc:latest") == .desktop)
        #expect(VMMachineKind.resolved(kind: nil, image: nil) == .base)
    }

    @Test func testSummaryResolvedKindPrefersServerKindOverImageName() {
        var summary = VMSummary(
            id: "noble-wren",
            provider: "freestyle",
            status: "running",
            // An image whose name says desktop, so the server's `base` has
            // something to override.
            image: "cmux-xfce-vnc:latest",
            createdAt: 0,
            base: nil
        )
        #expect(summary.resolvedKind == .desktop)
        summary.kind = .base
        #expect(summary.resolvedKind == .base)
        #expect(!(MachineSnapshotBuilder.snapshot(from: summary).isDesktop))
    }

    // MARK: CLI arguments

    @Test func testDefaultInvocationRequestsDesktopByKindWithoutPinningAnImage() {
        let (model, _) = makeModel()
        #expect(model.cliArguments == ["vm", "new", "--desktop", "--size", "20480"])
        #expect(!(model.cliArguments.contains("--image")))
    }

    @Test func testBaseKindSizeAndNameTravelAsFlags() {
        let (model, _) = makeModel(plan: MachinePlanSnapshot(activeCount: 1, maxActiveVms: 5, planId: "pro"))
        model.kind = .base
        model.name = "  build box  "
        #expect(model.cliArguments == ["vm", "new", "--base", "--size", "20480", "--name", "build box"])
    }

    @Test func testBlankNameIsNotSent() {
        let (model, _) = makeModel()
        model.name = "   "
        #expect(model.trimmedName == nil)
        #expect(!(model.cliArguments.contains("--name")))
    }

    @Test func testBaseSetupOpensTheWorkspaceWithoutSizeOrName() {
        let workspaceID = UUID()
        let (model, _) = makeModel(mode: .base(workspaceID: workspaceID))
        #expect(!(model.supportsSize))
        #expect(!(model.supportsName))
        model.name = "ignored"
        model.kind = .base
        #expect(model.cliArguments == ["vm", "base", "open", "--workspace", workspaceID.uuidString, "--base"])
    }

    // MARK: Plan ceilings

    @Test func testFreePlanGetsThePlanMachine() {
        let (model, _) = makeModel(plan: MachinePlanSnapshot(activeCount: 0, maxActiveVms: 1, planId: "free"))
        #expect(model.memoryOptions == [20480])
        #expect(model.memoryMb == 20480)
    }

    @Test func testPaidPlanGetsThePlanMachineAndDefaultsToIt() {
        let (model, _) = makeModel(plan: MachinePlanSnapshot(activeCount: 2, maxActiveVms: 50, planId: "pro"))
        #expect(model.memoryOptions == [20480])
        #expect(model.memoryMb == 20480)
    }

    @Test func testUnknownPlanUsesThePlanMachineCeiling() {
        let (model, _) = makeModel(plan: nil)
        #expect(model.memoryOptions == [20480])
        #expect(model.planMeterText == nil)
        #expect(model.freeAccessNoteText == nil)
    }

    @Test func testPlanTextsMirrorTheMeterAndFreeWindow() {
        let free = MachinePlanSnapshot(activeCount: 0, maxActiveVms: 1, planId: "free", freeAccessWindowDays: 7)
        let (model, _) = makeModel(plan: free)
        #expect(model.planMeterText == "0 of 1 machine in use")
        #expect(model.freeAccessNoteText == "Free plan: this machine stays reachable for 7 days. Upgrade to keep it.")

        let pro = MachinePlanSnapshot(activeCount: 2, maxActiveVms: 5, planId: "pro", freeAccessWindowDays: 7)
        let (proModel, _) = makeModel(plan: pro)
        #expect(proModel.planMeterText == "2 of 5 machines in use")
        #expect(proModel.freeAccessNoteText == nil)
    }

    @Test func testSelectedImageFollowsTheKind() {
        let kinds = [
            VMImageKindOption(kind: .desktop, image: "cmux-xfce-vnc:latest"),
            VMImageKindOption(kind: .base, image: "cmuxd-ws:tooling-20260509f"),
        ]
        let (model, _) = makeModel(imageKinds: kinds)
        #expect(model.selectedImage == "cmux-xfce-vnc:latest")
        model.kind = .base
        #expect(model.selectedImage == "cmuxd-ws:tooling-20260509f")
    }

    /// The sheet must not open preselected on a kind the deployment cannot
    /// provision: no provider ships a desktop image today, so a desktop
    /// default would make the primary button fail with an image config error.
    @Test func testKindDefaultsToAServableKind() {
        let baseOnly = [VMImageKindOption(kind: .base, image: "cmuxd-ws:tooling-20260509f")]
        let (baseModel, _) = makeModel(imageKinds: baseOnly)
        #expect(baseModel.kind == .base)
        #expect(baseModel.selectableKinds == [.base])

        let both = [
            VMImageKindOption(kind: .desktop, image: "cmux-xfce-vnc:latest"),
            VMImageKindOption(kind: .base, image: "cmuxd-ws:tooling-20260509f"),
        ]
        let (bothModel, _) = makeModel(imageKinds: both)
        #expect(bothModel.kind == .desktop)
        #expect(bothModel.selectableKinds == [.desktop, .base])
    }

    /// An older control plane sends no `limits.imageKinds`. Offering nothing
    /// would be worse than offering both, so the sheet keeps the full picker.
    @Test func testUnknownImageKindsStillOfferEveryKind() {
        let (model, _) = makeModel(imageKinds: [])
        #expect(model.selectableKinds == VMMachineKind.allCases)
        #expect(model.kind == .base)
    }

    @Test func testMemoryLabelsReadInGigabytes() {
        #expect(NewMachineModel.memoryLabel(mb: 24576) == "24 GB")
        #expect(NewMachineModel.memoryLabel(mb: 3000) == "3000 MB")
    }

    // MARK: Create lifecycle

    @Test func testCreateLaunchesOnceAndFinishesOnSuccess() {
        let (model, recorder) = makeModel()
        var outcomes: [NewMachineModel.Outcome] = []
        model.onFinished = { outcomes.append($0) }

        model.create()
        #expect(model.isCreating)
        model.create()
        #expect(recorder.value.arguments.count == 1, "a second click while creating must not launch again")

        recorder.value.pendingCompletion?(CloudVMActionLauncher.Completion(terminationStatus: 0, output: "", workspaceId: nil))
        #expect(!(model.isCreating))
        #expect(model.outcome == .created)
        #expect(outcomes == [.created])
    }

    @Test func testFailureShowsTheCLIOutputAndAllowsRetry() {
        let (model, recorder) = makeModel()
        model.create()
        recorder.value.pendingCompletion?(CloudVMActionLauncher.Completion(
            terminationStatus: 1,
            output: "Cloud VM temporarily unavailable (HTTP 503: vm_image_config_error)\n\nWhat to do:\n  Retry without `image`.\n",
            workspaceId: nil
        ))
        #expect(!(model.isCreating))
        #expect(model.outcome == nil)
        #expect(model.errorText == "Cloud VM temporarily unavailable (HTTP 503: vm_image_config_error)\n\nWhat to do:\n  Retry without `image`.")

        model.create()
        #expect(model.errorText == nil, "a retry clears the previous error while it runs")
        #expect(recorder.value.arguments.count == 2)
    }

    @Test func testCreatedMachineIDIsParsedFromTheCLIsCreatedLine() {
        #expect(NewMachineModel.createdMachineID(fromOutput: "Created Cloud VM calm-petrel\nError: noProvider(calm-petrel)") == "calm-petrel")
        #expect(NewMachineModel.createdMachineID(fromOutput: "  Created Cloud VM noble_wren2  ") == "noble_wren2")
        #expect(NewMachineModel.createdMachineID(fromOutput: "Error: Creating Cloud VM (HTTP 502)") == nil)
        #expect(NewMachineModel.createdMachineID(fromOutput: "Created Cloud VM") == nil)
        #expect(NewMachineModel.createdMachineID(fromOutput: "") == nil)
    }

    @Test func testCreatedButOpenFailedNeverRetriesTheCreate() {
        let (model, recorder) = makeModel()
        model.create()
        #expect(recorder.value.arguments.count == 1)
        recorder.value.pendingCompletion?(CloudVMActionLauncher.Completion(
            terminationStatus: 1,
            output: "Created Cloud VM calm-petrel\nError: No provider for machine calm-petrel.",
            workspaceId: nil
        ))
        #expect(model.createdMachineID == "calm-petrel")
        #expect(model.outcome == nil, "the sheet stays up so the person sees why the open failed")
        #expect(!(model.isCreating))
        #expect(model.errorText?.contains("calm-petrel") == true)
        #expect(model.errorText?.contains("No provider") == true, "the CLI output is kept for diagnosis")

        // The primary button is now "Done": it closes the sheet without launching again.
        model.create()
        #expect(recorder.value.arguments.count == 1, "a second create would mint a second machine")
        #expect(model.outcome == .created)
    }

    @Test func testBaseSetupFailureIsNotMistakenForACreatedMachine() {
        let (model, recorder) = makeModel(mode: .base(workspaceID: UUID()))
        model.create()
        recorder.value.pendingCompletion?(CloudVMActionLauncher.Completion(
            terminationStatus: 1,
            output: "Created Cloud VM base-1\nError: attach failed",
            workspaceId: nil
        ))
        #expect(model.createdMachineID == nil)
        #expect(model.outcome == nil)
        model.create()
        #expect(recorder.value.arguments.count == 2, "Base setup retries through the idempotent base open")
    }

    @Test func testEmptyFailureOutputGetsAGenericMessage() {
        let (model, recorder) = makeModel()
        model.create()
        recorder.value.pendingCompletion?(CloudVMActionLauncher.Completion(terminationStatus: 2, output: "  \n", workspaceId: nil))
        #expect(model.errorText == "The machine could not be created.")
    }

    @Test func testLaunchRefusalIsReportedWithoutFinishing() {
        let (model, _) = makeModel(starts: false)
        var outcomes: [NewMachineModel.Outcome] = []
        model.onFinished = { outcomes.append($0) }
        model.create()
        #expect(!(model.isCreating))
        #expect(model.errorText != nil)
        #expect(outcomes.isEmpty)
    }

    @Test func testCancelFinishesOnceAndBlocksLaterCreate() {
        let (model, recorder) = makeModel()
        var outcomes: [NewMachineModel.Outcome] = []
        model.onFinished = { outcomes.append($0) }
        model.cancel()
        model.cancel()
        model.create()
        #expect(outcomes == [.cancelled])
        #expect(recorder.value.arguments.isEmpty)
    }
}
