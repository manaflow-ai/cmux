//! Part of `Hub`; see `hub/mod.rs`. A turn the person did not start (Leo, 2026-10-31, about a
//! chat message that said only "Nothing new for you yet.": "why do you guys keep sending me
//! this/get pinged to send this"; then "yeah" to "a turn you didn't start that has nothing new to
//! tell you shouldn't show up as a message or ping you").
//!
//! Verified Cloud trigger prompts use the same records with trigger `system`,
//! without updating human-facing summary or unread state. Their provenance is
//! admitted by the dedicated trigger RPC, never raw local metadata.
//!
//! Claude Code runs turns acpmux never prompted: when a background task or subagent ends (a task
//! notification), on a scheduled wakeup or loop tick, or for a hook. Each runs from its
//! `system/init` to its `result` while no acpmux turn runs (`Session::harness_turn` without
//! `Session::turn`). acpmux records it between two mux `background_turn` records:
//!
//! - `{"state": "started", "id", "trigger", "cause"?}`, before the turn's own lines; `trigger` is
//!   `task_notification`, `scheduled` or `system` (what came just before its `system/init`), and a
//!   `task_notification` turn's `cause` names the task that ended and whether that is worth a
//!   response (`background_cause.rs`: `{kind, status, weight, origin?, summary?}`);
//! - `{"state": "ended", "id", "trigger", "quiet", "reason"}`, at its `result` (`reason:
//!   "result"`; for Codex, which runs its own turns toward an active goal and sends no `result`,
//!   when its thread goes idle: `_meta.codex.threadStatus.type: "idle"`), when a prompt starts an acpmux turn while it runs (`"prompt"`: the rest is that
//!   turn's), or when the agent exits (`"exit"`).
//!
//! Such a turn never pings: it never marks the chat unread, never ends an acpmux turn (so
//! `lastTurn` and the notifications cmux-tui-core posts from it do not move), and its words never
//! become the chat's `preview` / `lastMessage` (the sidebar line and a later notice's body).
//!
//! One thing it does move: a turn of its own with an explicit successful result proves the
//! chat works again, so a failed `lastTurn` before it gets
//! `recoveredAt` ([`recover_last_turn`]) and the status dot stops reading `failed`
//! (`views.rs` `status_indicator`). The turn's own outcome is unchanged. Its `ended` record says
//! `"failed": false` on success and `true` on error. Only an explicit success recovers it;
//! older records and Codex idle notifications with no outcome marker recover nothing. Before,
//! after one failed turn a chat that went on working through task notifications and `/loop`
//! ticks kept its red tab icon until the person prompted it again (Leo, 2026-11-27: "this isn't
//! leaving the tab icon even after you're not erroring anymore").
//!
//! A turn of its own that ends on the account's rate limit (its `result` is the 429's error) is a
//! strike of the chat and holds it as a prompted turn's 429 does (`rate_hold.rs`
//! [`Hub::hold_at_failure`]): acpmux cannot stop Claude Code from starting it, but what acpmux
//! would start next waits for the hold, and the strikes grow toward parking. Before, only a turn
//! acpmux prompted counted, so a chat that a background task or a `/loop` tick woke on its 429
//! kept getting the queue's turns at once (Leo, 2026-11-18: "claude-sr2-coord fell into a weird
//! "rate limited" loop again 429 and whatever").
//!
//! `quiet` says how the transcript draws it, and is decided here only: a turn whose reply is at
//! most one short line ([`SHORT_LINE`] characters), with no question and no link, is quiet and
//! draws as one muted line that opens on a click. A turn that changed a file (a call of kind
//! [`CHANGES`]) is never quiet, whatever its reply says: the person must see what it did and why
//! (claude-97, 2026-11-25: a finished review woke the agent, it edited two files and committed,
//! and its one-line reply hid under the muted line, so the edits looked as if no prompt started
//! them). Any other one draws in full, still without a ping. Turns the person started are unchanged.

use super::*;
use std::collections::VecDeque;

/// The mux record that brackets a turn the person did not start.
pub const RECORD_KIND: &str = "background_turn";

