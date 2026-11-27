import AppKit
import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Hosted Cloud tree invalidation", .serialized)
struct CloudTreeHostedUpdateTests {
    @Test("Real SwiftUI renders and native disclosure share the cached tree", arguments: [false, true])
    func hostedDisclosureAndUnrelatedDefaultsRender(usePrivatePreferences: Bool) async throws {
        let fixture = CloudSidebarOrderingFixture()
        defer { fixture.close() }
        let trace = Trace()
        let persistence: any CloudTreeExpansionPersistence = usePrivatePreferences
            ? CloudTreeExpansionPreferences(applicationID: fixture.defaultsName) : fixture.defaults
        let view = Host(
            defaults: fixture.defaults, expansion: CloudTreeExpansionStore(defaults: persistence),
            actions: fixture.coordinator.machineActions, nodeActions: fixture.coordinator.nodeActions,
            trace: trace
        )
        let host = NSHostingView(rootView: view)
        fixture.window.contentView = host
        let pump = AppKitTestEventPump()
        #expect(await pump.waitUntil {
            host.layoutSubtreeIfNeeded()
            return trace.builds > 0
        })
        let outline = try #require(Self.outline(in: host))
        let coordinator = try #require(outline.delegate as? CloudTreeOutlineView.Coordinator)
        let section = try #require(coordinator.nodes.first)
        await pump.drain()
        host.layoutSubtreeIfNeeded()
        let originalRows = outline.numberOfRows
        let initialBuilds = trace.builds
        let bodiesBeforeToggle = trace.bodies
        for _ in 0..<10 {
            outline.collapseItem(section)
            #expect(outline.numberOfRows < originalRows)
            outline.expandItem(section)
            #expect(outline.numberOfRows == originalRows)
        }
        await pump.drain()
        host.layoutSubtreeIfNeeded()
        #expect(trace.builds == initialBuilds)
        print("Cloud hosted disclosure privatePreferences=\(usePrivatePreferences) toggles=20 parentRenders=\(trace.bodies - bodiesBeforeToggle) nodeBuilds=\(trace.builds - initialBuilds)")

        // A real AppStorage change rebuilds the parent and its action closures.
        // The machine/catalog inputs stay equal, so updateNSView must skip nodes.
        fixture.defaults.set(1, forKey: Host.revisionKey)
        #expect(await pump.waitUntil {
            host.layoutSubtreeIfNeeded()
            return trace.renderedRevision == 1
        })
        #expect(trace.bodies > bodiesBeforeToggle)
        #expect(trace.builds == initialBuilds)
        #expect(coordinator.nodes.first === section)

        // Click/open and keyboard disclosure converge on the AppKit delegate.
        outline.selectRowIndexes(IndexSet(integer: outline.row(forItem: section)), byExtendingSelection: false)
        coordinator.performDisclosure(.collapse)
        #expect(!outline.isItemExpanded(section))
        coordinator.performDisclosure(.expand)
        #expect(outline.isItemExpanded(section))
        coordinator.open(section)
        #expect(!outline.isItemExpanded(section))
        if usePrivatePreferences { try fixture.attachScreenshot(named: "cloud-machines-collapsed", of: host) }
        coordinator.open(section)
        #expect(outline.isItemExpanded(section))
        if usePrivatePreferences { try fixture.attachScreenshot(named: "cloud-machines-expanded", of: host) }
        #expect(trace.builds == initialBuilds)
    }

    private static func outline(in view: NSView) -> CloudTreeNSOutlineView? {
        if let outline = view as? CloudTreeNSOutlineView { return outline }
        return view.subviews.lazy.compactMap { outline(in: $0) }.first
    }

    @MainActor private final class Trace {
        var builds = 0
        var bodies = 0
        var renderedRevision = -1
        var lastBuildRevision = -1
    }

    @MainActor private struct Host: View {
        static let revisionKey = "test.cloudTree.parentRevision"
        @AppStorage private var revision: Int
        let expansion: CloudTreeExpansionStore
        let actions: MachineRowActions
        let nodeActions: CloudTreeNodeActions
        let trace: Trace
        private let machines = (0..<100).map {
            MachineSnapshot(id: "hosted-\($0)", provider: "freestyle", image: "test", isDesktop: false, activity: .ready)
        }

        init(defaults: UserDefaults, expansion: CloudTreeExpansionStore,
             actions: MachineRowActions, nodeActions: CloudTreeNodeActions, trace: Trace) {
            _revision = AppStorage(wrappedValue: 0, Self.revisionKey, store: defaults)
            self.expansion = expansion
            self.actions = actions
            self.nodeActions = nodeActions
            self.trace = trace
        }

        var body: some View {
            // Test-only instrumentation; Trace is not observable view state.
            let _ = trace.bodies += 1
            let _ = trace.renderedRevision = self.revision
            let revision = self.revision
            CloudTreeOutlineView(
                machines: machines, snapshot: .empty, localWorkspaces: [],
                machineActions: actions, nodeActions: nodeActions, expansionStore: expansion,
                style: .defaultStyle, source: .cloudWithDevicesSection,
                nodeBuilder: { inputs in
                    trace.lastBuildRevision = revision
                    trace.builds += 1
                    return inputs.nodes()
                }
            )
        }
    }
}
