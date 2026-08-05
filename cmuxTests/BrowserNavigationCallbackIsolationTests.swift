import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite
struct BrowserNavigationCallbackIsolationTests {
    @Test
    func legacyNavigationCallbackHopsToMainActor() async throws {
        let panel = BrowserPanel(workspaceId: UUID())
        defer { panel.webView.stopLoading() }

        let renderedPDFURL = try #require(
            URL(string: "https://example.test/rendered.pdf")
        )
        panel.noteRenderedPDFDocument(renderedPDFURL, isMainFrame: true)
        #expect(panel.renderedPDFDocumentURL == renderedPDFURL)

        let callback = try #require(panel.navigationDelegate?.didClearPDFDocument)
        let callbackBox = BrowserNavigationCallbackSendableBox(value: callback)
        await Task.detached {
            await callbackBox.value()
        }.value

        #expect(panel.renderedPDFDocumentURL == nil)
    }
}
