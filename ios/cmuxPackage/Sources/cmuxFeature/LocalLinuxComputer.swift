#if os(iOS)
import CMUXMobileCore
import CmuxLocalLinux
import CmuxMobileShellUI
import CmuxMobileSupport
import Foundation
import OSLog
import SwiftUI
import UIKit

/// Every user-facing string of the local Linux feature, in one place.
enum LocalLinuxStrings {
    static var computerTitle: String {
        L10n.string("mobile.localLinux.computer.title", defaultValue: "This iPhone")
    }

    static var computerSubtitle: String {
        L10n.string("mobile.localLinux.computer.subtitle", defaultValue: "Local Alpine Linux")
    }

    static var title: String {
        L10n.string("mobile.localLinux.title", defaultValue: "Local Linux")
    }

    static var starting: String {
        L10n.string("mobile.localLinux.starting", defaultValue: "Starting local Linux…")
    }

    static var startingDetail: String {
        L10n.string(
            "mobile.localLinux.starting.detail",
            defaultValue: "Preparing an Alpine shell on this device."
        )
    }

    static var progress: String {
        L10n.string("mobile.localLinux.progress", defaultValue: "Loading local Linux")
    }

    static var ended: String {
        L10n.string("mobile.localLinux.ended", defaultValue: "The local Linux session ended")
    }

    static var endedDetail: String {
        L10n.string("mobile.localLinux.ended.detail", defaultValue: "Start a new shell to continue.")
    }

    static var errorTitle: String {
        L10n.string("mobile.localLinux.error.title", defaultValue: "Local Linux is unavailable")
    }

    static var retry: String {
        L10n.string("mobile.localLinux.retry", defaultValue: "Try Again")
    }

    static var retryHint: String {
        L10n.string(
            "mobile.localLinux.retry.hint",
            defaultValue: "Activate Try Again to restart the local shell."
        )
    }

    /// One sentence per failure class so a missing image, a kernel fault, a
    /// dead renderer, and a broken pty are distinguishable without logs.
    static func detail(for error: LocalLinuxError?) -> String {
        switch error {
        case .rootfsAssetMissing:
            L10n.string(
                "mobile.localLinux.error.rootfsMissing",
                defaultValue: "This build does not include the Linux system image."
            )
        case .rootfsImportFailed, .rootfsActivationFailed, .rootfsPersistenceFailed:
            L10n.string(
                "mobile.localLinux.error.rootfsInstall",
                defaultValue: "The Linux system image could not be installed on this device."
            )
        case .bootFailed, .kernelUnavailable, .notBooted:
            L10n.string(
                "mobile.localLinux.error.boot",
                defaultValue: "The Linux kernel could not start."
            )
        case .sessionOpenFailed, .invalidCommand, .invalidDimensions:
            L10n.string(
                "mobile.localLinux.error.session",
                defaultValue: "A shell could not be opened."
            )
        case .rendererUnavailable:
            L10n.string(
                "mobile.localLinux.error.renderer",
                defaultValue: "The terminal renderer is unavailable."
            )
        case .inputFailed, .inputByteCountInvalid:
            L10n.string(
                "mobile.localLinux.error.input",
                defaultValue: "The shell stopped accepting input."
            )
        default:
            L10n.string(
                "mobile.localLinux.error.linux",
                defaultValue: "The local Linux environment could not start."
            )
        }
    }
}

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

    public var title: String { LocalLinuxStrings.computerTitle }

    public var subtitle: String { LocalLinuxStrings.computerSubtitle }

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

