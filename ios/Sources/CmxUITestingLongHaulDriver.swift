#if DEBUG
import Foundation
import SwiftUI

@MainActor
final class CmxUITestingLongHaulStatus: ObservableObject {
    @Published private(set) var text = "long-haul idle"
    private(set) var isRunning = false
    private var lastUpdateKey = ""
    private var lastProgressEventAt = Date.distantPast
    private var lastVisibleStatusUpdateAt = Date.distantPast
    private var startedAt: Date?
    private var watchdog: CmxUITestingLongHaulWatchdog?
    private var driverTask: Task<Void, Never>?

    func runDriverIfNeeded(store: CmxConnectionStore) {
        guard driverTask == nil else { return }
        driverTask = Task { @MainActor [weak self, weak store] in
            guard let self, let store else { return }
            await CmxUITestingLongHaulDriver.maybeRun(store: store, status: self)
            driverTask = nil
        }
    }

    func start(mode: String, duration: TimeInterval) -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        lastUpdateKey = ""
        lastProgressEventAt = .distantPast
        lastVisibleStatusUpdateAt = .distantPast
        startedAt = Date()
        watchdog = CmxUITestingLongHaulWatchdog(mode: mode, duration: duration)
        watchdog?.start()
        text = "long-haul running mode=\(mode) iteration=0"
        CmxUITestingLongHaulStatusChannel.post(.running)
        NSLog("cmux long-haul started mode=%@ duration=%.1fs", mode, duration)
        return true
    }

    func update(mode: String, iteration: Int, token: String, action: String) {
        let updateKey = "\(iteration):\(action)"
        guard lastUpdateKey != updateKey else { return }
        lastUpdateKey = updateKey
        watchdog?.record(iteration: iteration, token: token, action: action)
        let now = Date()
        CmxUITestingLongHaulStatusChannel.postAction(action)
        if now.timeIntervalSince(lastProgressEventAt) >= 1 {
            lastProgressEventAt = now
            CmxUITestingLongHaulStatusChannel.post(.progress)
        }
        if now.timeIntervalSince(lastVisibleStatusUpdateAt) >= 5 {
            lastVisibleStatusUpdateAt = now
            let elapsed = now.timeIntervalSince(startedAt ?? now)
            text = String(
                format: "long-haul running mode=%@ iteration=%ld action=%@ token=%@ elapsed=%.1f",
                mode,
                iteration,
                action,
                token,
                elapsed
            )
        }
    }

    func complete(mode: String, iterations: Int, token: String) {
        watchdog?.finish()
        watchdog = nil
        let elapsed = Date().timeIntervalSince(startedAt ?? Date())
        text = String(
            format: "long-haul complete mode=%@ iterations=%ld token=%@ elapsed=%.1f",
            mode,
            iterations,
            token,
            elapsed
        )
        CmxUITestingLongHaulStatusChannel.postOutcome(.complete)
        NSLog("cmux long-haul complete mode=%@ iterations=%ld token=%@", mode, iterations, token)
        startedAt = nil
        isRunning = false
        driverTask = nil
    }

    func fail(mode: String, iteration: Int, message: String) {
        watchdog?.finish()
        watchdog = nil
        text = "long-haul failed mode=\(mode) iteration=\(iteration) error=\(message)"
        CmxUITestingLongHaulStatusChannel.postOutcome(.failed)
        NSLog("cmux long-haul failed mode=%@ iteration=%ld error=%@", mode, iteration, message)
        startedAt = nil
        isRunning = false
        driverTask = nil
    }
}

private enum CmxUITestingLongHaulStatusChannel {
    enum Event: String {
        case running
        case progress
        case heartbeat
        case complete
        case failed
    }

    static func post(_ event: Event) {
        postOnce(event)
    }

    static func postAction(_ action: String) {
        if action.hasSuffix("-seen") || action.hasSuffix("-ready") {
            postState(notificationName(for: "state.progress"))
        }
        postNotification(named: notificationName(for: "action.\(action)"))
    }

