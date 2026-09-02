import Foundation
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The New Machine sheet's model: the CLI invocation it builds, the plan
/// ceilings it mirrors, and how Create hands the work off without waiting.
@MainActor
final class NewMachineModelTests: XCTestCase {
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

    func testKindInferredFromImageWhenBackendOmitsIt() {
        XCTAssertEqual(VMMachineKind.inferred(fromImage: "cmux-xfce-vnc:latest"), .desktop)
        XCTAssertEqual(VMMachineKind.inferred(fromImage: "cmuxd-ws:tooling-20260509f"), .base)
        XCTAssertEqual(VMMachineKind.inferred(fromImage: ""), .base)
    }

    /// Regression: `devbox` used to imply a desktop because one provider's
    /// devbox image bundled xfce + noVNC. The shared devbox image every
    /// remaining provider boots is shell-only, so inferring a desktop from the
    /// name published a Desktop surface for a machine with no screen.
    func testSharedDevboxImageIsNotInferredAsDesktop() {
        XCTAssertEqual(VMMachineKind.inferred(fromImage: "cmux-devbox:devbox-20260828b"), .base)
        XCTAssertEqual(VMMachineKind.inferred(fromImage: "cmux-devbox-20260828b"), .base)
    }

    func testResolvedKindPrefersBackendField() {
        XCTAssertEqual(VMMachineKind.resolved(kind: "base", image: "cmux-devbox:devbox-20260828b"), .base)
        XCTAssertEqual(VMMachineKind.resolved(kind: "DESKTOP", image: "cmuxd-ws:tooling-20260509f"), .desktop)
        XCTAssertEqual(VMMachineKind.resolved(kind: "bogus", image: "cmux-xfce-vnc:latest"), .desktop)
        XCTAssertEqual(VMMachineKind.resolved(kind: nil, image: nil), .base)
    }

    func testSummaryResolvedKindPrefersServerKindOverImageName() {
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
        XCTAssertEqual(summary.resolvedKind, .desktop)
        summary.kind = .base
        XCTAssertEqual(summary.resolvedKind, .base)
        XCTAssertFalse(MachineSnapshotBuilder.snapshot(from: summary).isDesktop)
    }

    // MARK: CLI arguments

    func testDefaultInvocationRequestsDesktopByKindInTheBackground() {
        let (model, _) = makeModel()
        XCTAssertEqual(model.cliArguments, ["vm", "new", "--desktop", "--size", "24576", "--focus", "false"])
        XCTAssertFalse(model.cliArguments.contains("--image"))
    }

    func testBaseKindSizeAndNameTravelAsFlags() {
        let (model, _) = makeModel(plan: MachinePlanSnapshot(activeCount: 1, maxActiveVms: 5, planId: "pro"))
        model.kind = .base
        model.memoryMb = 8192
        model.name = "  build box  "
        XCTAssertEqual(model.cliArguments, ["vm", "new", "--base", "--size", "8192", "--name", "build box", "--focus", "false"])
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
            ["vm", "base", "open", "--workspace", workspaceID.uuidString, "--base", "--focus", "false"]
        )
        XCTAssertNil(model.createRequest.name, "Base has no label; the row is called Base")
        XCTAssertEqual(model.createRequest.baseWorkspaceID, workspaceID)
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
        let (freeModel, _) = makeModel(plan: free)
        XCTAssertEqual(freeModel.planMeterText, "0 of 1 machine in use")
        XCTAssertEqual(
            freeModel.freeAccessNoteText,
            "Free plan: this machine stays reachable for 7 days. Upgrade to keep it."
        )

