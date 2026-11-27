//! Part of `Hub`; see `hub/mod.rs`. The tap that logs one session's wire
//! traffic into its event log.

use super::*;

/// Raw Claude `stream_event` lines (text and tool-input deltas) are mostly not logged: the
/// translated `session/update` records that follow carry their content. They were most of a
/// Claude chat's log (44,000 of 54,000 records in 24 minutes on huge-blue, 2026-10-21), and each
/// one went to every subscriber and into every read of the log. Two kinds stay, because
/// optchat-chief reads them back to time each model request (`fold.rs` `time_request`:
/// headers_ms and ttft_ms): every `message_start`, and the first `content_block_delta` after it.
const RAW_STREAM_EVENT: &str = "claude.stream_event";

/// A raw Claude `control_response` line.
const RAW_CONTROL_RESPONSE: &str = "claude.control_response";

/// The most hook callbacks a tap remembers until their answers (`unread_records.rs`): Claude Code
/// answers each before its tool runs, so a few are open at once.
const MAX_HOOK_CALLS: usize = 256;

/// The most tool calls a session remembers as left open by the live log
/// (`Session::unclosed_tools`).
const MAX_UNCLOSED_TOOLS: usize = 1024;

/// The `session/update` kinds that show the model at work: what it says or does (a message, a
/// thought, a tool call and its progress, a plan), a compaction (the model summarizing) and a
/// subagent's progress.
const MODEL_UPDATES: [&str; 8] = [
    "agent_message_chunk",
    "agent_thought_chunk",
    "tool_call",
    "tool_call_update",
    "plan",
    "compaction",
    "compaction_summary",
    "subagent_progress",
];

/// The `session/update` kinds that show the model at work now, never only an error it ends a
/// turn with: a tool call it starts, a thought, a plan. A chat marked stuck
/// (`session_liveness.rs`) whose agent sends one is not stuck (`Hub::unstick_on_work`).
const WORK_UPDATES: [&str; 3] = ["tool_call", "agent_thought_chunk", "plan"];

/// The raw harness lines only a responding model produces, which often come long before any
/// update a client shows: Claude's stream (its first event is the model's answer starting), its
/// messages, its thinking (redacted thinking sends no thought), a running tool's heartbeat (a
/// prompt queued behind it), and Codex's moderation notice on what the model generates (Codex
/// reasoning without summaries sends nothing else for minutes).
const MODEL_LINES: [&str; 5] = [
    RAW_STREAM_EVENT,
    "claude.assistant",
    "claude.system.thinking_tokens",
    "claude.tool_progress",
    "codex.turn/moderationMetadata",
];

/// Whether an agent's message shows its model at work (`silent_turn.rs`): an update or a raw line
/// above, or a request it makes (a permission, a file, a terminal). The agent's own bookkeeping is
/// not: usage, commands, modes, its turn and usage notices (Codex sends them as soon as the prompt
/// goes out), answers to acpmux's requests, its host's stderr and exit.
fn from_the_model(msg: &Message) -> bool {
    match msg {
        Message::Request { .. } => true,
        Message::Notification { method, params }
            if method == crate::rpc::method::SESSION_UPDATE =>
        {
            params
                .as_ref()
                .and_then(|p| p.pointer("/update/sessionUpdate"))
                .and_then(Value::as_str)
                .is_some_and(|kind| MODEL_UPDATES.contains(&kind))
        }
        Message::Notification { method, .. } => MODEL_LINES.contains(&method.as_str()),
        _ => false,
    }
}

/// Whether a logged record shows the model at work, as `from_the_model` judged it when it came
/// in (`stalled_turn.rs` reads an adopted turn's last one): the update and line kinds above, or a
/// request the agent made. A history replay (`*.replay`) is not.
pub(super) fn logged_from_the_model(e: &crate::store::EventRecord) -> bool {
    e.dir == "in"
        && (MODEL_UPDATES.contains(&e.kind.as_str())
            || MODEL_LINES.contains(&e.kind.as_str())
            || (e.msg.get("id").is_some() && e.msg.get("method").is_some()))
}