/// The longest reply, in characters, that still reads as one short line.
pub const SHORT_LINE: usize = 160;

/// The most reply text kept to decide `quiet`: past it the reply is long anyway.
const TEXT_KEPT: usize = 4 * SHORT_LINE;

/// The ACP tool kinds that change files: a background turn with one of these calls is never quiet.
const CHANGES: [&str; 3] = ["edit", "delete", "move"];

/// The updates that start a pending background turn: the model at work.
const WORK: [&str; 4] = ["agent_message_chunk", "agent_thought_chunk", "tool_call", "plan"];

/// The reply messages of background turns kept, so their words stay off the preview
/// (`Hub::on_update` runs after the tap and may still be applying older ones).
const MESSAGES_KEPT: usize = 256;

/// One running background turn.
#[derive(Debug, Clone)]
pub(super) struct Running {
    id: String,
    trigger: &'static str,
    text: String,
    /// Its reply outgrew [`TEXT_KEPT`]: not quiet, whatever the kept part says.
    long: bool,
    /// A permission or structured question needs the person's attention.
    attention: bool,
    /// It called a tool that changes files ([`CHANGES`]): never quiet.
    changed: bool,
}

/// A session's background-turn state, read and written by its tap.
#[derive(Debug, Default)]
pub(super) struct BackgroundTurns {
    /// What the next `system/init` with no acpmux turn was started by, if a line said so.
    hint: Option<&'static str>,
    /// A `system/init` with no acpmux turn came, and what started it: the turn starts at its
    /// first word or tool call (a harness that only says `system/init`, as at its start, ran
    /// none).
    pending: Option<(&'static str, u64)>,
    running: Option<Running>,
    /// Reply message ids of background turns, newest last.
    messages: VecDeque<String>,
    /// The tasks started and the notifications heard: a turn's `cause`.
    causes: super::background_cause::Causes,
    /// An adopted host's replay is being read while the chat's log has an acpmux turn open
    /// ([`Hub::hold_adopted_turn`]): its model work is that turn's, which adoption rebuilds
    /// only once the replay is in the log, never a turn the person did not start.
    adopted_turn: bool,
}

/// Whether a reply is quiet: at most one short line, with no question and no link.
pub fn is_quiet(text: &str) -> bool {
    let text = text.trim();
    let lines = text.lines().filter(|l| !l.trim().is_empty()).count();
    lines <= 1 && text.chars().count() <= SHORT_LINE && !text.contains('?') && !text.contains("://")
}

impl BackgroundTurns {
    /// A raw Claude line, before it is logged. Returns the records to log first.
    fn on_line(&mut self, method: &str, line: &Value, acpmux_turn: bool, seq: u64) -> Vec<Value> {
        let mut out = Vec::new();
        if method == "claude.system.task_started" || !acpmux_turn {
            self.causes.on_line(method, line);
        }
        match method {
            "claude.system.task_notification" if !acpmux_turn => {
                self.hint = Some("task_notification");
            }
            "claude.command_lifecycle"
                if !acpmux_turn && line.get("state").and_then(Value::as_str) == Some("started") =>
            {
                self.hint = Some("scheduled");
            }
            "claude.system.init" if !acpmux_turn && self.running.is_none() => {
                self.pending = Some((self.hint.take().unwrap_or("system"), seq));
            }
            m if m.starts_with("claude.result") => {
                self.hint = None;
                self.pending = None;
                let failed = line.get("is_error") == Some(&Value::Bool(true));
                out.extend(self.end("result").map(|mut ended| {
                    ended.set("failed", json!(failed));
                    ended
                }));
            }
            _ => {}
        }
        out
    }

