import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Usage tips")
struct UsageTipsTests {
    private let catalog = UsageTipsCatalog(tips: [
        UsageTip(id: .globalSearch, title: "Global", body: "Global body", shortcutAction: .globalSearch),
        UsageTip(id: .canvasLayout, title: "Canvas", body: "Canvas body", shortcutAction: .toggleCanvasLayout),
        UsageTip(id: .splitZoom, title: "Zoom", body: "Zoom body", shortcutAction: .toggleSplitZoom),
    ])

    @Test func selectionUsesCuratedOrderAndUnseenTipsOnly() {
        #expect(catalog.nextUnseenTip(seenTipIDs: [])?.id == .globalSearch)
        #expect(catalog.nextUnseenTip(seenTipIDs: [UsageTipID.globalSearch.rawValue])?.id == .canvasLayout)
        #expect(catalog.unseenTips(seenTipIDs: [UsageTipID.canvasLayout.rawValue]).map(\.id) == [
            .globalSearch,
            .splitZoom,
        ])
    }

    @Test func selectionExhaustsWhenEveryTipWasSeen() {
        let seen = Set(catalog.tips.map { $0.id.rawValue })
        #expect(catalog.nextUnseenTip(seenTipIDs: seen) == nil)
    }

    @MainActor
    @Test func shortcutResolverUsesTheCurrentResolvedBinding() {
        let rebound = StoredShortcut(
            key: "x",
            command: true,
            shift: false,
            option: true,
            control: false
        )
        let resolver = UsageTipShortcutResolver { action in
            action == .globalSearch ? rebound : nil
        }

        #expect(resolver.displayString(for: .globalSearch) == "⌥⌘X")
    }

    @MainActor
    @Test func shortcutResolverGracefullySkipsUnboundActions() {
        let resolver = UsageTipShortcutResolver { _ in .unbound }
        #expect(resolver.displayString(for: .globalSearch) == nil)
    }
}
