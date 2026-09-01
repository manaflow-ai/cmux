#if canImport(UIKit) && DEBUG
import CmuxLocalLinux
import CmuxMobileTerminal
import CmuxMobileTerminalKit
import OSLog
import SwiftUI
import UIKit

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "local-linux.debug")

/// DEBUG harness: a Ghostty surface driven end to end by the embedded iSH
/// kernel (Alpine i386 userland, vendor/ish) with no Mac attached. Mounted
/// from the root scene when the process launches with `--cmux-local-linux`.
struct LocalLinuxDebugView: View {
    var body: some View {
        LocalLinuxDebugRepresentable()
            .ignoresSafeArea(.container, edges: .all)
            .statusBarHidden()
    }
}

private struct LocalLinuxDebugRepresentable: UIViewRepresentable {
    func makeCoordinator() -> LocalLinuxDebugCoordinator {
        LocalLinuxDebugCoordinator()
    }

    func makeUIView(context: Context) -> UIView {
        guard let runtime = try? GhosttyRuntime.shared() else {
            let label = UILabel()
            label.text = "LocalLinux: ghostty runtime init failed"
            label.textColor = .white
            return label
        }
        let view = GhosttySurfaceView(runtime: runtime, delegate: context.coordinator, fontSize: 12)
        context.coordinator.surfaceView = view
        context.coordinator.start()
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}

    static func dismantleUIView(_ uiView: UIView, coordinator: LocalLinuxDebugCoordinator) {
        coordinator.stop()
    }
}

@MainActor
final class LocalLinuxDebugCoordinator: NSObject, GhosttySurfaceViewDelegate {
    weak var surfaceView: GhosttySurfaceView?
    private var session: LocalLinuxSession?
    private var pumpTask: Task<Void, Never>?
    private var lastGrid: TerminalGridSize?

    func start() {
        guard pumpTask == nil else { return }
        pumpTask = Task { @MainActor [weak self] in
            let bootResult = await Task.detached(priority: .userInitiated) { () -> Result<LocalLinuxSession, Error> in
                do {
                    try LocalLinuxRuntime.shared.bootIfNeeded()
                    let session = try LocalLinuxRuntime.shared.openSession(columns: 80, rows: 24)
                    return .success(session)
                } catch {
                    return .failure(error)
                }
            }.value

            guard let self, !Task.isCancelled else { return }
            switch bootResult {
            case .failure(let error):
                log.error("local linux boot failed: \(String(describing: error), privacy: .public)")
                self.surfaceView?.processOutput(Data("\r\nlocal linux boot failed: \(error)\r\n".utf8))
            case .success(let session):
                self.session = session
                if let grid = self.lastGrid {
                    session.resize(columns: grid.columns, rows: grid.rows)
                }
                for await chunk in session.output {
                    guard !Task.isCancelled else { break }
                    self.surfaceView?.processOutput(chunk)
                }
            }
        }
    }

    func stop() {
        pumpTask?.cancel()
        pumpTask = nil
        session?.hangup()
        session = nil
    }

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {
        session?.send(data)
    }

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {
        guard size.columns > 0, size.rows > 0 else { return }
        lastGrid = size
        session?.resize(columns: size.columns, rows: size.rows)
        surfaceView.applyConfirmedViewSize(cols: size.columns, rows: size.rows, reportID: reportID)
    }
}
#endif
