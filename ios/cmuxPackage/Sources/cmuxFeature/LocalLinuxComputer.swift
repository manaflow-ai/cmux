#if os(iOS)
import CMUXMobileCore
import CmuxLocalLinux
import CmuxMobileShellUI
import CmuxMobileSupport
import CmuxMobileTerminal
import Foundation
import OSLog
import SwiftUI
import UIKit

nonisolated private let localLinuxProductionLog = Logger(
    subsystem: cmuxIOSLogSubsystem,
    category: "local-linux.production"
)

/// The phone-owned computer advertised by the Computers screen.
///
/// This provider is deliberately owned by the composition root. The shell UI
/// only sees the small `MobileLocalComputerProviding` protocol, while this
/// feature module owns the iSH process and the Ghostty surface that displays
/// it. No paired-Mac route or RPC ticket is fabricated for the local shell.
@MainActor
public final class LocalLinuxComputerProvider: MobileLocalComputerProviding {
    public let controller: LocalLinuxComputerController

    public init(controller: LocalLinuxComputerController) {
        self.controller = controller
    }

    /// Creates a provider with one runtime owned by the app composition root.
    public convenience init() {
        self.init(runtime: LocalLinuxRuntime())
    }

    /// Creates a provider over an explicitly injected runtime.
    public convenience init(runtime: LocalLinuxRuntime) {
        self.init(controller: LocalLinuxComputerController(runtime: runtime))
    }

    public var title: String {
        L10n.string(
            "mobile.localLinux.computer.title",
            defaultValue: "This iPhone"
        )
    }

    public var subtitle: String {
        L10n.string(
            "mobile.localLinux.computer.subtitle",
            defaultValue: "Local Alpine Linux"
        )
    }

    public var symbolName: String { "iphone" }

    /// The row is shown only when the rootfs resource is in the app bundle.
    /// Kernel startup errors remain visible in the terminal destination, so a
    /// corrupt or incompatible kernel cannot silently look like a paired Mac.
    public var isAvailable: Bool {
        LocalLinuxRuntime.bundledRootfsURL() != nil
    }

    public func makeDestination() -> AnyView {
        AnyView(LocalLinuxComputerView(controller: controller))
    }
}

/// Production destination for the phone-owned Linux computer.
public struct LocalLinuxComputerView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller: LocalLinuxComputerController
    @State private var retryGeneration: UInt64 = 0

    public init(controller: LocalLinuxComputerController) {
        _controller = State(initialValue: controller)
    }

    public var body: some View {
        ZStack {
            LocalLinuxTerminalRepresentable(
                controller: controller,
                sceneIsActive: scenePhase == .active
            )
            .id(retryGeneration)
            .ignoresSafeArea(.container, edges: .all)
            .background(Color.black)
            .accessibilityIdentifier("cmux.local-linux.terminal")

            if controller.state != .running {
                LocalLinuxComputerStatusOverlay(
                    state: controller.state,
                    canRetry: controller.canRetry,
                    retry: retry
                )
                .padding(.horizontal, 24)
                // Loading is informational. Keep the underlying surface
                // tappable so a user can focus the terminal as soon as the
                // kernel becomes ready, even if the card is still fading out.
                .allowsHitTesting(
                    controller.state != .idle && controller.state != .starting
                )
            }
        }
        .background(Color.black)
        .navigationTitle(
            L10n.string("mobile.localLinux.title", defaultValue: "Local Linux")
        )
        .navigationBarTitleDisplayMode(.inline)
    }

    private func retry() {
        controller.prepareForRetry()
        retryGeneration &+= 1
    }
}

private struct LocalLinuxComputerStatusOverlay: View {
    let state: LocalLinuxComputerController.State
    let canRetry: Bool
    let retry: () -> Void

    private var title: String {
        switch state {
        case .idle, .starting:
            L10n.string("mobile.localLinux.starting", defaultValue: "Starting local Linux…")
        case .running:
            L10n.string("mobile.localLinux.title", defaultValue: "Local Linux")
        case .ended:
            L10n.string("mobile.localLinux.ended", defaultValue: "The local Linux session ended")
        case .failed:
            L10n.string("mobile.localLinux.error.title", defaultValue: "Local Linux is unavailable")
        }
    }

