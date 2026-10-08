import CmuxCloud
import Foundation
import Observation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("New machine model")
@MainActor
struct NewMachineModelTests {
    @Test func lockedLadderCannotSubmitThroughTheModel() {
        var didSubmit = false
        let model = NewMachineModel(
            mode: .newMachine,
            plan: Self.proPlan,
            memoryOptionsMb: [32768],
            lockedMemoryOptionsMb: [32768],
            submit: { _ in didSubmit = true; return true }
        )
        model.create()
        #expect(model.hasNoAllowedMemoryOptions)
        #expect(!didSubmit)
        #expect(model.outcome == nil)
    }

    @Test("reapplying identical plan data does not invalidate the sheet")
    func identicalPlanRefreshIsANoOpForObservation() {
        let limits = VMPlanLimits(
            maxActiveVms: 10,
            planId: "pro",
            freeAccessWindowDays: 0,
            memoryOptionsMb: [4096, 8192]
        )
        let model = NewMachineModel(
            mode: .newMachine,
            plan: MachineSnapshotBuilder.planSnapshot(activeCount: 2, limits: limits),
            memoryOptionsMb: limits.memoryOptionsMb,
            submit: { _ in true }
        )
        var invalidated = false
        withObservationTracking {
            _ = model.plan
            _ = model.memoryOptions
            _ = model.lockedMemoryOptions
            _ = model.planIsLoading
        } onChange: {
            invalidated = true
        }

        model.applyPlan(activeCount: 2, limits: limits)

        #expect(!invalidated)
    }

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

