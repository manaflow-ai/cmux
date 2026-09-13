import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("New machine model")
@MainActor
struct NewMachineModelTests {
    @Test func goOffersThePlanThatActuallyUnlocksEachSize() {
        let model = NewMachineModel(
            mode: .newMachine,
            plan: MachinePlanSnapshot(activeCount: 0, maxActiveVms: 1, planId: "go"),
            memoryOptionsMb: [4096],
            lockedMemoryOptionsMb: [8192, 32768, 65536],
            memoryUpgradePlanId: "pro",
            memoryUpgradePlansByMb: ["8192": "pro", "32768": "max"],
            submit: { _ in true }
        )
        #expect(model.memoryMb == 4096)
        model.selectSize(8192)
        #expect(model.showsMaxUpgrade)
        #expect(model.selectedUpgradePlanId == "pro")
        model.selectSize(32768)
        #expect(model.selectedUpgradePlanId == "max")
        #expect(model.memoryMb == 4096)
        #expect(model.upgradePlan(for: 65536) == nil)
        #expect(MachinePlanSnapshot.isPaidPlanID("go"))
    }

    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private static let proPlan = MachinePlanSnapshot(activeCount: 0, maxActiveVms: 50, planId: "pro")
    private static let maxPlan = MachinePlanSnapshot(activeCount: 0, maxActiveVms: 50, planId: "max")

    private func makeModel(
        mode: NewMachineModel.Mode = .newMachine,
        plan: MachinePlanSnapshot? = nil,
        memoryOptionsMb: [Int] = NewMachineModel.memoryOptionsMb,
        lockedMemoryOptionsMb: [Int]? = nil,
        memoryUpgradePlanId: String? = nil,
        starts: Bool = true
    ) -> (NewMachineModel, Box<[MachineCreateRequest]>) {
        let recorder = Box<[MachineCreateRequest]>([])
        let model = NewMachineModel(
            mode: mode,
            plan: plan,
            memoryOptionsMb: memoryOptionsMb,
            lockedMemoryOptionsMb: lockedMemoryOptionsMb,
            memoryUpgradePlanId: memoryUpgradePlanId
        ) { request in
            recorder.value.append(request)
            return starts
        }
        return (model, recorder)
    }

    /// One snapshot serves every kind, so the sheet never asks: whatever the
    /// backend lists under `limits.imageKinds`, every create is the devbox
    /// with a screen (#12244).
    @Test func theSheetHasNoKindInputAndAlwaysCreatesTheDevboxWithAScreen() {
        let (model, recorder) = makeModel()
        #expect(NewMachineModel.machineKind == .desktop)
        model.create()
        #expect(recorder.value.first?.kind == .desktop)
        #expect(recorder.value.first?.arguments == ["vm", "new", "--desktop", "--size", "8192", "--focus", "false"])
        let workspaceID = UUID()
        let (base, baseRecorder) = makeModel(mode: .base(workspaceID: workspaceID))
        base.create()
        #expect(baseRecorder.value.first?.kind == .desktop)
        #expect(baseRecorder.value.first?.arguments == ["vm", "base", "open", "--workspace", workspaceID.uuidString, "--desktop", "--focus", "false"])
    }

    @Test func defaultSizeIsTheSmallestSupportedBaseImage() {
        let (model, _) = makeModel(plan: Self.maxPlan)
        #expect(model.memoryOptions == [4096, 8192, 16384, 24576, 32768, 65536])
        #expect(model.memoryMb == 8192)
        #expect(model.selectedSize == MachineSizeOption(memoryMb: 8192))
    }

