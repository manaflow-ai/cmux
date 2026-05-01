import Foundation
import OSLog

private let log = Logger(subsystem: "ai.manaflow.cmux.ios", category: "terminal.session-transport")

protocol TerminalRemoteDaemonResumeStateSnapshotting {
    func remoteDaemonResumeStateSnapshot() -> TerminalRemoteDaemonResumeState?
}

protocol TerminalRemoteDaemonSessionClient: Sendable {
    func sendHello() async throws -> TerminalRemoteDaemonHello
    func sessionAttach(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int
    ) async throws -> TerminalRemoteDaemonSessionStatus
    func terminalOpen(command: String, cols: Int, rows: Int, sessionID: String?) async throws -> TerminalRemoteDaemonTerminalOpenResult
    func terminalWrite(sessionID: String, data: Data) async throws
    func terminalRead(
        sessionID: String,
        offset: UInt64,
        maxBytes: Int,
        timeoutMilliseconds: Int
    ) async throws -> TerminalRemoteDaemonTerminalReadResult
    func sessionResize(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int
    ) async throws -> TerminalRemoteDaemonSessionStatus
    func sessionDetach(
        sessionID: String,
        attachmentID: String
    ) async throws -> TerminalRemoteDaemonSessionStatus
    func sessionClose(sessionID: String) async throws
    func sessionHistory(sessionID: String, format: String) async throws -> TerminalRemoteDaemonSessionHistoryResult
    /// Fetch the daemon's current workspace list so we can adopt an
    /// existing peer session when our saved session_id is missing.
    /// Part of the shared-session-identity plan's Step 5.
    func workspaceList() async throws -> TerminalRemoteDaemonWorkspaceListResult
}

enum TerminalRemoteDaemonSessionTransportError: LocalizedError {
    case missingCapability(String)
    case sharedSessionUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .missingCapability(let capability):
            return "Remote daemon is missing required capability \(capability)."
        case .sharedSessionUnavailable:
            return String(
                localized: "terminal.workspace.waiting_for_daemon",
                defaultValue: "Waiting for Mac to finish starting this workspace…"
            )
        }
    }
}

final class TerminalRemoteDaemonSessionTransport: @unchecked Sendable, TerminalTransport {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?

    private enum SubscriptionStart {
        case storedOffset
        case exactOffset(UInt64)
        case currentTail
    }

    private struct FreshSurfaceBootstrap {
        let sessionID: String
    }

    private let client: any TerminalRemoteDaemonSessionClient
    private let command: String
    private let sharedSessionID: String?
    // Stable attachment ID: reused across reconnections so we don't leak attachments
    private let stableAttachmentID: String = "ios-\(UUID().uuidString.prefix(8).lowercased())"
    private let resumeState: TerminalRemoteDaemonResumeState?
    private let readTimeoutMilliseconds: Int
    private let maxReadBytes: Int
    private let stateLock = NSLock()

    private var sessionID: String?
    private var attachmentID: String?
    private var nextOffset: UInt64 = 0
    private var readTask: Task<Void, Never>?
    private var closed = false
    private var pushSubscribed = false
    private var pendingInitialReplayData: Data?

    init(
        client: any TerminalRemoteDaemonSessionClient,
        command: String,
        sharedSessionID: String? = nil,
        resumeState: TerminalRemoteDaemonResumeState? = nil,
        readTimeoutMilliseconds: Int = 250,
        maxReadBytes: Int = 64 * 1024
    ) {
        self.client = client
        self.command = command
        self.sharedSessionID = sharedSessionID
        self.resumeState = resumeState
        self.readTimeoutMilliseconds = readTimeoutMilliseconds
        self.maxReadBytes = maxReadBytes
    }

