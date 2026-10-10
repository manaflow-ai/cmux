import AppKit
import CmuxCloud
import CmuxCloudResizeCore
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

    /// Cmd+Shift+Y on a nightly account: the sheet opens on its host window with a
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

    /// The grid's pop-ups read as one column: each starts at the column's
    /// leading edge at its own width, like the Network pop-up. A pop-up that
    /// fills the column, or hugs its trailing edge, breaks that column.
    @Test("the Base, Size, and Network pop-ups share a leading edge at their own widths")
    func popUpsShareLeadingEdgeAtNaturalWidth() throws {
        let machines = Self.nightlyMachines(renamedAt: 0)
        let model = NewMachineModel(
            mode: .newMachine,
            plan: MachineSnapshotBuilder.planSnapshot(
                activeCount: 0,
                limits: VMPlanLimits(maxActiveVms: 5, planId: "pro", freeAccessWindowDays: 0, memoryOptionsMb: [8192, 16384])
            ),
            memoryOptionsMb: [8192, 16384],
            sourceMachines: machines,
            defaults: UserDefaults(suiteName: "NewMachineSheetLayoutTests-\(UUID().uuidString)")!,
            submit: { _ in true }
        )
        model.applyNetworkCatalog(CloudNetworkPresetCatalog(presets: [], requiredDomains: []))
        let (host, window) = Self.render(
            NewMachineSheet(model: model, layout: .grid)
                .environment(\.accessibilityEnabled, true)
        )
        defer {
            window.contentView = nil
            window.close()
        }

        // SwiftUI attaches the identifier to an accessibility proxy rather than
        // the bridged NSPopUpButton when hosted in-process.
        let base = try #require(
            Self.accessibilityElement("NewMachineSheet.baseImage", in: host),
            "no Base pop-up in the hosted accessibility tree"
        )
        let size = try #require(
            Self.accessibilityElement("NewMachineSheet.size", in: host),
            "no Size pop-up in the hosted accessibility tree"
        )
        let rows = [("Base", base), ("Size", size)]
        let leading = try rows.map { try Self.frame(of: $0.1, in: host).minX }
        #expect(abs(leading[0] - leading[1]) <= 1, "Base starts at \(leading[0]), Size at \(leading[1])")
        for (name, popUp) in rows {
            let frame = try Self.frame(of: popUp, in: host)
            let control = try #require(
                Self.popUp(matching: frame, in: host),
                "no AppKit pop-up matches the \(name) accessibility frame \(frame)"
            )
            let controlFrame = control.convert(control.bounds, to: host)
            #expect(abs(frame.width - controlFrame.width) <= 1, "\(name) accessibility frame \(frame) does not match its control \(controlFrame)")
            #expect(
                controlFrame.width <= control.fittingSize.width + 1,
                "\(name) pop-up is \(controlFrame.width)pt wide; its fitting width is \(control.fittingSize.width)pt"
            )
        }
    }

    private static func render<V: View>(_ view: V) -> (NSHostingView<V>, NSWindow) {
        _ = NSApplication.shared
        let host = NSHostingView(rootView: view)
        let size = host.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.frame = NSRect(origin: .zero, size: size)
        for _ in 0..<3 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
        }
        return (host, window)
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
        let host = NSHostingView(
            rootView: NewMachineSheet(model: model, layout: layout)
                .environment(\.accessibilityEnabled, true)
        )
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

        let basePopUp = Self.accessibilityElement("NewMachineSheet.baseImage", in: host)
        #expect(
            basePopUp != nil,
            "\(label): the Base pop-up was not rendered in the hosted accessibility tree"
        )

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

    /// Finds a SwiftUI accessibility node through the same modern/legacy bridge
    /// used by the app's hosted accessibility tests.
    private static func accessibilityElement(_ identifier: String, in root: NSView) -> NSObject? {
        var pending: [NSObject] = [root]
        var visited = Set<ObjectIdentifier>()
        while !pending.isEmpty {
            let element = pending.removeFirst()
            guard visited.insert(ObjectIdentifier(element)).inserted else { continue }
            if element !== root,
               accessibilityAttribute(.identifier, getter: "accessibilityIdentifier", of: element) as? String == identifier {
                return element
            }
            let children = accessibilityAttribute(.children, getter: "accessibilityChildren", of: element) as? [Any]
            pending += NSAccessibility.unignoredChildren(from: children ?? []).compactMap { $0 as? NSObject }
        }
        return nil
    }

    /// Converts either a hosted NSView or an accessibility proxy frame into
    /// the hosting view's coordinate space.
    private static func frame(of element: NSObject, in host: NSView) throws -> NSRect {
        if let view = element as? NSView { return view.convert(view.bounds, to: host) }
        guard let accessibilityElement = element as? NSAccessibilityElement else {
            throw CocoaError(.featureUnsupported)
        }
        let screenFrame = accessibilityElement.accessibilityFrame()
        guard let window = host.window else { throw CocoaError(.fileNoSuchFile) }
        return host.convert(window.convertFromScreen(screenFrame), from: nil)
    }

    private static func popUp(matching frame: NSRect, in host: NSView) -> NSPopUpButton? {
        descendants(of: host)
            .compactMap { $0 as? NSPopUpButton }
            .filter { !$0.isHiddenOrHasHiddenAncestor }
            .min { lhs, rhs in
                let lhsFrame = lhs.convert(lhs.bounds, to: host)
                let rhsFrame = rhs.convert(rhs.bounds, to: host)
                return distance(from: lhsFrame, to: frame) < distance(from: rhsFrame, to: frame)
            }
    }

    private static func distance(from lhs: NSRect, to rhs: NSRect) -> CGFloat {
        abs(lhs.minX - rhs.minX) + abs(lhs.minY - rhs.minY) + abs(lhs.width - rhs.width) + abs(lhs.height - rhs.height)
    }

    private static func accessibilityAttribute(
        _ attribute: NSAccessibility.Attribute, getter: String, of element: NSObject
    ) -> Any? {
        let modern = NSSelectorFromString(getter)
        if element.responds(to: modern), let value = element.perform(modern)?.takeUnretainedValue() {
            return value
        }
        let names = NSSelectorFromString("accessibilityAttributeNames")
        let legacy = NSSelectorFromString("accessibilityAttributeValue:")
        guard element.responds(to: names), element.responds(to: legacy),
              let attributes = element.perform(names)?.takeUnretainedValue() as? [String],
              attributes.contains(attribute.rawValue) else { return nil }
        return element.perform(legacy, with: attribute.rawValue)?.takeUnretainedValue()
    }
}