    /// The client mirror of the server ladder: Pro (and every plan but Max)
    /// stops at 24 GB, and the two rows above it are locked and sold by Max.
    @Test func proPlanLocksTheMaxSizesWhenTheServerOmitsThem() {
        let (model, _) = makeModel(plan: Self.proPlan)
        #expect(model.memoryOptions == [4096, 8192, 16384, 24576])
        #expect(model.lockedMemoryOptions == [32768, 65536])
        #expect(model.memoryUpgradePlanId == "max")
        #expect(model.memoryUpgradePlanName == "Max")
        #expect(model.lockedSizesNoteText == "32 GB and 64 GB machines need cmux Max.")
        #expect(model.memoryUpgradeButtonTitle == "Upgrade to Max")
        #expect(model.lockedSizeMenuTitle(MachineSizeOption(memoryMb: 32768)!) == "32 GB RAM · 128 GB disk · Requires Max")
        #expect(NewMachineModel.maxMemoryMb(planId: "pro") == 24576)
        #expect(NewMachineModel.maxMemoryMb(planId: "free") == 24576)
        #expect(NewMachineModel.maxMemoryMb(planId: nil) == 24576)
        #expect(NewMachineModel.maxMemoryMb(planId: "max") == 65536)
        #expect(NewMachineModel.maxMemoryMb(planId: " Max\n") == 65536)
    }

    @Test func maxPlanHasTheWholeLadderAndNothingLocked() {
        let (model, _) = makeModel(plan: Self.maxPlan)
        #expect(model.memoryOptions == [4096, 8192, 16384, 24576, 32768, 65536])
        #expect(model.lockedMemoryOptions == [])
        #expect(model.memoryUpgradePlanId == nil)
        #expect(model.lockedSizesNoteText == nil)
        #expect(model.memoryUpgradeButtonTitle == nil)
    }

    /// `limits.lockedMemoryOptionsMb` is authoritative: an operator ceiling
    /// the mirror cannot know about (24 GB locked here) still renders locked,
    /// and a server that unlocks everything for a Pro plan is believed too.
    @Test func serverLockedSizesWinOverTheClientMirror() {
        let (tighter, _) = makeModel(
            plan: Self.proPlan,
            memoryOptionsMb: [4096, 8192, 16384],
            lockedMemoryOptionsMb: [24576, 32768, 65536],
            memoryUpgradePlanId: "max"
        )
        #expect(tighter.memoryOptions == [4096, 8192, 16384])
        #expect(tighter.lockedMemoryOptions == [24576, 32768, 65536])
        #expect(tighter.lockedSizesNoteText == "24 GB, 32 GB, and 64 GB machines need cmux Max.")

        let (open, _) = makeModel(plan: Self.proPlan, lockedMemoryOptionsMb: [], memoryUpgradePlanId: nil)
        #expect(open.memoryOptions == [4096, 8192, 16384, 24576, 32768, 65536])
        #expect(open.lockedMemoryOptions == [])
        #expect(open.memoryUpgradePlanId == nil)

        // A locked list without an upgrade plan still names Max, the plan
        // that sells the ladder, unless the plan already is Max.
        let (unnamed, _) = makeModel(plan: Self.proPlan, lockedMemoryOptionsMb: [65536], memoryUpgradePlanId: nil)
        #expect(unnamed.memoryUpgradePlanId == "max")
        #expect(unnamed.memoryOptions == [4096, 8192, 16384, 24576, 32768])
    }

    /// The Picker binding can only land on an allowed size: a locked pick
    /// snaps to the largest allowed size below it, and the create request
    /// carries that size.
    @Test func selectionNeverLandsOnALockedSize() {
        let (model, recorder) = makeModel(plan: Self.proPlan)
        model.memoryMb = 65536
        #expect(model.memoryMb == 24576)
        model.memoryMb = 32768
        #expect(model.memoryMb == 24576)
        model.memoryMb = 16384
        #expect(model.memoryMb == 16384)
        model.memoryMb = 65536
        model.create()
        #expect(recorder.value.first?.arguments == ["vm", "new", "--desktop", "--size", "24576", "--focus", "false"])

        let (smallest, _) = makeModel(plan: Self.proPlan, memoryOptionsMb: [8192, 16384], lockedMemoryOptionsMb: [4096, 32768])
        smallest.memoryMb = 4096
        #expect(smallest.memoryMb == 8192)

        let (maxModel, _) = makeModel(plan: Self.maxPlan)
        maxModel.memoryMb = 65536
        #expect(maxModel.memoryMb == 65536)
    }

