#if canImport(UIKit) && DEBUG
import CMUXMobileCore
import CmuxLocalLinux
import CmuxMobileSupport
import CmuxMobileTerminal
import CmuxMobileTerminalKit
import OSLog
import os.lock
import SwiftUI
import UIKit

nonisolated private let localLinuxLog = Logger(
    subsystem: "ai.manaflow.cmux.ios",
    category: "local-linux.debug"
)

/// Retains startup and session-close completion across a SwiftUI remount.
///
/// The retry action changes the representable identity, so its coordinator is
/// destroyed before the replacement coordinator starts. A coordinator-local
/// task would be released with the old object and could let the replacement
/// call into iSH while the old C pty is still unwinding. The outer DEBUG view
/// owns this fence in `@State`, which survives that identity change. The lock
/// only protects the short task/identity exchange; the potentially blocking
/// C hangup always runs in the detached task.
private nonisolated final class LocalLinuxDebugLifecycleFence: @unchecked Sendable {
    private struct State: Sendable {
        var closeTask: Task<Void, Never>?
        var closeID: UUID?
        var bootDrainTask: Task<Void, Never>?
        var bootDrainID: UUID?
    }

    // lint:allow lock: sanctioned carve-out for this synchronous C-lifecycle fence.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Starts and retains a close for `session`, chaining it after an earlier
    /// close if one is still settling. This method is synchronous so teardown
    /// can publish its state before SwiftUI creates a replacement coordinator.
    func schedule(_ session: LocalLinuxSession?) {
        guard let session else { return }
        state.withLock { state in
            let previous = state.closeTask
            let task = Task.detached(priority: .utility) {
                if let previous {
                    await previous.value
                }
                await session.hangup()
            }
            state.closeTask = task
            state.closeID = UUID()
        }
    }

    /// Retains a cancelled boot drain until the synchronous C open has
    /// returned. A replacement coordinator must await this operation before
    /// it starts another open. The caller supplies the identity so an old
    /// drain cannot clear a newer one while its completion callback unwinds.
    func registerBootDrain(_ task: Task<Void, Never>, id: UUID) {
        state.withLock { state in
            state.bootDrainTask = task
            state.bootDrainID = id
        }
    }

    /// Releases one boot-drain identity after its underlying startup task has
    /// settled. This is called before a stale coordinator asks itself to retry,
    /// so that self-retry cannot wait on its own completed drain.
    func completeBootDrain(id: UUID) {
        state.withLock { state in
            guard state.bootDrainID == id else { return }
            state.bootDrainTask = nil
            state.bootDrainID = nil
        }
    }

    /// Awaits every boot drain and session close scheduled before or during
    /// this wait. A newer retry can append another task while the current task
    /// is awaited, so metadata is cleared only when the identity still
    /// matches. Boot drains are observed first, which keeps a still-running C
    /// open from overlapping a session hangup or replacement open.
    func wait() async {
        while true {
            let snapshot = state.withLock { state in
                (
                    closeTask: state.closeTask,
                    closeID: state.closeID,
                    bootDrainTask: state.bootDrainTask,
                    bootDrainID: state.bootDrainID
                )
            }
            var waited = false

            if let task = snapshot.bootDrainTask {
                waited = true
                await task.value
                state.withLock { state in
                    guard state.bootDrainID == snapshot.bootDrainID else { return }
                    state.bootDrainTask = nil
                    state.bootDrainID = nil
                }
            }

            if let task = snapshot.closeTask {
                waited = true
                await task.value
                state.withLock { state in
                    guard state.closeID == snapshot.closeID else { return }
                    state.closeTask = nil
                    state.closeID = nil
                }
            }

            if !waited {
                return
            }
        }
    }
}

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
    /// Survives `.id(retryGeneration)` so a replacement coordinator waits for
    /// the previous session's asynchronous C teardown.
    @State private var lifecycleFence = LocalLinuxDebugLifecycleFence()

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
                lifecycleFence: lifecycleFence,
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
    let lifecycleFence: LocalLinuxDebugLifecycleFence
    let sceneIsActive: Bool
    let retryGeneration: UInt
    let onPhaseChange: @MainActor (LocalLinuxDebugPhase) -> Void

    func makeCoordinator() -> LocalLinuxDebugCoordinator {
        LocalLinuxDebugCoordinator(
            runtime: runtime,
            lifecycleFence: lifecycleFence,
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
                coordinator.failRenderer()
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
    private let lifecycleFence: LocalLinuxDebugLifecycleFence
    private let onPhaseChange: @MainActor (LocalLinuxDebugPhase) -> Void
    /// Used by isolated DEBUG harnesses and previews that do not receive the
    /// app-lifetime tracker through the SwiftUI environment.
    let fallbackKeyboardFrameTracker = MobileKeyboardFrameTracker()
    private var session: LocalLinuxSession?
    /// Tracks a successful open while its bounded ring is being attached.
    /// Teardown can run during that suspension, so it must close this handle
    /// before a retry starts another shell.
    private var pendingSession: LocalLinuxSession?
    private var scrollbackRing: LocalLinuxScrollbackRing?
    private var lane: LocalLinuxTerminalLane?
    private var bootTask: Task<Void, Never>?
    /// Generation associated with `bootTask`. A task from an invalidated
    /// generation stays retained until its cancellation has settled, so a
    /// retry cannot open a second pty while the old open is still suspended.
    private var bootTaskGeneration: UInt?
    /// Waits for a cancelled boot to finish. This is separate from
    /// `bootTask`, which remains the owner of the old operation until the
    /// barrier releases it.
    private var bootDrainTask: Task<Void, Never>?
    private var bootDrainGeneration: UInt?
    /// A retry or foreground attachment asks for a boot. The drain callback
    /// consumes this intent only after the previous operation is quiescent.
    private var bootStartRequested = false
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
    /// Blocks callbacks from a dismantled surface until a replacement session
    /// is fully installed. This keeps stale bytes out of the next shell.
    private var acceptsInput = true
    private var sceneIsActive: Bool
    private var retryGeneration: UInt = 0
    /// Invalidates every suspended boot/install continuation when the
    /// representable is detached, retried, or replaced. A cancellation alone
    /// is not enough because an await can already have returned by the time
    /// UIKit calls stopSession.
    private var lifecycleGeneration: UInt = 0
    private var phase: LocalLinuxDebugPhase = .starting

    private nonisolated static let initialColumns = 80
    private nonisolated static let initialRows = 24
    private nonisolated static let pendingInputLimit = 64 * 1024
    /// iSH reports a full non-blocking tty input buffer as negative EAGAIN.
    private nonisolated static let wouldBlockErrno: Int32 = -11

    init(
        runtime: LocalLinuxRuntime,
        lifecycleFence: LocalLinuxDebugLifecycleFence,
        sceneIsActive: Bool,
        onPhaseChange: @escaping @MainActor (LocalLinuxDebugPhase) -> Void
    ) {
        self.runtime = runtime
        self.lifecycleFence = lifecycleFence
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
        lifecycleFence.schedule(pendingSession)
        lifecycleFence.schedule(session)
        _ = pendingSession?.beginClose()
        _ = session?.beginClose()
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

    /// Stops an in-flight boot before exposing a renderer failure. UIKit can
    /// request a replacement surface while the detached iSH open is still
    /// suspended; leaving that task alive would let it publish a shell behind
    /// the error card.
    func failRenderer() {
        guard !isStopped else { return }
        stopSession(publish: false)
        report(.failed(.renderer))
    }

    func startIfNeeded() {
        guard !isStopped,
              sceneIsActive,
              isWindowAttached || surfaceView?.window != nil else { return }
        guard session == nil else { return }

        bootStartRequested = true
        if let bootTask {
            // A live task for this generation already owns startup. If stop
            // invalidated it, wait for the cancellation fence before trying
            // again. Dropping the handle here would permit two ptys to open
            // concurrently when `openSession` is suspended in the bridge.
            if bootTaskGeneration != lifecycleGeneration {
                scheduleBootDrainIfNeeded(task: bootTask)
            }
            return
        }
        guard bootDrainTask == nil else { return }

        report(.starting)
        let runtime = self.runtime
        let generation = lifecycleGeneration
        let task = Task { @MainActor [weak self, runtime, generation] in
            // Keep ownership of the startup task through every return path.
            // Teardown may race any await below, and the drain barrier must
            // not start a replacement until this continuation has settled.
            defer {
                self?.finishBootTask(generation: generation)
            }
            // A prior stop can have scheduled an asynchronous C hangup. Wait
            // for that fence before entering the next synchronous bridge open.
            await self?.waitForSessionCloseBarrier()
            guard self?.isCurrentBoot(generation) == true else { return }
            let result = await Self.bootSession(runtime: runtime)
            guard let self else {
                // The coordinator may be dismantled while the detached boot
                // worker is still unwinding. Never orphan a successful C
                // session when its owner has gone away.
                if case .success(let session) = result {
                    await session.hangup()
                }
                return
            }
            guard self.isCurrentBoot(generation) else {
                if case .success(let session) = result {
                    await session.hangup()
                }
                return
            }

            switch result {
            case .success(let session):
                guard self.isCurrentBoot(generation) else {
                    await session.hangup()
                    return
                }
                self.pendingSession = session
                defer {
                    if self.pendingSession === session {
                        self.pendingSession = nil
                    }
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
                    guard self.isCurrentBoot(generation),
                          self.pendingSession === session else { return }
                    self.report(.failed(.linux))
                    return
                }
                // A short-lived command may emit its terminal event before
                // openSession returns. Avoid publishing a dead handle as a
                // running shell or accepting input into it.
                let ended = await session.isEnded
                guard self.isCurrentBoot(generation),
                      self.pendingSession === session else {
                    await session.hangup()
                    return
                }
                guard !ended else {
                    await session.hangup()
                    self.acceptsInput = false
                    self.report(.ended)
                    return
                }
                let lane = LocalLinuxTerminalLane(session: session, ring: ring)
                self.session = session
                self.scrollbackRing = ring
                self.lane = lane
                self.acceptsInput = true
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
                guard self.isCurrentBoot(generation),
                      self.session === session else {
                    await session.hangup()
                    return
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
                guard self.isCurrentBoot(generation) else { return }
                localLinuxLog.error(
                    "local Linux boot failed: \(String(describing: error), privacy: .public)"
                )
                self.report(.failed(.linux))
                self.acceptsInput = false
                self.pendingInput.removeAll(keepingCapacity: false)
                self.bootStartRequested = false
            case .cancelled:
                self.bootStartRequested = false
                return
            }
        }
        self.bootTask = task
        self.bootTaskGeneration = generation
    }

    /// Retains a cancelled startup operation until all of its asynchronous
    /// cleanup has completed, then retries only when a caller still requests
    /// a live foreground shell. This is the DEBUG counterpart of the
    /// production startup fence.
    private func scheduleBootDrainIfNeeded(task: Task<Void, Never>) {
        guard bootDrainTask == nil,
              let generation = bootTaskGeneration,
              generation != lifecycleGeneration else { return }

        bootDrainGeneration = generation
        let fenceID = UUID()
        let lifecycleFence = self.lifecycleFence
        let drainTask = Task { @MainActor [weak self, task, generation, lifecycleFence, fenceID] in
            await task.value
            // Clear the shared fence before asking this coordinator to retry.
            // Otherwise a same-coordinator retry could await this very task
            // through `waitForSessionCloseBarrier` and deadlock.
            lifecycleFence.completeBootDrain(id: fenceID)
            guard let self else { return }
            guard self.bootTaskGeneration == generation else {
                // The startup continuation may have completed its defer just
                // before this waiter resumed. Only clear this barrier's own
                // metadata; never touch a replacement generation.
                if self.bootDrainGeneration == generation {
                    self.bootDrainTask = nil
                    self.bootDrainGeneration = nil
                }
                return
            }

            self.bootTask = nil
            self.bootTaskGeneration = nil
            if self.bootDrainGeneration == generation {
                self.bootDrainTask = nil
                self.bootDrainGeneration = nil
            }

            guard self.bootStartRequested else { return }
            self.startIfNeeded()
        }
        bootDrainTask = drainTask
        lifecycleFence.registerBootDrain(drainTask, id: fenceID)
    }

    /// Starts a nonblocking session close. The fence is shared by all
    /// representable generations, so a retry cannot lose this task when the
    /// old coordinator is dismantled.
    private func scheduleSessionClose(_ candidate: LocalLinuxSession?) {
        lifecycleFence.schedule(candidate)
    }

    /// Awaits all session closes currently owned by any DEBUG coordinator for
    /// this view. The shared fence remains alive across `.id` remounts.
    private func waitForSessionCloseBarrier() async {
        await lifecycleFence.wait()
    }

    private func finishBootTask(generation: UInt) {
        // An invalidated task is still owned by `bootDrainTask`. Its own
        // defer must not clear the metadata before that barrier observes the
        // task's settled value, or a retry could remain stuck behind an
        // orphaned drain. A task may clear itself only while its generation
        // is still current; stale metadata is released by the drain callback.
        guard bootTaskGeneration == generation else { return }
        guard lifecycleGeneration == generation else { return }
        bootTask = nil
        bootTaskGeneration = nil
    }

    private func isCurrentBoot(_ generation: UInt) -> Bool {
        guard !isStopped,
              !Task.isCancelled,
              generation == lifecycleGeneration,
              sceneIsActive,
              isWindowAttached || surfaceView?.window != nil else { return false }
        return true
    }

    func stop() {
        isStopped = true
        isWindowAttached = false
        stopSession(publish: false)
        surfaceView = nil
    }

    private func stopSession(publish: Bool) {
        lifecycleGeneration &+= 1
        acceptsInput = false
        bootStartRequested = false
        if let bootTask {
            bootTask.cancel()
            // Keep the handle until the cancellation continuation has fully
            // settled. A retry calls `startIfNeeded` immediately, which then
            // waits on this barrier instead of opening a competing pty.
            scheduleBootDrainIfNeeded(task: bootTask)
        }
        stopLane()
        inputTask?.cancel()
        inputTask = nil
        inputWorkerID = nil
        resizeTask?.cancel()
        resizeTask = nil
        scheduleSessionClose(pendingSession)
        pendingSession = nil
        scheduleSessionClose(session)
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
                    if frame.kind == .replay {
                        // UIKit can reuse this Ghostty view after a
                        // background/foreground transition. A bounded
                        // subscriber overflow can also reattach the lane.
                        // Reset the retained terminal model before applying
                        // every authoritative history frame.
                        surfaceView.processTerminalReplay(frame.bytes)
                    } else {
                        surfaceView.processOutput(frame.bytes)
                    }
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

    private nonisolated enum BootResult: Sendable {
        case success(LocalLinuxSession)
        case failure(LocalLinuxError)
        case cancelled
    }

#if compiler(>=6.2)
    @concurrent
#else
    @Sendable
#endif
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
        guard acceptsInput else {
            localLinuxLog.debug(
                "ignoring local Linux input while session admission is fenced"
            )
            return
        }

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
                            self.failInputSession()
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
                        self.failInputSession()
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

    /// Closes the pty that rejected input before showing the error state. This
    /// prevents a failed worker from leaving a live shell behind and makes
    /// retry create a clean session.
    private func failInputSession() {
        guard !isStopped else { return }
        stopSession(publish: false)
        report(.failed(.linux))
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