    private static let proPlan = MachinePlanSnapshot(activeCount: 0, maxActiveVms: 5, planId: "pro")
    private static let maxPlan = MachinePlanSnapshot(activeCount: 0, maxActiveVms: 5, planId: "max")

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
        #expect(recorder.value.first?.arguments == ["vm", "new", "--desktop", "--size", "8192", "--agent-updates", "latest", "--focus", "false"])
        let workspaceID = UUID()
        let (base, baseRecorder) = makeModel(mode: .base(workspaceID: workspaceID))
        base.create()
        #expect(baseRecorder.value.first?.kind == .desktop)
        #expect(baseRecorder.value.first?.arguments == ["vm", "base", "open", "--workspace", workspaceID.uuidString, "--desktop", "--focus", "false"])
    }

    @Test func selectingAMachineUsesTheForkCommandAsTheCreateSource() {
        let source = VMSummary(id: "vm-source", provider: "freestyle", status: "running", image: "sh-source", createdAt: 0, displayName: "Build machine")
        let (model, recorder) = makeModel()
        model.applySourceMachines([source])
        model.baseImage = .machine(source)
        #expect(model.baseImage.label == "Build machine")
        #expect(model.cliArguments == ["vm", "fork", "vm-source", "--focus", "false"])
        model.create()
        #expect(recorder.value.first?.arguments == ["vm", "fork", "vm-source", "--focus", "false"])
        // The pending row names the fork and its progress, not a generic new machine.
        #expect(recorder.value.first?.forkSourceName == "Build machine")
        #expect(recorder.value.first?.displayName == "Fork of Build machine")
        #expect(recorder.value.first?.progressLabel == "Forking…")
    }

    @Test("Base picker source refreshes keep machine IDs unique")
    func sourceRefreshDeduplicatesMachineIDs() {
        let first = VMSummary(id: "same", provider: "freestyle", status: "running", image: "a", createdAt: 0, displayName: "first")
        let duplicate = VMSummary(id: "same", provider: "freestyle", status: "running", image: "b", createdAt: 1, displayName: "duplicate")
        let (model, _) = makeModel()

        model.applySourceMachines([first, duplicate])

        #expect(model.sourceMachines.map(\.id) == ["same"])
        #expect(model.sourceMachines.first?.displayName == "first")
    }

    @Test func defaultSizeIsTheSmallestSupportedBaseImage() {
        let (model, _) = makeModel(plan: Self.maxPlan)
        #expect(model.memoryOptions == [4096, 8192, 16384, 24576, 32768, 65536])
        #expect(model.memoryMb == 8192)
        #expect(model.selectedSize == MachineSizeOption(memoryMb: 8192))
    }

    /// The client mirror of the server ladder: Pro, Team, and Founder's
    /// Edition stop at 32 GB, and only the 64 GB row is locked and sold by Max.
    @Test func proPlanLocksTheMaxSizesWhenTheServerOmitsThem() {
        let (model, _) = makeModel(plan: Self.proPlan)
        #expect(model.memoryOptions == [4096, 8192, 16384, 24576, 32768])
        #expect(model.lockedMemoryOptions == [65536])
        #expect(model.memoryUpgradePlanId == "max")
        #expect(model.memoryUpgradePlanName == "Max")
        #expect(model.lockedSizesNoteText == "64 GB machines need cmux Max.")
        #expect(model.memoryUpgradeButtonTitle == "Upgrade to Max")
        #expect(model.lockedSizeMenuTitle(MachineSizeOption(memoryMb: 65536)!) == "32 vCPU · 64 GB RAM · 128 GB disk · Requires Max")
        #expect(NewMachineModel.maxMemoryMb(planId: "pro") == 32768)
        #expect(NewMachineModel.maxMemoryMb(planId: "team") == 32768)
        #expect(NewMachineModel.maxMemoryMb(planId: "founders") == 32768)
        #expect(NewMachineModel.maxMemoryMb(planId: "go") == 4096)
        #expect(NewMachineModel.maxMemoryMb(planId: "free") == 8192)
        #expect(NewMachineModel.maxMemoryMb(planId: nil) == 8192)
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
        #expect(model.memoryMb == 32768)
        model.memoryMb = 16384
        #expect(model.memoryMb == 16384)
        model.memoryMb = 4096
        #expect(model.memoryMb == 4096)
        model.memoryMb = 65536
        model.create()
        #expect(recorder.value.first?.arguments == ["vm", "new", "--desktop", "--size", "32768", "--agent-updates", "latest", "--focus", "false"])

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
        #expect(MachineSizeOption(memoryMb: 8192)?.menuTitle == "4 vCPU · 8 GB RAM · 32 GB disk")
        #expect(MachineSizeOption(memoryMb: 24576)?.menuTitle == "12 vCPU · 24 GB RAM · 96 GB disk")
        #expect(MachineSizeOption(memoryMb: 65536)?.menuTitle == "32 vCPU · 64 GB RAM · 128 GB disk")
        #expect(MachineSizeOption(memoryMb: 16384)?.title == "16 GB RAM")
        #expect(MachineSizeOption(memoryMb: 16384)?.detail == "64 GB disk included")
        #expect(MachineSizeOption(memoryMb: 24576)?.title == "24 GB RAM")
        #expect(MachineSizeOption(memoryMb: 24576)?.detail == "96 GB disk included")
        #expect(MachineSizeOption(memoryMb: 32768)?.title == "32 GB RAM")
        #expect(MachineSizeOption(memoryMb: 32768)?.detail == "128 GB disk included")
        #expect(MachineSizeOption(memoryMb: 65536)?.title == "64 GB RAM")
        #expect(MachineSizeOption(memoryMb: 65536)?.detail == "128 GB disk included")
    }

    @Test func sizeLabelsUseTheServersVcpusWhenSent() {
        let served = NewMachineModel(
            mode: .newMachine,
            plan: Self.proPlan,
            memoryOptionsMb: [8192, 16384],
            vcpusByMemoryMb: ["8192": 6],
            submit: { _ in true }
        )
        #expect(served.sizeOption(memoryMb: 8192)?.menuTitle == "6 vCPU · 8 GB RAM · 32 GB disk")
        // A size the server left out, and an older server, fall back to the ladder table.
        #expect(served.sizeOption(memoryMb: 16384)?.vcpus == 8)
        let legacy = NewMachineModel(mode: .newMachine, plan: Self.proPlan, memoryOptionsMb: [8192], submit: { _ in true })
        #expect(legacy.selectedSize?.vcpus == 4)
    }

    /// The shared pool explains a size that does not fit what is free, memory
    /// first, offers Max only below Max, and never blocks the create itself.
    @Test func selectedSizeThatOverflowsThePoolExplainsWhy() {
        let pool = CloudVMResourcePool(poolVcpus: 20, poolMemoryMb: 40960, usedVcpus: 16, usedMemoryMb: 32768)
        let plan = MachinePlanSnapshot(activeCount: 2, maxActiveVms: 5, planId: "pro", resourcePool: pool)
        let (model, recorder) = makeModel(plan: plan, lockedMemoryOptionsMb: [65536])
        #expect(model.poolUsageText == pool.usageText)
        model.memoryMb = 8192
        #expect(model.selectedSizePoolShortfallText == nil)
        model.memoryMb = 16384
        #expect(model.selectedSizePoolShortfallText == CloudVMResourcePool.shortfallText(
            .memory(requestedMb: 16384, freeMb: 8192, poolMb: 40960), offersUpgrade: true
        ))
        model.create()
        #expect(recorder.value.count == 1)

        let maxPool = CloudVMResourcePool(poolVcpus: 80, poolMemoryMb: 163840, usedVcpus: 78, usedMemoryMb: 32768)
        let maxPlan = MachinePlanSnapshot(activeCount: 1, maxActiveVms: 5, planId: "max", resourcePool: maxPool)
        let (maxModel, _) = makeModel(plan: maxPlan)
        maxModel.memoryMb = 8192
        #expect(maxModel.selectedSizePoolShortfallText == CloudVMResourcePool.shortfallText(
            .vcpus(requested: 4, free: 2, pool: 80), offersUpgrade: false
        ))

        let (legacy, _) = makeModel(plan: Self.proPlan)
        #expect(legacy.poolUsageText == nil)
        #expect(legacy.selectedSizePoolShortfallText == nil)
    }

    @Test func serverOptionsAreSortedAndDeduplicated() {
        let plan = MachinePlanSnapshot(activeCount: 0, maxActiveVms: 50, planId: "pro")
        let (model, _) = makeModel(plan: plan, memoryOptionsMb: [16384, 8192, 8192], lockedMemoryOptionsMb: [])
        #expect(model.memoryOptions == [8192, 16384])
        #expect(model.memoryMb == 8192)
    }

    @Test func emptyServerOptionsPreserveLegacyDefaultWithoutSizeFlag() {
        let (model, _) = makeModel(memoryOptionsMb: [])
        #expect(model.memoryOptions == [])
        #expect(model.memoryMb == 20480)
        #expect(!model.supportsSize)
        #expect(model.cliArguments == ["vm", "new", "--desktop", "--agent-updates", "latest", "--focus", "false"])
    }

    /// #12239: the sheet's defaults create a machine with a VNC screen; only
    /// the size is user input here, and it travels as `--size`.
    @Test func defaultCreateIsADesktopMachineAtTheSelectedSize() {
        let (model, recorder) = makeModel(plan: Self.maxPlan)
        model.memoryMb = 32768
        model.create()
        let request = recorder.value.first
        #expect(request?.kind == .desktop)
        #expect(request?.name == nil)
        #expect(request?.arguments == ["vm", "new", "--desktop", "--size", "32768", "--agent-updates", "latest", "--focus", "false"])
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
