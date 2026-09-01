#if os(iOS)
import CMUXMobileCore
import CmuxLocalLinux
import CmuxMobileShellUI
import CmuxMobileSupport
import CmuxMobileTerminal
import Foundation
import Observation
import OSLog
import SwiftUI
import UIKit

private let localLinuxProductionLog = Logger(
    subsystem: "ai.manaflow.cmux.ios",
    category: "local-linux.production"
)

private enum LocalLinuxBootResult: Sendable {
    case success(LocalLinuxSession)
    case failure(LocalLinuxError)
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

/// Owns the process-wide iSH session while one or more Ghostty surfaces attach
/// to it. A view attachment is transient; the session and bounded scrollback
/// survive navigation and window detachment so returning to the row restores
/// the recent shell output.
@MainActor
@Observable
public final class LocalLinuxComputerController {
    public enum State: Equatable, Sendable {
        case idle
        case starting
        case running
        case ended
        case failed
    }

    private static let pendingInputLimit = 64 * 1024
    /// Linux `EAGAIN`, represented as the negative errno returned by iSH's
    /// non-blocking tty bridge when its line buffer is full.
    private static let wouldBlockErrno: Int32 = -11

    /// The injected actor that owns the process-global kernel configuration.
    /// Exposed so DEBUG harnesses can use the same instance as production.
    @ObservationIgnored public let runtime: LocalLinuxRuntime
    @ObservationIgnored private var session: LocalLinuxSession?
    @ObservationIgnored private var ring: LocalLinuxScrollbackRing?
    @ObservationIgnored private var bootTask: Task<LocalLinuxBootResult, Never>?
    @ObservationIgnored private var inputWorker: Task<Void, Never>?
    @ObservationIgnored private var inputWorkerID: UUID?
    @ObservationIgnored private var inputQueue: [Data] = []
    @ObservationIgnored private var inputQueueByteCount = 0
    @ObservationIgnored private var resizeTask: Task<Void, Never>?
    @ObservationIgnored private var pendingInput = Data()
    @ObservationIgnored private var lifecycleGeneration: UInt64 = 0

    public private(set) var state: State = .idle
    public private(set) var lastError: LocalLinuxError?

    public init(runtime: LocalLinuxRuntime) {
        self.runtime = runtime
    }

    /// Starts the shell once and resizes an already-running shell to the latest
    /// Ghostty grid. The blocking kernel boot work runs off the main actor.
    @discardableResult
    public func startIfNeeded(columns: Int = 80, rows: Int = 24) async -> Bool {
        let columns = max(1, columns)
        let rows = max(1, rows)

        // Boot failures are intentionally sticky for this controller and its
        // injected runtime. Re-entering the destination must not repeatedly
        // mutate a partially initialized process or present a misleading
        // retry action. The navigation Back action remains the escape path.
        if state == .failed {
            return false
        }

        if let session {
            // A natural process exit finishes the session's output stream but
            // leaves the actor object retained by the controller. Clear that
            // ended attachment before deciding whether a new boot is needed.
            if await session.isEnded {
                sessionDidEnd(session)
            } else {
                resize(columns: columns, rows: rows)
                state = .running
                return true
            }
        }

        let generation = lifecycleGeneration
        if let bootTask {
            let result = await bootTask.value
            return await install(
                result,
                columns: columns,
                rows: rows,
                generation: generation
            )
        }

        state = .starting
        lastError = nil
        let runtime = runtime
        let task = Task.detached(priority: .userInitiated) { () -> LocalLinuxBootResult in
            do {
                try await runtime.bootIfNeeded()
                let session = try await runtime.openSession(
                    columns: columns,
                    rows: rows
                )
                return .success(session)
            } catch let error as LocalLinuxError {
                return .failure(error)
            } catch {
                localLinuxProductionLog.error(
                    "unexpected local Linux boot error: \(String(describing: error), privacy: .public)"
                )
                return .failure(.sessionOpenFailed(errno: -1))
            }
        }
        bootTask = task
        let result = await task.value
        bootTask = nil
        return await install(
            result,
            columns: columns,
            rows: rows,
            generation: generation
        )
    }

