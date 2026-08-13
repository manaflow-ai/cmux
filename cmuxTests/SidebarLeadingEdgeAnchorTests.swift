import AppKit
import SwiftUI
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite(.serialized)
struct SidebarLeadingEdgeAnchorTests {
    @MainActor
    @Test
    func oversizedSidebarRowsStayLeadingAnchoredAcrossResizeWidths() {
        _ = NSApplication.shared

        let capture = SidebarLeadingEdgeFrameCapture()
        let layout = SidebarLayoutModel(width: 240)
        let root = SidebarLeadingEdgeProbe(layout: layout, capture: capture)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 120),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            window.contentView = nil
            window.close()
        }
        window.contentView = host

        for width in [CGFloat(240), 320, 180, 240] {
            layout.width = width
            host.frame = NSRect(x: 0, y: 0, width: width, height: 120)
            host.layoutSubtreeIfNeeded()
            window.contentView?.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            host.layoutSubtreeIfNeeded()

            let frames = capture.frames
            guard let short = frames[SidebarLeadingEdgeProbe.shortRowID],
                  let wide = frames[SidebarLeadingEdgeProbe.wideRowID] else {
                Issue.record("Sidebar probe did not report both row frames at width \(width).")
                continue
            }

            #expect(short.minX >= -0.5, "Short row moved off the leading edge at width \(width): \(short).")
            #expect(wide.minX >= -0.5, "Wide row moved off the leading edge at width \(width): \(wide).")
            #expect(abs(short.minX - wide.minX) < 0.5, "Rows no longer share one leading anchor: \(frames).")
        }
    }
}

private final class SidebarLeadingEdgeFrameCapture {
    var frames: [String: CGRect] = [:]
}

private struct SidebarLeadingEdgeFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: CGRect] = [:]

    static func reduce(value: inout [String: CGRect], nextValue: () -> [String: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SidebarLeadingEdgeProbe: View {
    static let shortRowID = "short"
    static let wideRowID = "wide"

    let layout: SidebarLayoutModel
    let capture: SidebarLeadingEdgeFrameCapture

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row(id: Self.shortRowID, width: 260)
            row(id: Self.wideRowID, width: 320)
        }
        // This is the interpreter's `.fixedSize()` failure mode: the root
        // reports its widest child (320pt), even when the pane is narrower.
        .fixedSize(horizontal: true, vertical: false)
        .modifier(SidebarWidthFrameModifier(layout: layout))
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .coordinateSpace(name: "sidebar-leading-edge-probe")
        .onPreferenceChange(SidebarLeadingEdgeFramePreferenceKey.self) {
            capture.frames = $0
        }
    }

    private func row(id: String, width: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: 20)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SidebarLeadingEdgeFramePreferenceKey.self,
                        value: [id: proxy.frame(in: .named("sidebar-leading-edge-probe"))]
                    )
                }
            }
    }
}
