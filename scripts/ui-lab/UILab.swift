import AppKit
import SwiftUI

/// Rendering support for ui-lab harnesses (see scripts/ui-lab/ui-lab.py).
/// A harness calls `UILab.main { ... }` and, inside it,
/// `UILab.render(name:) { scheme in ... }` to build and render its view.
/// The output directory is the process's first argument.
enum UILab {
    static let outputDirectory: URL = {
        let path = CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath
        return URL(fileURLWithPath: path, isDirectory: true)
    }()

    /// A harness's entry point: sets up AppKit (an application, so
    /// appearances and system colors resolve) and runs `body` on the main actor.
    static func main(_ body: @MainActor () -> Void) {
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            NSApp.setActivationPolicy(.prohibited)
            body()
        }
    }

    /// Writes `<name>-light@2x.png` and `<name>-dark@2x.png`, and, when
    /// `detail` is set, `<name>-light-detail@4x.png` cropped to that rect (in
    /// view points) for a close look at small glyphs. `build` runs once per
    /// scheme: views that pick colors from their own `colorScheme` property
    /// (like `GPUSpinnerNSView`) need it set, since the appearance alone does
    /// not reach them.
    @MainActor
    static func render(name: String, detail: NSRect? = nil, build: (ColorScheme) -> NSView) {
        for (label, scheme, appearanceName) in [
            ("light", ColorScheme.light, NSAppearance.Name.aqua),
            ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua),
        ] {
            let appearance = NSAppearance(named: appearanceName)!
            var view: NSView?
            appearance.performAsCurrentDrawingAppearance { view = build(scheme) }
            guard let view else { continue }
            write(view, appearance: appearance, scale: 2, rect: view.bounds, file: "\(name)-\(label)@2x.png")
            if let detail, label == "light" {
                write(view, appearance: appearance, scale: 4, rect: detail, file: "\(name)-\(label)-detail@4x.png")
            }
        }
    }

    @MainActor
    private static func write(_ view: NSView, appearance: NSAppearance, scale: CGFloat, rect: NSRect, file: String) {
        view.appearance = appearance
        var data: Data?
        appearance.performAsCurrentDrawingAppearance {
            layoutAll(view)
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(rect.width * scale),
                pixelsHigh: Int(rect.height * scale),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return }
            rep.size = rect.size
            view.cacheDisplay(in: rect, to: rep)
            data = rep.representation(using: .png, properties: [:])
        }
        let url = outputDirectory.appendingPathComponent(file)
        guard let data else {
            fail("could not encode \(url.path) as PNG")
        }
        do {
            try data.write(to: url)
            print(url.path)
        } catch {
            fail("could not write \(url.path): \(error)")
        }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write("ui-lab: \(message)\n".data(using: .utf8)!)
        exit(1)
    }

    @MainActor
    private static func layoutAll(_ view: NSView) {
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        view.subviews.forEach(layoutAll)
    }

    /// A flipped container: frames are laid out top-down like the sidebar cells.
    final class Canvas: NSView {
        var fill: NSColor?
        override var isFlipped: Bool { true }
        override func draw(_ dirtyRect: NSRect) {
            if let fill {
                fill.setFill()
                dirtyRect.fill()
            }
        }
    }
}