    private var detail: String? {
        switch state {
        case .idle, .starting:
            L10n.string(
                "mobile.localLinux.starting.detail",
                defaultValue: "Preparing an Alpine shell on this device."
            )
        case .running:
            nil
        case .ended:
            L10n.string(
                "mobile.localLinux.ended.detail",
                defaultValue: "Start a new shell to continue."
            )
        case .failed:
            L10n.string(
                "mobile.localLinux.error.linux",
                defaultValue: "The local Linux environment could not start."
            )
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            if state == .idle || state == .starting {
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel(
                        L10n.string(
                            "mobile.localLinux.progress",
                            defaultValue: "Loading local Linux"
                        )
                    )
            } else {
                Image(systemName: state == .failed ? "exclamationmark.triangle" : "pause.circle")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }

            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            if let detail {
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
            }

            // A natural PTY end and a renderer or input failure can be
            // restarted after the controller fences the old session. Boot and
            // rootfs failures remain sticky because the process-global kernel
            // cannot be safely reinitialized in place.
            if canRetry {
                Button(action: retry) {
                    Label(
                        L10n.string("mobile.localLinux.retry", defaultValue: "Try Again"),
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .accessibilityHint(
                    L10n.string(
                        "mobile.localLinux.retry.hint",
                        defaultValue: "Activate Try Again to restart the local shell."
                    )
                )
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(maxWidth: 360)
        .background(.black.opacity(0.86), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.16), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(detail ?? "")
    }
}

private struct LocalLinuxTerminalRepresentable: UIViewRepresentable {
    let controller: LocalLinuxComputerController
    let sceneIsActive: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller, sceneIsActive: sceneIsActive)
    }

    func makeUIView(context: Context) -> UIView {
        guard let runtime = try? GhosttyRuntime.shared() else {
            // UIKit asks `makeUIView` during a SwiftUI update transaction.
            // Defer the observable state write one main-actor turn so the
            // failure overlay does not trigger a "state changed during view
            // update" diagnostic.
            Task { @MainActor [controller] in
                controller.markRendererFailure()
            }
            let label = UILabel()
            label.numberOfLines = 0
            label.textAlignment = .center
            label.textColor = .white
            label.backgroundColor = .black
            label.text = L10n.string(
                "mobile.localLinux.error.renderer",
                defaultValue: "The terminal renderer could not start."
            )
            return label
        }

        let view = GhosttySurfaceView(
            runtime: runtime,
            delegate: context.coordinator,
            fontSize: 12,
            isMacRemote: false
        )
        view.accessibilityIdentifier = "cmux.local-linux.surface"
        context.coordinator.surfaceView = view
        context.coordinator.startIfNeeded()
        // Keep the production terminal on the same host wrapper as paired-Mac
        // surfaces. The wrapper owns keyboard tracking, clipping, and dock
        // placement; returning the bare surface lets the software keyboard
        // cover the terminal and loses the app-lifetime keyboard record.
        return GhosttySurfaceHostView(
            surfaceView: view,
            keyboardFrameTracker: context.environment.mobileKeyboardFrameTracker
                ?? context.coordinator.fallbackKeyboardFrameTracker,
            keyboardDockRebuildRevertEnabled: context.environment.keyboardDockRebuildRevertEnabled
        )
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.setSceneIsActive(sceneIsActive)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        if let host = uiView as? GhosttySurfaceHostView {
            host.surfaceView.prepareForDismantle()
        } else {
            (uiView as? GhosttySurfaceView)?.prepareForDismantle()
        }
        coordinator.stop()
    }

    @MainActor
    final class Coordinator: NSObject, GhosttySurfaceViewDelegate {
        weak var surfaceView: GhosttySurfaceView?

        private let controller: LocalLinuxComputerController
        let fallbackKeyboardFrameTracker = MobileKeyboardFrameTracker()
        private var sceneIsActive: Bool
        private var isWindowAttached = false
        private var outputTask: Task<Void, Never>?
        private var outputGeneration: UInt64 = 0
        private var lane: LocalLinuxTerminalLane?
        private var lastGrid: TerminalGridSize?
        private var inputGeneration: UInt64

        init(controller: LocalLinuxComputerController, sceneIsActive: Bool) {
            self.controller = controller
            self.sceneIsActive = sceneIsActive
            self.inputGeneration = controller.currentInputGeneration
            super.init()
        }

        deinit {
            outputTask?.cancel()
            if let lane {
                Task { await lane.close() }
            }
        }

        func setSceneIsActive(_ active: Bool) {
            guard active != sceneIsActive else { return }
            sceneIsActive = active
            if active {
                startIfNeeded()
            } else {
                stopLane()
            }
        }

        func startIfNeeded() {
            guard isWindowAttached || surfaceView?.window != nil else {
                // UIKit may call makeUIView before assigning a window. The
                // attachment callback below starts the lane at that boundary.
                return
            }
            guard sceneIsActive, outputTask == nil else { return }

            outputGeneration &+= 1
            let generation = outputGeneration
            // Snapshot the request before entering the asynchronous startup.
            // The coordinator owns this task, so capturing `self` across the
            // await would form a cycle and delay teardown if the C bridge open
            // is slow or cancellation cannot interrupt it.
            let controller = self.controller
            let columns = lastGrid?.columns ?? 80
            let rows = lastGrid?.rows ?? 24
            outputTask = Task { @MainActor [weak self, controller, generation, columns, rows] in
                let ready = await controller.startIfNeeded(
                    columns: columns,
                    rows: rows
                )
                guard let self else { return }
                guard !Task.isCancelled, self.outputGeneration == generation else {
                    if self.outputGeneration == generation {
                        self.outputTask = nil
                    }
                    return
                }
                guard ready,
                      let lane = controller.makeLane(),
                      let session = controller.currentSession else {
                    if !ready, !Task.isCancelled, self.outputGeneration == generation {
                        showFailure()
                    }
                    if self.outputGeneration == generation {
                        self.outputTask = nil
                    }
                    return
                }

                guard self.outputGeneration == generation else {
                    await lane.close()
                    return
                }

                self.inputGeneration = controller.currentInputGeneration
                self.lane = lane
                var outputStreamEnded = false
                while !Task.isCancelled, self.outputGeneration == generation {
                    do {
                        guard let frame = try await lane.receiveOutput() else {
                            outputStreamEnded = true
                            break
                        }
                        // Re-check attachment ownership after the receive
                        // suspension. A detach or renderer recovery can
                        // cancel this task while a frame is already queued;
                        // never let that stale frame land after a replacement
                        // lane has started its authoritative replay.
                        guard !Task.isCancelled,
                              self.outputGeneration == generation,
                              self.lane === lane,
                              self.isWindowAttached,
                              self.sceneIsActive,
                              let surfaceView = self.surfaceView else { break }
                        if frame.kind == .replay {
                            // The local lane's first frame is a complete
                            // bounded history. Ghostty survives a transient
                            // window detach and a bounded subscriber overflow,
                            // so clear its retained terminal model before
                            // applying every recovered history frame. The
                            // helper queues RIS and replay as one FIFO op.
                            surfaceView.processTerminalReplay(frame.bytes)
                        } else {
                            surfaceView.processOutput(frame.bytes)
                        }
                        controller.notifyOutputActivity()
                    } catch {
                        localLinuxProductionLog.error(
                            "local Linux output lane failed: \(String(describing: error), privacy: .public)"
                        )
                        break
                    }
                }
                await lane.close()
                // A lane can end because its source process exited, or because
                // this surface detached and cancelled its consumer. Only clear
                // the retained shell for a confirmed natural session end.
                if outputStreamEnded,
                   !Task.isCancelled,
                   self.outputGeneration == generation,
                   sceneIsActive,
                   await session.isEnded {
                    controller.sessionDidEnd(session)
                }
                guard self.outputGeneration == generation else { return }
                self.lane = nil
                outputTask = nil
            }
        }

        func stop() {
            isWindowAttached = false
            stopLane()
            surfaceView = nil
        }

        private func stopLane() {
            outputGeneration &+= 1
            outputTask?.cancel()
            outputTask = nil
            if let lane {
                self.lane = nil
                Task { await lane.close() }
            }
        }

        private func showFailure() {
            let text = L10n.string(
                "mobile.localLinux.error.linux",
                defaultValue: "The local Linux environment could not start."
            )
            surfaceView?.processOutput(Data("\r\n\(text)\r\n".utf8))
        }

        // MARK: GhosttySurfaceViewDelegate

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didChangeWindowAttachment isAttached: Bool) {
            // UIKit may deliver a final callback from a dismantled view after
            // SwiftUI has assigned this coordinator to a replacement view.
            // Never let that stale callback toggle the replacement lane.
            guard self.surfaceView === surfaceView else { return }
            isWindowAttached = isAttached
            if isAttached {
                startIfNeeded()
            } else {
                stopLane()
            }
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {
            guard self.surfaceView === surfaceView else { return }
            controller.send(data, generation: inputGeneration)
        }

        /// Routes terminal-protocol replies generated by Ghostty back to the
        /// embedded PTY. This is separate from user input: programs can issue
        /// device-attribute, cursor-position, or focus queries whose response
        /// originates in the terminal parser rather than the UIKit keyboard.
        func ghosttySurfaceView(
            _ surfaceView: GhosttySurfaceView,
            didProduceTerminalOutput data: Data
        ) {
            guard self.surfaceView === surfaceView else { return }
            controller.send(data, generation: inputGeneration)
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {
            guard self.surfaceView === surfaceView else { return }
            guard size.columns > 0, size.rows > 0 else { return }
            lastGrid = size
            controller.resize(columns: size.columns, rows: size.rows)
            surfaceView.applyConfirmedViewSize(
                cols: size.columns,
                rows: size.rows,
                reportID: reportID
            )
        }

        func ghosttySurfaceViewDidResetRenderPipeline(_ surfaceView: GhosttySurfaceView) {
            guard self.surfaceView === surfaceView,
                  sceneIsActive else { return }
            // Render recovery creates a fresh Ghostty surface but keeps the
            // local iSH session alive. Reopen the attachment so its replay
            // restores the terminal model on the replacement surface.
            stopLane()
            startIfNeeded()
        }

        func ghosttySurfaceViewOwnsLocalPrimaryScreenScroll(_ surfaceView: GhosttySurfaceView) -> Bool {
            true
        }
    }
}
#endif
