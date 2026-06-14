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
                await surfaceView.processOutputAndWait(Self.initialFrame)
                await surfaceView.processOutputAndWait(Self.historyBlock(start: 1, count: 260))
                for index in 261...320 {
                    guard !Task.isCancelled else { return }
                    try? await Task.sleep(nanoseconds: 18_000_000)
                    await surfaceView.processOutputAndWait(Self.sampleLine(index))
                }
                await surfaceView.processOutputAndWait(Self.footer)
            }
        }

        func stop() {
            task?.cancel()
            task = nil
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {}
        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize) {}

        private static var initialFrame: Data {
            var text = "\u{1b}[2J\u{1b}[H"
            text += "\u{1b}[38;5;81mcmux mobile science demo\u{1b}[0m\r\n"
            text += "\u{1b}[38;5;245mGhostty renderer, local demo feed, no auth, no pairing, no host round trip.\u{1b}[0m\r\n\r\n"
            text += "\u{1b}[1mexperiment\u{1b}[0m       smooth primary scrollback on iPhone\r\n"
            text += "\u{1b}[1mobservation\u{1b}[0m     touch scroll stays local until a real TUI alternate screen needs host wheel input\r\n"
            text += "\u{1b}[1mtransport\u{1b}[0m       canned PTY bytes into the same Ghostty surface used by the live app\r\n\r\n"
            text += "index  timestamp      signal       value       note\r\n"
            text += "-----  -------------  -----------  ----------  -----------------------------\r\n"
            return Data(text.utf8)
        }

        private static func historyBlock(start: Int, count: Int) -> Data {
            var data = Data()
            data.reserveCapacity(count * 96)
            for index in start..<(start + count) {
                data.append(sampleLine(index))
            }
            return data
        }

        private static func sampleLine(_ index: Int) -> Data {
            let signal = ["render", "scroll", "input", "latency", "viewport"][index % 5]
            let paddedSignal = signal.padding(toLength: 11, withPad: " ", startingAt: 0)
            let color = [82, 45, 214, 208, 141][index % 5]
            let value = String(format: "%.3f", Double(index * 37 % 997) / 997.0)
            let text = String(
                format: "%5d  T+%05dms    \u{1b}[38;5;%dm%@\u{1b}[0m  %@      primary scrollback sample\r\n",
                index,
                index * 70,
                color,
                paddedSignal,
                value
            )
            return Data(text.utf8)
        }

        private static var footer: Data {
            var text = "\r\n\u{1b}[38;5;118mready\u{1b}[0m  320 lines loaded. Drag upward to exercise local scrollback.\r\n"
            text += "      This screen intentionally bypasses Google sign-in for the demo build.\r\n"
            return Data(text.utf8)
        }
    }
}
#endif