        let pro = MachinePlanSnapshot(activeCount: 2, maxActiveVms: 5, planId: "pro", freeAccessWindowDays: 7)
        let (proModel, _) = makeModel(plan: pro)
        XCTAssertEqual(proModel.planMeterText, "2 of 5 machines in use")
        XCTAssertNil(proModel.freeAccessNoteText, "paid plans have no access window")
    }

    func testMemoryLabelsReadInGigabytes() {
        XCTAssertEqual(NewMachineModel.memoryLabel(mb: 2048), "2 GB")
        XCTAssertEqual(NewMachineModel.memoryLabel(mb: 24576), "24 GB")
        XCTAssertEqual(NewMachineModel.memoryLabel(mb: 1500), "1500 MB")
    }

    func testSelectedImageFollowsTheKind() {
        let kinds = [
            VMImageKindOption(kind: .desktop, image: "cmux-xfce-vnc:latest"),
            VMImageKindOption(kind: .base, image: "cmuxd-ws:tooling-20260509f"),
        ]
        let (model, _) = makeModel(imageKinds: kinds)
        XCTAssertEqual(model.selectedImage, "cmux-xfce-vnc:latest")
        model.kind = .base
        XCTAssertEqual(model.selectedImage, "cmuxd-ws:tooling-20260509f")
    }

    /// The sheet must not open preselected on a kind the deployment cannot
    /// provision: no provider ships a desktop image today, so a desktop
    /// default would make the primary button fail with an image config error.
    func testKindDefaultsToAServableKind() {
        let baseOnly = [VMImageKindOption(kind: .base, image: "cmuxd-ws:tooling-20260509f")]
        let (baseModel, _) = makeModel(imageKinds: baseOnly)
        XCTAssertEqual(baseModel.kind, .base)
        XCTAssertEqual(baseModel.selectableKinds, [.base])

        let both = [
            VMImageKindOption(kind: .desktop, image: "cmux-xfce-vnc:latest"),
            VMImageKindOption(kind: .base, image: "cmuxd-ws:tooling-20260509f"),
        ]
        let (bothModel, _) = makeModel(imageKinds: both)
        XCTAssertEqual(bothModel.kind, .desktop)
        XCTAssertEqual(bothModel.selectableKinds, [.desktop, .base])
    }

    /// An older control plane sends no `limits.imageKinds`. Offering nothing
    /// would be worse than offering both, so the sheet keeps the full picker.
    func testUnknownImageKindsStillOfferEveryKind() {
        let (model, _) = makeModel(imageKinds: [])
        XCTAssertEqual(model.selectableKinds, VMMachineKind.allCases)
        XCTAssertEqual(model.kind, .base)
    }

    // MARK: Create lifecycle

    /// https://github.com/manaflow-ai/cmux/issues/11397: Create must hand the
    /// person back their window immediately. The sheet finishes as soon as the
    /// create is submitted; the machine coming up (tens of seconds) is the
    /// coordinator's business, never the sheet's lifetime.
    func testCreateFinishesTheSheetBeforeTheMachineExists() {
        let (model, recorder) = makeModel()
        var outcomes: [NewMachineModel.Outcome] = []
        model.onFinished = { outcomes.append($0) }

        model.create()

        XCTAssertEqual(recorder.value.requests.count, 1, "the create is submitted once")
        XCTAssertEqual(outcomes, [.submitted], "the sheet must finish without waiting for the CLI to complete")
        XCTAssertEqual(model.outcome, .submitted)
        XCTAssertNil(model.errorText)
    }

    func testSubmittedRequestCarriesTheSheetsChoices() {
        let (model, recorder) = makeModel(plan: MachinePlanSnapshot(activeCount: 1, maxActiveVms: 5, planId: "pro"))
        model.kind = .base
        model.memoryMb = 4096
        model.name = " ci box "
        model.create()
        let request = recorder.value.requests.first
        XCTAssertEqual(request?.mode, .newMachine)
        XCTAssertEqual(request?.kind, .base)
        XCTAssertEqual(request?.name, "ci box")
        XCTAssertEqual(request?.displayName, "ci box")
        XCTAssertEqual(request?.arguments, ["vm", "new", "--base", "--size", "4096", "--name", "ci box", "--focus", "false"])
        XCTAssertEqual(request?.progressLabel, "Creating…")
    }

    func testSecondCreateAfterSubmitIsIgnored() {
        let (model, recorder) = makeModel()
        model.create()
        model.create()
        XCTAssertEqual(recorder.value.requests.count, 1, "a second click must not launch a second create")
    }

    func testLaunchRefusalIsReportedWithoutFinishing() {
        let (model, recorder) = makeModel(starts: false)
        var outcomes: [NewMachineModel.Outcome] = []
        model.onFinished = { outcomes.append($0) }
        model.create()
        XCTAssertNil(model.outcome)
        XCTAssertNotNil(model.errorText, "a refused launch is the one error the sheet still shows inline")
        XCTAssertTrue(outcomes.isEmpty)

        // Retry re-submits and clears the message while it runs.
        model.create()
        XCTAssertEqual(recorder.value.requests.count, 2)
        XCTAssertNotNil(model.errorText, "still refused, still shown")
    }

    func testCancelFinishesOnceAndBlocksLaterCreate() {
        let (model, recorder) = makeModel()
        var outcomes: [NewMachineModel.Outcome] = []
        model.onFinished = { outcomes.append($0) }
        model.cancel()
        model.cancel()
        model.create()
        XCTAssertEqual(outcomes, [.cancelled])
        XCTAssertTrue(recorder.value.requests.isEmpty)
    }
}
