//! Part of `Hub`; see `hub/mod.rs`.

use super::*;

mod host_load;

/// The tag naming the session whose agent started this one (`Hub::spawned_by`).
pub const SPAWNED_BY_TAG: &str = "spawnedBy";

/// The session's status dot, decided here once so every client draws the
/// same one (cx-zlox). First match wins:
///
/// - `input`: a permission or question waits for the person.
/// - `working`: a turn runs.
/// - `failed`: the last turn failed (also when the agent then exited).
/// - `lost`: the agent process is gone (`disconnected`, or a peer's
///   `unreachable`) and the chat's last turn did not answer. A chat with
///   no turn yet has nothing to lose.
/// - `working` again: work the session started runs on past its last turn
///   (`subagentsWorkingSince`: a background subagent or a working
///   sub-session, `work_below.rs`), except on a peer gone unreachable. A
///   task is not done until its subagents are (manaflow-ai/cmux#25230).
/// - `done`: the last turn answered. Whether the person saw it is each
///   client's own record.
/// - null: nothing to show (no turn yet, a cancelled turn, closed).
///
/// A peer's session that is `unreachable` mid-turn or with a question
/// waiting is `lost`: that turn cannot answer, nor the question be answered.
/// So is a `disconnected` one whose turn has not ended yet (the agent died
/// before its turn recorded `lastTurn`).
///
/// Reads only the summary's own fields, so a summary whose `status` changes
/// afterwards (a peer going unreachable) is re-decided from it.
pub fn status_indicator(summary: &Value) -> Option<&'static str> {
    let status = summary["status"].as_str().unwrap_or_default();
    let last = summary["lastTurn"]["status"].as_str();
    let answered = last == Some("completed");
    let pending = summary["pendingPermissions"].as_u64().unwrap_or(0) > 0;
    match status {
        "closed" => None,
        "unreachable" if pending || !summary["turn"].is_null() => Some("lost"),
        "disconnected" if !summary["turn"].is_null() => Some("lost"),
        "waiting" => Some("input"),
        _ if pending => Some("input"),
        "running" => Some("working"),
        _ if last == Some("failed") => Some("failed"),
        "disconnected" | "unreachable" if last.is_some() && !answered => Some("lost"),
        // A peer gone unreachable takes its work with it; a local chat whose harness stopped
        // (`disconnected`) still works while a sub-session it started runs.
        "unreachable" => answered.then_some("done"),
        _ if summary["subagentsWorkingSince"].is_u64() => Some("working"),
        _ if answered => Some("done"),
        _ => None,
    }
}

/// The keys of a turn's result kept as the session's `lastTurn` (its `detail` names why a turn
/// ended without an answer, e.g. `outcome_unknown`).
pub(super) const LAST_TURN_KEYS: [&str; 10] = [
    "turnId",
    "promptId",
    "status",
    "stopReason",
    "errorText",
    "errorSource",
    "detail",
    "errorKind",
    "recovery",
    "details",
];

impl Hub {
    /// Ends a turn no one heard the outcome of (`outcome_unknown`: a daemon restart, or a host
    /// that never got the prompt). The session shows that turn failed (`lastTurn`, its lane),
    /// recorded before the record goes out, as every turn's end is.
    pub(super) fn append_unknown_outcome(&self, session: &Session, result: Value) {
        self.record_last_turn(session, &result);
        self.append(session, "mux", "turn_result", result);
    }
}