/// Whether an agent's message is one of [`WORK_UPDATES`].
fn shows_work(msg: &Message) -> bool {
    matches!(msg, Message::Notification { method, params: Some(p) }
        if method == crate::rpc::method::SESSION_UPDATE
            && p.pointer("/update/sessionUpdate")
                .and_then(Value::as_str)
                .is_some_and(|kind| WORK_UPDATES.contains(&kind)))
}

impl Hub {
    /// A chat marked stuck whose agent works again (`shows_work`) is not stuck: its failures are
    /// forgotten at once, not at its next completed turn (2026-10-29: a coordinator read
    /// `stuck` while it made tool call after tool call). Logged `unstuck`, so watchers re-read it.
    pub(super) fn unstick_on_work(&self, session: &Session) {
        let reason = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let Some((reason, ..)) = m.harness_failures.stuck() else { return };
            m.harness_failures = crate::session_liveness::HarnessFailures::after(m.last_seq);
            reason
        };
        self.save_meta(session);
        self.append(session, "mux", "unstuck", json!({"stuckReason": reason}));
    }

    /// Make sure a live child process exists for the session. Spawns, runs
    /// `initialize`, and either creates or loads the agent session.
    /// The tap that logs one session's wire traffic (and the agent host
    /// entry each record logs, `hostSeq`).
    pub(super) fn session_tap(self: &Arc<Self>, session: &Arc<Session>) -> crate::agent::Tap {
        // Weak: the tap lives in the session's agent (`ChildAgent::tap`), which the session and
        // the hub hold, so a strong one is a cycle that keeps a dropped hub, its audit thread and
        // its sessions alive for ever (each simulated daemon crash leaked one, ~13 MB, until the
        // known-gap sweep ran its runner out of memory).
        let tap_session = Arc::downgrade(session);
        let tap_hub = Arc::downgrade(self);
        // The epoch its reports count in (`FloorState::report_epoch`).
        let report_epoch = session.floor.report_epoch.load(Ordering::SeqCst);
        // A `message_start` was logged and its first delta was not yet.
        let awaiting_first_delta = AtomicBool::new(false);
        // Claude Code's hook callbacks left out of the log, until their answers are
        // (`unread_records.rs`).
        let hook_calls = StdMutex::new(std::collections::HashSet::<String>::new());
        // This tap's number: once a Stop ended its agent, nothing it logs is a sign of work.
        let tap_number = session.taps.fetch_add(1, Ordering::SeqCst) + 1;
        // The last stderr line of this agent process that says why it would die, for its `exited`
        // record (`exit_reason::ExitLine`): a turn it ended well clears it, and a new process has
        // a new tap. Kept here, in entry order: the hub's stderr tail may not have taken the
        // host's last lines yet when its exit entry comes through.
        let last_stderr = std::sync::Mutex::new(super::exit_reason::ExitLine::default());
        Arc::new(move |dir: Direction, msg: &Message, host_seq: Option<u64>| -> bool {
            let (Some(tap_hub), Some(tap_session)) = (tap_hub.upgrade(), tap_session.upgrade())
            else {
                // Its hub or chat is gone: nothing is left to log it to.
                return false;
            };
            // The replay of a session this chat's `session/fork` made is the fork's, never this
            // chat's (`fork_replay.rs`): kept nowhere, it counts as logged, so a host drops it.
            if matches!(dir, Direction::In) && super::fork_replay::of_the_fork(&tap_session, msg) {
                return true;
            }
            let muted = tap_number <= tap_session.muted_taps.load(Ordering::SeqCst);
            // The sign of work is published before a tool call's end can bring the stalled
            // deadline nearer and wake the reaper (`stalled_turn.rs`).
            if !muted && matches!(dir, Direction::In) && from_the_model(msg) {
                let before = tap_session.heard.fetch_add(1, Ordering::SeqCst);
                if before == tap_session.prompt_heard.load(Ordering::SeqCst) {
                    tap_hub.model_answered(&tap_session);
                }
                if !tap_session.loading.load(Ordering::Relaxed) {
                    crate::send_trace::first_update(&tap_session.id);
                }
                tap_hub.heard_now(&tap_session);
                tap_session.last_model_at.store(crate::store::now_ms(), Ordering::Relaxed);
                tap_hub.heard_after_silence(&tap_session);
                // Not a history replay (`session/load`): the agent works now.
                if !tap_session.loading.load(Ordering::SeqCst) && shows_work(msg) {
                    tap_hub.unstick_on_work(&tap_session);
                }
            }
            if !muted
                && matches!(dir, Direction::In)
                && let Message::Notification { method, params: Some(p) } = msg
                && method == crate::rpc::method::SESSION_UPDATE
            {
                tap_hub.note_tool_update(&tap_session, &p["update"]);
                if !tap_session.loading.load(Ordering::SeqCst) {
                    tap_hub.note_verify(&tap_session, &p["update"]);
                    tap_hub.note_sidecars(&tap_session, &p["update"]);
                }
                // Counted before it is logged, so no check waits for the inbound loop to apply
                // it (review 69 of #23322).
                if super::full_access_bound::own_full_access_report(&tap_session, p) {
                    // Under the meta lock the view reads it under (`FullAccessView::of_session`).
                    let _m = tap_session.meta.lock().unwrap_or_else(|e| e.into_inner());
                    if tap_session.floor.report_epoch.load(Ordering::SeqCst) == report_epoch {
                        tap_session.floor.unapplied_full_access.fetch_add(1, Ordering::SeqCst);
                    }
                }
            }
            if matches!(dir, Direction::In) && super::exit_reason::ends_a_turn_well(msg) {
                last_stderr.lock().unwrap_or_else(|e| e.into_inner()).turn_ended_well();
            }
            let (d, kind) = match (dir, msg) {
                // Agent host stderr and exit entries: logged here, in entry
                // order, before the entry is acknowledged.
                (Direction::In, Message::Notification { method, params })
                    if method == crate::agent::HOST_STDERR =>
                {
                    let text = params.as_ref().and_then(|p| p.get("text")).cloned();
                    if let Some(line) = text.as_ref().and_then(Value::as_str) {
                        last_stderr.lock().unwrap_or_else(|e| e.into_inner()).heard(line);
                    }
                    return tap_hub
                        .append_logged(
                            &tap_session,
                            "mux",
                            "stderr",
                            json!({"text": text}),
                            host_seq,
                        )
                        .1;
                }
                (Direction::In, Message::Notification { method, params })
                    if method == crate::agent::HOST_EXIT =>
                {
                    let code = params.as_ref().and_then(|p| p.get("code")).cloned();
                    // The idle exit marked it before it ended the harness (`idle.rs`); a stop clears the mark.
                    let hibernating = tap_session.hibernated_at.load(Ordering::SeqCst) != 0
                        && tap_session.status() != SessionStatus::Closed;
                    let intentional = hibernating
                        || matches!(
                            tap_session.status(),
                            SessionStatus::Idle | SessionStatus::Closed
                        );
                    tap_session.harness_turn.store(false, Ordering::SeqCst);
                    tap_hub.end_background_turn(&tap_session, "exit");
                    // Its workflows ran in the agent's process: they end with it.
                    tap_hub.workflow_index.end_session(&tap_session.id, crate::store::now_ms());
                    return tap_hub
                        .append_logged(
                            &tap_session,
                            "mux",
                            if intentional { "stopped" } else { "exited" },
                            if hibernating {
                                json!({"code": code, "hibernated": true})
                            } else if intentional {
                                json!({"code": code})
                            } else {
                                let last =
                                    last_stderr.lock().unwrap_or_else(|e| e.into_inner()).take();
                                super::exit_reason::exited_data(code, last.as_deref())
                            },
                            host_seq,
                        )
                        .1;
                }
                (Direction::In, Message::Notification { method, params }) => {
                    let mut kind = method.clone();
                    let timing = method == RAW_STREAM_EVENT
                        && params.as_ref().is_some_and(|p| times_request(p, &awaiting_first_delta));
                    // Claude Code's whole /context answer (its grid, every MCP tool) is not
                    // logged either: the breakdown translated from it follows.
                    let context = method == RAW_CONTROL_RESPONSE
                        && params.as_ref().is_some_and(crate::claude_stdio::is_context_answer);
                    if (method == RAW_STREAM_EVENT && !timing) || context {
                        // Kept nowhere: the entry counts as logged, so the host drops it.
                        tap_hub.touch(&tap_session);
                        return true;
                    }
                    if method.starts_with("claude.") {
                        // A turn the person did not start: its records go before its lines
                        // (`background_turn.rs`).
                        if !muted && let Some(line) = params.as_ref() {
                            tap_hub.background_turn_line(&tap_session, method, line);
                        }
                        // Claude Code's turn, its own ones too (`Session::harness_turn`).
                        if method == "claude.system.init" {
                            tap_session.harness_turn.store(true, Ordering::SeqCst);
                        } else if method.starts_with("claude.result") {
                            tap_session.harness_turn.store(false, Ordering::SeqCst);
                        } else if (method == "claude.system.task_started"
                            || method == "claude.system.task_notification")
                            && let Some(line) = params.as_ref()
                        {
                            // A failed subagent's resume, and its end when only these lines
                            // show it (`subagent_retry.rs`).
                            tap_hub.observe_task_line(&tap_session, line);
                        }
                        // What ends a subagent whose end the bridge could not tell
                        // (`subagents::expiry`): the status Claude gave its task, and Claude's
                        // whole list of the tasks that still run.
                        if !muted && let Some(line) = params.as_ref() {
                            match method.as_str() {
                                "claude.command_lifecycle" => {
                                    tap_hub.command_lifecycle(&tap_session, line)
                                }
                                "claude.system.task_notification" => {
                                    tap_hub.subagent_task_notified(&tap_session, line)
                                }
                                "claude.system.task_started" => {
                                    tap_hub.subagent_task_started(&tap_session, line)
                                }
                                "claude.system.background_tasks_changed" => {
                                    tap_hub.subagent_tasks_changed(&tap_session, line)
                                }
                                _ => {}
                            }
                        }
                        // Kept nowhere either: a thinking tick, and a hook callback, whose
                        // answer goes too (`unread_records.rs`).
                        let hook_call =
                            params.as_ref().and_then(crate::unread_records::hook_callback_id);
                        if let Some(id) = hook_call {
                            let mut calls = hook_calls
                                .lock()
                                .unwrap_or_else(std::sync::PoisonError::into_inner);
                            // Answers that never came are not kept forever.
                            if calls.len() >= MAX_HOOK_CALLS {
                                calls.clear();
                            }
                            calls.insert(id.to_owned());
                        }
                        if method == crate::unread_records::THINKING_TICK || hook_call.is_some() {
                            tap_hub.touch(&tap_session);
                            return true;
                        }
                        // Raw stream-json line; translated messages follow. Claude's echo of a
                        // prompt (`--replay-user-messages`) carries its model-sized copies, and
                        // its assistant and user lines the bodies those messages carry.
                        let mut line = params.clone().unwrap_or(Value::Null);
                        crate::model_copies::scrub_logged(&mut line);
                        crate::claude_stdio::leave_out_bodies(&kind, &mut line);
                        // Claude Code repeats its whole system/init each turn; the log keeps
                        // the sections that changed (`logged_init.rs`).
                        let init_sections = tap_session
                            .logged_init
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner)
                            .leave_out_repeats(&kind, &mut line);
                        // Its answer to `initialize` repeats the lists the start before logged
                        // (`update_repeats.rs`).
                        let answer_sections = (method == RAW_CONTROL_RESPONSE).then(|| {
                            tap_session
                                .update_repeats
                                .lock()
                                .unwrap_or_else(std::sync::PoisonError::into_inner)
                                .leave_out_repeats(&kind, &mut line)
                        });
                        let retry = (!muted
                            && matches!(
                                method.as_str(),
                                "claude.system.api_retry" | "claude.system.api_error"
                            ))
                        .then(|| super::turn_retry::claude_retry(&line));
                        let logged =
                            tap_hub.append_logged(&tap_session, "in", &kind, line, host_seq).1;
                        // Only a logged line's sections count as logged: a retried write is
                        // compared with what the log holds.
                        if logged {
                            tap_session
                                .logged_init
                                .lock()
                                .unwrap_or_else(std::sync::PoisonError::into_inner)
                                .note_logged(init_sections);
                            if let Some(sections) = answer_sections {
                                tap_session
                                    .update_repeats
                                    .lock()
                                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                                    .note_logged(sections);
                            }
                        }
                        // The model request failed and Claude Code tries again (`turn_retry.rs`).
                        if let Some(retry) = retry {
                            // A sign-in the model API refuses ends the turn at its second retry.
                            tap_hub.end_sign_in_refused(&tap_session, &retry);
                            tap_hub.turn_retrying(&tap_session, retry);
                        }
                        return logged;
                    }
                    if method == crate::rpc::method::SESSION_UPDATE {
                        if let Some(su) = params
                            .as_ref()
                            .and_then(|p| p.get("update"))
                            .and_then(|u| u.get("sessionUpdate"))
                            .and_then(Value::as_str)
                        {
                            kind = su.to_owned();
                        }
                        if tap_session.loading.load(Ordering::SeqCst) {
                            kind.push_str(".replay");
                        }
                    }
                    ("in", kind)
                }
                (Direction::In, Message::Request { method, .. }) => ("in", method.clone()),
                (Direction::In, Message::Response { .. }) => ("in", "response".to_owned()),
                (Direction::Out, Message::Request { method, .. }) => ("out", method.clone()),
                (Direction::Out, Message::Notification { method, params })
                    if method == "claude.stdin" =>
                {
                    // The answer to a hook callback left out is left out too, unless it denies.
                    if let Some(id) =
                        params.as_ref().and_then(crate::unread_records::plain_answer_id)
                        && hook_calls
                            .lock()
                            .unwrap_or_else(std::sync::PoisonError::into_inner)
                            .remove(id)
                    {
                        tap_hub.touch(&tap_session);
                        return true;
                    }
                    let mut line = params.clone().unwrap_or(Value::Null);
                    crate::model_copies::scrub_logged(&mut line);
                    // A prompt's long text is in its `user_message` already (`logged_bodies.rs`).
                    crate::claude_stdio::leave_out_prompt_bodies("claude.stdin", &mut line);
                    return tap_hub
                        .append_logged(&tap_session, "out", "claude.stdin", line, host_seq)
                        .1;
                }
                (Direction::Out, Message::Notification { method, .. }) => ("out", method.clone()),
                (Direction::Out, Message::Response { .. }) => ("out", "response".to_owned()),
            };
            // A subagent's updates are recorded with their subagent and
            // parent (`crate::subagents`); they are not the session's own
            // message stream.
            let mut value = msg.to_value();
            // Less the model-sized image copies acpmux wrote to the agent, and any echo of them.
            crate::model_copies::scrub_logged(&mut value);
            // The prompt acpmux sends an agent: its long text is in its `user_message` already
            // (`logged_bodies.rs`).
            if d == "out" {
                crate::claude_stdio::leave_out_prompt_bodies(&kind, &mut value);
            }
            // The agent's own display line on its ask is neither logged nor shown
            // (`permissions/display.rs`): only acpmux writes the line a person reads.
            if d == "in"
                && msg.method() == Some(crate::rpc::method::SESSION_REQUEST_PERMISSION)
                && let Some(params) = value.get_mut("params")
            {
                super::drop_display_lines(params);
            }
            let mut subagent = None;
            // Whether this update changed which background subagents run: a root learned late
            // drops its phantom with no subagent event of its own (`SubagentTree::set_root`).
            let mut background_changed = false;
            // Whether it changed how many subagents run (`subagents_running`, the hover card's count)
            // or the latest ones the sidebar nests under the chat (`recentSubagents`).
            let mut running_changed = false;
            if d == "in"
                && msg.method() == Some(crate::rpc::method::SESSION_UPDATE)
                && let Some(params) = value.get_mut("params")
            {
                // An agent to-do list (a `plan`, a to-do tool call) is never logged, so no client
                // sees it (`todo_tools.rs`).
                if crate::todo_tools::drops(&tap_session.id, &params["update"]) {
                    tap_hub.touch(&tap_session);
                    return true;
                }
                // Gemini's plan approval names its plan file only: the update carries the plan
                // (`gemini_plan.rs`), in the log every client reads.
                if params.get("update").is_some_and(super::gemini_plan::names_plan) {
                    let cwd =
                        tap_session.meta.lock().unwrap_or_else(|e| e.into_inner()).cwd.clone();
                    super::gemini_plan::with_plan_update(
                        params,
                        &cwd,
                        &super::gemini_plan::gemini_homes(),
                    );
                }
                // Every ACP adapter eventually emits a tool_call/update here. Annotate its
                // structured edit content so Codex and other non-Claude harnesses get the same
                // per-turn alarm as the Claude stdio adapter.
                if let Some(update) = params.get_mut("update") {
                    // Harness-provided findings are not trusted detector evidence.
                    if let Some(object) = update.as_object_mut() {
                        object.remove("tampering");
                    }
                    let tampering = update
                        .get("sessionUpdate")
                        .and_then(Value::as_str)
                        .filter(|kind| *kind == "tool_call" || *kind == "tool_call_update")
                        // An edit proposal can fail or be cancelled. Both live Claude and
                        // Codex repeat structured diff content on successful settlement.
                        // Only that durable successful event authorizes Restore.
                        .filter(|_| {
                            update.get("status").and_then(Value::as_str) == Some("completed")
                        })
                        .and_then(|_| update.get("content"))
                        .and_then(crate::test_tampering::detect_diffs);
                    if let Some(tampering) = tampering {
                        update["tampering"] = tampering;
                    }
                }
                // The chat's own thread is never one of its subagents. Seed the
                // native roots (the current one and the earlier ones a daemon restart
                // forgot) before handling updates so echoed root activity cannot
                // create a phantom child; replay keeps live/background semantics.
                let (own, retired) = {
                    let meta = tap_session.meta.lock().unwrap_or_else(|e| e.into_inner());
                    (meta.agent_session_id.clone(), meta.retired_agent_session_ids.clone())
                };
                let mut tree = tap_session.subagents.lock().unwrap_or_else(|e| e.into_inner());
                tree.set_own(own.as_deref());
                let before = tree.background_running();
                let running_before = tree.running_count();
                let recent_before = tree.recent_revision();
                tree.set_roots(own.iter().chain(&retired).map(String::as_str));
                tree.set_clock(crate::store::now_ms());
                subagent = tree.annotate_live(params, !kind.ends_with(".replay"));
                background_changed = tree.background_running() != before;
                // A subagent that ended and one that started in its place keep the count but
                // change the list the sidebar nests under the chat (`recentSubagents`).
                running_changed = tree.running_count() != running_before
                    || tree.recent_revision() != recent_before;
                drop(tree);
                // The chat's own words in a turn the person did not start (`background_turn.rs`).
                if subagent.is_none() && !muted && !kind.ends_with(".replay") {
                    tap_hub.background_turn_update(&tap_session, &params["update"]);
                }
                // A wrap-up's first answer is the turn's suggestion where the harness makes none
                // (`wrap_up_suggestion.rs`).
                if subagent.is_none() && !muted && !kind.ends_with(".replay") {
                    crate::wrap_up_suggestion::observe(&tap_session.id, &params["update"]);
                    if let Some(update) = params.get("update") {
                        crate::memory_inbox::observe(&tap_session.id, update);
                    }
                }
                // A predicted next prompt reaches the composer only when likely to be taken
                // (`suggestion_gate.rs`); a withheld one goes on with no suggestion.
                if subagent.is_none() && !muted && kind == "prompt_suggestion" {
                    let harness =
                        tap_session.meta.lock().unwrap_or_else(|e| e.into_inner()).harness.clone();
                    crate::suggestion_gate::filter_update(
                        &tap_hub.suggestion_gate,
                        &tap_session.id,
                        &harness,
                        &mut params["update"],
                    );
                }
            }
            // A live update's workflow changes feed the daemon's index of them.
            if d == "in"
                && !kind.ends_with(".replay")
                && let Some(events) =
                    value.pointer("/params/_meta/acpmux/subagents").and_then(Value::as_array)
            {
                tap_hub.workflow_index.observe(&tap_session.id, events, crate::store::now_ms());
            }
            // Live agent updates (not a session/load replay) also feed the
            // stream watcher, which may record `message_superseded` first.
            let live_update = d == "in"
                && !kind.ends_with(".replay")
                && msg.method() == Some(crate::rpc::method::SESSION_UPDATE)
                && subagent.is_none();
            // It reads the update as logged, after the normalizing above.
            if live_update
                && let Some(segment) =
                    tap_hub.before_agent_update(&tap_session, value.get("params"))
            {
                super::stream::stamp_reply_segment(&mut value, &segment);
            }
            // An update that starts or ends a subagent may change the work that runs past the
            // chat's turn (`work_below.rs`).
            let subagent_events = d == "in"
                && !kind.ends_with(".replay")
                && value.pointer("/params/_meta/acpmux/subagents").is_some();
            // A shell's output file stays in the registry, off the record.
            let output = if d == "in" && kind == "background_task_update" {
                super::processes::take_output_file(&mut value)
            } else {
                None
            };
            // A load's replay of the chat's history is kept nowhere, but for the modes and options
            // it reports and the end of a tool call the live log left open (`unread_records.rs`).
            if d == "in" && crate::unread_records::unread_replay(&kind) {
                let closes = crate::unread_records::replayed_tool_end(&value).filter(|(id, _)| {
                    tap_session
                        .unclosed_tools
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .remove(id)
                });
                let Some((_, kept)) = closes else {
                    tap_hub.touch(&tap_session);
                    if background_changed {
                        tap_hub.refresh_work_below(&tap_session);
                    }
                    if running_changed {
                        let count = tap_session
                            .subagents
                            .lock()
                            .unwrap_or_else(|e| e.into_inner())
                            .running_count();
                        tap_hub.subagents_running(&tap_session, count);
                    }
                    return true;
                };
                value = kept;
            } else if live_update {
                note_live_tool(&tap_session, value.pointer("/params/update"));
            }
            // A state update that repeats what the log last kept is not logged again; the
            // session's meta took it already (`update_repeats.rs`).
            let repeats = if live_update
                && !subagent_events
                && !background_changed
                && !running_changed
                && let Some(update) = value.pointer_mut("/params/update")
            {
                let repeats = tap_session
                    .update_repeats
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .leave_out_repeats(&kind, update);
                if repeats.nothing_left {
                    tap_hub.touch(&tap_session);
                    return true;
                }
                Some(repeats)
            } else if d == "in" && kind == "response" {
                // The `initialize` response repeats the commands the start before logged; a
                // response is always logged (`hosts.rs` pairs a prompt with its response).
                Some(
                    tap_session
                        .update_repeats
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .leave_out_repeats(&kind, &mut value),
                )
            } else {
                None
            };
            let (rec, logged) = tap_hub.append_logged(&tap_session, d, &kind, value, host_seq);
            // A compaction summary the log took: its turns' outline follows, off this path
            // (`hub/compaction_outline.rs`).
            if logged && d == "in" && kind == "compaction_summary" {
                tap_hub.outline_compaction(&tap_session, rec.seq);
            }
            // Only a logged update's sections count as logged: a retried write is compared with
            // what the log holds.
            if logged && let Some(repeats) = repeats {
                tap_session
                    .update_repeats
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .note_logged(repeats);
            }
            if live_update {
                tap_hub.after_agent_update(&tap_session, &rec);
            }
            if subagent_events || background_changed {
                tap_hub.refresh_work_below(&tap_session);
            }
            // Watchers hear the new count on the summary (`subagentsRunning`, `hub/views.rs`).
            if running_changed {
                let count =
                    tap_session.subagents.lock().unwrap_or_else(|e| e.into_inner()).running_count();
                tap_hub.subagents_running(&tap_session, count);
            }
            // A background shell, a subagent's too (`processes.rs`).
            if d == "in" && kind == "background_task_update" {
                tap_hub.note_process(&tap_session, &rec, output.as_deref());
                // A dev server's URL, from its output file (`process_preview.rs`).
                tap_hub.watch_previews(&tap_session);
            }
            // A failed subagent's retry, once its end is logged (`subagent_retry.rs`).
            if d == "in"
                && !kind.ends_with(".replay")
                && let Some(events) =
                    rec.msg.pointer("/params/_meta/acpmux/subagents").and_then(Value::as_array)
            {
                tap_hub.observe_subagents(&tap_session, events);
            }
            // A subagent quiet past its bound ages out (`subagents::expiry`), checked at most
            // once a minute as the chat's lines arrive.
            if d == "in" && !muted {
                tap_hub.sweep_aged_subagents(&tap_session, false);
            }
            logged
        })
    }
}