    func connect(initialSize: TerminalGridSize) async throws {
        log.debug("Starting connect")
        let hello = try await client.sendHello()
        log.debug("Hello OK, capabilities=\(hello.capabilities.joined(separator: ","), privacy: .public)")
        guard hello.capabilities.contains("terminal.stream") else {
            throw TerminalRemoteDaemonSessionTransportError.missingCapability("terminal.stream")
        }

        let bootstrap = try await openOrAttachTerminal(initialSize: initialSize)
        log.debug("Terminal opened, sessionID=\(self.lockedSessionID() ?? "nil", privacy: .public)")

        eventHandler?(.connected)

        let subscriptionStart = try await prepareInitialReplayIfNeeded(bootstrap)

        if hello.capabilities.contains("terminal.subscribe"),
           let pushClient = client as? any TerminalRemoteDaemonPushSubscribing {
            try await startPushSubscription(pushClient: pushClient, start: subscriptionStart)
            log.debug("Push subscription active")
        } else {
            try await preparePollingOffset(start: subscriptionStart)
            emitPendingInitialReplayDataIfNeeded()
            startReadLoop()
            log.debug("Fallback polling read loop started")
        }
    }

    func send(_ data: Data) async throws {
        guard let sessionID = lockedSessionID() else { return }
        TerminalInputDebugLog.log("transport.send session=\(sessionID.prefix(8)) data=\(TerminalInputDebugLog.dataSummary(data))")
        try await client.terminalWrite(sessionID: sessionID, data: data)
    }

    func resize(_ size: TerminalGridSize) async {
        guard let state = lockedSessionState() else { return }
        let result = try? await client.sessionResize(
            sessionID: state.sessionID,
            attachmentID: state.attachmentID,
            cols: max(1, size.columns),
            rows: max(1, size.rows)
        )
        if let result {
            emitEffectiveSize(cols: result.effectiveCols, rows: result.effectiveRows)
        }
    }

    func disconnect() async {
        let state = lockedSessionState()
        let readTask = takeReadTask(markClosed: false)
        readTask?.cancel()
        await readTask?.value

        await tearDownPushSubscription(sessionID: state?.sessionID)

        if let state {
            if sharedSessionID != nil {
                // Detach instead of close so other clients keep the session
                _ = try? await client.sessionDetach(
                    sessionID: state.sessionID,
                    attachmentID: state.attachmentID
                )
            } else {
                try? await client.sessionClose(sessionID: state.sessionID)
            }
        }
        clearSessionState()
        finishDisconnect(error: nil)
    }

    func suspendPreservingSession() async {
        guard let state = lockedSessionState() else { return }

        let readTask = takeReadTask(markClosed: true)
        readTask?.cancel()
        await readTask?.value

        await tearDownPushSubscription(sessionID: state.sessionID)

        _ = try? await client.sessionDetach(
            sessionID: state.sessionID,
            attachmentID: state.attachmentID
        )
        clearSessionState()
    }