/// The session's lane (cx-v9k2f): what a coordinator watching many agents
/// needs at a glance, decided here once from the summary's own fields.
///
/// - `working` since its turn started, or since its subagents work on past
///   its last turn.
/// - `input`: a permission or question waits for the person.
/// - `failed` since its last turn ended, with that turn's error text (an
///   agent dead on "Credit balance too low" must not read as idle).
/// - `lost`: the agent process is gone without an answer.
/// - `idle` since its last turn ended, or since it was created.
///
/// A session lost mid-turn (its agent or its peer gone before the turn
/// ended) is lost since it went, and its `lastTurn` is the turn before: no
/// error from it. Waiting reads `inputSince` (when it began waiting), so a
/// later record or a draft save does not move it.
///
/// `step` is what it is doing now (hq#2509), see `lane_step`; `title` is the
/// session's title, else its latest prompt. The lane's error, step and title
/// are masked (`secret_scan`), so a view that reads only the lane never shows
/// a pasted secret. The summary's other fields (`turn.prompt`, `lastPrompt`,
/// `lastMessage`, `preview`, `title`) carry the raw text, masked only on the
/// way to a peer daemon (`server/peer_text.rs`).
///
/// `stalledSince`: a working lane whose turn has stalled (`hub/activity.rs`), since when.
///
/// `{state, since, error, step, title, stalledSince}`; null for a closed session.
pub fn lane(summary: &Value) -> Value {
    if summary["status"] == "closed" {
        return Value::Null;
    }
    let updated = summary["updatedAt"].as_u64();
    let in_turn = !summary["turn"].is_null();
    // A session with turns but no `lastTurn` (saved before it existed) is not idle since it was made.
    let made = if summary["turnCount"].as_u64() > Some(0) {
        updated
    } else {
        summary["createdAt"].as_u64()
    };
    let ended = summary["lastTurn"]["endedAt"].as_u64().or(made);
    let (state, since) = match status_indicator(summary) {
        // Its own turn's start, else since its subagents work on past the last one.
        Some("working") => (
            "working",
            summary["turn"]["startedAt"].as_u64().or(summary["subagentsWorkingSince"].as_u64()),
        ),
        Some("input") => ("input", summary["inputSince"].as_u64().or(updated)),
        Some("failed") => ("failed", ended),
        Some("lost") if in_turn => ("lost", updated),
        Some("lost") => ("lost", summary["lastTurn"]["endedAt"].as_u64().or(updated)),
        _ => ("idle", ended),
    };
    let error = match state {
        "failed" => summary["lastTurn"]["errorText"].clone(),
        "lost" if !in_turn => summary["lastTurn"]["errorText"].clone(),
        _ => Value::Null,
    };
    let error = error.as_str().map_or(Value::Null, |e| Value::String(masked_error(e)));
    let stalled =
        if state == "working" { summary["turn"]["stalledSince"].clone() } else { Value::Null };
    json!({"state": state, "since": since, "error": error, "step": lane_step(summary),
           "title": lane_title(summary), "stalledSince": stalled})
}

/// The lane's step, one line: the running turn's prompt, else the agent's
/// last reply line. Masked before it is folded and cut, so a cut never
/// leaves part of a secret unmasked. Null when there is neither, or when a
/// person's own message is the last one (it says nothing new).
fn lane_step(summary: &Value) -> Value {
    let reply = || {
        (summary["lastMessage"]["role"] == "agent")
            .then(|| summary["lastMessage"]["text"].as_str())
            .flatten()
    };
    let line = summary["turn"]["prompt"].as_str().or_else(reply).map(masked_line);
    line.filter(|l| !l.is_empty()).map_or(Value::Null, Value::String)
}

/// The lane's title: the session's title, else its latest prompt, masked and
/// cut like the step. Null when there is neither.
fn lane_title(summary: &Value) -> Value {
    let title = summary["title"].as_str().filter(|t| !t.trim().is_empty());
    let line = title.or_else(|| summary["lastPrompt"].as_str()).map(masked_line);
    line.filter(|l| !l.is_empty()).map_or(Value::Null, Value::String)
}

