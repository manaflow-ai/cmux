import AppKit
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Renderable system symbols")
struct RenderableSystemSymbolTests {
    @Test func rasterPointSizeClampsInvalidInputs() {
        #expect(RenderableSystemSymbol.clampedRasterPointSize(0) == 1)
        #expect(RenderableSystemSymbol.clampedRasterPointSize(-8) == 1)
        #expect(RenderableSystemSymbol.clampedRasterPointSize(11) == 11)
        #expect(RenderableSystemSymbol.clampedRasterPointSize(.nan) == 1)
        #expect(RenderableSystemSymbol.clampedRasterPointSize(.infinity) == 1)
        #expect(RenderableSystemSymbol.clampedRasterPointSize(-.infinity) == 1)
    }

    @Test func resolvedRasterPointSizeAppliesGlobalFontMagnificationWhenRequested() {
        #expect(RenderableSystemSymbol.resolvedRasterPointSize(
            10,
            globalFontPercent: 150,
            appliesGlobalFontMagnification: true
        ) == 15)
        #expect(RenderableSystemSymbol.resolvedRasterPointSize(
            10,
            globalFontPercent: 150,
            appliesGlobalFontMagnification: false
        ) == 10)
        #expect(RenderableSystemSymbol.resolvedRasterPointSize(
            0,
            globalFontPercent: 200,
            appliesGlobalFontMagnification: true
        ) == 2)
    }

    @Test @MainActor func configuredAppKitImageUsesTemplateImageWithClampedSize() throws {
        RenderableSystemSymbol.resetRenderabilityCacheForTesting()
        let image = try #require(RenderableSystemSymbol.configuredAppKitImage(
            systemName: "questionmark.circle",
            pointSize: 0,
            weight: .medium
        ))
        #expect(image.isTemplate)
        #expect(image.size == NSSize(width: 1, height: 1))
    }

    @Test @MainActor func configuredAppKitImagePreservesNonSquareSymbolAspectRatio() throws {
        RenderableSystemSymbol.resetRenderabilityCacheForTesting()
        let image = try #require(RenderableSystemSymbol.configuredAppKitImage(
            systemName: "arrow.right",
            pointSize: 16,
            weight: .regular
        ))
        #expect(abs(image.size.width - 16) < 0.001)
        #expect(image.size.height < 16)
    }

    @Test func fittedSymbolSizeScalesLongerDimensionToRasterSize() {
        #expect(RenderableSystemSymbol.fittedSymbolSize(
            NSSize(width: 20, height: 10),
            maximumDimension: 16
        ) == NSSize(width: 16, height: 8))
        #expect(RenderableSystemSymbol.fittedSymbolSize(
            NSSize(width: 0, height: 10),
            maximumDimension: 16
        ) == NSSize(width: 16, height: 16))
    }

    @Test @MainActor func configuredAppKitImageReusesCachedImage() throws {
        RenderableSystemSymbol.resetRenderabilityCacheForTesting()
        let first = try #require(RenderableSystemSymbol.configuredAppKitImage(
            systemName: "questionmark.circle",
            pointSize: 11,
            weight: .medium
        ))
        let second = try #require(RenderableSystemSymbol.configuredAppKitImage(
            systemName: "questionmark.circle",
            pointSize: 11,
            weight: .medium
        ))
        #expect(first === second)
    }

    @Test @MainActor func configuredAppKitImageRejectsUnknownSymbols() {
        RenderableSystemSymbol.resetRenderabilityCacheForTesting()
        #expect(RenderableSystemSymbol.configuredAppKitImage(
            systemName: "not.an.sf.symbol",
            pointSize: 11,
            weight: .regular
        ) == nil)
        #expect(RenderableSystemSymbol.isRenderable("not.an.sf.symbol") == false)
    }

    /// Every SF Symbol rendered by a view that is laid out during launch or session
    /// restore must resolve through the AppKit `NSImage` path (`CmuxSystemSymbolImage`
    /// / `configuredAppKitImage`). On macOS 27 these symbols crash when rendered via
    /// SwiftUI `Image(systemName:)` / `Label(systemImage:)`: CoreUI throws inside
    /// `-[CUINamedVectorGlyph _rasterizeImageUsingScaleFactor:...]` while the glyph is
    /// measured during the first `NSWindow.makeKeyAndOrderFront:` layout, killing the
    /// app before any window appears (issues #6703 / #6745). `NotificationsPage` is the
    /// decisive one: it is mounted unconditionally in the main content `ZStack` and only
    /// toggled with `.opacity`, so its body is laid out on every launch.
    ///
    /// The crash only reproduces on macOS 27, so it cannot be reproduced on CI's older
    /// macOS — macOS 27 launch coverage has to be validated on a macOS 27 runner/device.
    /// This test instead pins the launch/restore symbol set and proves each one renders
    /// through the non-crashing AppKit path that the fix routes them onto.
    @Test @MainActor func launchPathSymbolsRenderThroughAppKitPath() throws {
        RenderableSystemSymbol.resetRenderabilityCacheForTesting()
        // NotificationsPage, EmptyPanelView, AgentHibernationPlaceholderView, and
        // RemoteTmuxPaneHeader — the content-area views laid out on launch / restore.
        let launchPathSymbols = [
            "bell.slash", "bell.badge", "xmark.circle.fill",
            "terminal.fill", "globe", "pause.circle",
            "square.split.2x1", "square.split.1x2", "xmark",
        ]
        for symbol in launchPathSymbols {
            let image = try #require(
                RenderableSystemSymbol.configuredAppKitImage(
                    systemName: symbol,
                    pointSize: 16,
                    weight: .regular
                ),
                "Launch/restore-path symbol \(symbol) must resolve through the AppKit path"
            )
            #expect(image.isTemplate)
            #expect(image.size.width > 0 && image.size.height > 0)
        }
    }
}
