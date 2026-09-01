#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import CmuxLocalLinux
import CmuxMobileSupport
import CmuxMobileTerminal
import CmuxMobileTerminalKit
import OSLog
import SwiftUI
import UIKit

nonisolated private let localLinuxLog = Logger(
    subsystem: "ai.manaflow.cmux.ios",
    category: "local-linux.debug"
)

/// A temporary, DEBUG-only host for the on-device Alpine Linux terminal.
///
/// The view deliberately uses the same ``GhosttySurfaceHostView`` and
/// ``GhosttySurfaceView`` stack that renders a paired Mac terminal. This keeps
/// keyboard, selection, zoom, clipping, and accessibility behavior identical
/// while the local iSH session supplies the PTY bytes.
struct LocalLinuxDebugView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var phase: LocalLinuxDebugPhase = .starting
    @State private var retryGeneration: UInt = 0

    /// The app composition root owns this actor. Keeping it in the view value
    /// makes DEBUG launches use the same process-global kernel as the
    /// production local-computer destination instead of creating a second
    /// bridge during a SwiftUI update.
    private let runtime: LocalLinuxRuntime

    init(runtime: LocalLinuxRuntime = LocalLinuxRuntime()) {
        self.runtime = runtime
    }

    private var sceneIsActive: Bool {
        scenePhase == .active
    }

    var body: some View {
        ZStack {
            LocalLinuxDebugRepresentable(
                runtime: runtime,
                sceneIsActive: sceneIsActive,
                retryGeneration: retryGeneration,
                onPhaseChange: { phase = $0 }
            )
            .id(retryGeneration)
            .ignoresSafeArea(.container, edges: .all)
            .background(Color.black)
            .accessibilityIdentifier("cmux.local-linux.terminal")

            if phase.showsOverlay {
                LocalLinuxStatusOverlay(
                    phase: phase,
                    retry: {
                        phase = .starting
                        retryGeneration &+= 1
                    }
                )
                .padding(.horizontal, 24)
                .transition(.opacity)
            }
        }
        .background(Color.black)
        .statusBarHidden()
    }
}

private enum LocalLinuxDebugPhase: Equatable, Sendable {
    case starting
    case running
    case paused
    case ended
    case failed(LocalLinuxFailure)

    var showsOverlay: Bool {
        switch self {
        case .running:
            false
        case .starting, .paused, .ended, .failed:
            true
        }
    }
}

private enum LocalLinuxFailure: Equatable, Sendable {
    case renderer
    case linux
}

private struct LocalLinuxStatusOverlay: View {
    let phase: LocalLinuxDebugPhase
    let retry: () -> Void

    private var title: String {
        switch phase {
        case .starting:
            L10n.string("mobile.localLinux.starting", defaultValue: "Starting local Linux…")
        case .paused:
            L10n.string("mobile.localLinux.paused", defaultValue: "Local Linux is paused")
        case .ended:
            L10n.string("mobile.localLinux.ended", defaultValue: "The local Linux session ended")
        case .failed:
            L10n.string("mobile.localLinux.error.title", defaultValue: "Local Linux is unavailable")
        case .running:
            L10n.string("mobile.localLinux.title", defaultValue: "Local Linux")
        }
    }

    private var message: String? {
        switch phase {
        case .starting:
            return L10n.string(
                "mobile.localLinux.starting.detail",
                defaultValue: "Preparing an Alpine shell on this device."
            )
        case .paused:
            return L10n.string(
                "mobile.localLinux.paused.detail",
                defaultValue: "Return to cmux to resume the local shell."
            )
        case .ended:
            return L10n.string(
                "mobile.localLinux.ended.detail",
                defaultValue: "Start a new shell to continue."
            )
        case .failed(let failure):
            switch failure {
            case .renderer:
                return L10n.string(
                    "mobile.localLinux.error.renderer",
                    defaultValue: "The terminal renderer could not start."
                )
            case .linux:
                return L10n.string(
                    "mobile.localLinux.error.linux",
                    defaultValue: "The local Linux environment could not start."
                )
            }
        case .running:
            return nil
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            if phase == .starting {
                ProgressView()
                    .tint(.white)
                    .accessibilityLabel(
                        L10n.string("mobile.localLinux.progress", defaultValue: "Loading local Linux")
                    )
            } else {
                Image(systemName: phase == .failed(.renderer) ? "exclamationmark.triangle" : "pause.circle")
                    .font(.title2)
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
            }

            Text(title)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
            }

            if phase != .starting {
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
        // Keep the retry button as its own VoiceOver action. Combining all
        // children into one element would make the status card sound clear
        // but can hide the only recovery control from rotor navigation.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityValue(message ?? "")
        .accessibilityHint(
            phase == .starting
                ? L10n.string("mobile.localLinux.progress.hint", defaultValue: "Please wait.")
                : L10n.string("mobile.localLinux.retry.hint", defaultValue: "Activate Try Again to restart the local shell.")
        )
        // The loading card has no action. Let a user tap the terminal to make
        // it first responder while boot continues, especially when UIKit did
        // not autofocus the surface during a remount.
        .allowsHitTesting(phase != .starting)
    }
}

private struct LocalLinuxDebugRepresentable: UIViewRepresentable {
    let runtime: LocalLinuxRuntime
    let sceneIsActive: Bool
    let retryGeneration: UInt
    let onPhaseChange: @MainActor (LocalLinuxDebugPhase) -> Void

