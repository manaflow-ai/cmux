import AppKit
import CmuxCloud
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A pop-up's ideal width is its widest row. A pop-up pinned to that width
/// (`.fixedSize()`) overflows the fixed-width sheet once a row is long, and
/// the overflowing layout crashed the app with an AppKit "Update Constraints
/// in Window" loop while the sheet opened (Cmd+Y). Every control must stay
/// inside the sheet whatever the machine names are.
@MainActor
@Suite("New machine sheet layout")
struct NewMachineSheetLayoutTests {
    private static let longName = String(repeating: "very-long-machine-name-", count: 6) + "end"

    @Test("long base machine names keep every control inside the sheet", arguments: NewMachineSheetLayout.allCases)
    func longBaseMachineNamesStayInsideSheet(layout: NewMachineSheetLayout) {
        for forked in [false, true] {
            let machines = (0..<3).map { index in
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

    private func assertControlsInsideSheet(model: NewMachineModel, layout: NewMachineSheetLayout, label: String) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: NewMachineSheet(model: model, layout: layout))
        let size = host.fittingSize
        #expect(size.width <= layout.width + 0.5, "\(label): sheet is \(size.width) wide, layout is \(layout.width)")

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
