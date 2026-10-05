import AppKit
import CmuxCloud
import Observation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A pop-up's ideal width is its widest row. A pop-up pinned to that width
/// (`.fixedSize()`) overflows the fixed-width sheet once a row is long; the
/// sheet's root frame hides that from its fitting size, so this checks every
/// control's frame against the sheet whatever the machine names are.
@MainActor
@Suite("New machine sheet layout")
struct NewMachineSheetLayoutTests {
    private static let longName = String(repeating: "very-long-machine-name-", count: 6) + "end"

    @Test("long base machine names keep every control inside the sheet", arguments: NewMachineSheetLayout.allCases)
    func longBaseMachineNamesStayInsideSheet(layout: NewMachineSheetLayout) {
        for forked in [false, true] {
            let machines = (0..<8).map { index in
                VMSummary(
                    id: "machine-\(index)",
                    provider: "freestyle",
                    status: "running",
                    image: "cmux-devbox",
                    createdAt: 0,
                    displayName: "\(Self.longName)-\(index)"
                )
            }
            let model = NewMachineModel(
                mode: .newMachine,
                plan: MachineSnapshotBuilder.planSnapshot(
                    activeCount: 0,
                    limits: VMPlanLimits(maxActiveVms: 10, planId: "pro", freeAccessWindowDays: 0, memoryOptionsMb: [4096, 8192])
                ),
                memoryOptionsMb: [4096, 8192],
                sourceMachines: machines,
                baseImage: forked ? .machine(machines[2]) : .defaultImage,
                defaults: UserDefaults(suiteName: "NewMachineSheetLayoutTests-\(UUID().uuidString)")!,
                submit: { _ in true }
            )
            assertControlsInsideSheet(model: model, layout: layout, label: "\(layout.rawValue) forked=\(forked)")
        }
    }

    @Test("an unchanged machine list does not rebuild the Base pop-up")
    func unchangedSourceMachinesDoNotInvalidate() {
        let machines = [
            VMSummary(id: "machine-0", provider: "freestyle", status: "running", image: "cmux-devbox", createdAt: 0, displayName: "one"),
        ]
        let model = NewMachineModel(mode: .newMachine, plan: nil, sourceMachines: machines, submit: { _ in true })
        var invalidated = false
        withObservationTracking {
            _ = model.sourceMachines
        } onChange: {
            invalidated = true
        }
        model.applySourceMachines(machines)
        #expect(!invalidated)

        var renamed = machines
        renamed[0].displayName = "two"
        model.applySourceMachines(renamed)
        #expect(invalidated)
    }

    /// Cmd+Y on a nightly account: the sheet opens on its host window with a
    /// cold plan and many base machines, the Cloud cache refreshes the plan,
    /// pool, and machine list while it is up, and then the person picks a
    /// Base machine, which adds the inherited-settings row. Sizing the window
    /// from inside AppKit's layout pass aborted the app here; freezing it at
    /// its first size clips whatever arrives later. The window must end at
    /// the content's ideal size.
    @Test("an open sheet takes the size of content that arrives after it opens")
    func presentedSheetTracksContentThatArrivesLater() throws {
        _ = NSApplication.shared
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        host.identifier = NSUserInterfaceItemIdentifier("cmux.main.newMachineSheetLayoutTests")
        host.isReleasedWhenClosed = false
        host.orderFront(nil)
        defer { host.close() }

        let machines = Self.nightlyMachines(renamedAt: 0)
        let model = NewMachineModel(
            mode: .newMachine,
            plan: nil,
            sourceMachines: machines,
            defaults: UserDefaults(suiteName: "NewMachineSheetLayoutTests-\(UUID().uuidString)")!,
            planIsLoading: true,
            submit: { _ in true }
        )
        NewMachineSheetPresenter.shared.present(model: model, preferredWindow: host, loadPlanFromCache: false)
        defer { model.cancel() }
        let sheet = try #require(host.attachedSheet, "the sheet was not attached to its host window")

        for tick in 0..<12 {
            let pool = CloudVMResourcePool(poolVcpus: 40, poolMemoryMb: 81920, usedVcpus: 32 + tick % 3, usedMemoryMb: 65536)
            model.applyPlan(activeCount: machines.count + tick % 2, limits: VMPlanLimits(
                maxActiveVms: 20,
                planId: "pro",
                freeAccessWindowDays: 0,
                memoryOptionsMb: [4096, 8192, 16384],
                lockedMemoryOptionsMb: [32768, 65536],
                memoryUpgradePlanId: "max",
                resourcePool: pool
            ))
            model.applySourceMachines(Self.nightlyMachines(renamedAt: tick))
            Self.runMainLoopTurns()
        }
        model.selectBaseImage(.machine(model.sourceMachines[3]))
        Self.runMainLoopTurns()

        let ideal = NSHostingView(rootView: NewMachineSheet(model: model)).fittingSize
        let content = sheet.contentRect(forFrameRect: sheet.frame).size
        #expect(abs(content.height - ceil(ideal.height)) <= 1, "sheet content \(content) does not fit its content \(ideal)")
        #expect(abs(content.width - ceil(ideal.width)) <= 1, "sheet content \(content) does not fit its content \(ideal)")
    }

    /// Eight machines whose names a refresh may change, like a busy account.
    private static func nightlyMachines(renamedAt tick: Int) -> [VMSummary] {
        (0..<8).map { index in
            VMSummary(
                id: "vm-\(index)",
                provider: "freestyle",
                status: "running",
                image: "cmux-devbox",
                createdAt: 0,
                displayName: index == tick % 8 ? "cmux-devbox-\(index)-renamed-\(tick)" : "cmux-devbox-\(index)"
            )
        }
    }

    private static func runMainLoopTurns() {
        for _ in 0..<5 {
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.01))
        }
    }

    private func assertControlsInsideSheet(model: NewMachineModel, layout: NewMachineSheetLayout, label: String) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: NewMachineSheet(model: model, layout: layout))
        let size = host.fittingSize

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }

        let popUps = Self.descendants(of: host).compactMap { $0 as? NSPopUpButton }
        let basePopUp = popUps.first { popUp in
            popUp.itemTitles.contains { $0.hasPrefix(Self.longName) }
        }
        #expect(basePopUp != nil, "\(label): the Base pop-up was not rendered")

        let bounds = host.bounds.insetBy(dx: -0.5, dy: -0.5)
        for control in Self.descendants(of: host).compactMap({ $0 as? NSControl }) where !control.isHiddenOrHasHiddenAncestor {
            let frame = control.convert(control.bounds, to: host)
            #expect(
                bounds.contains(frame),
                "\(label): \(type(of: control)) \(frame) overflows the sheet \(host.bounds)"
            )
        }
    }

    private static func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