    func makeCoordinator() -> LocalLinuxDebugCoordinator {
        LocalLinuxDebugCoordinator(
            runtime: runtime,
            sceneIsActive: sceneIsActive,
            onPhaseChange: onPhaseChange
        )
    }

    func makeUIView(context: Context) -> UIView {
        guard let runtime = try? GhosttyRuntime.shared() else {
            // Defer the state write until after UIKit finishes this SwiftUI
            // update transaction. A synchronous callback here can trigger
            // "state changed during view update" and leave the retry card in
            // an indeterminate phase.
            let coordinator = context.coordinator
            Task { @MainActor in
                coordinator.report(.failed(.renderer))
            }
            let placeholder = UIView()
            placeholder.backgroundColor = .black
            placeholder.isAccessibilityElement = false
            return placeholder
        }

        let view = GhosttySurfaceView(
            runtime: runtime,
            delegate: context.coordinator,
            fontSize: 12,
            isMacRemote: false
        )
        view.accessibilityIdentifier = "cmux.local-linux.surface"
        context.coordinator.surfaceView = view
        // A representable can be inserted into an already-attached window
        // without a second `updateUIView` pass. The coordinator also listens
        // for the normal attachment callback, but this cheap check closes
        // that UIKit ordering gap.
        context.coordinator.startIfNeeded()
        // Keep the DEBUG harness on the same host wrapper as production
        // surfaces. The wrapper owns keyboard tracking, clipping, and dock
        // placement; returning the bare renderer would allow the software
        // keyboard to cover the terminal and lose the app-lifetime keyboard
        // record when SwiftUI remounts the representable.
        return GhosttySurfaceHostView(
            surfaceView: view,
            keyboardFrameTracker: context.environment.mobileKeyboardFrameTracker
                ?? context.coordinator.fallbackKeyboardFrameTracker,
            keyboardDockRebuildRevertEnabled: context.environment.keyboardDockRebuildRevertEnabled
        )
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.setSceneIsActive(sceneIsActive)
        context.coordinator.startIfNeeded()
        context.coordinator.retryIfNeeded(generation: retryGeneration)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: LocalLinuxDebugCoordinator) {
        // Mark the Ghostty surface dead before cancelling the local lane. UIKit
        // can deliver one final window/resize callback during dismantle; the
        // renderer must reject that callback instead of starting a new session.
        if let host = uiView as? GhosttySurfaceHostView {
            host.surfaceView.prepareForDismantle()
        } else {
            (uiView as? GhosttySurfaceView)?.prepareForDismantle()
        }
        coordinator.stop()
    }
}

@MainActor
private final class LocalLinuxDebugCoordinator: NSObject, GhosttySurfaceViewDelegate {
    weak var surfaceView: GhosttySurfaceView?

