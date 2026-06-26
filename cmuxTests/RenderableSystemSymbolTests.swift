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
}

/// Guards the views that are laid out during the first frame of a launched or
/// session-restored main window against the macOS 27 SF Symbol launch crash.
///
/// On macOS 27, SwiftUI `Image(systemName:)` / `Label(systemImage:)` rasterize
/// through CoreUI `-[CUINamedVectorGlyph _rasterizeImageUsingScaleFactor:...]`,
/// which throws an uncaught exception while `_layoutSubtreeIfNeeded` measures the
/// glyph during `NSWindow.makeKeyAndOrderFront:` — the app dies before any window
/// appears (issues #6703 / #6745). The fix is to render SF Symbols through
/// `CmuxSystemSymbolImage`, which resolves them as AppKit `NSImage`s and never
/// enters the crashing `RB::Symbol::Presentation::template_image()` path.
///
/// This crash only reproduces on the macOS 27 beta, so CI (older macOS) cannot
/// catch a regression behaviorally. Instead, assert at the source level that the
/// launch/restore-reachable content views never reintroduce the crash-prone
/// SwiftUI symbol APIs. `NotificationsPage` in particular is mounted unconditionally
/// in the main content `ZStack` (toggled only via `.opacity`), so its body is laid
/// out on every launch even when the sidebar shows the tab list.
@Suite("Launch-path SF Symbol rendering guard")
struct LaunchPathSymbolRenderingGuardTests {
    /// Content views that render without any user interaction when a main window is
    /// created or its session is restored. #6728 moved launch *chrome* (sidebar,
    /// titlebar, toolbars) off `Image(systemName:)`; these are the content-area views
    /// it left behind.
    static let launchPathSources = [
        "Sources/NotificationsPage.swift",
        "Sources/WorkspaceContentView.swift",
        "Sources/Panels/TerminalPanelView.swift",
        "Sources/RemoteTmuxPaneHeader.swift",
    ]

    @Test func launchPathViewsAvoidCrashingSwiftUISymbolRasterizer() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // cmuxTests
            .deletingLastPathComponent() // repo root
        var offenders: [String] = []
        for relativePath in Self.launchPathSources {
            let fileURL = repoRoot.appendingPathComponent(relativePath)
            let contents = try String(contentsOf: fileURL, encoding: .utf8)
            for (lineNumber, line) in contents.components(separatedBy: .newlines).enumerated() {
                // Match SwiftUI `Image(systemName:` but not `CmuxSystemSymbolImage(systemName:`.
                let usesRawImageSymbol = line.range(
                    of: "(?<![A-Za-z])Image\\(systemName:",
                    options: .regularExpression
                ) != nil
                let usesRawLabelSymbol = line.contains("Label(") && line.contains("systemImage:")
                if usesRawImageSymbol || usesRawLabelSymbol {
                    offenders.append("\(relativePath):\(lineNumber + 1): \(line.trimmingCharacters(in: .whitespaces))")
                }
            }
        }
        #expect(
            offenders.isEmpty,
            """
            Launch/restore-path views must render SF Symbols through CmuxSystemSymbolImage, \
            not SwiftUI Image(systemName:)/Label(systemImage:), to avoid the macOS 27 CoreUI \
            rasterization launch crash (#6745). Offenders:
            \(offenders.joined(separator: "\n"))
            """
        )
    }
}
