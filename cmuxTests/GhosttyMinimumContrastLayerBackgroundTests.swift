import AppKit
import CmuxTerminal
import GhosttyKit
import IOSurface
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// cmux paints the terminal background from its host layer
/// (`macos-background-from-layer = true`), so Ghostty draws text over a
/// transparent frame. With `minimum-contrast` above 1 on a light theme, dark
/// text must stay dark: it sits on the light background the host layer paints.
/// https://github.com/manaflow-ai/cmux/issues/4156
/// https://github.com/manaflow-ai/cmux/issues/3967
@MainActor
@Suite("Ghostty minimum contrast with a host-layer background", .serialized)
struct GhosttyMinimumContrastLayerBackgroundTests {
    @Test func darkTextOnLightThemeStaysDark() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            // Flexoki Light's colors, as in the reports. A fresh config keeps
            // the runner's own Ghostty config (a background image, say) out.
            let config = try #require(ghostty_config_new())
            let contents = """
            background = #fffcf0
            foreground = #100f0f
            minimum-contrast = 2
            macos-background-from-layer = true

            """
            contents.withCString { pointer in
                ghostty_config_load_string(
                    config,
                    pointer,
                    UInt(contents.utf8.count),
                    "/__cmux_test__/minimum-contrast.conf"
                )
            }
            ghostty_config_finalize(config)
            defer { ghostty_config_free(config) }

            let terminal = try ScrollbackTestTerminal(pinsOnScreenOcclusion: true)
            defer { terminal.close() }
            try await terminal.launch()
            let runtime = try #require(terminal.surface.surface)
            GhosttyApp.shared.suppressGhosttyReloadActions {
                ghostty_surface_update_config(runtime, config)
            }

            let line = String(repeating: "M", count: 40)
            try terminal.output(
                "\u{1b}[?25l\u{1b}[2J\u{1b}[H" + Array(repeating: line, count: 6).joined(separator: "\r\n")
            )

            // Frames drawn before the config lands still use the old colors,
            // so wait for dark text rather than sampling the first frame.
            terminal.window.makeKeyAndOrderFront(nil)
            terminal.window.displayIfNeeded()
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            var sample: TextPixelSample?
            while ContinuousClock.now < deadline {
                terminal.surface.forceRefresh(reason: "test.minimumContrast")
                try await Task.sleep(nanoseconds: 50_000_000)
                sample = Self.textPixels(in: terminal.view.layer)
                if let sample, sample.count > 50, sample.meanLuminance < 0.5 { break }
            }

            let result = try #require(
                sample,
                "Ghostty presented no IOSurface frame: \(Self.renderDiagnostics(terminal))"
            )
            #expect(result.count > 50, "Expected rendered text pixels, found \(result.count)")
            // Ghostty skipped its own background fill, so the host layer owns it.
            #expect(
                result.transparentFraction > 0.5,
                "Only \(result.transparentFraction) of the frame was transparent; host-layer background was not active"
            )
            #expect(
                result.meanLuminance < 0.5,
                "Dark text rendered with mean luminance \(result.meanLuminance) on a light background"
            )
        }
    }

    static func renderDiagnostics(_ terminal: ScrollbackTestTerminal) -> String {
        let layer = terminal.view.layer
        let contents = layer?.contents.map { String(describing: type(of: $0)) } ?? "nil"
        var text = "layer=\(layer.map { String(describing: type(of: $0)) } ?? "nil") contents=\(contents)"
        text += " sublayers=\(layer?.sublayers?.count ?? 0) bounds=\(terminal.view.bounds)"
        #if DEBUG
        let stats = terminal.surface.hostedView.debugRenderStats()
        text += " draws=\(stats.drawCount) presents=\(stats.presentCount) key=\(stats.layerContentsKey)"
        text += " visible=\(stats.windowOcclusionVisible) active=\(stats.isActive)"
        #endif
        return text
    }

    struct TextPixelSample {
        var count: Int
        var meanLuminance: Double
        var transparentFraction: Double
    }

    /// Mean luminance of the mostly opaque pixels in the presented frame. The
    /// frame is transparent except for text, because the host layer owns the
    /// background fill.
    static func textPixels(in layer: CALayer?) -> TextPixelSample? {
        guard let surface = presentedSurface(in: layer), surface.bytesPerElement == 4 else { return nil }
        surface.lock(options: .readOnly, seed: nil)
        defer { surface.unlock(options: .readOnly, seed: nil) }
        let bytes = surface.baseAddress.assumingMemoryBound(to: UInt8.self)
        let rowBytes = surface.bytesPerRow
        var count = 0
        var transparent = 0
        var luminance = 0.0
        for y in 0..<surface.height {
            for x in 0..<surface.width {
                // 32BGRA, premultiplied alpha.
                let pixel = bytes + y * rowBytes + x * 4
                if pixel[3] == 0 { transparent += 1 }
                let alpha = Double(pixel[3])
                guard alpha >= 160 else { continue }
                let blue = Double(pixel[0]) / alpha
                let green = Double(pixel[1]) / alpha
                let red = Double(pixel[2]) / alpha
                luminance += 0.2126 * red + 0.7152 * green + 0.0722 * blue
                count += 1
            }
        }
        let transparentFraction = Double(transparent) / Double(max(1, surface.width * surface.height))
        guard count > 0 else {
            return TextPixelSample(count: 0, meanLuminance: 1, transparentFraction: transparentFraction)
        }
        return TextPixelSample(
            count: count,
            meanLuminance: luminance / Double(count),
            transparentFraction: transparentFraction
        )
    }

    static func presentedSurface(in layer: CALayer?) -> IOSurface? {
        guard let layer else { return nil }
        if let contents = layer.contents, CFGetTypeID(contents as CFTypeRef) == IOSurfaceGetTypeID() {
            return (contents as! IOSurface)
        }
        for sublayer in layer.sublayers ?? [] {
            if let surface = presentedSurface(in: sublayer) { return surface }
        }
        return nil
    }
}
