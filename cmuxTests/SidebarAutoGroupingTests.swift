import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Sidebar automatic Group By sections")
struct SidebarAutoGroupingTests {
    private func input(
        _ id: UUID = UUID(),
        host: SidebarAutoGroupingHost = .local,
        status: SidebarAutoGroupingStatus = .terminals
    ) -> SidebarAutoGroupingInput {
        SidebarAutoGroupingInput(workspaceId: id, host: host, status: status)
    }

    @Test func manualModeDerivesNoSections() {
        let grouping = SidebarAutoGrouping(mode: .manual)
        let only = input()
        #expect(grouping.sections(for: [only]).isEmpty)
        #expect(grouping.sectionKey(for: only) == nil)
    }

    @Test func hostDropsUserPrefixSoLoginsToOneHostShareASection() {
        let first = UUID()
        let second = UUID()
        let sections = SidebarAutoGrouping(mode: .host).sections(for: [
            input(first, host: .remote(target: "leo@build-box")),
            input(second, host: .remote(target: "root@Build-Box")),
        ])
        #expect(sections.count == 1)
        #expect(sections.first?.title == "build-box")
        #expect(sections.first?.symbol == "network")
        #expect(sections.first?.workspaceIds == [first, second])
        #expect(SidebarAutoGroupingHost.hostName(fromTarget: "leo@box:2222") == "box:2222")
        #expect(SidebarAutoGroupingHost.hostName(fromTarget: "box") == "box")
    }

    @Test func hostOrdersThisMacThenHostsByNameThenCloudVMs() {
        let sections = SidebarAutoGrouping(mode: .host).sections(for: [
            input(host: .cloud(vmID: "vm-2", label: "Alpha VM")),
            input(host: .remote(target: "zeta")),
            input(host: .local),
            input(host: .remote(target: "me@alpha")),
            input(host: .cloud(vmID: "vm-1", label: nil)),
        ])
        #expect(sections.map(\.key) == [
            "host:local",
            "host:remote:alpha",
            "host:remote:zeta",
            "host:cloud:vm-2",
            "host:cloud:vm-1",
        ])
        #expect(sections.first?.symbol == "laptopcomputer")
        #expect(sections.last?.symbol == "cloud")
        #expect(sections[3].title == "Alpha VM")
    }

    @Test func eachCloudVMGetsItsOwnSection() {
        let sections = SidebarAutoGrouping(mode: .host).sections(for: [
            input(host: .cloud(vmID: "vm-a", label: nil)),
            input(host: .cloud(vmID: "vm-b", label: nil)),
        ])
        #expect(Set(sections.map(\.key)) == ["host:cloud:vm-a", "host:cloud:vm-b"])
        #expect(Set(sections.map(\.groupId)).count == 2)
    }

    struct StatusCase: Sendable, CustomTestStringConvertible {
        let states: [AgentHibernationLifecycleState]
        let unreadCount: Int
        let expected: SidebarAutoGroupingStatus
        var testDescription: String { "\(states) unread=\(unreadCount) -> \(expected)" }
    }

    @Test(arguments: [
        StatusCase(states: [.running, .needsInput], unreadCount: 3, expected: .needsInput),
        StatusCase(states: [.idle, .running], unreadCount: 3, expected: .running),
        StatusCase(states: [.idle], unreadCount: 1, expected: .unread),
        StatusCase(states: [], unreadCount: 2, expected: .unread),
        StatusCase(states: [.idle, .unknown], unreadCount: 0, expected: .idle),
        StatusCase(states: [], unreadCount: 0, expected: .terminals),
    ])
    func statusPrecedenceIsLoudestFirst(_ testCase: StatusCase) {
        #expect(
            SidebarAutoGroupingStatus(
                agentLifecycleStates: testCase.states,
                unreadCount: testCase.unreadCount
            ) == testCase.expected
        )
    }

    @Test func statusSectionsFollowPrecedenceAndOmitEmptyOnes() {
        let sections = SidebarAutoGrouping(mode: .status).sections(for: [
            input(status: .terminals),
            input(status: .needsInput),
            input(status: .idle),
        ])
        #expect(sections.map(\.key) == ["status:needs-input", "status:idle", "status:terminals"])
        #expect(sections.map(\.symbol) == ["exclamationmark.bubble", "checkmark.circle", "terminal"])
    }

    @Test func sectionsKeepTabsOrderForTheirMembers() {
        let ids = (0..<5).map { _ in UUID() }
        let sections = SidebarAutoGrouping(mode: .status).sections(for: [
            input(ids[0], status: .running),
            input(ids[1], status: .terminals),
            input(ids[2], status: .running),
            input(ids[3], status: .terminals),
            input(ids[4], status: .running),
        ])
        #expect(sections.map(\.workspaceIds) == [[ids[0], ids[2], ids[4]], [ids[1], ids[3]]])
    }

    @Test func syntheticGroupIdsAreStableAcrossRendersAndLaunches() {
        let local = SidebarAutoGroupingSection.groupId(forKey: "host:local")
        #expect(local == SidebarAutoGroupingSection.groupId(forKey: "host:local"))
        // Pinned value: the id must not depend on the process, so a relaunch
        // keeps the AppKit table and SwiftUI row identity.
        #expect(local.uuidString == "85A08E00-509E-863A-B32C-8F10760FFC17")
        #expect(local != SidebarAutoGroupingSection.groupId(forKey: "status:running"))
        // Version 8 nibble: never collides with a random version 4 id.
        #expect(local.uuidString[local.uuidString.index(local.uuidString.startIndex, offsetBy: 14)] == "8")
    }

    @Test func snapshotDecodesGroupByModeWithDefaults() throws {
        let decoder = JSONDecoder()
        let legacy = try decoder.decode(
            SessionTabManagerSnapshot.self,
            from: Data(#"{"workspaces":[]}"#.utf8)
        )
        #expect(legacy.sidebarGroupBy == nil)
        let host = try decoder.decode(
            SessionTabManagerSnapshot.self,
            from: Data(#"{"workspaces":[],"sidebarGroupBy":"host"}"#.utf8)
        )
        #expect(host.sidebarGroupBy == .host)
        let future = try decoder.decode(
            SessionTabManagerSnapshot.self,
            from: Data(#"{"workspaces":[],"sidebarGroupBy":"project"}"#.utf8)
        )
        #expect(future.sidebarGroupBy == .manual)
    }
}