    private let runtime: LocalLinuxRuntime
    private let onPhaseChange: @MainActor (LocalLinuxDebugPhase) -> Void
    /// Used by isolated DEBUG harnesses and previews that do not receive the
    /// app-lifetime tracker through the SwiftUI environment.
    let fallbackKeyboardFrameTracker = MobileKeyboardFrameTracker()
    private var session: LocalLinuxSession?
    private var scrollbackRing: LocalLinuxScrollbackRing?
    private var lane: LocalLinuxTerminalLane?
    private var bootTask: Task<Void, Never>?
    private var outputTask: Task<Void, Never>?
    private var inputTask: Task<Void, Never>?
    private var inputWorkerID: UUID?
    private var resizeTask: Task<Void, Never>?
    private var lastGrid: TerminalGridSize?
    private var pendingInput = Data()
    /// Bytes waiting for a non-blocking iSH pty write. Keeping whole queue
    /// elements and updating the head after every accepted prefix prevents a
    /// short write from duplicating bytes on the next retry.
    private var inputQueue: [Data] = []
    private var inputQueueByteCount = 0
    private var isWindowAttached = false
    /// Set when SwiftUI permanently dismantles this coordinator. UIKit can
    /// deliver one last attachment callback while the old surface is being
    /// removed; those callbacks must not publish state into a replacement
    /// representable.
    private var isStopped = false
    private var sceneIsActive: Bool
    private var retryGeneration: UInt = 0
    private var phase: LocalLinuxDebugPhase = .starting

    private nonisolated static let initialColumns = 80
    private nonisolated static let initialRows = 24
    private nonisolated static let pendingInputLimit = 64 * 1024
    /// iSH reports a full non-blocking tty input buffer as negative EAGAIN.
    private nonisolated static let wouldBlockErrno: Int32 = -11

    init(
        runtime: LocalLinuxRuntime,
        sceneIsActive: Bool,
        onPhaseChange: @escaping @MainActor (LocalLinuxDebugPhase) -> Void
    ) {
        self.runtime = runtime
        self.sceneIsActive = sceneIsActive
        self.onPhaseChange = onPhaseChange
        super.init()
    }

    deinit {
        bootTask?.cancel()
        outputTask?.cancel()
        inputTask?.cancel()
        inputWorkerID = nil
        resizeTask?.cancel()
        if let session {
            Task { await session.hangup() }
        }
        if let lane {
            Task { await lane.close() }
        }
    }

    func setSceneIsActive(_ active: Bool) {
        guard !isStopped, active != sceneIsActive else { return }
        sceneIsActive = active
        if active {
            startIfNeeded()
        } else {
            // Ending the session while the app is backgrounded prevents a
            // runaway command from retaining an unbounded output stream. The
            // next foreground mount starts a fresh login shell.
            stopSession(publish: false)
            report(.paused)
        }
    }

    func retryIfNeeded(generation: UInt) {
        guard !isStopped, generation != retryGeneration else { return }
        retryGeneration = generation
        stopSession(publish: false)
        report(.starting)
        startIfNeeded()
    }

    func report(_ nextPhase: LocalLinuxDebugPhase) {
        guard !isStopped, phase != nextPhase else { return }
        phase = nextPhase
        onPhaseChange(nextPhase)
    }

    func startIfNeeded() {
        guard !isStopped,
              sceneIsActive,
              isWindowAttached || surfaceView?.window != nil else { return }
        guard session == nil, bootTask == nil else { return }

        report(.starting)
        let runtime = self.runtime
        let bootTask = Task { @MainActor [weak self, runtime] in
            let result = await Self.bootSession(runtime: runtime)
            guard let self, !Task.isCancelled else {
                if case .success(let session) = result {
                    await session.hangup()
                }
                return
            }

            self.bootTask = nil
            switch result {
            case .success(let session):
                guard self.isWindowAttached, self.sceneIsActive else {
                    await session.hangup()
                    return
                }
                let ring = LocalLinuxScrollbackRing()
                do {
                    // Start draining the pty before publishing the lane. The
                    // iSH output stream can produce bytes immediately after
                    // boot; binding the ring first keeps those bytes in the
                    // bounded replay buffer instead of an unbounded source
                    // stream while resize and the first input are pending.
                    try await ring.start(source: session)
                } catch {
                    localLinuxLog.error(
                        "local Linux output ring failed to start: \(String(describing: error), privacy: .public)"
                    )
                    await session.hangup()
                    self.report(.failed(.linux))
                    return
                }
                let lane = LocalLinuxTerminalLane(session: session, ring: ring)
                self.session = session
                self.scrollbackRing = ring
                self.lane = lane
                if let grid = self.lastGrid {
                    do {
                        try await session.resize(columns: grid.columns, rows: grid.rows)
                    } catch {
                        localLinuxLog.error(
                            "local Linux initial resize failed: \(String(describing: error), privacy: .public)"
                        )
                    }
                } else {
                    do {
                        try await session.resize(
                            columns: Self.initialColumns,
                            rows: Self.initialRows
                        )
                    } catch {
                        localLinuxLog.error(
                            "local Linux initial resize failed: \(String(describing: error), privacy: .public)"
                        )
                    }
                }
                if !self.pendingInput.isEmpty {
                    // Transfer pre-boot bytes exactly once into the same
                    // ordered FIFO used by live callbacks. The worker keeps
                    // any short-write remainder at the queue head.
                    let pendingInput = self.pendingInput
                    self.pendingInput.removeAll(keepingCapacity: false)
                    self.enqueueInput(pendingInput)
                }
                self.report(.running)
                self.startOutputPump(for: lane, session: session)
            case .failure(let error):
                localLinuxLog.error(
                    "local Linux boot failed: \(String(describing: error), privacy: .public)"
                )
                self.report(.failed(.linux))
            case .cancelled:
                return
            }
        }
        self.bootTask = bootTask
    }

