@testable import CNBrowserUI
import SwiftUI
import Testing

struct ChromeTypeTests {
    /// The chrome follows the user's text size up to each surface's cap.
    @Test func followsTheUserUpToTheCap() {
        #expect(ChromeType(size: .large, cap: ChromeType.barCap).effective == .large)
        #expect(ChromeType(size: .xxxLarge, cap: ChromeType.barCap).effective == .xxxLarge)
        #expect(ChromeType(size: .accessibility5, cap: ChromeType.barCap).effective == .xxxLarge)
        #expect(ChromeType(size: .accessibility5, cap: ChromeType.cardCap).effective == .xxLarge)
        #expect(ChromeType(size: .accessibility5, cap: ChromeType.pageCap).effective == .accessibility1)
        #expect(ChromeType(size: .xSmall, cap: ChromeType.pageCap).effective == .xSmall)
    }
}
