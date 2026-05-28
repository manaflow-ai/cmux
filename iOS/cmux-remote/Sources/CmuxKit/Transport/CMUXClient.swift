import Foundation
public import Logging

/// High-level client that turns Swift API calls into `cmux <subcommand>`
/// invocations over an `CmuxSSHTransport`. The CLI on the Mac handles socket
/// path discovery, keychain auth, and v1/v2 envelope encoding — we only need
/// to invoke it correctly and parse JSON.
///
/// Method names mirror the cmux CLI contract (`docs/cli-contract.md`) so a
/// reviewer can trace each call back to its documented behaviour.
public actor CMUXClient {

    public let transport: any CmuxSSHTransport
    private let log: Logger
    /// `internal` (not `private`) so command extensions like
    /// `BrowserCommands` / `AgentDecisionResolver` in sibling files can
    /// honour the user's configured remote path.
    let cmuxBinaryPath: String

    public init(
        transport: any CmuxSSHTransport,
        cmuxBinaryPath: String = "cmux",
        logger: Logger = CmuxLog.make("cmux.client")
    ) {
        self.transport = transport
        self.cmuxBinaryPath = cmuxBinaryPath
        self.log = logger
    }

    // MARK: - System

    public func capabilities() async throws -> CmuxCapabilities {
        // `cmux rpc system.capabilities` returns the raw v2 response object.
        let json = try await runJSONObject(["rpc", "system.capabilities"])
        let version = (json["version"] as? String) ?? "unknown"
        let bootID = (json["boot_id"] as? String) ?? ""
        let supportsV2 = (json["v2"] as? Bool) ?? true
        let methods = (json["methods"] as? [String]) ?? []
        let features = (json["features"] as? [String]) ?? []
        let supportsEvents = methods.contains("events.stream") || (json["events_stream"] as? Bool) ?? true
        return CmuxCapabilities(
            version: version,
            bootID: bootID,
            supportsV2: supportsV2,
            supportsEventsStream: supportsEvents,
            supportedMethods: methods,
            supportedFeatures: features
        )
    }

    public func identify() async throws -> [String: Any] {
        try await runJSONObject(["rpc", "system.identify"])
    }

    public func ping() async throws -> Duration {
        try await transport.ping()
    }

    // MARK: - Workspaces / windows / panes / surfaces

    public func listWindows() async throws -> [CmuxWindow] {
        let arr = try await runJSONArray(["rpc", "window.list"])
        return arr.map { (entry: [String: Any]) -> CmuxWindow in
            CmuxWindow(
                id: WindowID((entry["id"] as? String) ?? (entry["ref"] as? String) ?? ""),
                title: entry["title"] as? String,
                isKey: (entry["is_key_window"] as? Bool) ?? (entry["key"] as? Bool) ?? false,
                workspaceCount: (entry["workspace_count"] as? Int) ?? 0,
                selectedWorkspaceID: (entry["selected_workspace_id"] as? String).map { WorkspaceID($0) }
            )
        }
    }

    public func listWorkspaces(windowID: WindowID? = nil) async throws -> [CmuxWorkspace] {
        var params: [String: Any] = [:]
        if let windowID {
            params["window_id"] = windowID.raw
        }
        let payload = try await runJSONObject(["rpc", "workspace.list", Self.encodeJSON(params)])
        let windowID = ((payload["window_id"] as? String) ?? (payload["window_ref"] as? String))
            .map { WindowID($0) }
        let arr = payload["workspaces"] as? [[String: Any]] ?? []
        return arr.compactMap { Self.decodeWorkspace($0, fallbackWindowID: windowID) }
    }

    public func listPanes(workspaceID: WorkspaceID) async throws -> [CmuxPane] {
        let arr = try await runJSONArray([
            "rpc",
            "pane.list",
            Self.encodeJSON(["workspace_id": workspaceID.raw])
        ])
        return arr.compactMap { (entry: [String: Any]) -> CmuxPane? in
            guard let id = (entry["id"] as? String) ?? (entry["ref"] as? String) else { return nil }
            return CmuxPane(
                id: PaneID(id),
                workspaceID: workspaceID,
                isFocused: (entry["focused"] as? Bool) ?? false,
                selectedSurfaceID: (entry["selected_surface_id"] as? String).map { SurfaceID($0) },
                frame: Self.decodeFrame(entry["frame"] as? [String: Any])
            )
        }
    }

    public func listSurfaces(paneID: PaneID, workspaceID: WorkspaceID) async throws -> [CmuxSurface] {
        let arr = try await runJSONArray([
            "rpc",
            "pane.surfaces",
            Self.encodeJSON([
                "workspace_id": workspaceID.raw,
                "pane_id": paneID.raw
            ])
        ])
        return arr.compactMap { (entry: [String: Any]) -> CmuxSurface? in
            guard let id = (entry["id"] as? String) ?? (entry["ref"] as? String) else { return nil }
            let kindRaw = (entry["kind"] as? String) ?? (entry["type"] as? String) ?? "terminal"
            return CmuxSurface(
                id: SurfaceID(id),
                paneID: paneID,
                workspaceID: workspaceID,
                kind: CmuxSurface.Kind(rawValue: kindRaw) ?? .other,
                title: entry["title"] as? String,
                isFocused: (entry["focused"] as? Bool) ?? false,
                isSelected: (entry["selected"] as? Bool) ?? false,
                unreadCount: (entry["unread_count"] as? Int) ?? 0
            )
        }
    }

    // MARK: - Surface input/output

    public func readScreen(
        surfaceID: SurfaceID,
        workspaceID: WorkspaceID? = nil,
        includeScrollback: Bool = false,
        lines: Int? = nil
    ) async throws -> String {
        var args = ["read-screen", "--surface", surfaceID.raw]
        if let workspaceID {
            args.append("--workspace")
            args.append(workspaceID.raw)
        }
        if includeScrollback { args.append("--scrollback") }
        if let lines {
            args.append("--lines")
            args.append(String(lines))
        }
        let result = try await runRaw(args)
        try Self.assertSuccess(result)
        return result.stdoutString
    }

    public func sendText(
        _ text: String,
        surfaceID: SurfaceID,
        workspaceID: WorkspaceID? = nil
    ) async throws {
        // `cmux send` expects the text as a positional argument after an
        // explicit `--` separator (per `docs/cli-contract.md` and the
        // parser in `CLI/cmux.swift`). Passing `--text` would be silently
        // ignored / treated as a flag the dispatcher does not recognise.
        var args = ["send", "--surface", surfaceID.raw]
        if let workspaceID {
            args.append("--workspace")
            args.append(workspaceID.raw)
        }
        args.append("--")
        args.append(text)
        let result = try await runRaw(args)
        try Self.assertSuccess(result)
    }

    public func sendKey(
        _ key: String,
        surfaceID: SurfaceID,
        workspaceID: WorkspaceID? = nil
    ) async throws {
        var args = ["send-key", "--surface", surfaceID.raw]
        if let workspaceID {
            args.append("--workspace")
            args.append(workspaceID.raw)
        }
        args.append("--")
        args.append(key)
        let result = try await runRaw(args)
        try Self.assertSuccess(result)
    }

    // MARK: - Focus

    public func focusSurface(_ surfaceID: SurfaceID, workspaceID: WorkspaceID? = nil) async throws {
        // Use the v2 socket method directly so we don't depend on
        // `focus-panel` vs `focus-pane` aliasing in the CLI. v2
        // `surface.focus` is documented in `docs/events.md` /
        // `docs/cli-contract.md` and tracks the same focus contract.
        var params: [String: Any] = ["surface_id": surfaceID.raw]
        if let workspaceID {
            params["workspace_id"] = workspaceID.raw
        }
        let result = try await runRaw(["rpc", "surface.focus", Self.encodeJSON(params)])
        try Self.assertSuccess(result)
    }

    private static func encodeJSON(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }

    public func selectWorkspace(_ id: WorkspaceID) async throws {
        let result = try await runRaw(["select-workspace", "--workspace", id.raw])
        try Self.assertSuccess(result)
    }

    public func focusWindow(_ id: WindowID) async throws {
        let result = try await runRaw(["focus-window", "--window", id.raw])
        try Self.assertSuccess(result)
    }

    // MARK: - Lifecycle

    public func newWorkspace(
        cwd: String? = nil,
        command: String? = nil,
        description: String? = nil,
        windowID: WindowID? = nil
    ) async throws -> CmuxWorkspace? {
        var params: [String: Any] = [:]
        if let cwd {
            params["cwd"] = cwd
        }
        if let command {
            params["initial_command"] = command
        }
        if let description {
            params["description"] = description
        }
        if let windowID {
            params["window_id"] = windowID.raw
        }
        let payload = try await runJSONObject(["rpc", "workspace.create", Self.encodeJSON(params)])
        guard let id = (payload["workspace_id"] as? String) ?? (payload["workspace_ref"] as? String) else {
            return nil
        }
        let responseWindowID = Self.nonEmptyString(payload["window_id"])
            ?? Self.nonEmptyString(payload["window_ref"])
        let resolvedWindowID = responseWindowID.map { WindowID($0) } ?? windowID
        let lookupWindowID = resolvedWindowID
        do {
            if let workspace = try await listWorkspaces(windowID: lookupWindowID)
                .first(where: { $0.id == WorkspaceID(id) }) {
                return workspace
            }
        } catch {
            log.warning("workspace lookup after create failed; using fallback", metadata: [
                "workspace_id": "\(id)"
            ])
        }
        guard let resolvedWindowID else {
            return nil
        }
        return CmuxWorkspace(
            id: WorkspaceID(id),
            windowID: resolvedWindowID,
            index: 0,
            title: nil,
            cwd: cwd,
            branch: nil,
            isPinned: false,
            isSelected: false,
            unreadCount: 0,
            isRemote: false,
            remoteHost: nil,
            remoteStatus: nil,
            listeningPorts: []
        )
    }

    public func closeWorkspace(_ id: WorkspaceID) async throws {
        let result = try await runRaw(["close-workspace", "--workspace", id.raw])
        try Self.assertSuccess(result)
    }

    // MARK: - Notifications

    public func listNotifications() async throws -> [CmuxNotification] {
        let arr = try await runJSONArray(["rpc", "notification.list"])
        return arr.compactMap(Self.decodeNotification)
    }

    public func listPendingAgentDecisions() async throws -> [AgentDecision] {
        let payload = try await runJSONObject([
            "rpc",
            "feed.list",
            Self.encodeJSON(["pending_only": true])
        ])
        let items = payload["items"] as? [[String: Any]] ?? []
        return items.compactMap(Self.decodePendingAgentDecision)
    }

    public func markRead(notificationID: NotificationID) async throws {
        let result = try await runRaw([
            "mark-notification-read",
            "--id", notificationID.raw
        ])
        try Self.assertSuccess(result)
    }

    public func dismiss(notificationID: NotificationID) async throws {
        let result = try await runRaw([
            "dismiss-notification",
            "--id", notificationID.raw
        ])
        try Self.assertSuccess(result)
    }

    public func openNotification(_ notificationID: NotificationID) async throws {
        let result = try await runRaw([
            "open-notification",
            "--id", notificationID.raw
        ])
        try Self.assertSuccess(result)
    }

    public func jumpToUnread() async throws {
        let result = try await runRaw(["jump-to-unread"])
        try Self.assertSuccess(result)
    }

    public func markAllRead() async throws {
        let result = try await runRaw(["mark-notification-read", "--all"])
        try Self.assertSuccess(result)
    }

    public func clearReadNotifications() async throws {
        let result = try await runRaw(["dismiss-notification", "--all-read"])
        try Self.assertSuccess(result)
    }

    // MARK: - Event stream

    /// Subscribe to the cmux events stream. The stream yields parsed
    /// `CmuxEventFrame`s and auto-finishes if the SSH channel closes — the
    /// caller is responsible for reconnecting with the persisted cursor.
    public nonisolated func eventStream(
        cursor: CmuxEventCursor,
        categories: [String] = []
    ) -> AsyncThrowingStream<CmuxEventFrame, any Error> {
        let command = buildEventsCommand(cursor: cursor, categories: categories)
        let lineStream = transport.runLineStream(command: command) { _ in
            // `cmux events` writes operational warnings to stderr but never
            // anything we need to surface to the consumer — log only.
        }
        let decoder = CmuxEventDecoder()
        return AsyncThrowingStream { continuation in
            let task = Task.detached {
                do {
                    for try await line in lineStream {
                        try Task.checkCancellation()
                        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if trimmed.isEmpty { continue }
                        let frame = try decoder.decode(line: trimmed)
                        continuation.yield(frame)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private nonisolated func buildEventsCommand(
        cursor: CmuxEventCursor,
        categories: [String]
    ) -> String {
        var parts = [cmuxBinaryPath, "events", "--reconnect"]
        if let seq = cursor.seq {
            parts.append("--after")
            parts.append(String(seq))
        }
        for category in categories {
            parts.append("--category")
            parts.append(category)
        }
        // No --no-ack: we WANT the ack to drive boot_id detection on every
        // connection.
        return ShellEscape.command(parts)
    }

    // MARK: - Raw exec helpers

    private func runRaw(_ args: [String]) async throws -> CmuxExecResult {
        var parts = [cmuxBinaryPath]
        parts.append(contentsOf: args)
        let command = ShellEscape.command(parts)
        log.debug("cmux exec", metadata: Self.redactedCommandMetadata(args))
        return try await transport.runOneShot(command: command, stdin: nil)
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func redactedCommandMetadata(_ args: [String]) -> Logger.Metadata {
        var metadata: Logger.Metadata = ["argc": "\(args.count)"]
        if let command = args.first {
            metadata["command"] = "\(command)"
        }
        if args.first == "rpc", args.count > 1 {
            metadata["rpc_method"] = "\(args[1])"
        }
        return metadata
    }

    private func runJSONObject(_ args: [String]) async throws -> [String: Any] {
        let result = try await runRaw(args)
        try Self.assertSuccess(result)
        guard
            let data = result.stdoutString.data(using: .utf8),
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw CmuxError.decoding("expected JSON object", underlying: nil)
        }
        return object
    }

    private func runJSONArray(_ args: [String]) async throws -> [[String: Any]] {
        let object = try await runJSONObject(args)
        // cmux JSON list endpoints wrap the array under a stable key.
        if let arr = object["workspaces"] as? [[String: Any]] { return arr }
        if let arr = object["windows"] as? [[String: Any]] { return arr }
        if let arr = object["panes"] as? [[String: Any]] { return arr }
        if let arr = object["surfaces"] as? [[String: Any]] { return arr }
        if let arr = object["notifications"] as? [[String: Any]] { return arr }
        if let arr = object["items"] as? [[String: Any]] { return arr }
        // Fallback: caller probably wanted the object itself
        return [object]
    }

    private static func assertSuccess(_ result: CmuxExecResult) throws {
        if result.exitCode != 0 {
            throw CmuxError.command(
                exitCode: result.exitCode,
                stderr: result.stderrString.isEmpty ? result.stdoutString : result.stderrString
            )
        }
    }

    // MARK: - Decoders

    static func decodeWorkspace(_ entry: [String: Any], fallbackWindowID: WindowID? = nil) -> CmuxWorkspace? {
        guard let id = Self.nonEmptyString(entry["id"]) ?? Self.nonEmptyString(entry["ref"]) else { return nil }
        guard let windowIDRaw = Self.nonEmptyString(entry["window_id"])
            ?? Self.nonEmptyString(entry["window_ref"])
            ?? Self.nonEmptyString(fallbackWindowID?.raw)
        else { return nil }
        let windowID = WindowID(windowIDRaw)
        let listening = (entry["listening_ports"] as? [Int])
            ?? (entry["ports"] as? [Int])
            ?? []
        let remote = entry["remote"] as? [String: Any]
        return CmuxWorkspace(
            id: WorkspaceID(id),
            windowID: windowID,
            index: (entry["index"] as? Int) ?? 0,
            title: entry["title"] as? String,
            cwd: (entry["cwd"] as? String) ?? (entry["current_directory"] as? String),
            branch: entry["branch"] as? String,
            isPinned: (entry["pinned"] as? Bool) ?? false,
            isSelected: (entry["selected"] as? Bool) ?? false,
            unreadCount: (entry["unread_count"] as? Int) ?? 0,
            isRemote: (entry["remote"] as? Bool) ?? ((remote?["enabled"] as? Bool) ?? false),
            remoteHost: (entry["remote_host"] as? String) ?? (remote?["host"] as? String),
            remoteStatus: (entry["remote_status"] as? String) ?? (remote?["state"] as? String),
            listeningPorts: listening
        )
    }

    static func decodeFrame(_ entry: [String: Any]?) -> CmuxPane.Frame? {
        guard let entry,
              let x = (entry["x"] as? NSNumber)?.doubleValue,
              let y = (entry["y"] as? NSNumber)?.doubleValue,
              let w = (entry["width"] as? NSNumber)?.doubleValue,
              let h = (entry["height"] as? NSNumber)?.doubleValue
        else { return nil }
        return CmuxPane.Frame(x: x, y: y, width: w, height: h)
    }

    static func decodeNotification(_ entry: [String: Any]) -> CmuxNotification? {
        guard let id = entry["id"] as? String else { return nil }
        let createdAt: Date = {
            if let s = entry["created_at"] as? String,
               let d = CmuxEventDecoder.parseTimestamp(s) { return d }
            if let t = entry["created_at"] as? TimeInterval { return Date(timeIntervalSince1970: t) }
            return Date()
        }()
        return CmuxNotification(
            id: NotificationID(id),
            workspaceID: (entry["workspace_id"] as? String).map { WorkspaceID($0) },
            surfaceID: (entry["surface_id"] as? String).map { SurfaceID($0) },
            title: entry["title"] as? String,
            subtitle: entry["subtitle"] as? String,
            body: entry["body"] as? String,
            tabTitle: entry["tab_title"] as? String,
            createdAt: createdAt,
            isRead: (entry["is_read"] as? Bool) ?? (entry["read"] as? Bool) ?? false
        )
    }

    static func decodePendingAgentDecision(_ entry: [String: Any]) -> AgentDecision? {
        guard
            let requestID = entry["request_id"] as? String,
            let kind = entry["kind"] as? String,
            let status = entry["status"] as? String,
            status == "pending"
        else {
            return nil
        }

        let source = (entry["source"] as? String) ?? "agent"
        let workspaceID = (entry["workspace_id"] as? String).map { WorkspaceID($0) }
        let surfaceID = (entry["surface_id"] as? String).map { SurfaceID($0) }
        let title = entry["title"] as? String
        let detail = (entry["detail"] as? String)
            ?? (entry["plan_summary"] as? String)
            ?? (entry["question_prompt"] as? String)
        let toolName = entry["tool_name"] as? String
        let command = entry["tool_input"] as? String
        let expiresAt = (entry["expires_at"] as? String).flatMap(CmuxEventDecoder.parseTimestamp)

        let decisionKind = entry["decision_kind"] as? String
        let hookEventName = entry["hook_event_name"] as? String

        switch kind {
        case "permissionRequest":
            if decisionKind == "diff" || hookEventName == "DiffApprovalRequest" {
                let summary = title ?? String(
                    format: String(localized: "decision.summary.diff", defaultValue: "%@ wants to apply a diff"),
                    locale: Locale.current,
                    source
                )
                return AgentDecision(
                    id: requestID,
                    itemID: entry["id"] as? String,
                    workspaceID: workspaceID,
                    surfaceID: surfaceID,
                    agentName: source,
                    kind: .diff,
                    summary: summary,
                    detail: detail ?? command,
                    toolName: toolName,
                    command: command,
                choices: [
                    AgentDecision.Choice(id: "apply", label: String(localized: "decision.choice.apply", defaultValue: "Apply"), style: .affirmative, requiresAuth: true),
                        AgentDecision.Choice(id: "reject", label: String(localized: "decision.choice.reject", defaultValue: "Reject"), style: .destructive, requiresAuth: false)
                    ],
                    expiresAt: expiresAt
                )
            }
            let tool = toolName ?? String(localized: "decision.tool.default_name", defaultValue: "tool")
            let summary = title ?? String(
                format: String(localized: "decision.summary.tool_call", defaultValue: "%@ wants to run %@"),
                locale: Locale.current,
                source,
                tool
            )
            return AgentDecision(
                id: requestID,
                itemID: entry["id"] as? String,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                agentName: source,
                kind: .toolCall,
                summary: summary,
                detail: detail,
                toolName: toolName,
                command: command,
                choices: [
                    AgentDecision.Choice(id: "allow", label: String(localized: "decision.choice.allow_once", defaultValue: "Allow once"), style: .affirmative, requiresAuth: true),
                    AgentDecision.Choice(id: "allow_session", label: String(localized: "decision.choice.allow_session", defaultValue: "Allow this session"), style: .default, requiresAuth: true),
                    AgentDecision.Choice(id: "allow_all", label: String(localized: "decision.choice.allow_all_tools", defaultValue: "Allow all tools"), style: .default, requiresAuth: true),
                    AgentDecision.Choice(id: "allow_bypass", label: String(localized: "decision.choice.bypass", defaultValue: "Bypass"), style: .affirmative, requiresAuth: true),
                    AgentDecision.Choice(id: "deny", label: String(localized: "decision.choice.deny", defaultValue: "Deny"), style: .destructive, requiresAuth: false)
                ],
                expiresAt: expiresAt
            )
        case "exitPlan":
            return AgentDecision(
                id: requestID,
                itemID: entry["id"] as? String,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                agentName: source,
                kind: .exitPlan,
                summary: title ?? String(localized: "decision.summary.exit_plan", defaultValue: "Agent is ready to exit plan mode"),
                detail: detail,
                choices: [
                    AgentDecision.Choice(id: "manual", label: String(localized: "decision.choice.manual", defaultValue: "Manual"), style: .affirmative, requiresAuth: true),
                    AgentDecision.Choice(id: "auto_accept", label: String(localized: "decision.choice.auto", defaultValue: "Auto"), style: .affirmative, requiresAuth: true),
                    AgentDecision.Choice(id: "ultraplan", label: String(localized: "decision.choice.ultraplan", defaultValue: "Ultraplan"), style: .default, requiresAuth: true),
                    AgentDecision.Choice(id: "allow_bypass", label: String(localized: "decision.choice.bypass", defaultValue: "Bypass"), style: .affirmative, requiresAuth: true),
                    AgentDecision.Choice(id: "deny", label: String(localized: "decision.choice.deny", defaultValue: "Deny"), style: .destructive, requiresAuth: false)
                ],
                expiresAt: expiresAt
            )
        case "question":
            return AgentDecision(
                id: requestID,
                itemID: entry["id"] as? String,
                workspaceID: workspaceID,
                surfaceID: surfaceID,
                agentName: source,
                kind: .choice,
                summary: (entry["question_prompt"] as? String)
                    ?? title
                    ?? String(localized: "decision.summary.agent_waiting", defaultValue: "Agent is waiting"),
                detail: detail,
                choices: Self.decodeQuestionChoices(entry),
                expiresAt: expiresAt
            )
        default:
            return nil
        }
    }

    private static func decodeQuestionChoices(_ entry: [String: Any]) -> [AgentDecision.Choice] {
        let questions = entry["questions"] as? [[String: Any]] ?? []
        if questions.count > 1 {
            let selections = questions.compactMap { question -> AgentDecision.QuestionSelection? in
                guard let questionID = question["id"] as? String,
                      let options = question["options"] as? [[String: Any]],
                      let firstID = options.first?["id"] as? String else {
                    return nil
                }
                return AgentDecision.QuestionSelection(questionID: questionID, optionIDs: [firstID])
            }
            if selections.count == questions.count {
                return [
                    AgentDecision.Choice(
                        id: "__cmux_defaults",
                        label: String(localized: "decision.choice.use_defaults", defaultValue: "Use defaults"),
                        style: .affirmative,
                        requiresAuth: true,
                        questionSelections: selections
                    )
                ]
            }
        }

        let directOptions = entry["question_options"] as? [[String: Any]] ?? []
        let firstQuestion = questions.first
        let nestedOptions = (firstQuestion?["options"] as? [[String: Any]]) ?? []
        let options = directOptions.isEmpty ? nestedOptions : directOptions
        let questionID = (firstQuestion?["id"] as? String) ?? "q0"
        return options.enumerated().compactMap { idx, option in
            guard let label = option["label"] as? String else { return nil }
            let id = (option["id"] as? String) ?? "opt_\(idx)"
            return AgentDecision.Choice(
                id: id,
                label: label,
                style: .default,
                requiresAuth: true,
                questionSelections: [
                    AgentDecision.QuestionSelection(questionID: questionID, optionIDs: [id])
                ]
            )
        }
    }
}