/// `text` folded to one line, masked and cut to `LANE_STEP_CHARS`. Only the
/// head of the folded text is scanned (a pasted log can be megabytes), and it
/// is masked before the cut, so a cut never leaves part of a secret unmasked.
/// The head is cut after folding: a raw cut inside a token behind a blank run
/// would leave the token's head unmasked once the run folds away.
fn masked_line(text: &str) -> String {
    let (mut head, mut chars) = (String::new(), 0);
    for word in text.split_whitespace() {
        if chars > 0 {
            head.push(' ');
            chars += 1;
        }
        let taken: String = word.chars().take(LANE_SCAN_CHARS.saturating_sub(chars)).collect();
        chars += taken.chars().count();
        head.push_str(&taken);
        if chars >= LANE_SCAN_CHARS {
            break;
        }
    }
    super::session::short_text(&crate::secret_scan::mask(&head), LANE_STEP_CHARS)
}

/// A turn's error masked, lines kept. An error can be a whole pasted log, so
/// only its head is scanned, and it is cut well inside that head after
/// masking, so a secret that straddles the cut is still masked whole.
fn masked_error(text: &str) -> String {
    if text.chars().nth(LANE_ERROR_CHARS).is_none() {
        return crate::secret_scan::mask(text);
    }
    let head: String = text.chars().take(LANE_SCAN_CHARS).collect();
    let mut error: String =
        crate::secret_scan::mask(&head).chars().take(LANE_ERROR_CHARS).collect();
    error.push('…');
    error
}

/// How long a lane's error may be.
const LANE_ERROR_CHARS: usize = 3072;
/// How long a lane's step may be; the row clips it to its width anyway.
const LANE_STEP_CHARS: usize = 240;
/// How much of a step or title is scanned: far past the cut, so a secret
/// that starts before it is still whole.
const LANE_SCAN_CHARS: usize = 4096;

/// Set the summary's derived fields: its status dot and its lane.
pub fn decide(summary: &mut Value) {
    summary["indicator"] = status_indicator(summary).map_or(Value::Null, Value::from);
    summary["lane"] = lane(summary);
}

/// The summary's `lastMessage`, one sidebar line: the last line of words in
/// the agent's reply, or the prompt while the turn has not answered yet.
/// Null before the first prompt.
fn last_message(m: &SessionMeta) -> Option<crate::protocol::session::LastMessage> {
    use crate::protocol::session::{LastMessage, MessageRole};
    let reply = m
        .preview
        .as_deref()
        .and_then(|p| p.lines().rev().find(|l| l.chars().any(char::is_alphanumeric)));
    if let Some(line) = reply {
        return Some(LastMessage { role: MessageRole::Agent, text: short_text(line, 160) });
    }
    m.last_prompt
        .as_deref()
        .filter(|p| !p.trim().is_empty())
        .map(|prompt| LastMessage { role: MessageRole::User, text: short_text(prompt, 160) })
}

/// What limits a session's agent as far as acpmux can tell. `policy` is
/// always the acpmux permission policy (the session's own, else
/// `default_policy`), so sessions on different harnesses compare; the
/// harness's mode is only named in `detail`. Host isolation is never
/// claimed, and no sandbox is inferred from a mode name.
pub(super) fn enforcement(m: &SessionMeta, default_policy: Option<PermissionPolicy>) -> Value {
    let policy = m
        .permission_policy
        .clone()
        .or_else(|| default_policy.map(|p| p.to_string()))
        .unwrap_or_else(|| "unknown".into());
    let mode = m.modes.as_ref().and_then(|x| x.get("currentModeId")).and_then(Value::as_str);
    let harness = m.family.as_deref().unwrap_or(&m.harness);
    json!({
        "policy": policy,
        "label": "native_policy",
        "isolation": "unverified",
        "detail": format!(
            "{harness} mode {}; acpmux policy {policy}{}; host isolation unverified",
            mode.unwrap_or("unknown"),
            if m.permission_policy.is_none() { " (the daemon default)" } else { "" }
        ),
    })
}

impl Hub {
    // ------------------------------------------------------------- views

