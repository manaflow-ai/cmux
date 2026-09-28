// ui-lab: source Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/CodeBlocks/TerminalCodeBlock.swift
// ui-lab: source Sources/TerminalCodeBlocks/TerminalCodeBlockViews.swift
//
// Terminal code block affordances over a mock agent pane:
// - hover: the Copy / Run pill at the top-right of a block the agent wrote,
//   with the Copy confirmation state;
// - offered: cards for blocks a process offered with `cmux code-block`;
// - review: what Run shows before opening a multi-line command.
// Row metrics mirror a 13 pt terminal font (cell height 17 pt); the pill sits
// on the blank row above the block (TerminalCodeBlockAnchorResolver.pillRow),
// near the pane's right edge.

import AppKit
import SwiftUI

UILab.main {
    func terminalCanvas(
        rows: [String],
        size: NSSize,
        scheme: ColorScheme
    ) -> UILab.Canvas {
        let canvas = UILab.Canvas(frame: NSRect(origin: .zero, size: size))
        let dark = scheme == .dark
        canvas.fill = dark ? NSColor(white: 0.11, alpha: 1) : NSColor(white: 0.985, alpha: 1)
        let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        for (index, row) in rows.enumerated() {
            let label = NSTextField(labelWithString: row)
            label.font = font
            label.textColor = dark ? NSColor(white: 0.88, alpha: 1) : NSColor(white: 0.15, alpha: 1)
            if row.hasPrefix("  ") && !row.hasPrefix("  ⎿") {
                label.textColor = dark
                    ? NSColor(red: 0.62, green: 0.82, blue: 0.98, alpha: 1)
                    : NSColor(red: 0.10, green: 0.35, blue: 0.62, alpha: 1)
            }
            label.frame = NSRect(x: 12, y: 10 + CGFloat(index) * 17, width: size.width - 24, height: 17)
            canvas.addSubview(label)
        }
        return canvas
    }

    func host<V: View>(_ view: V, scheme: ColorScheme) -> NSHostingView<some View> {
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, scheme))
        hosting.frame.size = hosting.fittingSize
        return hosting
    }

    let agentRows = [
        "⏺ The branch is pushed. Dispatch CI and watch the first failure:",
        "",
        "  gh workflow run ci.yml --repo example/app --ref feat/code-blocks",
        "  gh run list --repo example/app --limit 1",
        "",
        "  Then reload the dev build:",
        "",
        "  cat <<'EOF' > .env.local",
        "  CMUX_TAG=code-blocks",
        "  EOF",
        "  ./scripts/reload.sh --tag code-blocks",
        "",
        "────────────────────────────────────────────────────────────────────",
        "> ",
    ]

    let ciBlock = TerminalCodeBlock(
        text: "gh workflow run ci.yml --repo example/app --ref feat/code-blocks\ngh run list --repo example/app --limit 1",
        language: "bash",
        origin: .transcript
    )
    let reloadBlock = TerminalCodeBlock(
        text: "cat <<'EOF' > .env.local\nCMUX_TAG=code-blocks\nEOF\n./scripts/reload.sh --tag code-blocks",
        language: "bash",
        origin: .transcript
    )

    let paneSize = NSSize(width: 640, height: 262)

    UILab.render(name: "hover-pill", detail: NSRect(x: 380, y: 30, width: 260, height: 70)) { scheme in
        let canvas = terminalCanvas(rows: agentRows, size: paneSize, scheme: scheme)
        let pill = host(TerminalCodeBlockPill(block: ciBlock, onCopy: {}, onRun: {}), scheme: scheme)
        pill.frame.origin = NSPoint(x: paneSize.width - pill.frame.width - 10, y: 10 + 1 * 17 - 3)
        canvas.addSubview(pill)
        return canvas
    }

    UILab.render(name: "hover-pill-copied", detail: NSRect(x: 380, y: 110, width: 260, height: 70)) { scheme in
        let canvas = terminalCanvas(rows: agentRows, size: paneSize, scheme: scheme)
        let pill = host(
            TerminalCodeBlockPill(block: reloadBlock, onCopy: {}, onRun: {}, showsCopiedInitially: true),
            scheme: scheme
        )
        pill.frame.origin = NSPoint(x: paneSize.width - pill.frame.width - 10, y: 10 + 6 * 17 - 3)
        canvas.addSubview(pill)
        return canvas
    }

    UILab.render(name: "offered-cards") { scheme in
        let rows = Array(agentRows.prefix(4)) + ["", "", "", "", "", "", "", "", "────", "> "]
        let canvas = terminalCanvas(rows: rows, size: NSSize(width: 640, height: 300), scheme: scheme)
        let tray = host(
            TerminalCodeBlockTray(
                blocks: [
                    TerminalCodeBlock(
                        text: "make dev-app TAG=code-blocks\nopen build/dev/app.dmg",
                        language: "bash",
                        label: "Build a dev app for this branch",
                        origin: .offered
                    ),
                    TerminalCodeBlock(
                        text: "{\n  \"editor.formatOnSave\": true\n}",
                        language: "json",
                        label: "Settings snippet",
                        origin: .offered
                    ),
                ],
                onCopy: { _ in },
                onRun: { _ in },
                onDismiss: { _ in }
            ),
            scheme: scheme
        )
        tray.frame.origin = NSPoint(x: 640 - tray.frame.width - 10, y: 10)
        canvas.addSubview(tray)
        return canvas
    }

    UILab.render(name: "run-review") { scheme in
        let review = host(
            TerminalCodeBlockReviewView(block: reloadBlock, onConfirm: {}, onCancel: {}),
            scheme: scheme
        )
        let canvas = UILab.Canvas(frame: NSRect(origin: .zero, size: review.frame.size))
        canvas.fill = .windowBackgroundColor
        canvas.addSubview(review)
        return canvas
    }
}
