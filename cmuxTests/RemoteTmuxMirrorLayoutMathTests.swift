import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct RemoteTmuxMirrorLayoutMathTests {
    @Test func verticalStackSubtractsTabBarsAndDividerFromRows() {
        let layout = RemoteTmuxLayoutNode(
            width: 80, height: 24, x: 0, y: 0,
            content: .vertical([
                RemoteTmuxLayoutNode(width: 80, height: 11, x: 0, y: 0, content: .pane(1)),
                RemoteTmuxLayoutNode(width: 80, height: 12, x: 0, y: 12, content: .pane(2)),
            ])
        )

        let grid = RemoteTmuxMirrorLayoutMath.clientGrid(
            layout: layout,
            contentSize: CGSize(width: 800, height: 300),
            cellSize: CGSize(width: 10, height: 10),
            tabBarHeight: 30,
            dividerThickness: 1
        )

        #expect(grid?.columns == 80)
        #expect(grid?.rows == 23)
    }

    @Test func horizontalSplitSubtractsDividerFromColumns() {
        let layout = RemoteTmuxLayoutNode(
            width: 80, height: 24, x: 0, y: 0,
            content: .horizontal([
                RemoteTmuxLayoutNode(width: 39, height: 24, x: 0, y: 0, content: .pane(1)),
                RemoteTmuxLayoutNode(width: 40, height: 24, x: 40, y: 0, content: .pane(2)),
            ])
        )

        let grid = RemoteTmuxMirrorLayoutMath.clientGrid(
            layout: layout,
            contentSize: CGSize(width: 800, height: 300),
            cellSize: CGSize(width: 10, height: 10),
            tabBarHeight: 30,
            dividerThickness: 1
        )

        #expect(grid?.columns == 79)
        #expect(grid?.rows == 27)
    }

    @Test func mixedTreeSubtractsWorstPathChrome() throws {
        let layout = try #require(RemoteTmuxRawLayoutParser.parse(
            "abcd,120x40,0,0{60x40,0,0,4,59x40,61,0[59x20,61,0,5,59x19,61,21,8]}"
        ))

        let grid = RemoteTmuxMirrorLayoutMath.clientGrid(
            layout: layout,
            contentSize: CGSize(width: 1_200, height: 400),
            cellSize: CGSize(width: 10, height: 10),
            tabBarHeight: 30,
            dividerThickness: 1
        )

        #expect(grid?.columns == 119)
        #expect(grid?.rows == 33)
    }

    @Test func dividerFractionUsesParsedTmuxCellSeparators() throws {
        let layout = try #require(RemoteTmuxRawLayoutParser.parse(
            "abcd,120x40,0,0{60x40,0,0,4,59x40,61,0[59x20,61,0,5,59x19,61,21,8]}"
        ))
        guard case .horizontal(let rootChildren) = layout.content else {
            Issue.record("Expected horizontal root")
            return
        }
        #expect(RemoteTmuxMirrorLayoutMath.dividerFraction(
            first: rootChildren[0],
            rest: [rootChildren[1]],
            horizontal: true
        ) == 0.5)

        guard case .vertical(let nestedChildren) = rootChildren[1].content else {
            Issue.record("Expected nested vertical split")
            return
        }
        #expect(RemoteTmuxMirrorLayoutMath.dividerFraction(
            first: nestedChildren[0],
            rest: [nestedChildren[1]],
            horizontal: false
        ) == 0.5)
    }

    @Test func tinyAreaClampsToMinimumGrid() {
        let layout = RemoteTmuxLayoutNode(width: 80, height: 24, x: 0, y: 0, content: .pane(1))
        let grid = RemoteTmuxMirrorLayoutMath.clientGrid(
            layout: layout,
            contentSize: CGSize(width: 20, height: 20),
            cellSize: CGSize(width: 10, height: 10),
            tabBarHeight: 30,
            dividerThickness: 1
        )

        #expect(grid?.columns == 20)
        #expect(grid?.rows == 5)
    }

    @Test func paneTitleUsesCommandThenShellCwdThenNil() {
        #expect(RemoteTmuxMirrorLayoutMath.paneTitle(command: "vim", cwd: "/tmp/project") == "vim")
        #expect(RemoteTmuxMirrorLayoutMath.paneTitle(command: "zsh", cwd: "/tmp/project") == "project")
        #expect(RemoteTmuxMirrorLayoutMath.paneTitle(command: "", cwd: nil) == nil)
    }
}
