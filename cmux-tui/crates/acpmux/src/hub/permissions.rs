//! Part of `Hub`; see `hub/mod.rs`.

use super::person::ANSWERED_BY_SLOT;
use super::*;

// A losing answer is told the first one (`respond_permission`).
#[path = "permission_settled.rs"]
pub(super) mod settled;

impl Hub {
    // ------------------------------------------------------------- inbound

    pub(super) async fn inbound_loop(
        self: Arc<Self>,
        session: Arc<Session>,
        mut rx: mpsc::Receiver<Inbound>,
    ) {
        while let Some(item) = rx.recv().await {
            match item {
                Inbound::Notification { method: m, params, agent } => {
                    if m == method::SESSION_UPDATE {
                        // A /context breakdown or usage limits from an agent that was replaced
                        // (a failover's dying primary answering late) are not the chat's now. The
                        // child lock is held while it is applied: a failover takes it to retire
                        // the old agent, and again to detach it, before it clears the
                        // breakdown, so the check and the write cannot straddle the failover.
                        if params.as_ref().is_some_and(crate::agent::process_state) {
                            let child = session.child.lock().await;
                            if child
                                .as_ref()
                                .is_some_and(|c| c.generation == agent && !c.is_retired())
                            {
                                self.on_update(&session, params.as_ref());
                            }
                            continue;
                        }
                        self.on_update(&session, params.as_ref());
                    }
                }
                Inbound::Request { id, method: m, params } => {
                    let hub = self.clone();
                    let s = session.clone();
                    let epoch = session.permission_epoch.load(Ordering::SeqCst);
                    let turn_id = session.turn().map(|t| t.turn_id);
                    // Counted here, in the agent's order, as this loop
                    // reads it: a group's timer waits for every request
                    // read so far (`AskInFlight`). One this loop has not
                    // read within the group's 100 ms still forms a group
                    // of its own.
                    let ask = (m == method::SESSION_REQUEST_PERMISSION)
                        .then(|| super::permission_groups::AskInFlight::new(&session));
                    tokio::spawn(async move {
                        hub.on_agent_request(s, id, m, params, epoch, turn_id, ask).await
                    });
                }
                Inbound::Stderr(line, host_seq) => {
                    let line = short_text(&line, 4000);
                    tracing::debug!(session = %session.id, "stderr: {line}");
                    if !line.trim().is_empty() {
                        let mut tail = session.stderr_tail.lock().unwrap();
                        if tail.len() >= 6 {
                            tail.pop_front();
                        }
                        tail.push_back(line.clone());
                    }
                    // An agent host's stderr was logged before its ack.
                    if host_seq.is_none() {
                        self.append(&session, "mux", "stderr", json!({"text": line}));
                    }
                }
                Inbound::Barrier(done) => {
                    let _ = done.send(());
                }
                Inbound::Exited { pid, code, host_seq } => {
                    {
                        let mut slot = session.child.lock().await;
                        // A late exit from a process that was already replaced
                        // must not detach the new one.
                        if slot.as_ref().is_some_and(|c| c.pid != pid) {
                            continue;
                        }
                        *slot = None;
                    }
                    self.cancel_pending_permissions(&session);
                    self.revoke_permission_chat(&session);
                    // A new agent holds no grant and no undeclared mode.
                    session.floor.harness_grant.store(false, Ordering::SeqCst);
                    session.floor.unsandboxed.store(false, Ordering::SeqCst);
                    *session.floor.undeclared_mode.lock().unwrap_or_else(|e| e.into_inner()) = None;
                    // Its background processes ended with it (`processes.rs`).
                    self.processes_lost(&session, processes::HARNESS_EXIT);
                    let intentional =
                        matches!(session.status(), SessionStatus::Idle | SessionStatus::Closed);
                    // An agent host's exit was logged before its ack.
                    if host_seq.is_none() {
                        self.append(
                            &session,
                            "mux",
                            if intentional { "stopped" } else { "exited" },
                            json!({"code": code}),
                        );
                    }
                    if !intentional {
                        self.set_status(&session, SessionStatus::Disconnected);
                    }
                }
            }
        }
    }

