import CmuxCore
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Session snapshot browser state import")
struct SessionSnapshotImportBrowserStateTests {
    @Test("imported browser panels drop WebKit page state")
    func browserPanelsDropInteractionState() {
        // WebKit's interaction state carries its own back/forward list, so
        // keeping it would restore entries the history filter removed.
        let browser = SessionBrowserPanelSnapshot(
            urlString: "https://example.com",
            profileID: nil,
            shouldRenderWebView: true,
            pageZoom: 1,
            developerToolsVisible: false,
            backHistoryURLStrings: nil,
            forwardHistoryURLStrings: nil,
            interactionState: Data("file:///etc/passwd".utf8),
            keepsPageActive: true
        )

        let (sanitized, changed) = SessionSnapshotImportTrust.sanitizedBrowserPanel(browser)

        #expect(changed)
        #expect(sanitized.interactionState == nil)
        #expect(sanitized.keepsPageActive == nil)
        #expect(sanitized.urlString == "https://example.com")
    }
}
