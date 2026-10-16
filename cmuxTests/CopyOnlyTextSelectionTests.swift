import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite("Dynamic text selection", .serialized)
struct CopyOnlyTextSelectionTests {
    @Test("File preview headers stay off the field-editor path during updates")
    func filePathHeaderNeverCreatesSelectableFields() {
        let frame = NSRect(x: 0, y: 0, width: 640, height: 80)
        let window = NSWindow(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }

        let baseline = NSHostingView(rootView: Text("report.html").textSelection(.enabled))
        baseline.frame = frame
        window.contentView = baseline
        baseline.layoutSubtreeIfNeeded()
        #expect(!selectableTextFields(in: baseline).isEmpty)

        let makeHeader = { (filePath: String) in
            PanelFilePathHeader(
                iconSystemName: "doc",
                filePath: filePath,
                foregroundColor: .labelColor
            ) {
                EmptyView()
            }
        }
        let host = NSHostingView(rootView: makeHeader("/tmp/report.html"))
        host.frame = frame
        window.contentView = host

        for filePath in ["/tmp/report.html", "/tmp/更新されたファイル.html", "/tmp/report.html"] {
            host.rootView = makeHeader(filePath)
            host.layoutSubtreeIfNeeded()
            #expect(selectableTextFields(in: host).isEmpty)
        }
    }

    private func selectableTextFields(in root: NSView) -> [NSTextField] {
        var remainingViews = [root]
        var fields: [NSTextField] = []
        while let view = remainingViews.popLast() {
            if let field = view as? NSTextField, field.isSelectable {
                fields.append(field)
            }
            remainingViews.append(contentsOf: view.subviews)
        }
        return fields
    }
}