    pub(super) fn on_update(&self, session: &Session, params: Option<&Value>) {
        let Some(update) = params.and_then(|p| p.get("update")) else {
            return;
        };
        // A subagent's messages and settings are not the session's own.
        let sid = params.and_then(|p| p.get("sessionId")).and_then(Value::as_str);
        let owned = sid.is_some_and(|sid| {
            session.subagents.lock().unwrap_or_else(|e| e.into_inner()).owns(sid)
        });
        if owned {
            return;
        }
        let kind = update.get("sessionUpdate").and_then(Value::as_str).unwrap_or("");
        self.note_activity(session, update);
        // A mode or option change goes through the one setter below.
        let mut mode_write = None;
        let mut reported_tools = None;
        let mut goal_write = false;
        let mut mark_cleared = false;
        let mut breakdown_changed = false;
        let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        match kind {
            "agent_message_chunk" => {
                if let Some(text) =
                    update.get("content").and_then(|c| c.get("text")).and_then(Value::as_str)
                {
                    let mut preview = m.preview.clone().unwrap_or_default();
                    preview.push_str(text);
                    if preview.len() > 2000 {
                        let cut = preview.len() - 2000;
                        let mut idx = cut;
                        while !preview.is_char_boundary(idx) {
                            idx += 1;
                        }
                        preview = preview[idx..].to_owned();
                    }
                    m.preview = Some(preview);
                }
            }
            "tool_call" | "tool_call_update" => {
                super::pull_requests::absorb(session, update, &mut m)
            }
            "usage_update" => m.usage = Some(update.clone()),
            "available_commands_update" => m.available_commands = Some(update.clone()),
            "current_mode_update" => {
                // A mode the harness moves to by itself is not cmux's: the mark goes, so moving
                // back to it later is not cmux's either (`trust_wait.rs` `full_access_by_cmux`).
                let reported = update.get("currentModeId").and_then(Value::as_str);
                if m.mode_set_by_cmux.is_some() && reported != m.mode_set_by_cmux.as_deref() {
                    m.mode_set_by_cmux = None;
                    // Saved now, so a restart does not load the mark back.
                    mark_cleared = true;
                }
                mode_write = update.get("currentModeId").cloned().map(ModeWrite::CurrentMode);
            }
            "config_option_update" => {
                mode_write = update.get("configOptions").cloned().map(ModeWrite::ConfigOptions);
            }
            "session_info_update" => {
                if let Some(goal) = update.pointer("/_meta/goal") {
                    m.goal = goal.as_object().map(|_| goal.clone());
                    goal_write = true;
                }
                // A harness title made from the first input stops before a client context
                // (prompt_context.rs), so a Cmd-I chat titles from the person's words.
                if let Some(title) = update.get("title").and_then(Value::as_str) {
                    let title = cmux_chat_index::without_client_context(title).trim_end();
                    if !title.is_empty() {
                        m.title = Some(title.to_owned());
                        m.title_source = Some(super::titles::HARNESS.to_owned());
                    }
                }
                // Claude Code's /context breakdown, sent after each turn (`claude_stdio`). It comes
                // after the turn's own save, so it is saved here (below), or a restart loses it.
                if let Some(breakdown) = update.pointer("/_meta/acpmux/contextBreakdown") {
                    m.context_breakdown = Some(breakdown.clone());
                    breakdown_changed = true;
                }
                // The account's plan usage limits, merged by window (`claude_stdio`).
                if let Some(limits) = update.pointer("/_meta/acpmux/usageLimits") {
                    let merged =
                        crate::claude_stdio::merge_usage_limits(m.usage_limits.as_ref(), limits);
                    breakdown_changed |= m.usage_limits.as_ref() != Some(&merged);
                    m.usage_limits = Some(merged);
                }
                // Claude Code's system/init: its MCP servers, plugins and skills.
                reported_tools = update
                    .pointer("/_meta/claude")
                    .filter(|c| c.get("mcp_servers").is_some_and(Value::is_array))
                    .cloned();
            }
            _ => {}
        }
        drop(m);
        // Goal state must survive a daemon restart even when the turn has not settled yet.
        if goal_write || breakdown_changed {
            self.save_meta(session);
        }
        if let Some(claude) = reported_tools {
            self.absorb_reported_tools(session, &claude);
        }
        // Default deny on drift: also a mode the harness changes by itself.
        if let Some(w) = mode_write {
            self.write_mode_state(session, [w]);
        }
        if mark_cleared {
            self.save_meta(session);
        }
    }

    pub(super) async fn on_agent_request(
        self: Arc<Self>,
        session: Arc<Session>,
        id: Id,
        m: String,
        params: Option<Value>,
        epoch: u64,
        turn_id: Option<String>,
        ask: Option<super::permission_groups::AskInFlight>,
    ) {
        // Context was captured before spawning this request task, so cancel
        // or a new turn cannot make a delayed request join the new ask.
        let Some(child) = session.child.lock().await.clone() else {
            return;
        };
        // Grok's x.ai extension requests: a question or a plan approval,
        // asked through the same permission path (xai.rs).
        if let Some(kind) = super::xai::request_kind(&m) {
            let result = self
                .handle_xai_request(&session, kind, params.unwrap_or(Value::Null), epoch, turn_id)
                .await;
            let _ = child.respond(id, result).await;
            return;
        }
        // Cursor's cursor/ requests: a question or a plan approval (cursor_ext.rs).
        if let Some(kind) = super::cursor_ext::request_kind(&m) {
            let result = self
                .handle_cursor_request(
                    &session,
                    kind,
                    params.unwrap_or(Value::Null),
                    epoch,
                    turn_id,
                )
                .await;
            let _ = child.respond(id, result).await;
            return;
        }
        if m == method::SESSION_REQUEST_PERMISSION {
            let params = params.unwrap_or(Value::Null);
            let result =
                self.handle_permission_for(&session, params, epoch, turn_id, Some(&id), ask).await;
            let _ = child.respond(id, Ok(result)).await;
            return;
        }
        // ACP file-system methods: the harness delegates reads and writes to
        // the client. Writes go through the permission policy like any edit
        // tool; reads are refused only by deny-all or a deny rule.
        if m == "fs/write_text_file" {
            let result =
                self.handle_fs_write(&session, params.unwrap_or(Value::Null), epoch, turn_id).await;
            let _ = child.respond(id, result).await;
            return;
        }
        if m == "fs/read_text_file" {
            let result =
                self.handle_fs_read(&session, params.unwrap_or(Value::Null), epoch, turn_id).await;
            let _ = child.respond(id, result).await;
            return;
        }
        let _ = child.respond(id, Err(RpcError::method_not_found(&m))).await;
    }

