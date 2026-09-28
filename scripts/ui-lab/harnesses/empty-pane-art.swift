// ui-lab: source Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/ANSIArt/ANSIArt.swift
// ui-lab: source Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/ANSIArt/ANSIArtBlockElement.swift
// ui-lab: source Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/ANSIArt/ANSIArtBuilder.swift
// ui-lab: source Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/ANSIArt/ANSIArtColor.swift
// ui-lab: source Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/ANSIArt/ANSIArtLine.swift
// ui-lab: source Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/ANSIArt/ANSIArtPalette.swift
// ui-lab: source Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/ANSIArt/ANSIArtParser.swift
// ui-lab: source Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/ANSIArt/ANSIArtRGB.swift
// ui-lab: source Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/ANSIArt/ANSIArtRGB+NSColor.swift
// ui-lab: source Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/ANSIArt/ANSIArtRun.swift
// ui-lab: source Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/ANSIArt/ANSIArtScanner.swift
// ui-lab: source Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/ANSIArt/ANSIArtStyle.swift
// ui-lab: source Sources/EmptyPaneArtLayout.swift
// ui-lab: source Sources/EmptyPaneArtView.swift
//
// Empty panes with `emptyPane.artFile` art: lolcat-colored figlet text and a
// chafa-style half-block image, in a roomy pane and a small split. The pane
// mirrors EmptyPanelView's custom-art layout (16 pt stack spacing, 48 pt
// horizontal and 100 pt vertical reserve); the buttons are stand-ins with the
// same style. Writes the sample art files next to the PNGs.

import AppKit
import SwiftUI

/// Sample art in the escape dialects the tools emit.
struct SampleArt {
    static let esc = "\u{1B}"

    /// `figlet -f slant cmux | lolcat -t`: one truecolor escape per character.
    static var figletLolcat: String {
        let lines = [
            "                              ",
            "  _________ ___  __  ___  __",
            " / ___/ __ `__ \\/ / / / |/_/",
            "/ /__/ / / / / / /_/ />  <  ",
            "\\___/_/ /_/ /_/\\__,_/_/|_|  ",
            "",
        ]
        var out = ""
        for (row, line) in lines.enumerated() {
            for (column, character) in line.enumerated() {
                let phase = Double(row * 3 + column) * 0.12
                let r = Int(sin(phase) * 127 + 128)
                let g = Int(sin(phase + 2 * .pi / 3) * 127 + 128)
                let b = Int(sin(phase + 4 * .pi / 3) * 127 + 128)
                out += "\(esc)[38;2;\(r);\(g);\(b)m\(character)"
            }
            out += "\(esc)[0m\n"
        }
        return out
    }

    /// `chafa --size 40x20`: upper half blocks with truecolor foreground and
    /// background, wrapped in cursor hide/show like chafa prints.
    static var chafaBlocks: String {
        let width = 40
        let height = 40 // pixel rows; two per text row
        func pixel(_ x: Int, _ y: Int) -> (Int, Int, Int) {
            let dx = Double(x) - 19.5
            let dy = Double(y) - 19.5
            let distance = (dx * dx + dy * dy).squareRoot()
            guard distance < 18 else { return (30, 32, 40) }
            let t = distance / 18
            return (Int(250 - 120 * t), Int(120 + 60 * (1 - t)), Int(40 + 180 * t))
        }
        var out = "\(esc)[?25l"
        for row in stride(from: 0, to: height, by: 2) {
            for x in 0..<width {
                let top = pixel(x, row)
                let bottom = pixel(x, row + 1)
                out += "\(esc)[38;2;\(top.0);\(top.1);\(top.2);48;2;\(bottom.0);\(bottom.1);\(bottom.2)m▀"
            }
            out += "\(esc)[0m\n"
        }
        return out + "\(esc)[?25h"
    }

    /// `toilet -f future --gay`-style 16-color text with bold and dim.
    static var sixteenColor: String {
        "\(esc)[1;91m┏━╸\(esc)[93m┏┳┓\(esc)[92m╻ ╻\(esc)[96m╻ ╻\(esc)[0m\n"
            + "\(esc)[1;91m┃  \(esc)[93m┃┃┃\(esc)[92m┃ ┃\(esc)[96m┏╋┛\(esc)[0m\n"
            + "\(esc)[1;91m┗━╸\(esc)[93m╹ ╹\(esc)[92m┗━┛\(esc)[96m╹ ╹\(esc)[0m\n"
            + "\(esc)[2m   empty pane\(esc)[0m\n"
    }
}

/// A stand-in for EmptyPanelView's custom-art branch.
struct MockEmptyPane: View {
    let content: EmptyPaneArtView.Content
    let background: Color

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: 16) {
                EmptyPaneArtView(
                    content: content,
                    maxSize: CGSize(width: proxy.size.width - 48, height: proxy.size.height - 100)
                )
                HStack(spacing: 12) {
                    Button {} label: { Label("Terminal  ⌘T", systemImage: "terminal.fill") }
                    Button {} label: { Label("Browser  ⇧⌘L", systemImage: "globe") }
                }
                .buttonStyle(.borderedProminent)
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
        .background(background)
    }
}

UILab.main {
    let samples: [(String, String)] = [
        ("figlet-lolcat", SampleArt.figletLolcat),
        ("chafa", SampleArt.chafaBlocks),
        ("toilet-16", SampleArt.sixteenColor),
    ]
    for (name, text) in samples {
        try? text.write(to: UILab.outputDirectory.appendingPathComponent("\(name).ans"), atomically: true, encoding: .utf8)
    }

    let panes: [(sample: Int, size: CGSize)] = [
        (0, CGSize(width: 560, height: 320)),
        (1, CGSize(width: 560, height: 420)),
        (2, CGSize(width: 360, height: 260)),
        (0, CGSize(width: 360, height: 200)),
        (1, CGSize(width: 360, height: 280)),
    ]
    let bounds = NSRect(x: 0, y: 0, width: 560 + 360 + 12, height: 420 + 320 + 12)
    UILab.render(name: "empty-pane-art", detail: NSRect(x: 0, y: 0, width: 560, height: 320)) { scheme in
        let dark = scheme == .dark
        let foreground = dark ? NSColor(srgbRed: 0.77, green: 0.78, blue: 0.78, alpha: 1) : .black
        let background = dark ? NSColor(srgbRed: 0.16, green: 0.17, blue: 0.20, alpha: 1) : .white
        let palette = ANSIArtPalette(foreground: ANSIArtRGB(foreground), background: ANSIArtRGB(background))
        let canvas = UILab.Canvas(frame: bounds)
        canvas.fill = .windowBackgroundColor
        let origins = [
            CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 332), CGPoint(x: 572, y: 0),
            CGPoint(x: 572, y: 272), CGPoint(x: 572, y: 484 - 12),
        ]
        for (index, pane) in panes.enumerated() {
            guard let art = ANSIArtParser().parse(samples[pane.sample].1) else { continue }
            let view = NSHostingView(rootView: MockEmptyPane(
                content: EmptyPaneArtView.Content(art: art, palette: palette, fontFamily: "Menlo", preferredFontSize: 13),
                background: Color(nsColor: background)
            ))
            view.frame = NSRect(origin: origins[index], size: pane.size)
            canvas.addSubview(view)
        }
        return canvas
    }
}