    /// An own update of the chat (not a subagent's), before it is logged. Returns the
    /// `started` record to log first, when it is the first sign of a pending turn, or the
    /// `ended` record of the running one when Codex's thread went idle.
    fn on_update(&mut self, update: &Value, acpmux_turn: bool, seq: u64) -> Option<Value> {
        let kind = update.get("sessionUpdate").and_then(Value::as_str).unwrap_or("");
        // Codex sends no `result`: its thread going idle ends its own turn (one toward an active
        // `_session/goal`, `stop_condition.rs`).
        if !acpmux_turn
            && kind == "session_info_update"
            && update.pointer("/_meta/codex/threadStatus/type").and_then(Value::as_str)
                == Some("idle")
        {
            return self.end("result");
        }
        let mut started = None;
        if acpmux_turn {
            self.pending = None;
            self.causes.clear();
        } else if WORK.contains(&kind) && self.running.is_none() {
            // Model work with no acpmux turn is Claude Code's own turn. Its `system/init` may
            // have come before this daemon started (a restart, an adopted host): what started
            // it is then unknown.
            let (trigger, seq) = self.pending.take().unwrap_or(("system", seq));
            let id = format!("bg-{seq}");
            let mut record = json!({"state": "started", "id": id, "trigger": trigger});
            if let Some(cause) = self.causes.take().filter(|_| trigger == "task_notification")
                && let Some(fields) = record.as_object_mut()
            {
                fields.insert("cause".into(), cause);
            }
            started = Some(record);
            self.running = Some(Running {
                id,
                trigger,
                text: String::new(),
                long: false,
                attention: false,
                changed: false,
            });
        }
        let Some(running) = self.running.as_mut() else { return started };
        if matches!(kind, "tool_call" | "tool_call_update")
            && update.get("kind").and_then(Value::as_str).is_some_and(|k| CHANGES.contains(&k))
        {
            running.changed = true;
        }
        if kind != "agent_message_chunk" {
            return started;
        }
        if let Some(id) = update.get("messageId").and_then(Value::as_str)
            && self.messages.back().map(String::as_str) != Some(id)
        {
            self.messages.push_back(id.to_owned());
            while self.messages.len() > MESSAGES_KEPT {
                self.messages.pop_front();
            }
        }
        if let Some(text) = update.pointer("/content/text").and_then(Value::as_str) {
            if running.long || running.text.len() + text.len() > TEXT_KEPT {
                running.long = true;
            } else {
                running.text.push_str(text);
            }
        }
        started
    }

    /// Ends the running one, if any: its `ended` record.
    fn end(&mut self, reason: &str) -> Option<Value> {
        self.pending = None;
        let r = self.running.take()?;
        Some(json!({
            "state": "ended", "id": r.id, "trigger": r.trigger,
            "quiet": !r.attention && !r.long && !r.changed && is_quiet(&r.text), "reason": reason,
        }))
    }

    /// The turn of its own a `result` line ends, while no acpmux turn runs: the running one's id,
    /// or one only begun (its `system/init` came, no model work yet) named by its init's seq.
    fn own_turn(&self, acpmux_turn: bool) -> Option<String> {
        if acpmux_turn {
            return None;
        }
        let running = self.running.as_ref().map(|r| r.id.clone());
        running.or_else(|| self.pending.map(|(_, seq)| format!("bg-{seq}")))
    }

    /// Whether a reply message is a background turn's.
    fn owns_message(&self, id: &str) -> bool {
        self.messages.iter().any(|m| m == id)
    }
}

/// Whether a `background_turn` record is a turn of its own that ended cleanly: the chat works.
pub(super) fn recovers(record: &Value) -> bool {
    record.get("state").and_then(Value::as_str) == Some("ended")
        && record.get("reason").and_then(Value::as_str) == Some("result")
        // Old journals omitted this field for both success and failure. Only an explicit
        // successful result proves recovery when replayed by a newer daemon.
        && record.get("failed") == Some(&Value::Bool(false))
}

/// A later turn ended cleanly at `at` (a background turn, [`recovers`], or a trigger turn that
/// completed): a `lastTurn` that did not complete is marked `recoveredAt`, so the status dot
/// stops reading `failed` or `lost` (the module doc). Its status, error and the unread mark stay.
pub(super) fn recover_last_turn(last: &mut Option<Value>, at: u64) -> bool {
    let Some(last) = last.as_mut() else { return false };
    let status = last.get("status").and_then(Value::as_str);
    if status.is_some_and(|s| s != "completed") && last.get("recoveredAt").is_none() {
        last.set("recoveredAt", json!(at));
        return true;
    }
    false
}

/// The error of a Claude `result` line that failed on the account's usage or rate limit.
fn rate_limit_result(method: &str, line: &Value) -> Option<String> {
    if !method.starts_with("claude.result") || line.get("is_error") != Some(&Value::Bool(true)) {
        return None;
    }
    let error = line.get("result").and_then(Value::as_str)?;
    (crate::turn_errors::resume_cause(error, error) == Some("rate_limit")).then(|| error.to_owned())
}

impl Hub {
    /// An adopted host continues the already journaled bracket. Its earlier
    /// reply is not in memory, so keep the row expanded rather than guess.
    pub(super) fn restore_trigger_background(&self, session: &Session, turn_id: &str) {
        session.background_turns.lock().unwrap_or_else(|e| e.into_inner()).running =
            Some(Running {
                id: format!("bg-trigger-{turn_id}"),
                trigger: "system",
                text: String::new(),
                long: true,
                attention: false,
                changed: false,
            });
    }