    /// `enforcement` with the daemon's default policy (unknown only while
    /// the configuration is being written).
    pub(super) fn session_enforcement(&self, m: &SessionMeta) -> Value {
        enforcement(m, self.config.try_read().ok().map(|c| c.permission_policy))
    }

    /// The session whose agent started this one, as the chat lists fold it (`spawnedBy`): its
    /// lineage parent (`lineage.rs`), else the `spawnedBy` tag an older acpmux client set after a
    /// `session/new` sent from inside a session it could not prove (the caller's
    /// `ACPMUX_SESSION_ID`). A child lists under it, never on its own in a chat list. Kept only
    /// while that session is here, listed (not archived) and a root itself: one level, so a loop
    /// of tags or a parent nobody sees never hides a chat. `parent` gives the whole tree.
    pub fn spawned_by(&self, m: &SessionMeta) -> Option<String> {
        let parent = match self.lineage_of(m) {
            Some(lineage) => lineage.parent,
            None => live_tags(m).get(SPAWNED_BY_TAG)?.as_str()?.to_owned(),
        };
        let session =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(&parent).cloned()?;
        let pm = session.meta();
        let tags = live_tags(&pm);
        let listed = tags.get(SPAWNED_BY_TAG).is_none()
            && self.lineage_of(&pm).is_none()
            && tags.get("archived").is_none();
        (parent != m.id && listed).then_some(parent)
    }