    func stop() {
        isStopped = true
        isWindowAttached = false
        stopSession(publish: false)
        surfaceView = nil
    }

    private func stopSession(publish: Bool) {
        bootTask?.cancel()
        bootTask = nil
        stopLane()
        inputTask?.cancel()
        inputTask = nil
        inputWorkerID = nil
        resizeTask?.cancel()
        resizeTask = nil
        if let session {
            Task { await session.hangup() }
        }
        scrollbackRing = nil
        session = nil
        inputQueue.removeAll(keepingCapacity: false)
        inputQueueByteCount = 0
        pendingInput.removeAll(keepingCapacity: false)
        if publish {
            report(.ended)
        }
    }

    /// Detaches the output subscription without terminating the local shell.
    /// Render-pipeline recovery replaces Ghostty's surface model, so the
    /// existing session and bounded ring must remain alive while a new lane
    /// emits its authoritative replay into that replacement model.
    private func stopLane() {
        outputTask?.cancel()
        outputTask = nil
        if let lane {
            self.lane = nil
            Task { await lane.close() }
        }
    }

    /// Reopens a lane over the current session and ring. This is used only for
    /// renderer recovery; scene/window detachment still uses `stopSession` in
    /// this DEBUG harness so the next foreground mount starts a clean shell.
    private func restartLaneIfNeeded() {
        guard !isStopped,
              sceneIsActive,
              isWindowAttached,
              outputTask == nil,
              let session,
              let scrollbackRing else { return }
        let lane = LocalLinuxTerminalLane(session: session, ring: scrollbackRing)
        self.lane = lane
        startOutputPump(for: lane, session: session)
    }

    private func startOutputPump(for lane: LocalLinuxTerminalLane, session: LocalLinuxSession) {
        outputTask?.cancel()
        outputTask = Task { @MainActor [weak self, lane, session] in
            defer {
                Task {
                    await lane.close()
                }
            }

            do {
                var isFirstFrame = true
                while !Task.isCancelled {
                    guard let frame = try await lane.receiveOutput() else { break }
                    guard !Task.isCancelled else { return }
                    guard let self,
                          self.session === session,
                          self.lane === lane,
                          self.isWindowAttached,
                          self.sceneIsActive,
                          let surfaceView = self.surfaceView else {
                        // The lane belongs to a detached or superseded
                        // surface. Stop consuming immediately; the defer
                        // below closes only this lane so a renderer reset can
                        // reopen the same session and replay its ring.
                        break
                    }
                    if isFirstFrame, frame.kind == .replay {
                        // UIKit can reuse this Ghostty view after a
                        // background/foreground transition. Reset the
                        // retained terminal model before applying the new
                        // session's history, in one FIFO output operation.
                        surfaceView.processTerminalReplay(frame.bytes)
                    } else {
                        surfaceView.processOutput(frame.bytes)
                    }
                    isFirstFrame = false
                    // A full non-blocking tty can accept zero bytes until
                    // the foreground process consumes output. Each output
                    // frame is a progress signal, so retry the retained FIFO
                    // head without polling or sleeping.
                    self.startInputWorkerIfNeeded()
                }
            } catch {
                guard let self,
                      !Task.isCancelled,
                      self.session === session,
                      self.lane === lane else { return }
                localLinuxLog.error(
                    "local Linux output lane failed: \(String(describing: error), privacy: .public)"
                )
            }

            guard let self,
                  !Task.isCancelled,
                  self.session === session,
                  self.lane === lane,
                  self.isWindowAttached,
                  self.sceneIsActive else { return }
            // The output stream ended or failed while this task still owned
            // the active lane. Release the session before clearing references;
            // explicit detach/recovery cancellation clears `lane` first and
            // therefore skips this path.
            await session.hangup()
            guard !Task.isCancelled,
                  self.session === session,
                  self.lane === lane else { return }
            self.lane = nil
            self.scrollbackRing = nil
            self.session = nil
            self.outputTask = nil
            self.inputTask?.cancel()
            self.inputTask = nil
            self.inputWorkerID = nil
            self.inputQueue.removeAll(keepingCapacity: false)
            self.inputQueueByteCount = 0
            self.resizeTask?.cancel()
            self.resizeTask = nil
            self.report(.ended)
        }
    }

