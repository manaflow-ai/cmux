@testable import CmuxLiteCore
import Foundation
import Testing

@Suite
struct CmuxWorkspaceTreeTests {
    @Test
    func selectsActivePTYFromFirstWorkspace() throws {
        let json = Data(
            #"{"workspaces":[{"id":4,"name":"one","active":true,"screens":[{"id":3,"name":null,"active":true,"active_pane":2,"panes":[{"id":2,"name":null,"active_tab":1,"tabs":[{"surface":9,"kind":"browser","name":null,"title":"web","size":null,"dead":false},{"surface":11,"kind":"pty","name":null,"title":"shell","size":{"cols":80,"rows":24},"dead":false}]}]}]},{"id":8,"name":"two","active":false,"screens":[]}] }"#.utf8
        )
        let tree = try JSONDecoder().decode(CmuxWorkspaceTree.self, from: json)

        #expect(tree.selectedSurface() == 11)
    }

    @Test
    func fallsBackToFirstLivePTYWhenActiveTabIsBrowser() throws {
        let json = Data(
            #"{"workspaces":[{"id":4,"name":"one","active":true,"screens":[{"id":3,"name":null,"active":true,"active_pane":2,"panes":[{"id":2,"active_tab":0,"tabs":[{"surface":9,"kind":"browser","name":null,"title":"web","size":null,"dead":false},{"surface":12,"kind":"pty","name":null,"title":"shell","size":null,"dead":false}]}]}]}]}"#.utf8
        )
        let tree = try JSONDecoder().decode(CmuxWorkspaceTree.self, from: json)

        #expect(tree.selectedSurface() == 12)
    }
}
