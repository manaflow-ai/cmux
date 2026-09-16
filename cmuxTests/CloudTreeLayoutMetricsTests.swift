import CoreGraphics
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud tree layout metrics")
struct CloudTreeLayoutMetricsTests {
    private let metrics = CloudTreeLayoutMetrics()

    @Test("document width fills narrow and wide viewports")
    func documentWidthTracksViewport() {
        #expect(metrics.documentWidth(viewportWidth: 180) == 180)
        #expect(metrics.documentWidth(viewportWidth: 420) == 420)
        #expect(metrics.documentWidth(viewportWidth: -1) == 0)
    }

    @Test("document height stays usable before rows load")
    func documentHeightTracksViewport() {
        #expect(metrics.documentHeight(viewportHeight: 300, contentHeight: 0) == 300)
        #expect(metrics.documentHeight(viewportHeight: 300, contentHeight: 520) == 520)
    }

    @Test("title width receives space after stable trailing content")
    func titleWidthReservesControls() {
        #expect(metrics.titleWidth(rowWidth: 420, leadingContentWidth: 92, trailingContentWidth: 76) == 240)
        #expect(metrics.titleWidth(rowWidth: 180, leadingContentWidth: 92, trailingContentWidth: 76) == 0)
    }

    @Test("the content inset matches the former setup entry")
    func referenceInsetIsTwelvePoints() {
        #expect(metrics.referenceInset == 12)
        #expect(CloudTreeRowGrid.trailingPadding == metrics.referenceInset)
    }

    @Test("machine pins persist by account and team and keep stable order")
    @MainActor
    func machinePinsPersistAndOrder() {
        let suite = "cloud-machine-pins-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var scope: String? = "user:a|team:one"
        let first = CloudMachinePinStore(defaults: defaults, scopeProvider: { scope })
        first.reconcile(machineIDs: ["b", "a", "c"])
        first.setPinned(true, machineID: "c")
        first.setPinned(true, machineID: "a")
        #expect(first.orderedMachineIDs(["b", "a", "c"]) == ["c", "a", "b"])

        let restored = CloudMachinePinStore(defaults: defaults, scopeProvider: { scope })
        #expect(restored.orderedMachineIDs(["a", "b", "c"]) == ["c", "a", "b"])
        scope = "user:a|team:two"
        restored.refreshScope()
        #expect(restored.orderedMachineIDs(["a", "b", "c"]) == ["a", "b", "c"])
        scope = "user:a|team:one"
        restored.refreshScope()
        restored.reconcile(machineIDs: ["a", "c"])
        #expect(restored.orderedMachineIDs(["a", "c"]) == ["c", "a"])
    }

    @Test("new machines append after refresh and relaunch without reshuffling existing machines")
    @MainActor
    func newMachinesAppendToRememberedOrder() {
        let suite = "cloud-machine-order-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("old-default", forKey: "cloud.defaultMachineID")
        let store = CloudMachinePinStore(defaults: defaults, scopeProvider: { "team:one" })
        #expect(defaults.object(forKey: "cloud.defaultMachineID") == nil)
        #expect(store.pinnedMachineIDs.isEmpty)
        store.reconcile(machineIDs: ["b", "a", "c"])
        store.setPinned(true, machineID: "c")
        store.reconcile(machineIDs: ["new", "a", "c", "b"])
        #expect(store.orderedMachineIDs(["new", "a", "c", "b"]) == ["c", "b", "a", "new"])
        let restored = CloudMachinePinStore(defaults: defaults, scopeProvider: { "team:one" })
        #expect(restored.orderedMachineIDs(["new", "b", "c", "a"]) == ["c", "b", "a", "new"])
        restored.setPinned(false, machineID: "c")
        restored.reconcile(machineIDs: ["newer", "new", "a", "b", "c"])
        #expect(restored.orderedMachineIDs(["newer", "new", "a", "b", "c"]) == ["c", "b", "a", "new", "newer"])
    }
}