    /// Creates a lane attachment over the retained shell and output ring.
    /// Callers must close the lane when their Ghostty surface is dismantled.
    public func makeLane() -> LocalLinuxTerminalLane? {
        guard let session, let ring else { return nil }
        return LocalLinuxTerminalLane(session: session, ring: ring, cursor: nil)
    }

    /// The session paired with the most recent lane attachment. Coordinators
    /// pass this identity back on natural EOF so a stale lane cannot clear a
    /// newer shell that started while the old output task was unwinding.
    public var currentSession: LocalLinuxSession? {
        session
    }

    /// Sends raw terminal bytes. Ghostty input includes control and escape
    /// sequences, so it must not be lossy-converted through `String` first.
    public func send(_ data: Data) {
        guard !data.isEmpty else { return }
        if session != nil {
            let remaining = Self.pendingInputLimit - inputQueueByteCount
            guard remaining > 0 else {
                localLinuxProductionLog.error(
                    "local Linux input queue is full; dropping \(data.count, privacy: .public) bytes"
                )
                return
            }
            let bytes = Data(data.prefix(remaining))
            inputQueue.append(bytes)
            inputQueueByteCount += bytes.count
            if bytes.count != data.count {
                localLinuxProductionLog.error(
                    "local Linux input queue limit dropped \(data.count - bytes.count, privacy: .public) bytes"
                )
            }
            startInputWorkerIfNeeded()
            return
        }

        let remaining = Self.pendingInputLimit - pendingInput.count
        guard remaining > 0 else {
            localLinuxProductionLog.error(
                "local Linux pending input queue is full; dropping \(data.count, privacy: .public) bytes"
            )
            return
        }
        let bytes = Data(data.prefix(remaining))
        pendingInput.append(bytes)
        if bytes.count != data.count {
            localLinuxProductionLog.error(
                "local Linux pending input limit dropped \(data.count - bytes.count, privacy: .public) bytes"
            )
        }
    }

    /// Gives a blocked input write a fallback retry signal. Production iSH
    /// sessions signal their readiness stream directly; this path remains for
    /// older bridges that only expose output activity.
    public func notifyOutputActivity() {
        guard !inputQueue.isEmpty, let session else { return }
        session.signalInputReady()
    }

