#if DEBUG
import Foundation
import SwiftUI

@MainActor
final class CmxUITestingLongHaulStatus: ObservableObject {
    @Published private(set) var text = "long-haul idle"
    private(set) var isRunning = false
    private var lastUpdateKey = ""
    private var lastStatusUpdateAt = Date.distantPast
    private var watchdog: CmxUITestingLongHaulWatchdog?

    func start(mode: String, duration: TimeInterval) -> Bool {
        guard !isRunning else { return false }
        isRunning = true
        lastUpdateKey = ""
        lastStatusUpdateAt = .distantPast
        watchdog = CmxUITestingLongHaulWatchdog(mode: mode, duration: duration)
        watchdog?.start()
        text = "long-haul running mode=\(mode) iteration=0"
        CmxUITestingLongHaulStatusChannel.post(.running)
        return true
    }

    func update(mode: String, iteration: Int, token: String, action: String) {
        let updateKey = "\(iteration):\(action)"
        guard lastUpdateKey != updateKey else { return }
        lastUpdateKey = updateKey
        watchdog?.record(iteration: iteration, token: token, action: action)
        let now = Date()
        guard now.timeIntervalSince(lastStatusUpdateAt) >= 1 else { return }
        lastStatusUpdateAt = now
        text = "long-haul progress mode=\(mode) iteration=\(iteration) token=\(token) action=\(action)"
    }

    func complete(mode: String, iterations: Int, token: String) {
        watchdog?.finish()
        watchdog = nil
        text = "long-haul complete mode=\(mode) iterations=\(iterations) token=\(token)"
        CmxUITestingLongHaulStatusChannel.post(.complete)
        isRunning = false
    }

    func fail(mode: String, iteration: Int, message: String) {
        watchdog?.finish()
        watchdog = nil
        text = "long-haul failed mode=\(mode) iteration=\(iteration) error=\(message)"
        CmxUITestingLongHaulStatusChannel.post(.failed)
        isRunning = false
    }
}

private enum CmxUITestingLongHaulStatusChannel {
    enum Event: String {
        case running
        case complete
        case failed
    }

    static func post(_ event: Event) {
        let token = ProcessInfo.processInfo.environment["CMUX_IOS_LONG_HAUL_STATUS_TOKEN"]
            ?? "dev.cmux.ios.longhaul.status"
        postNotification(named: "dev.cmux.ios.longhaul.\(token).\(event.rawValue)")
    }

    private static func postNotification(named name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString),
            nil,
            nil,
            true
        )
    }
}

private final class CmxUITestingLongHaulWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let mode: String
    private let timeout: TimeInterval
    private let deadline: Date
    private var lastUpdate = Date()
    private var lastMainActorHeartbeat = Date()
    private var lastIteration = 0
    private var lastToken = "none"
    private var lastAction = "start"
    private var isFinished = false
    private var task: Task<Void, Never>?

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
        task = Task.detached(priority: .background) { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.requestMainActorHeartbeat()
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                switch self.nextOutcome() {
                case .complete(let snapshot):
                    self.postCompletion(snapshot)
                    return
                case .failed(let snapshot, let reason):
                    self.postFailure(snapshot, reason: reason)
                    return
                case .none:
                    break
                }
            }
        }
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
        let task = task
        self.task = nil
        lock.unlock()
        task?.cancel()
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
        finish()
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
        finish()
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
                Task {
                    await CmxUITestingLongHaulDriver.maybeRun(store: store, status: status)
                }
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

    static func maybeRun(store: CmxConnectionStore, status: CmxUITestingLongHaulStatus) async {
        guard CmxLaunchConfiguration.usesUITestingEchoSession(),
              let mode = mode() else { return }

        let duration: TimeInterval = mode == "hour" ? 3_600 : 30
        guard status.start(mode: mode, duration: duration) else { return }
        if mode == "freeze" {
            status.update(mode: mode, iteration: 0, token: "freeze", action: "freeze-main-actor")
            blockMainActorForFreezeDetectionTest()
        }
        let deadline = Date().addingTimeInterval(duration)
        let maximumStressWorkspaceCount = 5
        var iteration = 0
        var lastToken = "none"

        do {
            try await waitForReadyStore(store)
            store.terminalScreenDidAppear()

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

                if Date() < deadline, iteration.isMultiple(of: 2) {
                    let workspaces = store.workspaces
                    let target = workspaces[iteration % workspaces.count]
                    status.update(mode: mode, iteration: iteration, token: token, action: "select-workspace")
                    store.select(workspace: target)
                    try await waitForOutput(containing: "ui-test$", terminalID: store.selectedTerminalID, store: store)
                }

                if Date() < deadline, iteration.isMultiple(of: 3) {
                    status.update(mode: mode, iteration: iteration, token: token, action: "resize-small")
                    store.updateTerminalSize(terminalID: store.selectedTerminalID, size: CmxTerminalSize(cols: 42, rows: 20))
                    await yieldToRenderer()
                    status.update(mode: mode, iteration: iteration, token: token, action: "resize-large")
                    store.updateTerminalSize(terminalID: store.selectedTerminalID, size: CmxTerminalSize(cols: 96, rows: 44))
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

                if Date() < deadline, iteration.isMultiple(of: 5) {
                    try await send(
                        "cmux-stress-burst 48 \(token)_burst\n",
                        expected: "\(token)_burst line 47",
                        action: "burst",
                        token: token,
                        mode: mode,
                        iteration: iteration,
                        store: store,
                        status: status
                    )
                }

                if Date() < deadline, iteration.isMultiple(of: 6) {
                    try await send(
                        "clear\n",
                        expected: "ui-test$",
                        action: "clear",
                        token: token,
                        mode: mode,
                        iteration: iteration,
                        store: store,
                        status: status
                    )
                }

                if Date() < deadline, iteration.isMultiple(of: 7) {
                    if store.workspaces.count < maximumStressWorkspaceCount {
                        let workspaceTitle = "stress-\(iteration)"
                        try await send(
                            "cmx new-workspace \(workspaceTitle)\n",
                            expected: workspaceTitle,
                            action: "new-workspace",
                            token: token,
                            mode: mode,
                            iteration: iteration,
                            store: store,
                            status: status
                        )
                    } else {
                        let boundedWorkspaces = Array(store.workspaces.prefix(maximumStressWorkspaceCount))
                        let target = boundedWorkspaces[iteration % boundedWorkspaces.count]
                        status.update(mode: mode, iteration: iteration, token: token, action: "cycle-workspace")
                        store.select(workspace: target)
                        try await waitForOutput(containing: "ui-test$", terminalID: store.selectedTerminalID, store: store)
                    }
                }

                if Date() < deadline, iteration.isMultiple(of: 8) {
                    let workspaceTitle = "stress-\(iteration % maximumStressWorkspaceCount)-\(iteration)"
                    try await send(
                        "cmx rename workspace \(workspaceTitle)\n",
                        expected: "renamed workspace \(workspaceTitle)",
                        action: "rename-workspace",
                        token: token,
                        mode: mode,
                        iteration: iteration,
                        store: store,
                        status: status
                    )
                }

                if Date() < deadline, iteration.isMultiple(of: 9) {
                    if store.selectedWorkspace.spaces.count < 3 {
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
                    if store.selectedSpace.terminals.count < 3 {
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
                   iteration.isMultiple(of: 10),
                   let workspace = store.workspaces.first {
                    status.update(mode: mode, iteration: iteration, token: token, action: "pin-unread")
                    store.togglePinned(for: workspace)
                    store.toggleUnread(for: workspace)
                    await yieldToRenderer()
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
                    await yieldToRenderer()
                    store.terminalScreenDidAppear()
                    try await waitForOutput(containing: "ui-test$", terminalID: store.selectedTerminalID, store: store)
                }

                if Date() < deadline, iteration.isMultiple(of: 17) {
                    try await send(
                        "cmx move-workspace next\n",
                        expected: "ui-test$",
                        action: "move-workspace",
                        token: token,
                        mode: mode,
                        iteration: iteration,
                        store: store,
                        status: status
                    )
                }
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
        try await waitForOutput(containing: expected, terminalID: terminalID, store: store)
        await yieldToRenderer()
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
        try? await Task.sleep(nanoseconds: 50_000_000)
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