    /// A verified trigger is prompted by acpmux, but is still not the person's
    /// turn. Use the existing transcript record and its supported discriminator.
    pub(super) fn start_trigger_background(&self, session: &Session, turn_id: &str) {
        let id = format!("bg-trigger-{turn_id}");
        let mut state = session.background_turns.lock().unwrap_or_else(|e| e.into_inner());
        if state.running.as_ref().is_some_and(|r| r.id == id) {
            return;
        }
        let previous = state.end("prompt");
        state.running = Some(Running {
            id: id.clone(),
            trigger: "system",
            text: String::new(),
            long: false,
            attention: false,
            changed: false,
        });
        drop(state);
        if let Some(msg) = previous {
            self.append(session, "mux", RECORD_KIND, msg);
        }
        self.append(
            session,
            "mux",
            RECORD_KIND,
            json!({"state":"started", "id":id, "trigger":"system"}),
        );
    }

    /// Non-Claude adapters have no raw claude.result, so settle their bracket
    /// after the inbound barrier too. A result already ended it is a no-op.
    pub(super) fn end_trigger_background(&self, session: &Session, turn_id: &str) {
        let id = format!("bg-trigger-{turn_id}");
        let mut state = session.background_turns.lock().unwrap_or_else(|e| e.into_inner());
        let ended = state
            .running
            .as_ref()
            .is_some_and(|r| r.id == id)
            .then(|| state.end("result"))
            .flatten();
        drop(state);
        if let Some(msg) = ended {
            self.append(session, "mux", RECORD_KIND, msg);
        }
    }

    pub(super) fn background_attention(&self, session: &Session) {
        if let Some(running) =
            session.background_turns.lock().unwrap_or_else(|e| e.into_inner()).running.as_mut()
        {
            running.attention = true;
        }
    }

    /// The tap saw a raw Claude line (`claude.*`): logs the background-turn records it starts or
    /// ends, before the line itself.
    /// A turn of its own that ends on the account's limit is a strike and holds the chat (the
    /// module doc).
    pub(super) fn background_turn_line(
        self: &Arc<Self>,
        session: &Arc<Session>,
        method: &str,
        line: &Value,
    ) {
        let acpmux_turn = session.turn().is_some();
        let seq = session.meta.lock().unwrap_or_else(|e| e.into_inner()).last_seq + 1;
        let mut state = session.background_turns.lock().unwrap_or_else(|e| e.into_inner());
        let acpmux_turn = acpmux_turn || state.adopted_turn;
        let limited =
            rate_limit_result(method, line).and_then(|e| Some((state.own_turn(acpmux_turn)?, e)));
        let records = state.on_line(method, line, acpmux_turn, seq);
        drop(state);
        for msg in records {
            self.append_background_record(session, msg);
        }
        if let Some((turn, error)) = limited {
            let _parked = self.hold_at_failure(session, &turn, &error, None);
        }
    }

