import CmuxConversationGeometry
import Testing

struct ConversationMenuGlassTests {
    /// Messages' long-press menu (a UIKit context menu) reads 237,237,239
    /// over its 206,206,210 veil on iOS 26.5; a plain regular glass of that
    /// size reads 239,239,242, bluer and lighter. A faint warm-gray tint
    /// lands it on 237,237,239 (fitted in a glass probe at the menu's size).
    @Test func longPressLightGlassMatchesContextMenuPlatter() {
        let tint = ConversationMenuGlassTint.longPressLightIOS26
        #expect(tint == ConversationMenuGlassTint(red: 0.94, green: 0.94, blue: 0.938, alpha: 0.3))
    }

    /// iOS 27.0: Messages' menu reads 230,230,230 over its neutral 204 veil,
    /// where a plain regular glass of our menu's size reads 237,237,237. A
    /// 9 % mid-gray tint lands on 230 (glass probe at 250 x 241 pt).
    @Test func longPressLightGlassMatchesContextMenuPlatterOnIOS27() {
        let tint = ConversationMenuGlassTint.longPressLightIOS27
        #expect(tint == ConversationMenuGlassTint(red: 0.5, green: 0.5, blue: 0.5, alpha: 0.09))
    }
}

/// The long-press menu's place and veil (Messages, iPhone 17 Pro).
struct MessageMenuPlacementTests {
    /// iOS 27: an outgoing bubble's menu ends at the bubble's trailing edge,
    /// 16 pt from the screen (Reply at x 136, 250 wide); ours stopped 20 pt in.
    @Test func outgoingMenuReachesSixteenPointsFromTheEdge() {
        let x = MessageMenuGeometry.menuX(previewMinX: 316.3, previewMaxX: 386, isOutgoing: true, width: 402, menuWidth: 250)
        #expect(x == 136)
        #expect(MessageMenuGeometry.menuX(previewMinX: 16, previewMaxX: 120, isOutgoing: false, width: 402, menuWidth: 250) == 16)
        #expect(MessageMenuGeometry.menuX(previewMinX: 300, previewMaxX: 400, isOutgoing: true, width: 402, menuWidth: 250) == 136)
    }

    /// iOS 27 dark: the transcript and header behind the menu drop to ~0.52
    /// of their brightness (avatar fill 53.7 -> 28.0, gray labels 141 -> 73);
    /// light keeps white -> 204.
    @Test func iOS27VeilIsDeeperInDark() {
        #expect(MessageMenuGeometry.neutralVeilAlpha(dark: true) == 0.48)
        #expect(MessageMenuGeometry.neutralVeilAlpha(dark: false) == 0.2)
    }
}