    fn fs_path(session: &Session, params: &Value) -> Result<std::path::PathBuf, RpcError> {
        let raw = params
            .get("path")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::invalid_params("path is required"))?;
        let p = std::path::PathBuf::from(raw);
        let p = if p.is_absolute() { p } else { session.meta().cwd.join(p) };
        // Rules match the path text: resolve `.` and `..` first so
        // `src/../../secret` is judged (and written) as where it lands.
        Ok(normalize_path(&p))
    }

    async fn handle_fs_write(
        self: &Arc<Self>,
        session: &Arc<Session>,
        params: Value,
        epoch: u64,
        turn_id: Option<String>,
    ) -> Result<Value, RpcError> {
        let mut path = Self::fs_path(session, &params)?;
        // The remote floor: never through a symlink, the question names the
        // resolved path, and only that file is written (`write_approved`).
        let web_turn = Self::web_turn(session);
        if web_turn {
            path = super::remote_floor::write_target(&path)
                .map_err(|e| RpcError::new(-32000, format!("write refused: {e}")))?;
        }
        let content = params
            .get("content")
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::invalid_params("content is required"))?
            .to_owned();
        // Show the path relative to the session directory; the harness may
        // hand back the canonical form (/private/var vs /var on macOS).
        let cwd = session.meta().cwd;
        let cwd_canon = cwd.canonicalize().unwrap_or_else(|_| cwd.clone());
        let shown = path
            .strip_prefix(&cwd)
            .or_else(|_| path.strip_prefix(&cwd_canon))
            .map(|p| p.to_string_lossy().into_owned())
            .unwrap_or_else(|_| path.to_string_lossy().into_owned());
        let request = json!({
            "sessionId": session.meta().agent_session_id.clone().unwrap_or_else(|| session.id.clone()),
            "toolCall": {"toolCallId": format!("fs-{}", uuid::Uuid::now_v7()), "title": format!("Write {shown}"), "kind": "edit", "status": "pending", "rawInput": {"path": path, "bytes": content.len()}, "locations": [{"path": path}]},
            "options": [
                {"optionId": "allow_once", "name": "Allow", "kind": "allow_once"},
                {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"}
            ]
        });
        let outcome = self.handle_permission(session, request, epoch, turn_id).await;
        if !outcome_allows(&outcome) {
            return Err(RpcError::new(
                -32000,
                format!("write to {shown} rejected by the acpmux permission policy"),
            ));
        }
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| RpcError::internal(format!("create {}: {e}", parent.display())))?;
        }
        let written = if web_turn {
            super::remote_floor::write_approved(&path, content.as_bytes())
        } else {
            std::fs::write(&path, content.as_bytes())
        };
        written.map_err(|e| RpcError::internal(format!("write {}: {e}", path.display())))?;
        Ok(Value::Null)
    }

    async fn handle_fs_read(
        self: &Arc<Self>,
        session: &Arc<Session>,
        params: Value,
        epoch: u64,
        turn_id: Option<String>,
    ) -> Result<Value, RpcError> {
        let mut path = Self::fs_path(session, &params)?;
        // A read from a cancelled turn, or one that arrived before another
        // turn began, is refused, as a permission request from it is cancelled.
        if session.permission_epoch.load(Ordering::SeqCst) != epoch || stale_turn(session, &turn_id)
        {
            return Err(RpcError::new(-32000, "the turn of this read ended"));
        }
        // The remote floor: a Web turn judges, asks about and reads the
        // resolved file; outside its folder it asks first.
        let target = if Self::web_turn(session) {
            let t = super::remote_floor::read_target(&path, &session.meta().cwd);
            if let Some(t) = &t {
                path.clone_from(&t.real);
            }
            Some(t)
        } else {
            None
        };
        let outside = target.as_ref().is_some_and(|t| !t.as_ref().is_some_and(|t| t.inside));
        let config_policy = self.config.read().await.permission_policy;
        let policy = self.policy_for(session, config_policy);
        let probe = json!({"toolCall": {"title": format!("Read {}", path.display()), "kind": "read", "rawInput": {"path": path}}});
        let rule =
            session.meta().permission_rules.as_ref().and_then(|r| super::rules::decide(r, &probe));
        let mut denied = matches!(rule, Some(super::rules::RuleDecision::Deny))
            || (rule.is_none() && policy == PermissionPolicy::DenyAll);
        if !denied && (outside || matches!(rule, Some(super::rules::RuleDecision::Ask))) {
            // An `ask` rule prompts for the read like any other tool call.
            let request = json!({
                "sessionId": session.meta().agent_session_id.clone().unwrap_or_else(|| session.id.clone()),
                "toolCall": {"toolCallId": format!("fs-{}", uuid::Uuid::now_v7()), "title": format!("Read {}", path.display()), "kind": "read", "status": "pending", "rawInput": {"path": path}, "locations": [{"path": path}]},
                "options": [
                    {"optionId": "allow_once", "name": "Allow", "kind": "allow_once"},
                    {"optionId": "reject_once", "name": "Reject", "kind": "reject_once"}
                ]
            });
            denied =
                !outcome_allows(&self.handle_permission(session, request, epoch, turn_id).await);
        }
        if denied {
            return Err(RpcError::new(
                -32000,
                format!("read of {} rejected by the acpmux permission policy", path.display()),
            ));
        }
        let read =
            |e: std::io::Error| RpcError::new(-32000, format!("read {}: {e}", path.display()));
        let text = match target {
            Some(Some(t)) => {
                use std::io::Read;
                let mut text = String::new();
                let mut file = super::remote_floor::open_read_target(&t).map_err(read)?;
                file.read_to_string(&mut text).map_err(read)?;
                text
            }
            Some(None) => return Err(read(std::io::Error::other("the path cannot be resolved"))),
            None => std::fs::read_to_string(&path).map_err(read)?,
        };
        let line = params.get("line").and_then(Value::as_u64).map(|l| l.max(1) as usize);
        let limit = params.get("limit").and_then(Value::as_u64).map(|l| l as usize);
        let content = match (line, limit) {
            (None, None) => text,
            (l, n) => {
                let start = l.unwrap_or(1) - 1;
                let lines: Vec<&str> = text.lines().collect();
                let end = n.map_or(lines.len(), |n| start.saturating_add(n).min(lines.len()));
                if start >= lines.len() { String::new() } else { lines[start..end].join("\n") }
            }
        };
        Ok(json!({"content": content}))
    }

    pub(super) fn policy_for(
        &self,
        session: &Session,
        config_policy: PermissionPolicy,
    ) -> PermissionPolicy {
        session
            .meta()
            .permission_policy
            .as_deref()
            .and_then(|p| p.parse().ok())
            .unwrap_or(config_policy)
    }

    /// `epoch` is `permission_epoch` read when the agent's request arrived.
    pub(super) async fn handle_permission(
        self: &Arc<Self>,
        session: &Arc<Session>,
        request: Value,
        epoch: u64,
        turn_id: Option<String>,
    ) -> Value {
        self.handle_permission_for(session, request, epoch, turn_id, None, None).await
    }

    /// `handle_permission` for the agent's own `session/request_permission`
    /// with JSON-RPC id `agent_request_id`, recorded so a controller that
    /// adopts the agent's host can still answer it.
    pub(super) async fn handle_permission_for(
        self: &Arc<Self>,
        session: &Arc<Session>,
        mut request: Value,
        epoch: u64,
        turn_id: Option<String>,
        agent_request_id: Option<&Id>,
        ask: Option<super::permission_groups::AskInFlight>,
    ) -> Value {
        // One harness-neutral copy of any questions, before rules and the
        // record see the request (questions.rs).
        super::questions::normalize(&mut request, Self::preview_format(session));
        let needs_person = super::questions::needs_person(&request);
        // A shell command that only reads (`shell_readonly.rs`), judged before the lock and off
        // the async workers: its git reads look at the repositories on disk.
        // Only under approve-reads: approve-edits writes files unasked, so a command's own
        // program could be one the agent wrote.
        let reads_policy = {
            let cfg = self.config.read().await;
            self.policy_for(session, cfg.permission_policy) == PermissionPolicy::ApproveReads
        };
        // Judged in the environment the harness runs it with: the daemon's, the allow-listed
        // login values, then the env its agent was started with (`ensure_child`). An agent this
        // daemon did not start (re-adopted after a restart) asks.
        let launched = session.launch_env.lock().unwrap_or_else(|e| e.into_inner()).clone();
        let shell_reads = reads_policy
            && request.pointer("/toolCall/kind").and_then(Value::as_str) == Some("execute")
            && match launched {
                None => false,
                Some(own) => {
                    let meta = session.meta();
                    let family = self.config.read().await.family(&meta.harness);
                    let mut env = crate::login_env::effective_for(family.as_deref(), &own);
                    // The agent's PATH, unless its own env names one (`apply_tokio_for`).
                    if let Some(path) = crate::login_env::agent_path()
                        && !own.contains_key("PATH")
                    {
                        env.insert("PATH".to_owned(), path.to_string_lossy().into_owned());
                    }
                    let (request, cwd) = (request.clone(), meta.cwd);
                    // A probe that takes too long asks; its thread finishes on its own.
                    let probe = tokio::task::spawn_blocking(move || {
                        super::shell_readonly::request_is_read_only(&request, &cwd, &env)
                    });
                    matches!(
                        tokio::time::timeout(super::shell_readonly::PROBE_TIMEOUT, probe).await,
                        Ok(Ok(true))
                    )
                }
            };
        // Read before the locks (it reads the settings file); the mode is read again under them.
        let full_access_on =
            full_access_mode(&session.meta()).is_some() && super::start_mode::full_access_allowed();
        let (rx, prev, grouping, permission_id) = {
            let cfg = self.config.read().await;
            let mut state = session.permissions.lock().unwrap();
            if session.permission_epoch.load(Ordering::SeqCst) != epoch
                || stale_turn(session, &turn_id)
            {
                return json!({"outcome":{"outcome":"cancelled"}});
            }
            // The remote floor (`remote_floor.rs`): a Web turn whose mode left
            // the asking table is cancelled, and nothing in it approves itself.
            let web_turn = Self::web_turn(session);
            if web_turn && let Some(reason) = self.remote_floor_breach(session) {
                self.append(session,"mux","permission_auto",json!({"permissionId":uuid::Uuid::now_v7().to_string(),"request":request,"cancelled":true,"reason":reason}));
                drop(state);
                drop(cfg);
                // The turn ends too (a config reload can end the asking
                // mode with no mode write).
                self.remote_floor_cancel(session, reason);
                return json!({"outcome":{"outcome":"cancelled"}});
            }
            let policy = self.policy_for(session, cfg.permission_policy);
            let options =
                request.get("options").and_then(Value::as_array).cloned().unwrap_or_default();
            let pick = |kinds: &[&str]| -> Option<String> {
                for k in kinds {
                    if let Some(o) =
                        options.iter().find(|o| o.get("kind").and_then(Value::as_str) == Some(k))
                    {
                        return o.get("optionId").and_then(Value::as_str).map(str::to_owned);
                    }
                }
                None
            };
            let tool_kind = request
                .get("toolCall")
                .and_then(|t| t.get("kind"))
                .and_then(Value::as_str)
                .unwrap_or("");
            let rule = session
                .meta()
                .permission_rules
                .as_ref()
                .and_then(|r| super::rules::decide(r, &request));
            let auto = match rule {
                Some(super::rules::RuleDecision::Approve) => pick(&["allow_once", "allow_always"]),
                Some(super::rules::RuleDecision::Deny) => pick(&["reject_once", "reject_always"]),
                Some(super::rules::RuleDecision::Ask) => None,
                None => match policy {
                    PermissionPolicy::ApproveAll => pick(&["allow_once", "allow_always"]),
                    PermissionPolicy::DenyAll => pick(&["reject_once", "reject_always"]),
                    PermissionPolicy::ApproveReads | PermissionPolicy::ApproveEdits => {
                        let edits = policy == PermissionPolicy::ApproveEdits;
                        if matches!(tool_kind, "read" | "search" | "fetch" | "think")
                            || (edits && tool_kind == "edit")
                        {
                            pick(&["allow_once", "allow_always"])
                        } else if tool_kind == "execute"
                            && shell_reads
                            && policy == PermissionPolicy::ApproveReads
                        {
                            // Judged under approve-reads before the lock; the policy read here
                            // must still be it.
                            // A shell command that only reads (`shell_readonly.rs`), once:
                            // allow_always would widen later asks and set the harness grant.
                            pick(&["allow_once"])
                        } else {
                            None
                        }
                    }
                    PermissionPolicy::Ask => None,
                },
            };
            let denied = policy == PermissionPolicy::DenyAll
                || rule == Some(super::rules::RuleDecision::Deny);
            // The chat allowance never answers in a Web turn, nor what an `ask` rule sends to the person.
            let chat_option = if state.chat_allowed
                && !denied
                && rule != Some(super::rules::RuleDecision::Ask)
                && session.turn().is_some_and(|t| t.control != Control::Web)
                && super::permission_groups::eligible(&request)
            {
                super::permission_groups::option(&request, "allow_once")
            } else {
                None
            };
            let floored = web_turn && !denied && auto.is_some();
            // Full access answers what the harness still asks, unless a rule decided it.
            let full_access = (full_access_on && rule.is_none() && !denied)
                .then(|| full_access_allow(session, &request))
                .flatten();
            let auto = if denied {
                pick(&["reject_once", "reject_always"])
            } else if needs_person || web_turn {
                // Policy never answers a question: only a person does.
                None
            } else if let Some((_, option_id)) = &full_access {
                Some(option_id.clone())
            } else {
                chat_option.clone().or(auto)
            };
            let permission_id = uuid::Uuid::now_v7().to_string();
            if let Some(option_id) = auto {
                if option_kind(&options, &option_id) == Some("allow_always") {
                    session.floor.harness_grant.store(true, Ordering::SeqCst);
                }
                let mut record = json!({"permissionId": permission_id, "policy": policy.to_string(), "rule": rule.map(|r| format!("{r:?}").to_lowercase()), "optionId": option_id, "chatAllowance": chat_option.is_some() && full_access.is_none(), "request": request});
                // The mode that answered it, for the transcript's "Approved: … (Full access)".
                if let Some((mode, _)) = &full_access {
                    record["fullAccess"] = json!(mode);
                    tracing::info!(session = %session.id, %mode, "full access approved a request the harness raised");
                }
                self.append(session, "mux", "permission_auto", record);
                return json!({"outcome": {"outcome": "selected", "optionId": option_id}});
            }
            // No safe rejection option means cancel, never fall through to an allow ask.
            if denied {
                self.append(session,"mux","permission_auto",json!({"permissionId":permission_id,"policy":policy.to_string(),"request":request,"cancelled":true}));
                return json!({"outcome":{"outcome":"cancelled"}});
            }
            let (tx, rx) = oneshot::channel();
            let grouping = if super::permission_groups::eligible(&request) && turn_id.is_some() {
                match state.register(
                    &permission_id,
                    &request,
                    turn_id.clone(),
                    epoch,
                    std::time::Instant::now(),
                ) {
                    Ok(g) => Some(g),
                    Err(error) => {
                        self.append(session,"mux","permission_auto",json!({"permissionId":permission_id,"request":request,"cancelled":true,"reason":error.message}));
                        return json!({"outcome":{"outcome":"cancelled"}});
                    }
                }
            } else {
                None
            };
            let decision_nonce = super::person::new_nonce();
            let prev = session.status();
            state.pending.insert(
                permission_id.clone(),
                PendingPermission {
                    // Who asked: acpmux itself (Grok's, Cursor's asks) or the agent.
                    ancestor_may_answer: super::questions::ancestor_answerable(
                        &request,
                        agent_request_id.is_some(),
                    ),
                    request: request.clone(),
                    reply: tx,
                    decision_nonce: decision_nonce.clone(),
                    prev_status: prev,
                },
            );
            self.append(session,"mux","permission_request",json!({"permissionId":permission_id,"decisionNonce":decision_nonce,"personInstance":self.person.instance(),"request":request,"groupId":grouping.as_ref().map(|(id,_)|id),"turnId":turn_id,"agentRequestId":agent_request_id,"remoteFloor":floored}));
            self.set_status(session, SessionStatus::Waiting);
            (rx, prev, grouping, permission_id)
        };
        // Joined its group (or none): the group's timer need not wait for it.
        drop(ask);
        if let Some((id, true)) = grouping {
            self.start_permission_group_timer(session, id);
        }
        let mut outcome = rx.await.unwrap_or_else(|_| json!({"outcome":"cancelled"}));
        // Who answered for the person (`hub/person.rs` answered_by): audit
        // only, never sent to the agent.
        let answered_by = outcome.as_object_mut().and_then(|o| o.remove(ANSWERED_BY_SLOT));
        self.settle_permission(session, &permission_id, outcome.clone(), answered_by, prev);
        let mut out = json!({"outcome": outcome});
        if let Some(m) = out["outcome"].get("_meta").cloned() {
            out["_meta"] = m;
            if let Some(o) = out["outcome"].as_object_mut() {
                o.remove("_meta");
            }
        }
        out
    }

    /// Logs the answer `outcome` to the prompt `permission_id` (the record the chat drops its
    /// card on) and, once the session asks nothing else, takes back its Waiting status
    /// (`status_after_ask` from `prev`, the status before the prompt). Every prompt this process
    /// raised ends here, also a trust card withdrawn without its task (`trust_wait.rs`).
    pub(super) fn settle_permission(
        &self,
        session: &Session,
        permission_id: &str,
        outcome: Value,
        answered_by: Option<Value>,
        prev: SessionStatus,
    ) {
        let mut decision = json!({"permissionId": permission_id, "outcome": outcome});
        if let Some(by) = answered_by {
            decision["answeredBy"] = by;
        }
        self.append(session, "mux", "permission_decision", decision.clone());
        let mut state = session.permissions.lock().unwrap();
        state.settled.remember(permission_id, decision.get("answeredBy"), &decision["outcome"]);
        if state.pending.is_empty()
            && session.status() == SessionStatus::Waiting
            && !self.secrets.waiting_in(&session.id)
        {
            self.set_status(session, status_after_ask(session, prev));
        }
    }

    /// Answer a pending permission. `option_id = None` cancels. `answers`
    /// carries user input for interactive tools (AskUserQuestion), keyed by
    /// question text.
    pub async fn respond_permission(
        &self,
        session: &Session,
        permission_id: &str,
        option_id: Option<String>,
        answers: Option<Value>,
        answered_by: Option<Value>,
        answerer: super::person::Answerer<'_>,
        control: Control,
    ) -> Result<(), RpcError> {
        self.respond_permission_annotated(
            session,
            permission_id,
            option_id,
            answers,
            None,
            answered_by,
            answerer,
            control,
        )
        .await
    }

    /// `respond_permission` with a question's `annotations` (the chosen
    /// preview and notes, `questions::check_annotations`): only the person's
    /// own answer carries them, or a relayed one under the person's decision
    /// proof over them (`person/decision_answers.rs`); never a phone's signed
    /// one (its signature covers the answers alone) or a session's.
    pub async fn respond_permission_annotated(
        &self,
        session: &Session,
        permission_id: &str,
        option_id: Option<String>,
        answers: Option<Value>,
        annotations: Option<Value>,
        answered_by: Option<Value>,
        answerer: super::person::Answerer<'_>,
        control: Control,
    ) -> Result<(), RpcError> {
        // Checked again here, at the answer, not only in the remote guard.
        self.web_control_check(session, control)?;
        let cfg = self.config.read().await;
        let (pending, answered_by, annotations) = {
            let mut guard = session.permissions.lock().unwrap();
            let state = &mut *guard;
            let map = &mut state.pending;
            // Answered already: the first answer won, and this one is told who gave it and how.
            let p = map.get(permission_id).ok_or_else(|| {
                let lost = RpcError::not_found(format!("no pending permission {permission_id}"));
                match state.settled.lost(permission_id) {
                    Some(data) => lost.with_data(data),
                    None => lost,
                }
            })?;
            // A question's annotations, after the lookup so a losing answer still learns who
            // won: only the person's own answer, or one with the person's decision proof (which
            // must cover them, below), and only beside its answers.
            if annotations.is_some() && !answerer.person && answerer.decision.is_none() {
                return Err(super::person::person_required("annotations"));
            }
            if annotations.is_some() && answers.is_none() {
                return Err(RpcError::invalid_params("annotations go only with answers"));
            }
            // Legacy clients may answer items in a group, but cannot bypass
            // a policy edit or choose an absent/ambiguous option.
            if let Some(o) = &option_id {
                let offered: Vec<_> = p.request["options"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter(|x| x["optionId"] == *o)
                    .collect();
                if offered.len() != 1 {
                    return Err(RpcError::invalid_params(format!(
                        "option {o:?} was not uniquely offered for permission {permission_id}"
                    )));
                }
                let kind = offered[0]["kind"].as_str();
                // A Web answer allows once or denies once: never a lasting grant.
                if control == Control::Web && !matches!(kind, Some("allow_once" | "reject_once")) {
                    return Err(super::web_control::lasting_grant_refused(kind.unwrap_or("?")));
                }
                let is_reject = matches!(kind, Some("reject_once" | "reject_always"));
                // A remote browser cannot trust a folder on this machine
                // (`acp.trust.set` is refused for it too, `remote_guard.rs`).
                if control == Control::Web
                    && !is_reject
                    && super::questions::trust_cwd(&p.request).is_some()
                {
                    return Err(RpcError::invalid_params(
                        "trust.web_cannot_answer: trust the folder in the app or the CLI",
                    )
                    .with_data(json!({"reason": "trust.web_cannot_answer"})));
                }
                let denied = self.policy_for(session, cfg.permission_policy)
                    == PermissionPolicy::DenyAll
                    || session
                        .meta()
                        .permission_rules
                        .as_ref()
                        .and_then(|r| super::rules::decide(r, &p.request))
                        == Some(super::rules::RuleDecision::Deny);
                if !is_reject && denied {
                    return Err(RpcError::new(-32000, "policy_changed")
                        .with_data(json!({"reason":"policy_changed"})));
                }
                if kind == Some("allow_always") {
                    session.floor.harness_grant.store(true, Ordering::SeqCst);
                }
            }
            super::questions::check_reply(&p.request, option_id.as_deref(), answers.as_ref())?;
            let checked_annotations = match &annotations {
                Some(a) => super::questions::check_annotations(&p.request, a)?,
                None => None,
            };
            // The authoritative person rule (`person.rs`), here under the
            // prompt's lock, whatever the request check saw: a client that
            // is not the person may cancel or reject; an allow, or who
            // answered, needs the person's decision proof for this very
            // prompt, which is checked again and spent with the answer.
            if !answerer.person {
                let rejects = option_id.as_ref().is_some_and(|o| {
                    p.request["options"].as_array().into_iter().flatten().any(|x| {
                        x["optionId"] == *o
                            && matches!(x["kind"].as_str(), Some("reject_once" | "reject_always"))
                    })
                });
                let allows = option_id.is_some() && !rejects;
                // An ancestor session's answer to a question
                // (`subsession_answer.rs`): answers to a prompt recorded as a
                // question when it was asked (`questions::ancestor_answerable`,
                // never from its input's shape), with its one-time allow and
                // the hub's own `answeredBy`; never a permission prompt, a
                // lasting grant or a plan.
                let ancestor_answers = answerer.ancestor.is_some()
                    && answered_by.is_some()
                    && answers.is_some()
                    && p.ancestor_may_answer
                    && super::questions::trust_cwd(&p.request).is_none()
                    && option_id.as_deref().is_some_and(|o| {
                        option_kind(p.request["options"].as_array().map_or(&[], Vec::as_slice), o)
                            == Some("allow_once")
                    });
                let needs_proof = (allows || answered_by.is_some()) && !ancestor_answers;
                // Annotations from a connection that is not the person count only under the
                // person's proof over them, so never on a reject or an ancestor's answer.
                if annotations.is_some() && !needs_proof {
                    return Err(super::person::person_required("annotations"));
                }
                if needs_proof {
                    let proved = match (&option_id, answerer.decision) {
                        (Some(o), Some((nonce, proof))) => {
                            cmux_local_auth::tokens_match(nonce, &p.decision_nonce)
                                && self.person.decision_proves(
                                    &session.id,
                                    permission_id,
                                    o,
                                    nonce,
                                    answers.as_ref(),
                                    annotations.as_ref(),
                                    proof,
                                )
                        }
                        _ => false,
                    };
                    // A phone's signed allow or answer (`approvers.rs`): it
                    // covers the answers, never `answeredBy` or annotations.
                    let signed = !proved
                        && answered_by.is_none()
                        && annotations.is_none()
                        && match (&option_id, answerer.approver) {
                            (Some(o), Some((nonce, decision))) => {
                                cmux_local_auth::tokens_match(nonce, &p.decision_nonce)
                                    && self.person.approver_proves(
                                        &session.id,
                                        permission_id,
                                        o,
                                        nonce,
                                        answers.as_ref(),
                                        decision,
                                    )
                            }
                            _ => false,
                        };
                    let spent = (proved
                        && answerer.decision.is_some_and(|(n, _)| self.person.spend_decision(n)))
                        || (signed
                            && answerer
                                .approver
                                .is_some_and(|(n, _)| self.person.spend_decision(n)));
                    if !spent {
                        return Err(super::person::person_required("allowing a permission"));
                    }
                }
            }
            let p = map.remove(permission_id).unwrap();
            // A person's answer names them beside any device (`author.rs`), after the person
            // rule above, which it never satisfies.
            let answered_by = crate::author::answered_by(answered_by, answerer.author);
            let decided = match &option_id {
                Some(o) => json!({"outcome": "selected", "optionId": o}),
                None => json!({"outcome": "cancelled"}),
            };
            // Told to a later answer at once, before the asking task logs the decision.
            state.settled.remember(permission_id, answered_by.as_ref(), &decided);
            if let Some(group) = state.finish_item(&session.id, permission_id, option_id.is_none())
            {
                self.append(session, "mux", "permission_group", json!({"group":group}));
            }
            (p, answered_by, checked_annotations)
        };
        let mut outcome = match option_id {
            Some(o) => json!({"outcome": "selected", "optionId": o}),
            None => json!({"outcome": "cancelled"}),
        };
        if let Some(a) = answers {
            let mut input =
                pending.request.pointer("/toolCall/rawInput").cloned().unwrap_or(json!({}));
            input["answers"] = a;
            if let Some(notes) = annotations {
                input["annotations"] = notes;
            }
            outcome["_meta"] = json!({"updatedInput": input});
        }
        if let Some(by) = answered_by {
            outcome[ANSWERED_BY_SLOT] = by;
        }
        let _ = pending.reply.send(outcome);
        Ok(())
    }

    pub(super) fn cancel_pending_permissions(&self, session: &Session) {
        let drained: Vec<_> = {
            let mut state = session.permissions.lock().unwrap();
            session.permission_epoch.fetch_add(1, Ordering::SeqCst);
            let drained: Vec<_> = state.pending.drain().collect();
            for (id, _) in &drained {
                // Told to a later answer at once (`permission_settled.rs`): no one answered.
                state.settled.remember(id, None, &json!({"outcome": "cancelled"}));
                if let Some(group) = state.finish_item(&session.id, id, true) {
                    self.append(session, "mux", "permission_group", json!({"group":group}));
                }
            }
            drained
        };
        for (_, p) in drained {
            let _ = p.reply.send(json!({"outcome": "cancelled"}));
        }
        // A secret card waits on the same turn (`secrets.rs`).
        self.cancel_pending_secrets(session);
    }
}

