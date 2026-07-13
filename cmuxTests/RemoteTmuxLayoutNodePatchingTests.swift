import CmuxRemoteSession
import Testing

@Suite
struct RemoteTmuxLayoutNodePatchingTests {
    @Test
    func patchingLeafRectsRewritesOnlyKnownLeaves() {
        func node(
            _ content: RemoteTmuxLayoutContent, w: Int, h: Int, x: Int = 0, y: Int = 0
        ) -> RemoteTmuxLayoutNode {
            RemoteTmuxLayoutNode(width: w, height: h, x: x, y: y, content: content)
        }
        let tree = node(.horizontal([
            node(.pane(1), w: 50, h: 20),
            node(.vertical([
                node(.pane(2), w: 49, h: 9, x: 51),
                node(.pane(3), w: 49, h: 10, x: 51, y: 10),
            ]), w: 49, h: 20, x: 51),
        ]), w: 100, h: 20)
        let patched = tree.patchingLeafRects([
            1: (x: 0, y: 1, width: 50, height: 19),
            2: (x: 51, y: 1, width: 49, height: 8),
        ])
        guard case let .horizontal(top) = patched.content,
              case let .vertical(right) = top[1].content else {
            Issue.record("structure must be preserved")
            return
        }
        #expect(top[0].y == 1 && top[0].height == 19)
        #expect(right[0].y == 1 && right[0].height == 8)
        #expect(right[1].y == 10 && right[1].height == 10)
        #expect(top[1].width == 49 && top[1].y == 0)
        #expect(patched.width == 100)
    }
}