    static func postOutcome(_ event: Event) {
        switch event {
        case .complete:
            postState(notificationName(for: "state.complete"))
        case .failed:
            postState(notificationName(for: "state.failed"))
        default:
            break
        }
        postOnce(event)
        Task.detached(priority: .background) {
            for _ in 0..<30 {
                try? await Task.sleep(nanoseconds: 500_000_000)
                postOnce(event)
            }
        }
    }

    private static func postOnce(_ event: Event) {
        postNotification(named: notificationName(for: event.rawValue))
    }

    static func notificationName(for event: String) -> String {
        let token = ProcessInfo.processInfo.environment["CMUX_IOS_LONG_HAUL_STATUS_TOKEN"]
            ?? "dev.cmux.ios.longhaul.status"
        return "dev.cmux.ios.longhaul.\(token).\(event)"
    }

    private static func postNotification(named name: String) {
        _ = name.withCString { notify_post($0) }
    }

    private static func postState(_ name: String) {
        name.withCString { pointer in
            var token: Int32 = 0
            guard notify_register_check(pointer, &token) == 0 else { return }
            var state: UInt64 = 0
            _ = notify_get_state(token, &state)
            _ = notify_set_state(token, state &+ 1)
            _ = notify_post(pointer)
            _ = notify_cancel(token)
        }
    }
}

private final class CmxUITestingLongHaulWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "dev.cmux.ios.longhaul.watchdog")
    private let mode: String
    private let timeout: TimeInterval
    private let deadline: Date
    private var lastUpdate = Date()
    private var lastMainActorHeartbeat = Date()
    private var lastIteration = 0
    private var lastToken = "none"
    private var lastAction = "start"
    private var lastHeartbeatPost = Date.distantPast
    private var isFinished = false
    private var timer: DispatchSourceTimer?
    private var terminalOutcome: CmxUITestingLongHaulStatusChannel.Event?
    private var terminalOutcomeRepeatsRemaining = 0

    init(mode: String, duration: TimeInterval) {
        self.mode = mode
        deadline = Date().addingTimeInterval(duration)
        if let rawValue = ProcessInfo.processInfo.environment["CMUX_IOS_LONG_HAUL_STALL_TIMEOUT_SECONDS"],
           let value = TimeInterval(rawValue),
           value > 0 {
            timeout = value
        } else {
            timeout = 20
        }
    }

    deinit {
        finish()
    }

    func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .seconds(1), leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if self.postTerminalOutcomeIfNeeded() {
                return
            }
            switch self.nextOutcome() {
            case .complete(let snapshot):
                self.postCompletion(snapshot)
            case .failed(let snapshot, let reason):
                self.postFailure(snapshot, reason: reason)
            case .none:
                self.requestMainActorHeartbeat()
                self.postHeartbeatIfNeeded()
                break
            }
        }
        lock.lock()
        self.timer = timer
        lock.unlock()
        timer.resume()
    }

    private func postHeartbeatIfNeeded() {
        let now = Date()
        guard now.timeIntervalSince(lastHeartbeatPost) >= 5 else { return }
        lastHeartbeatPost = now
        CmxUITestingLongHaulStatusChannel.post(.heartbeat)
    }

    func record(iteration: Int, token: String, action: String) {
        lock.lock()
        lastUpdate = Date()
        lastIteration = iteration
        lastToken = token
        lastAction = action
        lock.unlock()
    }

    func recordMainActorHeartbeat() {
        lock.lock()
        lastMainActorHeartbeat = Date()
        lock.unlock()
    }

    func finish() {
        lock.lock()
        isFinished = true
        terminalOutcome = nil
        terminalOutcomeRepeatsRemaining = 0
        let timer = timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
    }

    private func beginTerminalOutcome(_ event: CmxUITestingLongHaulStatusChannel.Event) {
        lock.lock()
        isFinished = true
        terminalOutcome = event
        terminalOutcomeRepeatsRemaining = 30
        lock.unlock()
    }

    private func postTerminalOutcomeIfNeeded() -> Bool {
        lock.lock()
        guard let terminalOutcome else {
            lock.unlock()
            return false
        }
        if terminalOutcomeRepeatsRemaining <= 0 {
            self.terminalOutcome = nil
            let timer = timer
            self.timer = nil
            lock.unlock()
            timer?.cancel()
            return true
        }
        terminalOutcomeRepeatsRemaining -= 1
        lock.unlock()
        CmxUITestingLongHaulStatusChannel.post(terminalOutcome)
        return true
    }

    private func requestMainActorHeartbeat() {
        Task { @MainActor [weak self] in
            self?.recordMainActorHeartbeat()
        }
    }

    private func nextOutcome() -> CmxUITestingLongHaulWatchdogOutcome? {
        lock.lock()
        defer { lock.unlock() }
        guard !isFinished else { return nil }
        let now = Date()
        let snapshot = CmxUITestingLongHaulWatchdogSnapshot(
            iteration: lastIteration,
            token: lastToken,
            action: lastAction,
            idle: now.timeIntervalSince(lastUpdate),
            mainActorIdle: now.timeIntervalSince(lastMainActorHeartbeat)
        )
        if snapshot.mainActorIdle >= timeout {
            return .failed(snapshot, reason: "main-actor-heartbeat")
        }
        if snapshot.idle >= timeout {
            return .failed(snapshot, reason: "action-progress")
        }
        if now >= deadline {
            return .complete(snapshot)
        }
        return nil
    }

    private func postCompletion(_ snapshot: CmxUITestingLongHaulWatchdogSnapshot) {
        NSLog(
            "cmux long-haul watchdog complete mode=%@ iteration=%ld token=%@ action=%@ idle=%.1fs mainActorIdle=%.1fs",
            mode,
            snapshot.iteration,
            snapshot.token,
            snapshot.action,
            snapshot.idle,
            snapshot.mainActorIdle
        )
        CmxUITestingLongHaulStatusChannel.post(.complete)
        beginTerminalOutcome(.complete)
    }

    private func postFailure(_ snapshot: CmxUITestingLongHaulWatchdogSnapshot, reason: String) {
        NSLog(
            "cmux long-haul watchdog failed reason=%@ mode=%@ iteration=%ld token=%@ action=%@ idle=%.1fs mainActorIdle=%.1fs timeout=%.1fs",
            reason,
            mode,
            snapshot.iteration,
            snapshot.token,
            snapshot.action,
            snapshot.idle,
            snapshot.mainActorIdle,
            timeout
        )
        CmxUITestingLongHaulStatusChannel.post(.failed)
        beginTerminalOutcome(.failed)
    }
}

private struct CmxUITestingLongHaulWatchdogSnapshot {
    var iteration: Int
    var token: String
    var action: String
    var idle: TimeInterval
    var mainActorIdle: TimeInterval
}

private enum CmxUITestingLongHaulWatchdogOutcome {
    case complete(CmxUITestingLongHaulWatchdogSnapshot)
    case failed(CmxUITestingLongHaulWatchdogSnapshot, reason: String)
}

struct CmxUITestingLongHaulStatusView: View {
    @ObservedObject var status: CmxUITestingLongHaulStatus

    var body: some View {
        Text(status.text)
            .font(.caption2.monospaced())
            .frame(width: 1, height: 1)
            .opacity(0.01)
            .accessibilityIdentifier("longhaul.status")
            .accessibilityValue(status.text)
        .allowsHitTesting(false)
    }
}

struct CmxUITestingLongHaulHarness: View {
    @ObservedObject var status: CmxUITestingLongHaulStatus
    let store: CmxConnectionStore

