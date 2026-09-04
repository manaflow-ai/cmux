import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The New Machine sheet's model: the CLI invocation it builds, the plan
/// ceilings it mirrors, and how Create hands the work off without waiting.
@Suite("New machine model")
@MainActor
struct NewMachineModelTests {
    private struct SubmitRecorder {
        var requests: [MachineCreateRequest] = []
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
    ) -> (NewMachineModel, Box<SubmitRecorder>) {
        let recorder = Box(SubmitRecorder())
        let model = NewMachineModel(mode: mode, plan: plan, imageKinds: imageKinds) { request in
            recorder.value.requests.append(request)
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

    /// With no `limits.imageKinds` from the backend the sheet opens on
    /// shell-only (no provider ships a desktop image), and the kind travels
    /// as a flag: no image id is pinned, and the create runs in the background.
    /// The default size is omitted so the backend applies its plan default,
    /// which an operator memory brake may have lowered below the plan machine.
    @Test func testDefaultInvocationRequestsShellOnlyByKindInTheBackground() {
        let (model, _) = makeModel()
        #expect(model.cliArguments == ["vm", "new", "--base", "--focus", "false"])
        #expect(!(model.cliArguments.contains("--image")))
        #expect(!(model.cliArguments.contains("--size")))
    }

    @Test func testDesktopKindTravelsAsAFlagWhenTheBackendServesIt() {
        let kinds = [
            VMImageKindOption(kind: .desktop, image: "cmux-xfce-vnc:latest"),
            VMImageKindOption(kind: .base, image: "cmuxd-ws:tooling-20260509f"),
        ]
        let (model, _) = makeModel(imageKinds: kinds)
        #expect(model.cliArguments == ["vm", "new", "--desktop", "--focus", "false"])
        #expect(!(model.cliArguments.contains("--image")))
    }

    @Test func testBaseKindSizeAndNameTravelAsFlags() {
        let (model, _) = makeModel(plan: MachinePlanSnapshot(activeCount: 1, maxActiveVms: 5, planId: "pro"))
        model.kind = .base
        model.name = "  build box  "
        #expect(model.cliArguments == ["vm", "new", "--base", "--name", "build box", "--focus", "false"])
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
        #expect(model.cliArguments == ["vm", "base", "open", "--workspace", workspaceID.uuidString, "--base", "--focus", "false"])
        #expect(model.createRequest.name == nil, "Base has no label; the row is called Base")
        #expect(model.createRequest.baseWorkspaceID == workspaceID)
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
        let (freeModel, _) = makeModel(plan: free)
        #expect(freeModel.planMeterText == "0 of 1 machine in use")
        #expect(freeModel.freeAccessNoteText == "Free plan: this machine stays reachable for 7 days. Upgrade to keep it.")

        let pro = MachinePlanSnapshot(activeCount: 2, maxActiveVms: 5, planId: "pro", freeAccessWindowDays: 7)
        let (proModel, _) = makeModel(plan: pro)
        #expect(proModel.planMeterText == "2 of 5 machines in use")
        #expect(proModel.freeAccessNoteText == nil, "paid plans have no access window")
    }

    @Test func testMemoryLabelsReadInGigabytes() {
        #expect(NewMachineModel.memoryLabel(mb: 2048) == "2 GB")
        #expect(NewMachineModel.memoryLabel(mb: 24576) == "24 GB")
        #expect(NewMachineModel.memoryLabel(mb: 1500) == "1500 MB")
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

    // MARK: Create lifecycle

    /// https://github.com/manaflow-ai/cmux/issues/11397: Create must hand the
    /// person back their window immediately. The sheet finishes as soon as the
    /// create is submitted; the machine coming up (tens of seconds) is the
    /// coordinator's business, never the sheet's lifetime.
    @Test func testCreateFinishesTheSheetBeforeTheMachineExists() {
        let (model, recorder) = makeModel()
        var outcomes: [NewMachineModel.Outcome] = []
        model.onFinished = { outcomes.append($0) }

        model.create()

        #expect(recorder.value.requests.count == 1, "the create is submitted once")
        #expect(outcomes == [.submitted], "the sheet must finish without waiting for the CLI to complete")
        #expect(model.outcome == .submitted)
        #expect(model.errorText == nil)
    }

    @Test func testSubmittedRequestCarriesTheSheetsChoices() {
        let (model, recorder) = makeModel(plan: MachinePlanSnapshot(activeCount: 1, maxActiveVms: 5, planId: "pro"))
        model.kind = .base
        model.memoryMb = 4096
        model.name = " ci box "
        model.create()
        let request = recorder.value.requests.first
        #expect(request?.mode == .newMachine)
        #expect(request?.kind == .base)
        #expect(request?.name == "ci box")
        #expect(request?.displayName == "ci box")
        #expect(request?.arguments == ["vm", "new", "--base", "--size", "4096", "--name", "ci box", "--focus", "false"])
        #expect(request?.progressLabel == "Creating…")
    }

    @Test func testSecondCreateAfterSubmitIsIgnored() {
        let (model, recorder) = makeModel()
        model.create()
        model.create()
        #expect(recorder.value.requests.count == 1, "a second click must not launch a second create")
    }

    @Test func testLaunchRefusalIsReportedWithoutFinishing() {
        let (model, recorder) = makeModel(starts: false)
        var outcomes: [NewMachineModel.Outcome] = []
        model.onFinished = { outcomes.append($0) }
        model.create()
        #expect(model.outcome == nil)
        #expect(model.errorText != nil, "a refused launch is the one error the sheet still shows inline")
        #expect(outcomes.isEmpty)

        // Retry re-submits and clears the message while it runs.
        model.create()
        #expect(recorder.value.requests.count == 2)
        #expect(model.errorText != nil, "still refused, still shown")
    }

    @Test func testCancelFinishesOnceAndBlocksLaterCreate() {
        let (model, recorder) = makeModel()
        var outcomes: [NewMachineModel.Outcome] = []
        model.onFinished = { outcomes.append($0) }
        model.cancel()
        model.cancel()
        model.create()
        #expect(outcomes == [.cancelled])
        #expect(recorder.value.requests.isEmpty)
    }
}