/// Whether a raw `stream_event` line is one a request's timing reads: a `message_start`, or the
/// first `content_block_delta` after one. Only the main agent's requests are timed; a subagent's
/// lines (`parent_tool_use_id`) stream alongside them and are never kept.
fn times_request(params: &Value, awaiting_first_delta: &AtomicBool) -> bool {
    if params.get("parent_tool_use_id").is_some_and(|p| !p.is_null()) {
        return false;
    }
    match params.pointer("/event/type").and_then(Value::as_str) {
        Some("message_start") => {
            awaiting_first_delta.store(true, Ordering::Relaxed);
            true
        }
        Some("content_block_delta") => awaiting_first_delta.swap(false, Ordering::Relaxed),
        _ => false,
    }
}

/// A live update of the session's own tool call: open until its end (`Session::unclosed_tools`).
fn note_live_tool(session: &Session, update: Option<&Value>) {
    let Some(update) = update else { return };
    let kind = update.get("sessionUpdate").and_then(Value::as_str);
    let Some(id) = update.get("toolCallId").and_then(Value::as_str) else { return };
    let status = update.get("status").and_then(Value::as_str);
    let mut open = session.unclosed_tools.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    match (kind, status) {
        (Some("tool_call" | "tool_call_update"), Some("completed" | "failed")) => {
            open.remove(id);
        }
        (Some("tool_call"), _) | (Some("tool_call_update"), Some(_)) => {
            if open.len() >= MAX_UNCLOSED_TOOLS && !open.contains(id) {
                open.clear();
            }
            open.insert(id.to_owned());
        }
        _ => {}
    }
}

#[cfg(test)]
#[path = "tap_bodies_tests.rs"]
mod bodies_tests;

#[cfg(test)]
#[path = "tap_unread_tests.rs"]
mod unread_tests;