    init(store: CmxConnectionStore, status: CmxUITestingLongHaulStatus) {
        self.store = store
        self.status = status
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button {
                status.runDriverIfNeeded(store: store)
            } label: {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("longhaul.start")
            .accessibilityLabel("longhaul.start")

            CmxUITestingLongHaulStatusView(status: status)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task {
            if CmxUITestingLongHaulDriver.shouldAutostart() {
                status.runDriverIfNeeded(store: store)
            }
        }
        .onAppear {
            CmxUITestingLongHaulControlChannel.shared.startListening {
                status.runDriverIfNeeded(store: store)
            }
        }
    }
}

@MainActor
private final class CmxUITestingLongHaulControlChannel {
    static let shared = CmxUITestingLongHaulControlChannel()

    private var observer: UnsafeMutableRawPointer?
    private var startHandler: (@MainActor @Sendable () -> Void)?

    private init() {}

    @MainActor
    func startListening(handler: @escaping @MainActor @Sendable () -> Void) {
        startHandler = handler
        guard observer == nil else { return }
        let observer = Unmanaged.passUnretained(self).toOpaque()
        self.observer = observer
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            observer,
            { _, observer, name, _, _ in
                guard let observer, let name else { return }
                Unmanaged<CmxUITestingLongHaulControlChannel>
                    .fromOpaque(observer)
                    .takeUnretainedValue()
                    .handleNotification(named: name.rawValue as String)
            },
            CmxUITestingLongHaulStatusChannel.notificationName(for: "start") as CFString,
            nil,
            .deliverImmediately
        )
    }

    private func handleNotification(named name: String) {
        guard name == CmxUITestingLongHaulStatusChannel.notificationName(for: "start") else {
            return
        }
        Task { @MainActor in
            startHandler?()
        }
    }
}