    pub fn session_summary(&self, session: &Session) -> Value {
        use crate::protocol::session::{
            QueuedImage, QueuedPromptSummary, SessionSummary, TurnSummary,
        };
        let m = session.meta();
        let waiting = super::subsession_send::waiting_on(session);
        let turn = session.turn();
        let lineage = self.lineage_of(&m);
        let stall_after = self.config.try_read().ok().and_then(|c| c.stalled_turn());
        let heard_at = session.last_model_at.load(Ordering::Relaxed);
        // After `turn`: a retry's turn that started since is seen there (`retry_row`).
        let (retry, retry_deciding) = self.retry_row(session, m.last_turn.as_ref());
        let summary = SessionSummary {
            session_id: m.id.clone(),
            name: m.name.clone(),
            harness: m.harness.clone(),
            family: m.family.clone(),
            cwd: m.cwd.to_string_lossy().into_owned(),
            status: m.status.to_string(),
            agent_session_id: m.agent_session_id.clone(),
            created_at: m.created_at,
            updated_at: m.updated_at,
            last_seq: m.last_seq,
            event_count: m.event_count,
            turn_count: m.turn_count,
            parent_id: m.parent_id.clone(),
            // Where a fork branched off its parent (the pane's < 1/2 > arrows, cx-ncc.61).
            fork_seq: m.fork_seq,
            spawned_by: self.spawned_by(&m),
            parent: lineage.as_ref().map(|l| l.parent.clone()),
            root: lineage.as_ref().map_or_else(|| m.id.clone(), |l| l.root.clone()),
            spawn_tool_call_id: lineage.as_ref().and_then(|l| l.tool_call_id.clone()),
            pull_requests: m.pull_requests.clone(),
            started_by: m.subsession.as_ref().map(|l| l.started_by.clone()),
            short_name: m.subsession.as_ref().map(|l| l.short_name.clone()),
            depth: lineage.as_ref().map_or(0, |l| l.depth),
            children: self.subsessions.open_count(&m.id),
            title: m.title.clone(),
            title_source: m.title_source.clone(),
            last_prompt: m.last_prompt.clone(),
            preview: m.preview.as_deref().map(|p| short_text(p, 160)),
            last_message: last_message(&m),
            queued: session.queued(),
            // A turn failed: the prompts that waited behind it wait for a client to resume them.
            queue_paused: session.queue_paused(),
            // Its queued prompt waits for a run slot of its parent (`subsession_runs.rs`).
            waits_for_slot: self.waits_for_slot(&m),
            // Being moved to another daemon (`transfer_out.rs`): it takes no prompt meanwhile.
            moving: session.moving().is_some(),
            // Shows a conversation another app runs (`watch.rs`): it takes no prompt until taken over.
            watching: m.watching.as_ref().map(|w| w.family.clone()),
            // The agent takes a prompt mid-turn (`_meta.acpmux.steer`); else a steer waits, or
            // with `interrupt` stops the turn and runs next.
            steering: session.steering.load(Ordering::SeqCst),
            // Ctrl-B moves its work: by the kind its harness started as (`processes.rs`).
            backgrounds_work: session.backgrounds_work.load(Ordering::SeqCst),
            turn: turn.map(|t| TurnSummary {
                stalled_since: super::activity::stalled_since(
                    t.started_at,
                    heard_at,
                    t.doing.tool_in_flight(),
                    crate::store::now_ms(),
                    stall_after,
                ),
                started_at: t.started_at,
                client: t.client,
                prompt: t.prompt_preview,
                turn_id: t.turn_id,
                prompt_id: t.prompt_id,
                turn_seq: t.turn_seq,
                activity: t.doing.activity,
                plan_step: t.doing.plan_step,
            }),
            queue: session
                .queue()
                .into_iter()
                .map(|q| QueuedPromptSummary {
                    prompt_id: q.prompt_id,
                    turn_id: q.turn_id,
                    client: q.client,
                    prompt: q.preview,
                    queued_at: q.queued_at,
                    held: q.held,
                    from_agent: q.run.agent.clone(),
                    author: crate::author::listed(q.run.provenance.as_ref()),
                    // By attachment id: `_acpmux/attachment` reads each back.
                    images: super::prompt_images::named(&q.run.blocks)
                        .into_iter()
                        .map(|image| QueuedImage {
                            id: image["id"].as_str().unwrap_or_default().to_owned(),
                            mime_type: image["mimeType"].as_str().unwrap_or_default().to_owned(),
                            name: image["name"].as_str().map(str::to_owned),
                        })
                        .collect(),
                })
                .collect(),
            pending_permissions: session.pending_permissions().len() as u64,
            waiting_on: waiting.as_ref().map(|w| w.0.to_owned()),
            waiting_prompt: waiting.and_then(|w| w.1),
            // Since when it waits on the person (`lane`); null while it does not.
            input_since: match session.input_since.load(Ordering::SeqCst) {
                0 => None,
                since => Some(since),
            },
            current_mode_id: m
                .modes
                .as_ref()
                .and_then(|x| x.get("currentModeId"))
                .cloned()
                .unwrap_or(Value::Null),
            model: current_model(&m),
            policy: m.permission_policy.clone(),
            enforcement: self.session_enforcement(&m),
            rules: m.permission_rules.is_some(),
            // The chat's tools and whether `_acpmux/set_tools` can change them (`hub/tools.rs`).
            tools: m.tools.rows.iter().map(Into::into).collect(),
            tools_mutable: m.tools.mutable,
            // The MCP servers the harness reported loaded (cx-ncc.105), never guessed from config.
            mcp_servers: crate::protocol::session::McpServerSummary::loaded(&m.tools.rows),
            tags: live_tags(&m),
            state_seq: session.state_seq.load(Ordering::SeqCst),
            unread: m.unread,
            last_turn: m.last_turn.clone(),
            // A retry of its failed last turn waits, or is being decided (`auto_resume.rs`).
            retry,
            retry_deciding,
            attached: session.attached.load(Ordering::SeqCst) as u64,
            // Some attached client shows the chat (`hub/seen.rs`).
            shown: self.shown(session),
            // Set from the summary's own fields by `decide`.
            indicator: None,
            lane: None,
            lifecycle_receipt: None,
            peer: None,
        };
        let receipt = SessionReceipt::new(
            LOCAL_HOST_ID,
            m.id.clone(),
            m.agent_session_id.clone(),
            self.started_at,
        );
        let mut summary = serde_json::to_value(summary).unwrap_or(Value::Null);
        summary["qualifiedSessionId"] = Value::String(receipt.qualified_id());
        summary["sessionReceipt"] = receipt.to_value();
        // The branch its folder has checked out now (`git_watch.rs`); null on
        // a detached HEAD or outside a repository.
        summary["gitBranch"] = json!(self.git_branch_now(&m));
        // Since when work it started runs on past its own turn (`work_below.rs`).
        summary["subagentsWorkingSince"] = json!(self.work_below_since(session));
        decide(&mut summary);
        summary
    }