    private func openOrAttachTerminal(initialSize: TerminalGridSize) async throws -> FreshSurfaceBootstrap? {
        let cols = max(1, initialSize.columns)
        let rows = max(1, initialSize.rows)

        // For shared sessions, always use the shared session ID with a stable
        // attachment ID so we don't leak attachments on reconnection.
        if let sharedSessionID {
            do {
                let status = try await client.sessionAttach(
                    sessionID: sharedSessionID,
                    attachmentID: stableAttachmentID,
                    cols: cols,
                    rows: rows
                )
                log.debug("Attached to shared session \(sharedSessionID, privacy: .public) as \(self.stableAttachmentID, privacy: .public)")
                let resumeOffset = resumeState?.sessionID == sharedSessionID ? resumeState?.readOffset : nil
                withLockedState {
                    sessionID = sharedSessionID
                    attachmentID = stableAttachmentID
                    nextOffset = resumeOffset ?? 0
                    closed = false
                }
                emitEffectiveSize(cols: status.effectiveCols, rows: status.effectiveRows)
                if resumeOffset == nil || resumeOffset == 0 {
                    return FreshSurfaceBootstrap(sessionID: sharedSessionID)
                }
                return nil
            } catch let error as TerminalRemoteDaemonClientError {
                if case .rpc(let code, _) = error, code == "not_found" {
                    log.debug("Shared session \(sharedSessionID, privacy: .public) not found, waiting for daemon-owned session")
                    throw TerminalRemoteDaemonSessionTransportError.sharedSessionUnavailable(sharedSessionID)
                } else {
                    throw error
                }
            }
        }

        // Try resuming a previously saved session (non-shared only).
        // If the saved session is gone from the daemon, probe
        // `workspace.list` for a live session on the same host that
        // our ResumeState workspace can adopt — that way we don't
        // silently mint a fresh session_id diverging from mac. If no
        // peer session is available, propagate the failure up so the
        // UI surfaces an "ended" state instead of secretly starting
        // a new shell.
        if let resumeState, sharedSessionID == nil {
            do {
                let status = try await client.sessionAttach(
                    sessionID: resumeState.sessionID,
                    attachmentID: resumeState.attachmentID,
                    cols: cols,
                    rows: rows
                )
                withLockedState {
                    sessionID = resumeState.sessionID
                    attachmentID = resumeState.attachmentID
                    nextOffset = resumeState.readOffset
                    closed = false
                }
                emitEffectiveSize(cols: status.effectiveCols, rows: status.effectiveRows)
                if resumeState.readOffset == 0 {
                    return FreshSurfaceBootstrap(sessionID: resumeState.sessionID)
                }
                return nil
            } catch let error as TerminalRemoteDaemonClientError {
                if case .rpc(let code, _) = error, code == "not_found" {
                    if let adopted = try? await attemptAdoptPeerSessionFromWorkspaceList(
                        client: client,
                        cols: cols,
                        rows: rows
                    ) {
                        withLockedState {
                            sessionID = adopted.sessionID
                            attachmentID = adopted.attachmentID
                            nextOffset = 0
                            closed = false
                        }
                        emitEffectiveSize(cols: adopted.effectiveCols, rows: adopted.effectiveRows)
                        return FreshSurfaceBootstrap(sessionID: adopted.sessionID)
                    }
                    // No peer session found. Clear saved state and fall
                    // through — for a shared-session world we'd surface
                    // "session ended" here, but today the terminal.open
                    // below still mints a deterministic id that mac's
                    // workspace.sync can eventually carry back.
                    clearSessionState()
                } else {
                    throw error
                }
            }
        }

        let openResult = try await client.terminalOpen(
            command: command,
            cols: cols,
            rows: rows,
            sessionID: nil
        )

        withLockedState {
            sessionID = openResult.sessionID
            attachmentID = openResult.attachmentID
            nextOffset = openResult.offset
            closed = false
        }
        emitEffectiveSize(cols: openResult.effectiveCols, rows: openResult.effectiveRows)
        return nil
    }