@MainActor
enum CmxUITestingLongHaulDriver {
    static func mode(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let rawValue = environment["CMUX_IOS_LONG_HAUL_STRESS_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard let rawValue, !rawValue.isEmpty else { return nil }
        return rawValue
    }

    static func shouldAutostart(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment["CMUX_IOS_LONG_HAUL_AUTOSTART"] == "1"
    }

    static func maybeRun(store: CmxConnectionStore, status: CmxUITestingLongHaulStatus) async {
        guard CmxLaunchConfiguration.usesUITestingEchoSession(),
              let mode = mode() else { return }

        let duration: TimeInterval = mode == "hour" ? 3_600 : 30
        guard status.start(mode: mode, duration: duration) else { return }
        let deadline = Date().addingTimeInterval(duration)
        var iteration = 0
        var lastToken = "none"

        do {
            try await waitForReadyStore(store)
            store.terminalScreenDidAppear()
            if mode == "freeze" {
                status.update(mode: mode, iteration: 0, token: "freeze", action: "freeze-main-actor")
                blockMainActorForFreezeDetectionTest()
            }

            while Date() < deadline {
                iteration += 1
                let token = "LH_\(iteration)_\(mode)"
                lastToken = token

                guard Date() < deadline else { break }
                try await send(
                    "echo \(token) first line\n",
                    expected: token,
                    action: "type-single",
                    token: token,
                    mode: mode,
                    iteration: iteration,
                    store: store,
                    status: status
                )

                guard Date() < deadline else { break }
                try await send(
                    "echo \(token)_multi_a && echo \(token)_multi_b\n",
                    expected: "\(token)_multi_b",
                    action: "type-multiline",
                    token: token,
                    mode: mode,
                    iteration: iteration,
                    store: store,
                    status: status
                )

                if mode != "hour", Date() < deadline, iteration.isMultiple(of: 2) {
                    let workspaces = store.workspaces
                    let target = workspaces[iteration % workspaces.count]
                    status.update(mode: mode, iteration: iteration, token: token, action: "select-workspace")
                    store.select(workspace: target)
                    try await waitForOutput(containing: "ui-test$", terminalID: store.selectedTerminalID, store: store)
                }

                if mode != "hour", Date() < deadline, iteration.isMultiple(of: 3) {
                    status.update(mode: mode, iteration: iteration, token: token, action: "resize-small")
                    store.updateTerminalSize(terminalID: store.selectedTerminalID, size: CmxTerminalSize(cols: 42, rows: 20))
                    status.update(mode: mode, iteration: iteration, token: token, action: "resize-small-applied")
                    status.update(mode: mode, iteration: iteration, token: token, action: "resize-small-rendered")
                    status.update(mode: mode, iteration: iteration, token: token, action: "resize-large")
                    store.updateTerminalSize(terminalID: store.selectedTerminalID, size: CmxTerminalSize(cols: 96, rows: 44))
                    status.update(mode: mode, iteration: iteration, token: token, action: "resize-large-applied")
                    try await send(
                        "echo \(token)_resize_ok\n",
                        expected: "\(token)_resize_ok",
                        action: "resize-echo",
                        token: token,
                        mode: mode,
                        iteration: iteration,
                        store: store,
                        status: status
                    )
                }

                if Date() < deadline, iteration.isMultiple(of: 4) {
                    try await send(
                        "vim\n",
                        expected: "LONG-HAUL BUFFER",
                        action: "alt-screen-enter",
                        token: token,
                        mode: mode,
                        iteration: iteration,
                        store: store,
                        status: status
                    )
                    try await send(
                        ":q\n",
                        expected: "alt screen exited",
                        action: "alt-screen-exit",
                        token: token,
                        mode: mode,
                        iteration: iteration,
                        store: store,
                        status: status
                    )
                }

                if Date() < deadline, iteration.isMultiple(of: 9) {
                    if store.selectedWorkspace.spaces.count < 2 {
                        try await send(
                            "cmx new-space space-\(iteration)\n",
                            expected: "ui-test$",
                            action: "new-space",
                            token: token,
                            mode: mode,
                            iteration: iteration,
                            store: store,
                            status: status
                        )
                    }
                    if store.selectedSpace.terminals.count < 2 {
                        try await send(
                            "cmx new-tab tab-\(iteration)\n",
                            expected: "ui-test$",
                            action: "new-tab",
                            token: token,
                            mode: mode,
                            iteration: iteration,
                            store: store,
                            status: status
                        )
                    }
                }

                if Date() < deadline,
                   iteration.isMultiple(of: 11),
                   let terminal = store.selectedSpace.terminals.last {
                    status.update(mode: mode, iteration: iteration, token: token, action: "select-terminal")
                    store.select(terminal: terminal)
                    try await waitForOutput(containing: "ui-test$", terminalID: store.selectedTerminalID, store: store)
                    try await send(
                        "echo \(token)_terminal_switch_ok\n",
                        expected: "\(token)_terminal_switch_ok",
                        action: "terminal-switch-echo",
                        token: token,
                        mode: mode,
                        iteration: iteration,
                        store: store,
                        status: status
                    )
                }

                if Date() < deadline,
                   iteration.isMultiple(of: 12),
                   let space = store.selectedWorkspace.spaces.last {
                    status.update(mode: mode, iteration: iteration, token: token, action: "select-space")
                    store.select(space: space)
                    try await waitForOutput(containing: "ui-test$", terminalID: store.selectedTerminalID, store: store)
                    try await send(
                        "echo \(token)_space_switch_ok\n",
                        expected: "\(token)_space_switch_ok",
                        action: "space-switch-echo",
                        token: token,
                        mode: mode,
                        iteration: iteration,
                        store: store,
                        status: status
                    )
                }

                if Date() < deadline, iteration.isMultiple(of: 13) {
                    status.update(mode: mode, iteration: iteration, token: token, action: "terminal-hide-show")
                    store.terminalScreenDidDisappear()
                    status.update(mode: mode, iteration: iteration, token: token, action: "terminal-hide-show-hidden")
                    status.update(mode: mode, iteration: iteration, token: token, action: "terminal-hide-show-showing")
                    store.terminalScreenDidAppear()
                    status.update(mode: mode, iteration: iteration, token: token, action: "terminal-hide-show-shown")
                    try await waitForOutput(containing: "ui-test$", terminalID: store.selectedTerminalID, store: store)
                    status.update(mode: mode, iteration: iteration, token: token, action: "terminal-hide-show-ready")
                }

                await paceStressIteration()
            }

            status.complete(mode: mode, iterations: iteration, token: lastToken)
        } catch {
            status.fail(mode: mode, iteration: iteration, message: error.localizedDescription)
        }
    }

    private static func send(
        _ text: String,
        expected: String,
        action: String,
        token: String,
        mode: String,
        iteration: Int,
        store: CmxConnectionStore,
        status: CmxUITestingLongHaulStatus
    ) async throws {
        status.update(mode: mode, iteration: iteration, token: token, action: action)
        let terminalID = store.selectedTerminalID
        store.sendInput(Data(text.utf8), terminalID: terminalID)
        status.update(mode: mode, iteration: iteration, token: token, action: "\(action)-sent")
        try await waitForOutput(containing: expected, terminalID: terminalID, store: store)
        status.update(mode: mode, iteration: iteration, token: token, action: "\(action)-seen")
    }

    private static func waitForReadyStore(_ store: CmxConnectionStore) async throws {
        try await waitUntil(timeout: 15, failure: "timed out waiting for terminal store") {
            !store.workspaces.isEmpty && store.terminalDetailPresentation == .terminal
        }
    }

    private static func waitForOutput(
        containing expected: String,
        terminalID: UInt64,
        store: CmxConnectionStore
    ) async throws {
        let deadline = Date().addingTimeInterval(10)
        var lastChunkID = store.latestOutputChunkID(for: terminalID)
        var didRequestReplay = false

        while true {
            if terminalOutput(terminalID: terminalID, store: store).contains(expected) {
                return
            }

            let currentChunkID = store.latestOutputChunkID(for: terminalID)
            if currentChunkID != lastChunkID {
                lastChunkID = currentChunkID
                didRequestReplay = false
            } else if !didRequestReplay {
                didRequestReplay = true
                store.requestPtyReplay(terminalID: terminalID)
            }

            if Date() >= deadline {
                throw CmxUITestingLongHaulError(
                    message: "timed out waiting for \(expected); terminal=\(terminalID) chunks=\(currentChunkID)"
                )
            }

            await yieldToRenderer()
        }
    }

    private static func terminalOutput(terminalID: UInt64, store: CmxConnectionStore) -> String {
        let maximumBytesToScan = 128 * 1_024
        var data = store.outputChunks(for: terminalID).suffix(64).reduce(into: Data()) { output, chunk in
            output.append(chunk.data)
        }
        if data.count > maximumBytesToScan {
            data = Data(data.suffix(maximumBytesToScan))
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func waitUntil(
        timeout: TimeInterval,
        failure: String,
        predicate: @MainActor @escaping () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() {
            if Date() >= deadline {
                throw CmxUITestingLongHaulError(message: failure)
            }
            await yieldToRenderer()
        }
    }

    private static func yieldToRenderer() async {
        await Task.yield()
    }

    private static func paceStressIteration() async {
        await Task.yield()
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    private static func blockMainActorForFreezeDetectionTest() -> Never {
        // DEBUG-only test path: intentionally simulates a hung UI thread.
        while true {
            Thread.sleep(forTimeInterval: 60)
        }
    }
}

private struct CmxUITestingLongHaulError: LocalizedError {
    var message: String

    var errorDescription: String? {
        message
    }
}
#endif