    public func resize(columns: Int, rows: Int) {
        guard columns > 0, rows > 0 else { return }
        guard let session else { return }
        let generation = lifecycleGeneration
        resizeTask?.cancel()
        resizeTask = Task { @MainActor [weak self, session] in
            guard let self,
                  self.lifecycleGeneration == generation,
                  self.session === session else { return }
            do {
                try await session.resize(columns: columns, rows: rows)
            } catch {
                guard self.lifecycleGeneration == generation,
                      self.session === session else { return }
                localLinuxProductionLog.error(
                    "local Linux resize failed: \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// Terminates the local shell. Navigation and scene detachment should not
    /// call this; use it only when the local computer is explicitly removed.
    public func terminate() {
        lifecycleGeneration &+= 1
        bootTask?.cancel()
        bootTask = nil
        inputWorker?.cancel()
        inputWorker = nil
        inputWorkerID = nil
        inputQueue.removeAll(keepingCapacity: false)
        inputQueueByteCount = 0
        resizeTask?.cancel()
        resizeTask = nil
        if let session {
            Task { await session.hangup() }
        }
        session = nil
        ring = nil
        pendingInput.removeAll(keepingCapacity: false)
        state = .ended
    }

    /// Records a natural pty exit for exactly the session that produced it.
    /// Lane detaches do not call this method, so navigating away keeps the
    /// shell alive and a later attachment can continue from the ring.
    public func sessionDidEnd(_ endedSession: LocalLinuxSession) {
        guard let session, session === endedSession else { return }
        // Natural EOF has already quiesced the stream. Closing the actor now
        // releases the bridge handle promptly while preserving the identity
        // guard below for any late callbacks.
        Task { await endedSession.close() }
        lifecycleGeneration &+= 1
        bootTask?.cancel()
        bootTask = nil
        inputWorker?.cancel()
        inputWorker = nil
        inputWorkerID = nil
        inputQueue.removeAll(keepingCapacity: false)
        inputQueueByteCount = 0
        resizeTask?.cancel()
        resizeTask = nil
        self.session = nil
        ring = nil
        pendingInput.removeAll(keepingCapacity: false)
        state = .ended
    }

    private func install(
        _ result: LocalLinuxBootResult,
        columns: Int,
        rows: Int,
        generation: UInt64
    ) async -> Bool {
        guard generation == lifecycleGeneration else {
            if case let .success(session) = result {
                await session.hangup()
            }
            return false
        }
        if let session {
            resizeTask?.cancel()
            let resizeGeneration = lifecycleGeneration
            resizeTask = Task { @MainActor [weak self, session] in
                guard let self,
                      self.lifecycleGeneration == resizeGeneration,
                      self.session === session else { return }
                try? await session.resize(columns: columns, rows: rows)
            }
            state = .running
            return true
        }

        switch result {
        case let .success(session):
            guard generation == lifecycleGeneration else {
                await session.hangup()
                return false
            }
            let newRing = LocalLinuxScrollbackRing()
            do {
                // Start the sole output consumer before publishing the session.
                // This drains the runtime's bounded ingress into a fixed-size
                // replay ring immediately, including while the app is inactive
                // or no Ghostty view is mounted.
                try await newRing.start(source: session)
            } catch {
                await session.hangup()
                guard generation == lifecycleGeneration else { return false }
                let localError = LocalLinuxError.operationFailed(
                    "terminal output retention could not start"
                )
                lastError = localError
                state = .failed
                localLinuxProductionLog.error(
                    "local Linux output retention failed: \(String(describing: error), privacy: .public)"
                )
                return false
            }
            // `start(source:)` crosses the ring actor. Teardown can win while
            // it is suspended, so revalidate ownership before installing.
            guard generation == lifecycleGeneration else {
                await session.hangup()
                return false
            }
            self.session = session
            ring = newRing
            resize(columns: columns, rows: rows)
            if !pendingInput.isEmpty {
                let bytes = pendingInput
                pendingInput.removeAll(keepingCapacity: false)
                send(bytes)
            }
            state = .running
            return true
        case let .failure(error):
            lastError = error
            state = .failed
            localLinuxProductionLog.error(
                "local Linux boot failed: \(String(describing: error), privacy: .public)"
            )
            return false
        }
    }

    /// Serializes terminal input through one worker. Ghostty can emit one
    /// callback per keystroke, so a task chain per callback would retain a long
    /// linked list during a paste. This bounded FIFO preserves byte order with
    /// one cancellable task instead.
    private func startInputWorkerIfNeeded() {
        guard inputWorker == nil else { return }
        guard let workerSession = session else { return }
        let workerID = UUID()
        inputWorkerID = workerID
        inputWorker = Task { @MainActor [weak self, workerID, workerSession] in
            guard let self else { return }
            defer {
                if self.inputWorkerID == workerID {
                    self.inputWorkerID = nil
                    self.inputWorker = nil
                }
            }

            // Keep one iterator for the worker's entire lifetime. The
            // bufferingNewest(1) stream preserves an edge that arrives between
            // a zero-byte write and this await, so no polling or timer is
            // needed.
            let readiness = workerSession.inputReady
            var readinessIterator = readiness.makeAsyncIterator()

            while !Task.isCancelled,
                  self.inputWorkerID == workerID,
                  self.session === workerSession,
                  !self.inputQueue.isEmpty {
                let session = workerSession
                // Keep the current element in the FIFO while it is being
                // written. This preserves the exact remainder when the
                // non-blocking tty reports EAGAIN (zero accepted bytes).
                let bytes = self.inputQueue[0]
                var offset = 0
                var waitForReadiness = false

                do {
                    while offset < bytes.count, !Task.isCancelled {
                        guard self.inputWorkerID == workerID,
                              self.session === session else { return }
                        let remainder = Data(bytes.dropFirst(offset))
                        let accepted = try await session.send(remainder)
                        guard self.inputWorkerID == workerID,
                              self.session === session else { return }

                        guard accepted >= 0, accepted <= remainder.count else {
                            // Keep the unsent remainder. A malformed bridge
                            // result is a backpressure boundary, not permission
                            // to lose terminal input.
                            localLinuxProductionLog.error(
                                "local Linux input accepted invalid byte count \(accepted) of \(remainder.count)"
                            )
                            self.markInputFailure(
                                .operationFailed("terminal input returned an invalid byte count")
                            )
                            return
                        }
                        guard accepted > 0 else {
                            // The C shim uses zero for a full non-blocking tty
                            // buffer. Leave the remainder in place and wait
                            // for the next coalesced input-readiness edge.
                            localLinuxProductionLog.error(
                                "local Linux input backpressured with \(remainder.count, privacy: .public) bytes pending"
                            )
                            waitForReadiness = true
                            break
                        }

                        offset += accepted
                        self.inputQueueByteCount -= accepted
                        self.inputQueue[0] = Data(bytes.dropFirst(offset))
                    }
                } catch {
                    // `closed` is expected during teardown. Preserve a
                    // remainder for every other failure so a later explicit
                    // attach can make one more attempt rather than losing it.
                    localLinuxProductionLog.error(
                        "local Linux input failed: \(String(describing: error), privacy: .public)"
                    )
                    if let error = error as? LocalLinuxError, error == .closed {
                        return
                    }
                    // iSH's non-blocking tty API reports a full line buffer as
                    // -EAGAIN. This is temporary backpressure, not a broken
                    // shell. Keep the FIFO head and await the readiness stream.
                    if case let LocalLinuxError.inputFailed(errno) = error,
                       errno == Self.wouldBlockErrno {
                        waitForReadiness = true
                        break
                    }
                    self.markInputFailure(
                        (error as? LocalLinuxError)
                            ?? .operationFailed("terminal input failed")
                    )
                    return
                }

                guard self.inputWorkerID == workerID,
                      self.session === session else { return }
                if offset == bytes.count {
                    self.inputQueue.removeFirst()
                    // `inputQueueByteCount` was decremented per accepted
                    // chunk, so no additional count adjustment is needed.
                }
                if waitForReadiness {
                    guard await readinessIterator.next() != nil else { return }
                    guard !Task.isCancelled,
                          self.inputWorkerID == workerID,
                          self.session === session else { return }
                }
            }
        }
    }

    /// Marks a renderer setup failure so the destination does not remain on a
    /// permanent loading overlay when Ghostty cannot create its surface.
    func markRendererFailure() {
        guard state != .running else { return }
        state = .failed
        lastError = .operationFailed("terminal renderer unavailable")
    }

    /// Exposes an unrecoverable pty write error through the same visible
    /// failure state as boot errors. The pending FIFO remains intact until a
    /// later attachment can make another write attempt, so this boundary
    /// cannot silently lose bytes.
    private func markInputFailure(_ error: LocalLinuxError) {
        guard state != .ended else { return }
        state = .failed
        lastError = error
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
        controller.terminate()
        retryGeneration &+= 1
    }
}

private struct LocalLinuxComputerStatusOverlay: View {
    let state: LocalLinuxComputerController.State
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

            // A natural PTY end can be restarted on this runtime. A boot or
            // renderer failure is sticky for the process, so offering the
            // same action there would only repeat a known failure. The user
            // can use the navigation Back action to leave that error state.
            if state == .ended {
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

        init(controller: LocalLinuxComputerController, sceneIsActive: Bool) {
            self.controller = controller
            self.sceneIsActive = sceneIsActive
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
            outputTask = Task { @MainActor [weak self, generation] in
                guard let self else { return }
                let ready = await controller.startIfNeeded(
                    columns: lastGrid?.columns ?? 80,
                    rows: lastGrid?.rows ?? 24
                )
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

                self.lane = lane
                var outputStreamEnded = false
                var isFirstFrame = true
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
                        if isFirstFrame, frame.kind == .replay {
                            // The local lane's first frame is a complete
                            // bounded history. Ghostty survives a transient
                            // window detach, so clear its retained terminal
                            // model before applying that history. The helper
                            // queues RIS and replay as one FIFO operation.
                            surfaceView.processTerminalReplay(frame.bytes)
                        } else {
                            surfaceView.processOutput(frame.bytes)
                        }
                        isFirstFrame = false
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
            controller.send(data)
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
            controller.send(data)
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