    private enum BootResult: Sendable {
        case success(LocalLinuxSession)
        case failure(LocalLinuxError)
        case cancelled
    }

    private nonisolated static func bootSession(runtime: LocalLinuxRuntime) async -> BootResult {
        let worker = Task.detached(priority: .userInitiated) {
            do {
                try Task.checkCancellation()
                try await runtime.bootIfNeeded()
                try Task.checkCancellation()
                let session = try await runtime.openSession(
                    columns: Self.initialColumns,
                    rows: Self.initialRows
                )
                guard !Task.isCancelled else {
                    await session.hangup()
                    return BootResult.cancelled
                }
                return BootResult.success(session)
            } catch is CancellationError {
                return BootResult.cancelled
            } catch let error as LocalLinuxError {
                return BootResult.failure(error)
            } catch {
                localLinuxLog.error(
                    "unexpected local Linux boot error: \(String(describing: error), privacy: .public)"
                )
                return BootResult.failure(.sessionOpenFailed(errno: -1))
            }
        }

        return await withTaskCancellationHandler(operation: {
            await worker.value
        }, onCancel: {
            worker.cancel()
        })
    }

    // MARK: GhosttySurfaceViewDelegate

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didChangeWindowAttachment isAttached: Bool) {
        // UIKit can deliver a final callback from an old surface after a
        // SwiftUI representable has installed a replacement. Do not let that
        // callback start or stop the replacement session.
        guard !isStopped, self.surfaceView === surfaceView else { return }
        isWindowAttached = isAttached
        if isAttached {
            startIfNeeded()
        } else {
            stopSession(publish: false)
            report(.paused)
        }
    }

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didProduceInput data: Data) {
        guard !isStopped, self.surfaceView === surfaceView else { return }
        guard !data.isEmpty else { return }
        enqueueInput(data)
    }

    /// Feed terminal responses generated by libghostty back into the local
    /// iSH pty. This uses the same ordered writer and bounded pre-boot queue as
    /// user input, so a query response cannot overtake a preceding keystroke.
    func ghosttySurfaceView(
        _ surfaceView: GhosttySurfaceView,
        didProduceTerminalOutput data: Data
    ) {
        guard !isStopped, self.surfaceView === surfaceView else { return }
        ghosttySurfaceView(surfaceView, didProduceInput: data)
    }

    /// Enqueue one raw terminal operation. User keystrokes and libghostty
    /// protocol replies share this FIFO, preserving byte order while keeping
    /// both the pre-boot and live queues bounded.
    private func enqueueInput(_ data: Data) {
        guard !data.isEmpty else { return }

        if session != nil {
            let remaining = Self.pendingInputLimit - inputQueueByteCount
            guard remaining > 0 else {
                localLinuxLog.error(
                    "local Linux input queue is full; dropping \(data.count, privacy: .public) bytes"
                )
                return
            }
            let bytes = Data(data.prefix(remaining))
            inputQueue.append(bytes)
            inputQueueByteCount += bytes.count
            if bytes.count != data.count {
                localLinuxLog.error(
                    "local Linux input queue limit dropped \(data.count - bytes.count, privacy: .public) bytes"
                )
            }
            startInputWorkerIfNeeded()
            return
        }

        // The renderer can become first responder before the iSH boot worker
        // finishes. Keep a bounded amount of early typing so a fast user does
        // not lose the first command, while preventing an accidental paste
        // from growing memory during a failed boot.
        let remaining = Self.pendingInputLimit - pendingInput.count
        guard remaining > 0 else {
            localLinuxLog.error(
                "local Linux pending input queue is full; dropping \(data.count, privacy: .public) bytes"
            )
            return
        }
        let bytes = Data(data.prefix(remaining))
        pendingInput.append(bytes)
        if bytes.count != data.count {
            localLinuxLog.error(
                "local Linux pending input limit dropped \(data.count - bytes.count, privacy: .public) bytes"
            )
        }
    }

    /// Serialize non-blocking pty writes and retain each unsent suffix. A
    /// zero-byte write or EAGAIN waits on the session's coalesced readiness
    /// stream, so a foreground reader that produces no output still frees the
    /// queued bytes without polling.
    private func startInputWorkerIfNeeded() {
        guard inputTask == nil,
              let session,
              !inputQueue.isEmpty else { return }

        let workerID = UUID()
        inputWorkerID = workerID
        inputTask = Task { @MainActor [weak self, session, workerID] in
            guard let self else { return }
            defer {
                if self.inputWorkerID == workerID {
                    self.inputWorkerID = nil
                    self.inputTask = nil
                }
            }

            var readinessIterator = session.inputReady.makeAsyncIterator()

            while !Task.isCancelled,
                  self.inputWorkerID == workerID,
                  self.session === session,
                  !self.inputQueue.isEmpty {
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
                            localLinuxLog.error(
                                "local Linux input accepted invalid byte count \(accepted) of \(remainder.count)"
                            )
                            self.report(.failed(.linux))
                            return
                        }
                        guard accepted > 0 else {
                            // iSH uses zero for a full non-blocking tty input
                            // buffer. Keep the exact remainder until the
                            // emulated process consumes input.
                            waitForReadiness = true
                            break
                        }

                        offset += accepted
                        self.inputQueueByteCount -= accepted
                        self.inputQueue[0] = Data(bytes.dropFirst(offset))
                    }
                } catch {
                    // The session can close while a write is suspended. Its
                    // owner clears the queue during teardown, so do not turn
                    // that expected race into a visible error.
                    if let localError = error as? LocalLinuxError,
                       localError == .closed {
                        return
                    }

                    // A full non-blocking tty is temporary backpressure, not
                    // a failed shell. Keep the head and await readiness.
                    if case let LocalLinuxError.inputFailed(errno) = error,
                       errno == Self.wouldBlockErrno {
                        waitForReadiness = true
                    } else {
                        localLinuxLog.error(
                            "local Linux input failed: \(String(describing: error), privacy: .public)"
                        )
                        self.report(.failed(.linux))
                        return
                    }
                }

                guard self.inputWorkerID == workerID,
                      self.session === session else { return }
                if offset == bytes.count {
                    self.inputQueue.removeFirst()
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

    func ghosttySurfaceView(_ surfaceView: GhosttySurfaceView, didResize size: TerminalGridSize, reportID: UInt64) {
        guard !isStopped, self.surfaceView === surfaceView else { return }
        guard size.columns > 0, size.rows > 0 else { return }
        lastGrid = size
        if let session {
            resizeTask?.cancel()
            resizeTask = Task { @MainActor [weak self, session] in
                guard !Task.isCancelled, let self, self.session === session else { return }
                do {
                    try await session.resize(columns: size.columns, rows: size.rows)
                } catch {
                    localLinuxLog.error(
                        "local Linux resize failed: \(String(describing: error), privacy: .public)"
                    )
                }
            }
        }
        surfaceView.applyConfirmedViewSize(
            cols: size.columns,
            rows: size.rows,
            reportID: reportID
        )
    }

    func ghosttySurfaceViewDidResetRenderPipeline(_ surfaceView: GhosttySurfaceView) {
        guard !isStopped,
              self.surfaceView === surfaceView,
              sceneIsActive,
              isWindowAttached else { return }
        // Keep the active iSH shell and ring. Only the lane is replaced, so
        // the replacement Ghostty surface receives a complete replay without
        // racing an asynchronous old-session hangup against a new boot.
        stopLane()
        restartLaneIfNeeded()
    }

    /// The local pty owns the primary screen, so Ghostty can apply its bounded
    /// scrollback ring locally. Returning `false` would route wheel gestures to
    /// the no-op remote callback and make a long Alpine transcript appear
    /// unscrollable.
    func ghosttySurfaceViewOwnsLocalPrimaryScreenScroll(_ surfaceView: GhosttySurfaceView) -> Bool {
        true
    }
}
#endif
