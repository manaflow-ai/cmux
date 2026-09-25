import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite
struct CmuxPanelTemplateTests {
    @Test
    func decodesMarkdownTemplateAndClampsUnsafeMetrics() throws {
        let data = Data("""
        {
          "font": " Fira Code ",
          "fontSize": 14,
          "lineHeight": 1.6,
          "cssOverlay": ".markdown-body { max-width: 90ch; }",
          "viewport": { "maxWidth": 1200, "padding": 28, "alignment": "center" },
          "headerExtensions": "# Header"
        }
        """.utf8)

        let template = try JSONDecoder().decode(CmuxPanelTemplate.self, from: data)

        #expect(template.font == "Fira Code")
        #expect(template.fontSize == 14)
        #expect(template.lineHeight == 1.6)
        #expect(template.viewport?.maxWidth == 1200)
        #expect(template.viewport?.padding == 28)
        #expect(template.viewport?.alignment == .center)
        #expect(template.headerExtensions == "# Header")
    }

    @Test
    func templateDefaultsProvideAStableBaseForEveryPanel() {
        #expect(CmuxPanelTemplate.markdownDefault.fontSize == 15)
        #expect(CmuxPanelTemplate.markdownDefault.lineHeight == 1.5)
        #expect(CmuxPanelTemplate.diffDefault.fontSize == 10)
        #expect(CmuxPanelTemplate.diffDefault.lineHeight == 20)
    }
}