    @Test func sizeLabelsDescribeMemoryAndDisk() {
        #expect(MachineSizeOption(memoryMb: 4096)?.title == "4 GB RAM")
        #expect(MachineSizeOption(memoryMb: 4096)?.detail == "16 GB disk included")
        #expect(MachineSizeOption(memoryMb: 4096)?.diskTitle == "16 GB")
        #expect(MachineSizeOption(memoryMb: 8192)?.title == "8 GB RAM")
        #expect(MachineSizeOption(memoryMb: 8192)?.detail == "32 GB disk included")
        #expect(MachineSizeOption(memoryMb: 8192)?.menuTitle == "8 GB RAM · 32 GB disk")
        #expect(MachineSizeOption(memoryMb: 16384)?.title == "16 GB RAM")
        #expect(MachineSizeOption(memoryMb: 16384)?.detail == "64 GB disk included")
        #expect(MachineSizeOption(memoryMb: 24576)?.title == "24 GB RAM")
        #expect(MachineSizeOption(memoryMb: 24576)?.detail == "96 GB disk included")
        #expect(MachineSizeOption(memoryMb: 32768)?.title == "32 GB RAM")
        #expect(MachineSizeOption(memoryMb: 32768)?.detail == "128 GB disk included")
        #expect(MachineSizeOption(memoryMb: 65536)?.title == "64 GB RAM")
        #expect(MachineSizeOption(memoryMb: 65536)?.detail == "128 GB disk included")
    }

    @Test func serverOptionsAreSortedAndDeduplicated() {
        let plan = MachinePlanSnapshot(activeCount: 0, maxActiveVms: 50, planId: "pro")
        let (model, _) = makeModel(plan: plan, memoryOptionsMb: [16384, 8192, 8192])
        #expect(model.memoryOptions == [8192, 16384])
        #expect(model.memoryMb == 8192)
    }

    @Test func emptyServerOptionsPreserveLegacyDefaultWithoutSizeFlag() {
        let (model, _) = makeModel(memoryOptionsMb: [])
        #expect(model.memoryOptions == [])
        #expect(model.memoryMb == 20480)
        #expect(!model.supportsSize)
        #expect(model.cliArguments == ["vm", "new", "--desktop", "--focus", "false"])
    }

    /// #12239: the sheet's defaults create a machine with a VNC screen; only
    /// the size is user input here, and it travels as `--size`.
    @Test func defaultCreateIsADesktopMachineAtTheSelectedSize() {
        let (model, recorder) = makeModel(plan: Self.maxPlan)
        model.memoryMb = 65536
        model.create()
        let request = recorder.value.first
        #expect(request?.kind == .desktop)
        #expect(request?.name == nil)
        #expect(request?.arguments == ["vm", "new", "--desktop", "--size", "65536", "--focus", "false"])
    }

    @Test func baseSetupHasNoSizeFlagAndDefaultsToADesktop() {
        let workspaceID = UUID()
        let (model, recorder) = makeModel(mode: .base(workspaceID: workspaceID))
        #expect(!model.supportsSize)
        #expect(model.cliArguments == ["vm", "base", "open", "--workspace", workspaceID.uuidString, "--desktop", "--focus", "false"])
        model.create()
        #expect(recorder.value.first?.kind == .desktop)
    }

    @Test func planTextsMirrorTheMeterAndFreeWindow() {
        let free = MachinePlanSnapshot(activeCount: 0, maxActiveVms: 1, planId: "free", freeAccessWindowDays: 7)
        let (model, _) = makeModel(plan: free)
        #expect(model.planMeterText == "0 of 1 machine in use")
        #expect(model.freeAccessNoteText == "Free plan: this machine stays reachable for 7 days. Upgrade to keep it.")
    }

    @Test func createFinishesWithoutWaitingForTheMachine() {
        let (model, recorder) = makeModel()
        var outcomes: [NewMachineModel.Outcome] = []
        model.onFinished = { outcomes.append($0) }
        model.create()
        #expect(recorder.value.count == 1)
        #expect(outcomes == [.submitted])
        #expect(model.outcome == .submitted)
    }

    @Test func launchRefusalStaysInTheSheet() {
        let (model, recorder) = makeModel(starts: false)
        model.create()
        #expect(recorder.value.count == 1)
        #expect(model.outcome == nil)
        #expect(model.errorText != nil)
    }
}