/// The Full access mode chat `m` runs in now: its current mode, when the shared rule
/// (`spec/full-access-modes.json`, `start_mode::is_full_access`) names it full access and cmux set
/// it itself (`SessionMeta::mode_set_by_cmux`: the person's pick or start mode, never a mode the
/// harness reported on its own, `trust_wait.rs` `full_access_by_cmux`).
fn full_access_mode(m: &SessionMeta) -> Option<String> {
    let mode = crate::web_modes::mode_of(m)?;
    (m.mode_set_by_cmux.as_deref() == Some(mode.as_str())
        && super::start_mode::is_full_access(&mode))
    .then_some(mode)
}

/// The Full access mode and the one-time allow with which a chat in Full access answers `request`
/// unasked (Leo, 2026-10-25, on what Claude Code still asks in bypassPermissions, such as
/// "Dangerous rm operation on statically-unresolvable target": "i think it should... idk like if
/// it is on bypass permissions, that's not auto"): bypass means no prompts, for the harness's own
/// guards and plain tool approvals alike. Only a plain tool ask (`plain_tool_ask`: never a
/// question, a plan approval or a folder-trust card, which stay the person's), only while the
/// current mode is Full access (a chat switched out of it asks again from its next request), and
/// only with a one-time allow: never an "always" option, which writes a rule. The caller keeps
/// deny-all, rules and Web turns ahead of it.
fn full_access_allow(session: &Session, request: &Value) -> Option<(String, String)> {
    if !super::permission_groups::plain_tool_ask(request) {
        return None;
    }
    let mode = full_access_mode(&session.meta())?;
    Some((mode, super::permission_groups::option(request, "allow_once")?))
}

