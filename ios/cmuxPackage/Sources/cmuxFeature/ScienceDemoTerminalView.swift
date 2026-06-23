#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import CmuxMobileTerminal
import SwiftUI
import UIKit

struct ScienceDemoTerminalView: View {
    var body: some View {
        ScienceDemoTerminalSurface()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background {
                Color(red: 0x27 / 255.0, green: 0x28 / 255.0, blue: 0x22 / 255.0)
                    .ignoresSafeArea(.container, edges: [.horizontal, .bottom])
            }
            .ignoresSafeArea(.container, edges: .bottom)
            .ignoresSafeArea(.keyboard, edges: .bottom)
    }
}

private struct ScienceDemoTerminalSurface: UIViewRepresentable {
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        guard let runtime = try? GhosttyRuntime.shared() else {
            let label = UILabel()
            label.numberOfLines = 0
            label.textColor = .white
            label.backgroundColor = UIColor(red: 0x27 / 255.0, green: 0x28 / 255.0, blue: 0x22 / 255.0, alpha: 1)
            label.text = "Ghostty runtime failed to initialize."
            return label
        }

        let view = GhosttySurfaceView(
            runtime: runtime,
            delegate: context.coordinator,
            fontSize: MobileTerminalFontPreference.defaultSize
        )
        view.autoFocusOnWindowAttach = false
        view.hostSurfaceID = "science-demo-terminal"
        context.coordinator.surfaceView = view
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.stop()
        (uiView as? GhosttySurfaceView)?.prepareForDismantle()
    }

    @MainActor
    final class Coordinator: NSObject, GhosttySurfaceViewDelegate {
        weak var surfaceView: GhosttySurfaceView?
        private var task: Task<Void, Never>?

        func start() {
            task?.cancel()
            task = Task { @MainActor [weak self] in
                guard let self, let surfaceView else { return }
                guard let envelope = try? Self.snapshotEnvelope() else { return }
                await surfaceView.processRenderGridEnvelopeAndWait(envelope)
            }
        }

        func stop() {
            task?.cancel()
            task = nil
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}
        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize) {}

        private static func snapshotEnvelope() throws -> MobileTerminalRenderGridEnvelope {
            let columns = 112
            let visibleRows = 48
            let allLines = demoLines()
            let scrollbackLines = Array(allLines.dropLast(visibleRows))
            let viewportLines = Array(allLines.suffix(visibleRows))
            let frame = try MobileTerminalRenderGridFrame(
                surfaceID: "science-demo-terminal",
                stateSeq: 1,
                columns: columns,
                rows: visibleRows,
                cursor: .init(row: visibleRows - 1, column: 0),
                styles: demoStyles,
                rowSpans: rowSpans(for: viewportLines, startingAt: 0),
                terminalForeground: "#F8F8F2",
                terminalBackground: "#272822",
                terminalCursorColor: "#F8F8F2",
                scrollbackRows: scrollbackLines.count,
                scrollbackSpans: rowSpans(for: scrollbackLines, startingAt: 0)
            )
            return try .snapshot(frame)
        }

        private static var demoStyles: [MobileTerminalRenderGridFrame.Style] {
            [
                .default,
                .init(id: 1, foreground: "#66D9EF", bold: true),
                .init(id: 2, foreground: "#A6E22E"),
                .init(id: 3, foreground: "#AE81FF"),
                .init(id: 4, foreground: "#F92672"),
                .init(id: 5, foreground: "#E6DB74"),
                .init(id: 6, foreground: "#75715E"),
            ]
        }

        private static func demoLines() -> [(styleID: Int, text: String)] {
            var lines: [(styleID: Int, text: String)] = [
                (1, "cmux mobile science demo"),
                (6, "Ghostty renderer, render-grid feed, no auth, no pairing, no host round trip."),
                (0, ""),
                (1, "experiment       smooth primary scrollback on iPhone"),
                (1, "observation     touch scroll stays local on primary screen"),
                (1, "transport       semantic render-grid snapshot into the live terminal surface"),
                (0, ""),
                (0, "index  timestamp      signal       value       note"),
                (6, "-----  -------------  -----------  ----------  -----------------------------"),
            ]
            for index in 1...320 {
                lines.append(sampleLine(index))
            }
            lines.append((0, ""))
            lines.append((2, "ready  320 lines loaded. Drag upward to exercise local scrollback."))
            lines.append((6, "       This screen intentionally bypasses Google sign-in for the demo build."))
            return lines
        }

        private static func sampleLine(_ index: Int) -> (styleID: Int, text: String) {
            let styleIDs = [2, 1, 3, 5, 4]
            let signalIndex = index % 5
            let signal = ["render", "scroll", "input", "latency", "viewport"][signalIndex]
            let paddedSignal = signal.padding(toLength: 11, withPad: " ", startingAt: 0)
            let value = String(format: "%.3f", Double(index * 37 % 997) / 997.0)
            return (
                styleIDs[signalIndex],
                String(
                    format: "%5d  T+%05dms    %@  %@      primary scrollback sample",
                    index,
                    index * 70,
                    paddedSignal,
                    value
                )
            )
        }

        private static func rowSpans(
            for lines: [(styleID: Int, text: String)],
            startingAt rowOffset: Int
        ) -> [MobileTerminalRenderGridFrame.RowSpan] {
            lines.enumerated().compactMap { index, line in
                guard !line.text.isEmpty else { return nil }
                return .init(
                    row: rowOffset + index,
                    column: 0,
                    styleID: line.styleID,
                    text: line.text
                )
            }
        }
    }
}
#endif