    /// The tap saw one of the chat's own updates (not a subagent's).
    pub(super) fn background_turn_update(&self, session: &Session, update: &Value) {
        let acpmux_turn = session.turn().is_some();
        let seq = session.meta.lock().unwrap_or_else(|e| e.into_inner()).last_seq + 1;
        let mut state = session.background_turns.lock().unwrap_or_else(|e| e.into_inner());
        let acpmux_turn = acpmux_turn || state.adopted_turn;
        let record = state.on_update(update, acpmux_turn, seq);
        drop(state);
        if let Some(msg) = record {
            self.append_background_record(session, msg);
        }
    }

    /// Logs a `background_turn` record; one that ends a turn cleanly first marks a failed
    /// `lastTurn` recovered (the module doc), as the journal restore does (`count_restored`).
    fn append_background_record(&self, session: &Session, msg: Value) {
        let recovered = recovers(&msg)
            && recover_last_turn(
                &mut session.meta.lock().unwrap_or_else(|e| e.into_inner()).last_turn,
                now_ms(),
            );
        self.append(session, "mux", RECORD_KIND, msg);
        if recovered {
            // Handoff drains queued metadata saves; it does not snapshot unsaved mutations.
            self.save_meta(session);
        }
    }

    /// While an agent host is adopted (`hosts.rs` `adopt_held`): its replay comes before
    /// adoption rebuilds the open turn from the complete log (`recover_work`), so until the
    /// returned hold drops, model work counts as the turn the chat's log has open, when it has
    /// one (`open`, [`Hub::log_turn_open`]'s read, made off the executor). Before, the replayed
    /// words of the person's own streaming turn opened a `background_turn` bracket, which the pane
    /// folds into one muted line: after a restart the reply streamed on hidden until the turn
    /// ended (manaflow-ai/cmuxterm-hq#6338).
    pub(super) fn hold_adopted_turn<'a>(
        &self,
        session: &'a Session,
        open: bool,
    ) -> AdoptedTurn<'a> {
        session.background_turns.lock().unwrap_or_else(|e| e.into_inner()).adopted_turn = open;
        AdoptedTurn(session)
    }

    /// Whether the chat's log ends inside an acpmux turn: its last turn marker is a
    /// `turn_started`, or a `turn_result` that carried into the next turn (`carried_turn.rs`).
    /// Read from the end, as `open_work` finds the last turn.
    pub(super) fn log_turn_open(&self, session: &Session) -> bool {
        let mut open = false;
        let _ = self.store.scan_back(
            &session.id,
            0,
            u64::MAX,
            &|dir, kind| dir != b"mux" || !matches!(kind, b"turn_started" | b"turn_result"),
            // A line whose head does not read reaches here unskipped.
            &mut |e| {
                if e.dir == "mux" && matches!(e.kind.as_str(), "turn_started" | "turn_result") {
                    open = e.kind == "turn_started"
                        || e.msg.get("carriedTo").is_some_and(|c| !c.is_null());
                    return false;
                }
                true
            },
        );
        open
    }

    /// A prompt starts an acpmux turn, or the agent exited: a running background turn ends here.
    pub(super) fn end_background_turn(&self, session: &Session, reason: &str) {
        let ended = session.background_turns.lock().unwrap_or_else(|e| e.into_inner()).end(reason);
        if let Some(msg) = ended {
            self.append(session, "mux", RECORD_KIND, msg);
        }
    }

    /// Whether an `agent_message_chunk` is a background turn's: its words stay off the preview.
    pub(super) fn background_message(&self, session: &Session, update: &Value) -> bool {
        if session.turn().is_some_and(|t| t.trigger)
            || session
                .ending
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .as_ref()
                .is_some_and(|t| t.trigger)
        {
            return true;
        }
        let Some(id) = update.get("messageId").and_then(Value::as_str) else { return false };
        session.background_turns.lock().unwrap_or_else(|e| e.into_inner()).owns_message(id)
    }
}

/// [`Hub::hold_adopted_turn`]'s hold: model work goes by the chat's own turn again once it drops.
pub(super) struct AdoptedTurn<'a>(&'a Session);

impl Drop for AdoptedTurn<'_> {
    fn drop(&mut self) {
        self.0.background_turns.lock().unwrap_or_else(|e| e.into_inner()).adopted_turn = false;
    }
}

#[cfg(test)]
#[path = "background_turn_tests.rs"]
mod tests;
