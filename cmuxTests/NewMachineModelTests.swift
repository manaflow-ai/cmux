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
    private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
    }

    private func makeModel(
        mode: NewMachineModel.Mode = .newMachine,
        plan: MachinePlanSnapshot? = nil,
        memoryOptionsMb: [Int] = NewMachineModel.memoryOptionsMb,
        starts: Bool = true
    ) -> (NewMachineModel, Box<[MachineCreateRequest]>) {
        let recorder = Box<[MachineCreateRequest]>([])
        let model = NewMachineModel(mode: mode, plan: plan, memoryOptionsMb: memoryOptionsMb) { request in
            recorder.value.append(request)
            return starts
        }
        return (model, recorder)
    }

    @Test func defaultSizeIsTheSmallestSupportedBaseImage() {
        let (model, _) = makeModel()
        #expect(model.memoryOptions == [4096, 8192, 16384, 24576, 32768, 65536])
        #expect(model.memoryMb == 8192)
        #expect(model.selectedSize == MachineSizeOption(memoryMb: 8192))
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
        #expect(model.cliArguments == ["vm", "new", "--base", "--focus", "false"])
    }

    @Test func selectedSizeTravelsAsBaseSizeFlagOnly() {
        let (model, recorder) = makeModel()
        model.memoryMb = 65536
        model.create()
        let request = recorder.value.first
        #expect(request?.kind == .base)
        #expect(request?.name == nil)
        #expect(request?.arguments == ["vm", "new", "--base", "--size", "65536", "--focus", "false"])
    }

    @Test func baseSetupHasNoSizeFlag() {
        let workspaceID = UUID()
        let (model, _) = makeModel(mode: .base(workspaceID: workspaceID))
        #expect(!model.supportsSize)
        #expect(model.cliArguments == ["vm", "base", "open", "--workspace", workspaceID.uuidString, "--base", "--focus", "false"])
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