/// The kind of the offered option `id`.
fn option_kind<'a>(options: &'a [Value], id: &str) -> Option<&'a str> {
    options
        .iter()
        .find(|o| o.get("optionId").and_then(Value::as_str) == Some(id))
        .and_then(|o| o.get("kind").and_then(Value::as_str))
}

/// Whether a permission outcome selected an allow option.
fn outcome_allows(outcome: &Value) -> bool {
    outcome
        .pointer("/outcome/optionId")
        .and_then(Value::as_str)
        .map(|o| o.starts_with("allow"))
        .unwrap_or(false)
}

/// `path` with `.` and `..` resolved lexically (`..` at the root stays there).
fn normalize_path(path: &std::path::Path) -> std::path::PathBuf {
    use std::path::Component;
    let mut out = std::path::PathBuf::new();
    for part in path.components() {
        match part {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// Whether a request that arrived during turn `then` (None: between turns) is
/// stale: another turn runs now, and the request must not join its ask. A turn
/// that only ended keeps it (cx-jo8yo): subagents and background shells outlive
/// their turn and still ask, often in the moment between the harness's end of
/// turn and acpmux's. A cancel bumps `permission_epoch`, and the remote floor
/// still judges a request after a Web turn by that turn (`web_turn`).
fn stale_turn(session: &Session, then: &Option<String>) -> bool {
    // A turn the remote floor cancelled stays cancelled for every request
    // from it, also after it ended and a local client restored an asking mode.
    if then.is_some()
        && *session.floor.floor_cancelled_turn.lock().unwrap_or_else(|e| e.into_inner()) == *then
    {
        return true;
    }
    session.turn().is_some_and(|now| Some(&now.turn_id) != then.as_ref())
}

/// The status of a chat whose last ask (a permission or a secret) was just
/// answered, from `prev`, its status when that ask came: running in a turn,
/// ready between turns (an ask that outlived its turn), else as it was.
pub(super) fn status_after_ask(session: &Session, prev: SessionStatus) -> SessionStatus {
    match (session.turn().is_some(), prev) {
        (true, _) => SessionStatus::Running,
        (false, SessionStatus::Running | SessionStatus::Waiting) => SessionStatus::Ready,
        (false, prev) => prev,
    }
}