    pub fn session_detail(&self, session: &Session) -> Value {
        let m = session.meta();
        let mut v = self.session_summary(session);
        v["modes"] = m.modes.clone().unwrap_or(Value::Null);
        v["configOptions"] = m.config_options.clone().unwrap_or(Value::Null);
        v["models"] = m.models.clone().unwrap_or(Value::Null);
        v["agentInfo"] = m.agent_info.clone().unwrap_or(Value::Null);
        v["agentCapabilities"] = m.agent_capabilities.clone().unwrap_or(Value::Null);
        v["usage"] = m.usage.clone().unwrap_or(Value::Null);
        v["goal"] = m.goal.clone().unwrap_or(Value::Null);
        // What the context holds by category, as Claude Code's /context says after each turn.
        v["contextBreakdown"] = m.context_breakdown.clone().unwrap_or(Value::Null);
        // The account's plan usage limits, as Claude Code's rate_limit_event last said them.
        v["usageLimits"] = m.usage_limits.clone().unwrap_or(Value::Null);
        // The newest command list: a client that has it needs no read of the log for it.
        if let Some(commands) = &m.available_commands {
            v["availableCommands"] = commands.clone();
        }
        v["forkSeq"] = json!(m.fork_seq);
        v["rulesJson"] = m.permission_rules.clone().unwrap_or(Value::Null);
        // The folder's HEAD when the session started (`git_state.rs`); its
        // `gitBranch` is the summary's, the branch checked out now.
        v["gitHead"] = json!(m.git_head);
        // What the session's turns cost together (`turn_usage.rs`).
        v["totals"] = json!(m.totals);
        // The sub-session limits in force and where each comes from (`subsessions.rs`).
        v["subsessionLimits"] = self.subsession_limits_value(&m);
        let mut pending = session.permissions.lock().unwrap().pending_records();
        for p in &mut pending {
            p["personInstance"] = Value::String(self.person.instance().to_owned());
        }
        v["pending"] = Value::Array(pending);
        v
    }