/// Production destination for the phone-owned Linux computer. The DEBUG
/// launch switch mounts this same view, so there is one lifecycle path.
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
            .accessibilityIdentifier(LocalLinuxAccessibilityIdentifier.terminal)

            if controller.state != .running {
                LocalLinuxComputerStatusOverlay(
                    state: controller.state,
                    error: controller.lastError,
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
        .navigationTitle(LocalLinuxStrings.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func retry() {
        controller.prepareForRetry()
        retryGeneration &+= 1
    }
}

private struct LocalLinuxComputerStatusOverlay: View {
    let state: LocalLinuxComputerController.State
    let error: LocalLinuxError?
    let canRetry: Bool
    let retry: () -> Void

    private var title: String {
        switch state {
        case .idle, .starting:
            LocalLinuxStrings.starting
        case .running:
            LocalLinuxStrings.title
        case .ended:
            LocalLinuxStrings.ended
        case .failed:
            LocalLinuxStrings.errorTitle
        }
    }

    private var detail: String? {
        switch state {
        case .idle, .starting:
            LocalLinuxStrings.startingDetail
        case .running:
            nil
        case .ended:
            LocalLinuxStrings.endedDetail
        case .failed:
            LocalLinuxStrings.detail(for: error)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            if state == .idle || state == .starting {
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel(LocalLinuxStrings.progress)
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
                    Label(LocalLinuxStrings.retry, systemImage: "arrow.clockwise")
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(.black)
                .accessibilityHint(LocalLinuxStrings.retryHint)
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

/// Placeholder returned when the shared Ghostty renderer cannot be created.
///
/// SwiftUI calls ``UIViewRepresentable.makeUIView`` during reconciliation.
/// Publishing the failure from that method would mutate the parent observable
/// during the update transaction. UIKit calls these lifecycle hooks once the
/// placeholder is installed, and the coordinator publishes on the next turn.
@MainActor
private final class LocalLinuxRendererFailurePlaceholderView: UIView {
    var onInstall: (@MainActor () -> Void)?

    private var didReportInstallation = false

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        reportInstallationIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        reportInstallationIfNeeded()
    }

    private func reportInstallationIfNeeded() {
        guard superview != nil || window != nil, !didReportInstallation else { return }
        didReportInstallation = true
        let callback = onInstall
        onInstall = nil
        callback?()
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
            return makeRendererFailurePlaceholder(context: context)
        }

        let view = GhosttySurfaceView(
            runtime: runtime,
            delegate: context.coordinator,
            fontSize: 12,
            isMacRemote: false
        )
        // The shared runtime can exist while libghostty still fails to create
        // the actual surface. Do not start a local PTY behind a view that can
        // only discard its output. The placeholder reports the same deferred
        // failure as a runtime acquisition error after UIKit installs it.
        guard view.hasRendererSurface else {
            // The bridge can retain a failed view until its C teardown is
            // complete. Dispose it before returning a different UIView from
            // this representable, so a failed mount cannot leak a view cycle.
            view.prepareForDismantle()
            return makeRendererFailurePlaceholder(context: context)
        }
        view.accessibilityIdentifier = LocalLinuxAccessibilityIdentifier.surface
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

    private func makeRendererFailurePlaceholder(context: Context) -> UIView {
        let placeholder = LocalLinuxRendererFailurePlaceholderView()
        placeholder.onInstall = { [weak coordinator = context.coordinator] in
            coordinator?.rendererFailurePlaceholderDidInstall()
        }
        placeholder.backgroundColor = .black
        placeholder.isAccessibilityElement = false
        return placeholder
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

    /// Bridges one Ghostty surface to the controller: attaches for output,
    /// forwards input with the attachment's generation, and detaches when the
    /// surface leaves the window or the scene goes inactive. It never decides
    /// whether the shell has ended; the controller owns that.
    @MainActor
    final class Coordinator: NSObject, GhosttySurfaceViewDelegate {
        weak var surfaceView: GhosttySurfaceView?

        private let controller: LocalLinuxComputerController
        let fallbackKeyboardFrameTracker = MobileKeyboardFrameTracker()
        private var sceneIsActive: Bool
        private var isWindowAttached = false
        private var outputTask: Task<Void, Never>?
        private var outputGeneration: UInt64 = 0
        private var attachment: LocalLinuxAttachment?
        private var lastGrid: TerminalGridSize?
        private var rendererFailureTask: Task<Void, Never>?
        private var isStopped = false

        init(controller: LocalLinuxComputerController, sceneIsActive: Bool) {
            self.controller = controller
            self.sceneIsActive = sceneIsActive
            super.init()
        }

        deinit {
            rendererFailureTask?.cancel()
            outputTask?.cancel()
            if let attachment {
                Task { await attachment.lane.close() }
            }
        }

        func setSceneIsActive(_ active: Bool) {
            guard active != sceneIsActive else { return }
            sceneIsActive = active
            if active {
                startIfNeeded()
            } else {
                detach()
            }
        }

        func startIfNeeded() {
            guard isWindowAttached || surfaceView?.window != nil else {
                // UIKit may call makeUIView before assigning a window. The
                // attachment callback below starts the lane at that boundary.
                return
            }
            guard let surfaceView, surfaceView.hasRendererSurface else {
                rendererFailurePlaceholderDidInstall()
                return
            }
            guard sceneIsActive, outputTask == nil else { return }

            outputGeneration &+= 1
            let generation = outputGeneration
            // Snapshot the request before entering the asynchronous startup.
            // The coordinator owns this task, so capturing `self` strongly
            // across the await would form a cycle and delay teardown if the C
            // bridge open is slow or cancellation cannot interrupt it.
            let controller = self.controller
            let columns = lastGrid?.columns ?? LocalLinuxComputerController.fallbackGrid.columns
            let rows = lastGrid?.rows ?? LocalLinuxComputerController.fallbackGrid.rows
            outputTask = Task { @MainActor [weak self, controller, generation, columns, rows] in
                let attachment = await controller.attach(columns: columns, rows: rows)
                guard let self else {
                    if let attachment {
                        await attachment.lane.close()
                    }
                    return
                }
                guard !Task.isCancelled, self.outputGeneration == generation else {
                    if let attachment {
                        await attachment.lane.close()
                    }
                    if self.outputGeneration == generation {
                        self.outputTask = nil
                    }
                    return
                }
                guard let attachment else {
                    // The overlay shows `controller.lastError`; nothing is
                    // written into the terminal so there is one message path.
                    self.outputTask = nil
                    return
                }

                self.attachment = attachment
                let lane = attachment.lane
                while !Task.isCancelled, self.outputGeneration == generation {
                    do {
                        guard let frame = try await lane.receiveOutput() else { break }
                        // Re-check attachment ownership after the receive
                        // suspension. A detach or renderer recovery can
                        // cancel this task while a frame is already queued;
                        // never let that stale frame land after a replacement
                        // lane has started its authoritative replay.
                        guard !Task.isCancelled,
                              self.outputGeneration == generation,
                              self.attachment?.lane === lane,
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
                    } catch {
                        LocalLinuxLog.logger.error(
                            "local Linux output lane failed: \(String(describing: error), privacy: .public)"
                        )
                        break
                    }
                }
                await lane.close()
                guard self.outputGeneration == generation else { return }
                self.attachment = nil
                self.outputTask = nil
            }
        }

        func stop() {
            isStopped = true
            rendererFailureTask?.cancel()
            rendererFailureTask = nil
            isWindowAttached = false
            detach()
            surfaceView = nil
        }

        /// Publishes the renderer failure on the next MainActor turn. This is
        /// reachable synchronously from `makeUIView` (a surface without a
        /// renderer) and from the placeholder's UIKit insertion hooks, both of
        /// which can run inside SwiftUI's update transaction. One task hop is
        /// enough to leave that transaction; no yield or delay is involved.
        func rendererFailurePlaceholderDidInstall() {
            guard !isStopped, rendererFailureTask == nil else { return }
            rendererFailureTask = Task { @MainActor [weak self] in
                guard let self, !Task.isCancelled, !self.isStopped else { return }
                self.controller.markRendererFailure()
                self.rendererFailureTask = nil
            }
        }

        private func detach() {
            outputGeneration &+= 1
            outputTask?.cancel()
            outputTask = nil
            if let attachment {
                self.attachment = nil
                Task { await attachment.lane.close() }
            }
        }

        /// Attached surfaces send with their generation so a replaced surface
        /// cannot write into a replacement pty. Before the attachment exists,
        /// typeahead is queued against the current generation and flushed
        /// when the pty opens.
        private func forwardInput(_ data: Data) {
            guard !isStopped else { return }
            if let attachment {
                controller.send(data, generation: attachment.generation)
            } else {
                controller.send(data)
            }
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
                detach()
            }
        }

        func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {
            guard self.surfaceView === surfaceView else { return }
            forwardInput(data)
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
            forwardInput(data)
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
            guard surfaceView.hasRendererSurface else {
                rendererFailurePlaceholderDidInstall()
                return
            }
            // Render recovery creates a fresh Ghostty surface but keeps the
            // local iSH session alive. Reopen the attachment so its replay
            // restores the terminal model on the replacement surface.
            detach()
            startIfNeeded()
        }

        func ghosttySurfaceViewOwnsLocalPrimaryScreenScroll(_ surfaceView: GhosttySurfaceView) -> Bool {
            true
        }
    }
}
#endif