    /// Forward the daemon's authoritative view size to the event
    /// handler whenever the backend reports a real size (nonzero on
    /// both axes). Zero on either axis means the daemon hasn't settled
    /// yet, likely because no attachment has reported geometry — skip
    /// so we don't collapse the local Ghostty surface to 0 cols.
    private func emitEffectiveSize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        eventHandler?(.viewSize(cols: cols, rows: rows))
    }

    /// Probe the daemon's current workspace tree for any pane whose
    /// session_id is attachable — preferred over minting a fresh
    /// session when our saved session_id is gone. Returns the first
    /// pane whose `session.attach` succeeds, or nil if the daemon
    /// has no live sessions. Keeps the "never mint on iOS" invariant
    /// from the shared-session plan: we always adopt daemon-owned
    /// session IDs rather than invent our own.
    private func attemptAdoptPeerSessionFromWorkspaceList(
        client: any TerminalRemoteDaemonSessionClient,
        cols: Int,
        rows: Int
    ) async throws -> (sessionID: String, attachmentID: String, effectiveCols: Int, effectiveRows: Int)? {
        let list = try await client.workspaceList()
        for workspace in list.workspaces {
            guard let panes = workspace.panes else { continue }
            for pane in panes {
                guard let candidate = pane.sessionID, !candidate.isEmpty else { continue }
                let newAttachmentID = stableAttachmentID
                do {
                    let status = try await client.sessionAttach(
                        sessionID: candidate,
                        attachmentID: newAttachmentID,
                        cols: max(1, cols),
                        rows: max(1, rows)
                    )
                    return (candidate, newAttachmentID, status.effectiveCols, status.effectiveRows)
                } catch {
                    continue
                }
            }
        }
        return nil
    }

    private func startReadLoop() {
        withLockedState {
            readTask?.cancel()
            readTask = Task { [weak self] in
                await self?.runReadLoop()
            }
        }
    }

    private func prepareInitialReplayIfNeeded(_ bootstrap: FreshSurfaceBootstrap?) async throws -> SubscriptionStart {
        guard let bootstrap else { return .storedOffset }

        let result = try await client.sessionHistory(sessionID: bootstrap.sessionID, format: "vt")
        log.debug(
            "Initial VT history session=\(bootstrap.sessionID, privacy: .public) bytes=\(result.history.utf8.count, privacy: .public) nextOffset=\(String(describing: result.nextOffset), privacy: .public) containsPrompt=\(Self.containsPromptLikeText(result.history), privacy: .public) containsFeedback=\(result.history.contains("feedback"), privacy: .public) tail=\(Self.textTailSummary(result.history), privacy: .public)"
        )

        if let nextOffset = result.nextOffset {
            withLockedState {
                if sessionID == bootstrap.sessionID {
                    self.nextOffset = nextOffset
                    self.pendingInitialReplayData = Data(result.history.utf8)
                }
            }
            return .exactOffset(nextOffset)
        }

        let replayData = Data(result.history.utf8)
        if !replayData.isEmpty {
            withLockedState {
                if sessionID == bootstrap.sessionID {
                    self.pendingInitialReplayData = replayData
                }
            }
        }
        log.warning("session.history for \(bootstrap.sessionID, privacy: .public) did not include next_offset; falling back to tail-only subscribe")
        return .currentTail
    }

    private func startPushSubscription(
        pushClient: any TerminalRemoteDaemonPushSubscribing,
        start: SubscriptionStart
    ) async throws {
        guard let state = lockedSessionStateWithOffset() else { return }

        await pushClient.setPushHandler(sessionID: state.sessionID) { [weak self] event in
            self?.handlePushEvent(event)
        }
        withLockedState { pushSubscribed = true }

        let result: TerminalRemoteDaemonTerminalReadResult
        do {
            result = try await pushClient.terminalSubscribe(
                sessionID: state.sessionID,
                offset: subscriptionOffset(for: start, storedOffset: state.offset)
            )
        } catch {
            await pushClient.removePushHandler(sessionID: state.sessionID)
            withLockedState { pushSubscribed = false }
            throw error
        }

        log.debug(
            "Initial subscribe payload session=\(state.sessionID, privacy: .public) bytes=\(result.data.count, privacy: .public) offset=\(result.offset, privacy: .public) truncated=\(result.truncated, privacy: .public) eof=\(result.eof, privacy: .public) containsPrompt=\(Self.dataContainsPromptLikeText(result.data), privacy: .public) containsFeedback=\(Self.dataContains(result.data, "feedback"), privacy: .public) tail=\(Self.dataTailSummary(result.data), privacy: .public)"
        )
        let handledInitialReplay = applyInitialReplaySubscriptionPayload(
            data: result.data,
            offset: result.offset,
            truncated: result.truncated,
            eof: result.eof
        )
        if !handledInitialReplay {
            applySubscriptionPayload(
                data: result.data,
                offset: result.offset,
                truncated: result.truncated,
                eof: result.eof
            )
        }
    }

    private func preparePollingOffset(start: SubscriptionStart) async throws {
        switch start {
        case .storedOffset:
            return
        case .exactOffset(let offset):
            withLockedState { nextOffset = offset }
        case .currentTail:
            guard let state = lockedSessionStateWithOffset() else { return }
            let result = try await client.terminalRead(
                sessionID: state.sessionID,
                offset: UInt64.max,
                maxBytes: 1,
                timeoutMilliseconds: 0
            )
            withLockedState { nextOffset = result.offset }
        }
    }

    private func subscriptionOffset(for start: SubscriptionStart, storedOffset: UInt64) -> UInt64? {
        switch start {
        case .storedOffset:
            return storedOffset
        case .exactOffset(let offset):
            return offset
        case .currentTail:
            return nil
        }
    }

    private static func textTailSummary(_ text: String, maxCharacters: Int = 220) -> String {
        guard !text.isEmpty else { return "<empty>" }
        let tail = String(text.suffix(maxCharacters))
        return sanitizeForLog(tail)
    }

    private static func dataTailSummary(_ data: Data, maxBytes: Int = 220) -> String {
        guard !data.isEmpty else { return "<empty>" }
        let tail = data.suffix(maxBytes)
        return sanitizeForLog(String(decoding: tail, as: UTF8.self))
    }

    private static func sanitizeForLog(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "\u{001B}", with: "<ESC>")
            .replacingOccurrences(of: "\r", with: "<CR>")
            .replacingOccurrences(of: "\n", with: "<LF>")
        guard escaped.count > 260 else { return escaped }
        return "\(escaped.prefix(260))..."
    }

    private static func containsPromptLikeText(_ text: String) -> Bool {
        text.contains("lawrence") || text.contains(" λ") || text.contains("$ ") || text.contains("% ")
    }

    private static func dataContainsPromptLikeText(_ data: Data) -> Bool {
        containsPromptLikeText(String(decoding: data, as: UTF8.self))
    }

    private static func dataContains(_ data: Data, _ needle: String) -> Bool {
        String(decoding: data, as: UTF8.self).contains(needle)
    }

    private func handlePushEvent(_ event: TerminalPushEvent) {
        switch event {
        case .output(let data, let offset, _, let truncated, let eof, let seq, let notifications):
            applySubscriptionPayload(data: data, offset: offset, truncated: truncated, eof: eof)
            if let notifications, let sid = lockedSessionStateWithOffset()?.sessionID {
                Task { @MainActor in
                    NotificationManager.shared.handleTerminalNotifications(
                        sessionID: sid,
                        seq: seq,
                        payload: notifications
                    )
                }
            }
        case .eof:
            clearSessionState()
            finishDisconnect(error: nil)
        case .viewSize(let cols, let rows):
            eventHandler?(.viewSize(cols: cols, rows: rows))
        }
    }

    private func applySubscriptionPayload(
        data: Data,
        offset: UInt64,
        truncated: Bool,
        eof: Bool
    ) {
        let filtered = takeNewSubscriptionData(data: data, offset: offset)

        if truncated, filtered.didAdvance {
            log.debug("Push payload truncated, resetting emulator buffer")
            eventHandler?(.notice("Terminal output truncated; buffer reset."))
            // RIS (ESC c) clears the emulator before the post-truncation tail.
            eventHandler?(.output(Data([0x1B, 0x63])))
        }

        if !filtered.data.isEmpty {
            eventHandler?(.output(filtered.data))
        }

        if eof {
            log.debug("EOF via push for session")
            clearSessionState()
            finishDisconnect(error: nil)
        }
    }

    @discardableResult
    private func applyInitialReplaySubscriptionPayload(
        data: Data,
        offset: UInt64,
        truncated: Bool,
        eof: Bool
    ) -> Bool {
        guard let initialReplay = takePendingInitialReplayData() else { return false }
        let filtered = takeNewSubscriptionData(data: data, offset: offset)
        log.debug(
            "Apply initial replay payload initialBytes=\(initialReplay.count, privacy: .public) rawBytes=\(data.count, privacy: .public) filteredBytes=\(filtered.data.count, privacy: .public) offset=\(offset, privacy: .public) advanced=\(filtered.didAdvance, privacy: .public) truncated=\(truncated, privacy: .public) eof=\(eof, privacy: .public) tail=\(Self.dataTailSummary(filtered.data), privacy: .public)"
        )

        var replay = initialReplay
        if truncated, filtered.didAdvance {
            log.warning("Initial subscribe payload was truncated; using VT history snapshot without truncated raw tail")
        } else if !filtered.data.isEmpty {
            replay.append(filtered.data)
        }

        if !replay.isEmpty {
            eventHandler?(.output(replay))
        }

        if eof {
            log.debug("EOF via initial push for session")
            clearSessionState()
            finishDisconnect(error: nil)
        }
        return true
    }

    private func emitPendingInitialReplayDataIfNeeded() {
        guard let initialReplay = takePendingInitialReplayData(), !initialReplay.isEmpty else { return }
        eventHandler?(.output(initialReplay))
    }

    private func takePendingInitialReplayData() -> Data? {
        withLockedState {
            let data = pendingInitialReplayData
            pendingInitialReplayData = nil
            return data
        }
    }

    private func takeNewSubscriptionData(data: Data, offset: UInt64) -> (data: Data, didAdvance: Bool) {
        // The daemon's existing terminal.subscribe / terminal.output contract
        // reports `offset` as the byte position after this payload. Derive the
        // start from the payload length so de-dupe can discard stale overlap
        // without skipping the next real PTY bytes.
        let payloadLength = UInt64(data.count)
        let payloadEnd = offset
        let payloadStart = offset >= payloadLength ? offset - payloadLength : 0
        return withLockedState {
            let currentOffset = nextOffset
            guard payloadEnd > currentOffset else {
                return (Data(), false)
            }

            let dropCount: Int
            if currentOffset > payloadStart {
                dropCount = Int(min(payloadLength, currentOffset - payloadStart))
            } else {
                dropCount = 0
            }

            nextOffset = payloadEnd
            if dropCount == 0 {
                return (data, true)
            }
            return (Data(data.dropFirst(dropCount)), true)
        }
    }

    private func runReadLoop() async {
        while !Task.isCancelled {
            guard let state = lockedSessionStateWithOffset() else { return }

            do {
                let result = try await client.terminalRead(
                    sessionID: state.sessionID,
                    offset: state.offset,
                    maxBytes: maxReadBytes,
                    timeoutMilliseconds: readTimeoutMilliseconds
                )

                withLockedState {
                    nextOffset = result.offset
                }

                if !result.data.isEmpty {
                    eventHandler?(.output(result.data))
                }

                if result.eof {
                    log.debug("readLoop: EOF received for session \(state.sessionID, privacy: .public), data=\(result.data.count, privacy: .public) bytes")
                    clearSessionState()
                    finishDisconnect(error: nil)
                    return
                }
            } catch let error as TerminalRemoteDaemonClientError {
                if case .rpc(let code, _) = error, code == "deadline_exceeded" {
                    continue
                }
                log.error("readLoop RPC error: \(error.localizedDescription, privacy: .public)")
                finishDisconnect(error: error.localizedDescription)
                return
            } catch {
                log.error("readLoop error: \(String(describing: error), privacy: .public)")
                finishDisconnect(error: error.localizedDescription)
                return
            }
        }
    }

    private func finishDisconnect(error: String?) {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        readTask?.cancel()
        readTask = nil
        stateLock.unlock()

        eventHandler?(.disconnected(error))
    }

    private func lockedSessionID() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sessionID
    }

    private func lockedSessionState() -> (sessionID: String, attachmentID: String)? {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let sessionID, let attachmentID else { return nil }
        return (sessionID, attachmentID)
    }

    private func lockedSessionStateWithOffset() -> (sessionID: String, attachmentID: String, offset: UInt64)? {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let sessionID, let attachmentID else { return nil }
        return (sessionID, attachmentID, nextOffset)
    }

    private func clearSessionState() {
        withLockedState {
            sessionID = nil
            attachmentID = nil
            nextOffset = 0
            pendingInitialReplayData = nil
        }
    }

    private func takeReadTask(markClosed: Bool) -> Task<Void, Never>? {
        withLockedState {
            let task = readTask
            readTask = nil
            if markClosed {
                closed = true
            }
            return task
        }
    }

    private func tearDownPushSubscription(sessionID: String?) async {
        let wasSubscribed: Bool = withLockedState {
            let prev = pushSubscribed
            pushSubscribed = false
            return prev
        }
        guard wasSubscribed,
              let sessionID,
              let pushClient = client as? any TerminalRemoteDaemonPushSubscribing else {
            return
        }
        await pushClient.removePushHandler(sessionID: sessionID)
    }

    private func withLockedState<Result>(_ body: () -> Result) -> Result {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}

extension TerminalRemoteDaemonSessionTransport: TerminalRemoteDaemonResumeStateSnapshotting {
    func remoteDaemonResumeStateSnapshot() -> TerminalRemoteDaemonResumeState? {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let sessionID, let attachmentID else { return nil }
        return TerminalRemoteDaemonResumeState(
            sessionID: sessionID,
            attachmentID: attachmentID,
            readOffset: nextOffset
        )
    }
}

extension TerminalRemoteDaemonSessionTransport: TerminalSessionParking {}