    pub async fn status(&self) -> Value {
        // Before the config lock: it may wait up to `host_pressure::SAMPLE_WAIT` for a sample.
        let host_pressure = self.host_pressure_status().await;
        let cfg = self.config.read().await;
        // The space of acpmux's disk, `disk.low` with what to free under the floor. Blocking
        // (statvfs and a bounded, cached folder walk), so off the async workers.
        let low = cfg.disk_low_bytes.unwrap_or(crate::recovery::DISK_LOW_DEFAULT_BYTES);
        let disk = tokio::task::spawn_blocking(move || crate::recovery::disk_status(low))
            .await
            .unwrap_or(Value::Null);
        let sessions = self.sessions();
        let mut live = 0;
        for s in &sessions {
            if s.child.lock().await.is_some() {
                live += 1;
            }
        }
        let exe_unstable = crate::daemon::exe_path::current_unstable();
        json!({
            "version": VERSION,
            "build": BUILD,
            // The protocol surfaces this build serves (`capabilities.rs`).
            "capabilities": crate::capabilities::ids(),
            "pid": std::process::id(),
            // Its own executable, and whether it runs as `cmux-tui acp …`, so a
            // client (host enroll) tells which program runs it without scanning
            // processes. Never its command line: `--token` is on it.
            "exe": std::env::current_exe().ok().map(|e| e.to_string_lossy().into_owned()),
            "runsAsCmuxTuiAcp": runs_as_cmux_tui_acp(std::env::args_os()),
            // Whether that executable is a stable install, and why not (`runner-work`, `temp`,
            // `build-tree`): reach, lane-place and `host ls` flag a daemon that a runner's
            // cleanup can delete (`daemon/exe_path.rs`).
            "exeStable": exe_unstable.is_none(),
            "exeUnstable": exe_unstable,
            "startedAt": self.started_at,
            // Whether this run holds a person key, and its id (`hub/person.rs`):
            // the app checks that a daemon it started with a key still runs.
            "personKey": self.person.has_key(),
            "personInstance": self.person.instance(),
            "home": crate::config::home(),
            "userHome": dirs::home_dir(),
            "socket": crate::config::socket_path(),
            "store": cfg.store,
            "sessions": sessions.len(),
            "liveAgents": live,
            "disk": disk,
            // macOS: whether this daemon's agents can read the login keychain
            // (`daemon/login_session.rs`); absent elsewhere.
            "loginSession": daemon_login_session(),
            "ownHome": crate::daemon::login_placement::own_home(
                &crate::config::home(),
                &crate::config::default_home()
            ),
            // `deny`: this daemon starts no agent process (cx-9ettq).
            "agentLaunch": crate::launch_policy::status_word(),
            // Hidden pre-created sessions; never counted above.
            "pool": self.pool_view_json(),
            // New agents outlive this daemon (agent hosts): a restart for an
            // update keeps them running.
            "agentHosts": self.agent_hosts_enabled(),
            "harnesses": cfg.harnesses.keys().collect::<Vec<_>>(),
            "defaultHarness": cfg.default_harness,
            "permissionPolicy": cfg.permission_policy.to_string(),
            "peers": self.peers(),
            "remoteSessions": self.remote_sessions.lock().unwrap().len(),
            "openWaits": self.open_waits.load(Ordering::SeqCst),
            "webUrl": web_url(&cfg),
            "listen": cfg.web_listener().map(|w| w.listen.clone()),
            "ready": self.startup_complete(),
            "loginEnv": crate::login_env::state(self.login_env_requested.load(Ordering::SeqCst)),
            // The Chief home the built-in Chief presets use (`config/chief_builtins.rs`),
            // from this daemon's own environment; the app hands off a Chief-home
            // daemon that lacks it.
            "chiefMuxHome": crate::config::chief_builtins::Context::current().chief_home,
            // The host's CPU and RAM budget and this daemon's share of the load (`host_load.rs`).
            "host_pressure": host_pressure,
        })
    }
}

/// Whether a command line runs `cmux-tui acp …` (a cmux session daemon, or
/// enroll's `~/.local/bin/acpmux` link to a cmux-tui), not `acpmux …`.
pub(crate) fn runs_as_cmux_tui_acp<A: AsRef<std::ffi::OsStr>>(
    args: impl IntoIterator<Item = A>,
) -> bool {
    let mut args = args.into_iter();
    let first = args.next();
    first.is_some_and(|a| std::path::Path::new(a.as_ref()).file_name() == Some("cmux-tui".as_ref()))
        && args.next().is_some_and(|a| a.as_ref() == "acp")
}

#[cfg(test)]
#[path = "views_lane_tests.rs"]
mod lane_tests;

/// `true` when this daemon runs in the user's login session (its agents read the
/// login keychain), `false` when it does not, `"unknown"` when its security session
/// could not be read; null off macOS.
fn daemon_login_session() -> Value {
    #[cfg(target_os = "macos")]
    return match crate::daemon::login_session::in_login_session() {
        Some(here) => Value::Bool(here),
        None => Value::String("unknown".into()),
    };
    #[cfg(not(target_os = "macos"))]
    Value::Null
}
