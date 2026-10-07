import CmuxiOSCloudCore
import CmuxiOSFeatureKit
import Foundation
import Testing

struct CloudListModelTests {
    func snapshot(_ state: CloudState, live: Bool = true) -> SourceSnapshot<CloudState> {
        SourceSnapshot(revision: 1, value: state, connection: live ? .live(path: "cloud") : .offline(reason: nil))
    }

    @Test func groupsMachinesAndOffersActionsByStatus() {
        let state = CloudState(machines: [
            CloudMachine(id: "vm_run", status: .running),
            CloudMachine(id: "vm_paused", status: .paused, pauseReason: .noReport),
            CloudMachine(id: "vm_bad", status: .failed, failure: CloudMachineFailure(code: "x", message: "boom", at: Date())),
            CloudMachine(id: "vm_going", status: .deleting),
        ], creating: [CloudPendingCreate(id: IntentKey(rawValue: "k"), name: "new", size: CloudMachineSize())],
            plan: MockCloudMachineSource.sample().plan, isLoaded: true)
        let model = CloudMachineListModel(snapshot: snapshot(state))
        #expect(model.sections.map(\.kind) == [.active, .paused, .failed])
        #expect(model.sections[0].rows.map(\.id) == ["create:k", "vm_run", "vm_going"])
        #expect(model.sections[0].rows[0].isPendingCreate)
        #expect(model.sections[0].rows[1].actions == [.pause, .delete])
        #expect(model.sections[0].rows[2].actions.isEmpty)
        #expect(model.sections[1].rows[0].actions == [.resume, .delete])
        #expect(model.sections[1].rows[0].pauseReason == .noReport)
        #expect(model.sections[2].rows[0].failureMessage == "boom")
        #expect(model.usage?.active == 1)
        #expect(model.usage?.maxActive == 2)
    }

    @Test func offlineOffersNoActions() {
        let state = CloudState(machines: [CloudMachine(id: "vm_run", status: .running)], isLoaded: true)
        let model = CloudMachineListModel(snapshot: snapshot(state, live: false))
        #expect(model.sections[0].rows[0].actions.isEmpty)
        #expect(!model.isLive)
    }

    @Test func createOptionsComeFromThePlan() throws {
        let plan = try #require(MockCloudMachineSource.sample().plan)
        let options = CloudCreateOptions(plan: plan)
        #expect(options.sizes.map(\.memoryMB) == [2048, 4096, 8192, 16384])
        #expect(options.sizes.last?.isLocked == true)
        #expect(options.defaultOption?.memoryMB == 2048)
        #expect(options.canCreate)
        var full = plan
        full.usage.active = full.limits.maxActive
        #expect(!CloudCreateOptions(plan: full).canCreate)
        #expect(!CloudCreateOptions(plan: CloudPlan(planID: "none")).canCreate)
        #expect(CloudCreateOptions.normalizedName("  box  ") == "box")
        #expect(CloudCreateOptions.normalizedName("   ") == nil)
    }

    @Test func firstMachineCreatesTheSmallestUnlockedSize() async {
        let source = MockCloudMachineSource(state: CloudState(plan: MockCloudMachineSource.sample().plan, isLoaded: true))
        let outcome = await CloudFirstMachine(source: source, name: "first").create()
        #expect(outcome == .created)
        let state = await source.hub.current.value
        #expect(state.machines.map(\.name) == ["first"])
        #expect(state.machines.first?.size.memoryMB == 2048)
    }

    @Test func firstMachineReportsAFullPlan() async {
        var state = MockCloudMachineSource.sample()
        state.plan?.usage.active = 2
        let outcome = await CloudFirstMachine(source: MockCloudMachineSource(state: state)).create()
        #expect(outcome == .refused(code: "cloud.quota.exceeded"))
    }
}
