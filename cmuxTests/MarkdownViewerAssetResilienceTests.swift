import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
struct MarkdownViewerAssetResilienceTests {
    @Test func missingRequiredAssetRendersFallbackDocument() {
        let assets = MarkdownViewerAssets { name, ext in
            guard name != "marked.min" else { return nil }
            return "fixture-\(name).\(ext)"
        }

        let html = assets.shellHTML(isDark: false)

        #expect(html.contains("data-cmux-markdown-assets-unavailable"))
        #expect(html.contains("<!doctype html>"))
        #expect(html.contains("{{") == false)
    }

    @Test func missingLazyAssetReturnsNilInsteadOfTrapping() {
        let assets = MarkdownViewerAssets { name, ext in
            guard name != "mermaid.min" else { return nil }
            return "fixture-\(name).\(ext)"
        }

        #expect(assets.lazyAsset(name: "mermaid.min", ext: "js") == nil)
    }
}
