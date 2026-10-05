import CmuxCloud
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("New machine sheet plan readiness")
struct NewMachineSheetPresenterTests {
    @Test("cached plan takes precedence over a stale caller plan")
    func cachedPlanTakesPrecedence() {
        let cached = MachineSnapshotBuilder.planSnapshot(
            activeCount: 0,
            limits: VMPlanLimits(maxActiveVms: 10, planId: "cached", freeAccessWindowDays: 0)
        )
        let caller = MachineSnapshotBuilder.planSnapshot(
            activeCount: 0,
            limits: VMPlanLimits(maxActiveVms: 1, planId: "caller", freeAccessWindowDays: 0)
        )

        #expect(NewMachineSheetPresenter.effectivePlan(cachedPlan: cached, callerPlan: caller)?.planId == "cached")
        #expect(NewMachineSheetPresenter.effectivePlan(cachedPlan: nil, callerPlan: caller)?.planId == "caller")
    }

    @Test("initial cached plan fills a model that opened before the panel refresh")
    func initialCachedPlanIsAppliedBeforePresentation() {
        let model = NewMachineModel(
            mode: .newMachine,
            plan: nil,
            memoryOptionsMb: [],
            submit: { _ in true }
        )
        #expect(model.supportsSize == false)

        let data = NewMachineSheetData(
            hasPlan: true,
            limits: VMPlanLimits(
                planId: "pro",
                freeAccessWindowDays: 0,
                memoryOptionsMb: [4096, 8192]
            ),
            activeCount: 0,
            catalog: nil,
            catalogFailed: false
        )
        NewMachineSheetPresenter.applyInitialData(data, to: model)

        #expect(model.supportsSize)
        #expect(model.memoryOptions == [4096, 8192])
    }

    @Test("a plan can arrive after the sheet opens without enabling Create early")
    func loadingPlanStaysDisabledUntilApplied() {
        let model = NewMachineModel(
            mode: .newMachine,
            plan: nil,
            planIsLoading: true,
            submit: { _ in true }
        )
        #expect(model.planIsLoading)
        #expect(model.supportsSize)
        model.applyPlan(activeCount: 0, limits: VMPlanLimits(
            maxActiveVms: 1,
            planId: "pro",
            freeAccessWindowDays: 0,
            memoryOptionsMb: [4096, 8192]
        ))
        #expect(!model.planIsLoading)
        #expect(model.planLoadError == nil)
        #expect(model.supportsSize)
    }

    @Test("presentation waits for and uses the shared authoritative fleet page")
    func transientFleetMissIsRetried() async {
        var attempts = 0
        let expected = VMListPage(vms: [], limits: VMPlanLimits(
            maxActiveVms: nil,
            planId: "pro",
            freeAccessWindowDays: 0,
            memoryOptionsMb: [4096, 8192, 16384]
        ))
        let model = CloudMenuModel(
            listMachines: {
                attempts += 1
                if attempts == 1 { throw URLError(.networkConnectionLost) }
                return expected
            },
            isAvailable: { true },
            isFeatureEnabled: { true },
            mainMenu: { nil }
        )

        let page = await model.fleetPageForPresentation()

        #expect(page?.limits?.memoryOptionsMb == [4096, 8192, 16384])
        #expect(attempts == 2)
        #expect(model.fleetPage?.limits?.memoryOptionsMb == [4096, 8192, 16384])
    }

    @Test("exhausted retries release presentation without an incomplete page")
    func exhaustedRetries() async {
        var attempts = 0
        let model = CloudMenuModel(
            listMachines: {
                attempts += 1
                throw URLError(.networkConnectionLost)
            },
            isAvailable: { true },
            isFeatureEnabled: { true },
            mainMenu: { nil }
        )
        let page = await model.fleetPageForPresentation()
        #expect(page == nil)
        #expect(attempts == 3)
    }

    @Test("already cancelled presentation starts no fleet request")
    func cancelledPresentation() async {
        var attempts = 0
        let model = CloudMenuModel(
            listMachines: {
                attempts += 1
                return VMListPage(vms: [])
            },
            isAvailable: { true },
            isFeatureEnabled: { true },
            mainMenu: { nil }
        )
        let request = Task { await model.fleetPageForPresentation() }
        request.cancel()
        let page = await request.value
        #expect(page == nil)
        #expect(attempts == 0)
    }
}
