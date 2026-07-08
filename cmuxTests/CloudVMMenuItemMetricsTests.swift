import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct CloudVMMenuItemMetricsTests {
    @Test func mouseDownCloudVMMenuRowMatchesNativeMenuItemHeight() throws {
        let menu = TitlebarCloudVMButton.makeCloudVMMenu()
        let firstView = try #require(menu.items.first?.view)

        #expect(abs(firstView.frame.height - Self.nativeMenuItemRowHeight()) < 0.5)
    }

    private static func nativeMenuItemRowHeight() -> Double {
        let oneItemMenu = NSMenu()
        oneItemMenu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))

        let twoItemMenu = NSMenu()
        twoItemMenu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
        twoItemMenu.addItem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))

        return twoItemMenu.size.height - oneItemMenu.size.height
    }
}
