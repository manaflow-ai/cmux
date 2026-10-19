import AppKit
import Combine
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
        let probeState = SidebarLeadingEdgeProbeState()
        let root = SidebarLeadingEdgeProbe(
            layout: layout,
            probeState: probeState,
            capture: capture
        )
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
            probeState.generation &+= 1
            let generation = probeState.generation
            layout.width = width
            host.frame = NSRect(x: 0, y: 0, width: width, height: 120)
            let deadline = Date(timeIntervalSinceNow: 0.5)
            while !capture.hasMeasurement(for: generation, width: width), Date() < deadline {
                host.layoutSubtreeIfNeeded()
                window.contentView?.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                _ = RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.001))
            }

            guard let frames = capture.measurement(for: generation, width: width) else {
                Issue.record("Sidebar probe did not report current geometry at width \(width).")
                continue
            }
            guard let short = frames[SidebarLeadingEdgeProbe.shortRowID],
                  let wide = frames[SidebarLeadingEdgeProbe.wideRowID] else {
                Issue.record("Sidebar probe did not report both row frames at width \(width).")
                continue
            }

            #expect(abs(short.minX) < 0.5, "Short row moved off x=0 at width \(width): \(short).")
            #expect(abs(wide.minX) < 0.5, "Wide row moved off x=0 at width \(width): \(wide).")
            #expect(abs(short.minX - wide.minX) < 0.5, "Rows no longer share one leading anchor: \(frames).")
        }
    }
}

@MainActor
private final class SidebarLeadingEdgeProbeState: ObservableObject {
    @Published var generation = 0
}

private struct SidebarLeadingEdgeMeasurement: Equatable {
    let frame: CGRect
    let generation: Int
    let containerWidth: CGFloat
}

private final class SidebarLeadingEdgeFrameCapture {
    var measurements: [String: SidebarLeadingEdgeMeasurement] = [:]

    func hasMeasurement(for generation: Int, width: CGFloat) -> Bool {
        measurement(for: generation, width: width) != nil
    }

    func measurement(for generation: Int, width: CGFloat) -> [String: CGRect]? {
        let matching = measurements.filter {
            $0.value.generation == generation && abs($0.value.containerWidth - width) < 0.5
        }
        guard matching.count == 2 else { return nil }
        return matching.reduce(into: [String: CGRect]()) { result, entry in
            result[entry.key] = entry.value.frame
        }
    }
}

private struct SidebarLeadingEdgeFramePreferenceKey: PreferenceKey {
    static let defaultValue: [String: SidebarLeadingEdgeMeasurement] = [:]

    static func reduce(
        value: inout [String: SidebarLeadingEdgeMeasurement],
        nextValue: () -> [String: SidebarLeadingEdgeMeasurement]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct SidebarLeadingEdgeProbe: View {
    static let shortRowID = "short"
    static let wideRowID = "wide"

    let layout: SidebarLayoutModel
    @ObservedObject var probeState: SidebarLeadingEdgeProbeState
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
            capture.measurements = $0
        }
    }

    private func row(id: String, width: CGFloat) -> some View {
        Color.clear
            .frame(width: width, height: 20)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SidebarLeadingEdgeFramePreferenceKey.self,
                        value: [id: SidebarLeadingEdgeMeasurement(
                            frame: proxy.frame(in: .named("sidebar-leading-edge-probe")),
                            generation: probeState.generation,
                            containerWidth: layout.width
                        )]
                    )
                }
            }
    }
}
