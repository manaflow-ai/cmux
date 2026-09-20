import AppKit
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CloudWorkspaceCreationSidebarTests {
    @Test("Both workspace sidebars share the create receipt before daemon refresh", arguments: [false, true])
    func receiptAppearsBeforeRefresh(focus: Bool) async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let fixture = try CloudWorkspaceCreationSidebarFixture()
            defer { fixture.close() }
            let originalIDs = Set(fixture.manager.tabs.map(\.id))
            var pendingID: UUID?
            fixture.provider.beforeRefresh = {
                let created = fixture.manager.tabs.filter { !originalIDs.contains($0.id) }
                #expect(created.count == 1, "The left navigator must contain the new workspace before refresh returns")
                pendingID = created.first?.id
                let row = try #require(fixture.workspaceRows().first)
                if case .workspace(_, _, _, _, let openIn) = row.kind {
                    #expect(openIn != nil, "The Cloud row must navigate to the same pending local workspace")
                    #expect(openIn == pendingID)
                }
                // Completion must not select over navigation performed while connecting.
                fixture.manager.selectedTabId = fixture.originalWorkspaceID
            }
            let result = try await CloudTreeNodeActions.createWorkspaceAndOpenLocally(
                machine: fixture.provider.machine, provider: fixture.provider, catalog: fixture.catalog,
                name: nil, focus: focus
            )
            let opened = try #require(result.opened)
            #expect(opened.workspaceID == pendingID)
            #expect(fixture.manager.tabs.filter { !originalIDs.contains($0.id) }.count == 1)
            #expect(fixture.workspaceRows().count == 1)
            #expect(fixture.catalog.projections.filter { $0.workspaceID == opened.workspaceID }.count == 1)
            #expect(fixture.manager.selectedTabId == fixture.originalWorkspaceID)
            #expect(fixture.provider.terminalCreates == 0, "A starter receipt must not spawn another terminal")
        }
    }
}
