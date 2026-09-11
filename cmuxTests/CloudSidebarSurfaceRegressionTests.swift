import Foundation
import Testing
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Cloud sidebar surface lifecycle")
struct CloudSidebarSurfaceRegressionTests {
    private let machine = SurfaceMachineID.cloud("sidebar-vm")

    private func nodes(link: SurfaceLinkState?, desktop: Bool = true) -> [CloudTreeNode] {
        let row = MachineSnapshot(
            id: machine.rawValue, provider: "freestyle", image: "desktop",
            isDesktop: desktop, activity: .ready, createdAt: nil, label: nil
        )
        let info = link.map {
            SurfaceMachineInfo(
                id: machine, name: machine.rawValue, status: "running", image: "desktop",
                hasDesktop: desktop, memoryMb: nil, diskMb: nil, linkState: $0,
                linkError: $0 == .error ? "Connection failed" : nil,
                cpuPercent: nil, memoryUsedMb: nil, diskUsedMb: nil
            )
        }
        return CloudTreeNodeBuilder.flattened(CloudTreeNodeBuilder.nodes(
            machines: [row],
            snapshot: SurfaceCatalogSnapshot(machines: info.map { [$0] } ?? [], resources: [], projections: []),
            localWorkspaces: [], includeLocalMachine: false
        ))
    }

    @Test("Fleet discovery never leaves a childless machine before registration")
    func awaitingProviderHasLoadingRow() {
        #expect(nodes(link: nil).contains {
            if case .placeholder(_, let value) = $0.kind { return value.style == .connecting }
            return false
        })
    }

    @Test("Desktop capability remains visible before the terminal snapshot", arguments: [SurfaceLinkState.connecting, .error, .asleep, .connected])
    func desktopBeforeSessionSnapshot(link: SurfaceLinkState) {
        #expect(nodes(link: link).contains {
            if case .display(let resource, _, _) = $0.kind { return resource.id.key == SurfaceResourceID.desktopDisplayKey }
            return false
        })
    }

    @Test("Ports distinguish loading, error, asleep, and a successful empty scan", arguments: [SurfaceLinkState.connecting, .error, .asleep, .connected])
    func emptyPortsStayVisible(link: SurfaceLinkState) throws {
        let group = try #require(nodes(link: link, desktop: false).first {
            if case .portsGroup = $0.kind { return true }
            return false
        })
        #expect(group.children.count == 1)
        guard case .placeholder(_, let value) = group.children[0].kind else {
            Issue.record("Ports must explain why there are no rows")
            return
        }
        if link == .connecting { #expect(value.style == .connecting) }
        if link == .error { #expect(value.style == .error) }
    }

    @Test("Shell-only machines do not invent a desktop")
    func noDesktopForBaseMachine() {
        #expect(!nodes(link: .connected, desktop: false).contains {
            if case .display = $0.kind { return true }
            return false
        })
    }
}

@MainActor
@Suite("Cloud sidebar organization persistence")
struct CloudSidebarOrganizationTests {
    private func folder(_ id: String, children: [CloudTreeNode] = []) -> CloudTreeNode {
        CloudTreeNode(id: id, kind: .workspacesGroup(machine: .cloud("vm")), children: children)
    }

    @Test func reorderPinsAndMissingRowsSurviveRestart() throws {
        let suite = "cloud-organization-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudTreeOrganizationStore(defaults: defaults)
        let original = [folder("a"), folder("b"), folder("c")]
        #expect(store.move("c", by: -1, in: original))
        #expect(store.arranged(original).map(\.id) == ["a", "c", "b"])
        store.togglePin("b", in: original)
        #expect(store.arranged(original).map(\.id) == ["b", "a", "c"])
        #expect(!store.canMove("b", by: 1, in: original))
        #expect(!store.canMove("a", by: -1, in: original))

        // The reconnect can remove all rows or only one folder temporarily.
        #expect(store.arranged([]).isEmpty)
        #expect(store.move("c", by: -1, in: [original[0], original[2]]))
        let restored = CloudTreeOrganizationStore(defaults: defaults)
        let refreshed = [folder("c"), folder("b"), folder("a"), folder("new")]
        #expect(restored.arranged(refreshed).map(\.id) == ["b", "c", "a", "new"])
        #expect(restored.arranged(refreshed).first?.isPinned == true)
        restored.togglePin("b", in: refreshed)
        #expect(restored.arranged(refreshed).map(\.id) == ["b", "c", "a", "new"])
        #expect(restored.arranged(refreshed).allSatisfy { !$0.isPinned })
    }

    @Test func nestedMovesNeverReparentOrMutateSource() throws {
        let suite = "cloud-organization-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = CloudTreeOrganizationStore(defaults: defaults)
        let tree = [folder("one", children: [folder("a"), folder("b")]), folder("two")]
        #expect(!store.move("b", parentID: "two", to: 0, in: tree))
        #expect(store.move("b", parentID: "one", to: 0, in: tree))
        #expect(store.arranged(tree)[0].children.map(\.id) == ["b", "a"])
        #expect(tree[0].children.map(\.id) == ["a", "b"])
        store.togglePin("a", in: tree)
        #expect(store.arranged(tree)[0].children.map(\.id) == ["a", "b"])
        #expect(store.arranged(tree).map(\.id) == ["one", "two"])
    }
}
