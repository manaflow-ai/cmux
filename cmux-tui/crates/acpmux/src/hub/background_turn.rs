//! Part of `Hub`; see `hub/mod.rs`. A turn the person did not start (Leo, 2026-10-31, about a
//! chat message that said only "Nothing new for you yet.": "why do you guys keep sending me
//! this/get pinged to send this"; then "yeah" to "a turn you didn't start that has nothing new to
//! tell you shouldn't show up as a message or ping you").
//!
//! Claude Code runs turns acpmux never prompted: when a background task or subagent ends (a task
//! notification), on a scheduled wakeup or loop tick, or for a hook. Each runs from its
//! `system/init` to its `result` while no acpmux turn runs (`Session::harness_turn` without
//! `Session::turn`). acpmux records it between two mux `background_turn` records:
//!
//! - `{"state": "started", "id", "trigger"}`, before the turn's own lines; `trigger` is
//!   `task_notification`, `scheduled` or `system` (what came just before its `system/init`);
//! - `{"state": "ended", "id", "trigger", "quiet", "reason"}`, at its `result` (`reason:
//!   "result"`), when a prompt starts an acpmux turn while it runs (`"prompt"`: the rest is that
//!   turn's), or when the agent exits (`"exit"`).
//!
//! Such a turn never pings: it never marks the chat unread, never ends an acpmux turn (so
//! `lastTurn` and the notifications cmux-tui-core posts from it do not move), and its words never
//! become the chat's `preview` / `lastMessage` (the sidebar line and a later notice's body).
//!
//! `quiet` says how the transcript draws it, and is decided here only: a turn whose reply is at
//! most one short line ([`SHORT_LINE`] characters), with no question and no link, is quiet and
//! draws as one muted line that opens on a click. Any other one draws in full, still without a
//! ping. Turns the person started are unchanged.

use super::*;
use std::collections::VecDeque;

/// The mux record that brackets a turn the person did not start.
pub const RECORD_KIND: &str = "background_turn";

/// The longest reply, in characters, that still reads as one short line.
pub const SHORT_LINE: usize = 160;

/// The most reply text kept to decide `quiet`: past it the reply is long anyway.
const TEXT_KEPT: usize = 4 * SHORT_LINE;

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
                out.extend(self.end("result"));
            }
            _ => {}
        }
        out
    }

    /// An own update of the chat (not a subagent's), before it is logged. Returns the
    /// `started` record to log first, when it is the first sign of a pending turn.
    fn on_update(&mut self, update: &Value, acpmux_turn: bool, seq: u64) -> Option<Value> {
        let kind = update.get("sessionUpdate").and_then(Value::as_str).unwrap_or("");
        let mut started = None;
        if acpmux_turn {
            self.pending = None;
        } else if WORK.contains(&kind) && self.running.is_none() {
            // Model work with no acpmux turn is Claude Code's own turn. Its `system/init` may
            // have come before this daemon started (a restart, an adopted host): what started
            // it is then unknown.
            let (trigger, seq) = self.pending.take().unwrap_or(("system", seq));
            let id = format!("bg-{seq}");
            started = Some(json!({"state": "started", "id": id, "trigger": trigger}));
            self.running = Some(Running { id, trigger, text: String::new(), long: false });
        }
        let Some(running) = self.running.as_mut() else { return started };
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
            "quiet": !r.long && is_quiet(&r.text), "reason": reason,
        }))
    }

    /// Whether a reply message is a background turn's.
    fn owns_message(&self, id: &str) -> bool {
        self.messages.iter().any(|m| m == id)
    }
}

impl Hub {
    /// The tap saw a raw Claude line (`claude.*`): logs the background-turn records it starts or
    /// ends, before the line itself.
    pub(super) fn background_turn_line(&self, session: &Session, method: &str, line: &Value) {
        let acpmux_turn = session.turn().is_some();
        let seq = session.meta.lock().unwrap_or_else(|e| e.into_inner()).last_seq + 1;
        let records = session.background_turns.lock().unwrap_or_else(|e| e.into_inner()).on_line(
            method,
            line,
            acpmux_turn,
            seq,
        );
        for msg in records {
            self.append(session, "mux", RECORD_KIND, msg);
        }
    }

    /// The tap saw one of the chat's own updates (not a subagent's).
    pub(super) fn background_turn_update(&self, session: &Session, update: &Value) {
        let acpmux_turn = session.turn().is_some();
        let seq = session.meta.lock().unwrap_or_else(|e| e.into_inner()).last_seq + 1;
        let started = session.background_turns.lock().unwrap_or_else(|e| e.into_inner()).on_update(
            update,
            acpmux_turn,
            seq,
        );
        if let Some(msg) = started {
            self.append(session, "mux", RECORD_KIND, msg);
        }
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
        let Some(id) = update.get("messageId").and_then(Value::as_str) else { return false };
        session.background_turns.lock().unwrap_or_else(|e| e.into_inner()).owns_message(id)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn chunk(id: &str, text: &str) -> Value {
        json!({"sessionUpdate": "agent_message_chunk", "messageId": id,
               "content": {"type": "text", "text": text}})
    }

    #[test]
    fn quiet_is_one_short_line_with_no_question_or_link() {
        assert!(is_quiet("Nothing new for you yet."));
        assert!(is_quiet("  Still waiting on CI.\n"));
        assert!(is_quiet(""));
        assert!(!is_quiet("Should I merge #12?"));
        assert!(!is_quiet("Merged: https://github.com/o/r/pull/1"));
        assert!(!is_quiet("Line one.\nLine two."));
        assert!(!is_quiet(&"a".repeat(SHORT_LINE + 1)));
    }

    #[test]
    fn a_task_notification_turn_is_bracketed_and_quiet() {
        let mut b = BackgroundTurns::default();
        assert!(b.on_line("claude.system.task_notification", &json!({}), false, 1).is_empty());
        assert!(b.on_line("claude.system.init", &json!({}), false, 2).is_empty());
        let started = b.on_update(&chunk("m1", "Nothing new "), false, 0);
        assert_eq!(
            started,
            Some(json!({"state": "started", "id": "bg-2", "trigger": "task_notification"}))
        );
        assert_eq!(b.on_update(&chunk("m1", "for you yet."), false, 0), None);
        assert!(b.owns_message("m1"));
        let ended = b.on_line("claude.result.success", &json!({}), false, 5);
        assert_eq!(
            ended,
            [json!({"state": "ended", "id": "bg-2", "trigger": "task_notification",
                    "quiet": true, "reason": "result"})]
        );
        // The next one, with nothing before it, is the system's; a long reply is not quiet.
        b.on_line("claude.system.init", &json!({}), false, 6);
        b.on_update(&chunk("m2", "Merged #1.\nThe nightly is green."), false, 0);
        let ended = b.on_line("claude.result.success", &json!({}), false, 9);
        assert_eq!(ended[0]["trigger"], "system");
        assert_eq!(ended[0]["quiet"], false);
    }

    #[test]
    fn a_scheduled_wakeup_is_named() {
        let mut b = BackgroundTurns::default();
        b.on_line("claude.command_lifecycle", &json!({"state": "started"}), false, 1);
        b.on_line("claude.system.init", &json!({}), false, 2);
        let started = b.on_update(&json!({"sessionUpdate": "tool_call"}), false, 0).unwrap();
        assert_eq!(started["trigger"], "scheduled");
    }

    #[test]
    fn a_turn_acpmux_started_is_never_a_background_one() {
        let mut b = BackgroundTurns::default();
        b.on_line("claude.system.task_notification", &json!({}), true, 1);
        assert!(b.on_line("claude.system.init", &json!({}), true, 2).is_empty());
        assert_eq!(b.on_update(&chunk("m1", "Done."), true, 0), None);
        assert!(!b.owns_message("m1"));
        assert!(b.on_line("claude.result.success", &json!({}), true, 4).is_empty());
    }

    #[test]
    fn an_init_with_no_work_after_it_is_no_turn() {
        // Claude Code's system/init at its start, before any prompt.
        let mut b = BackgroundTurns::default();
        b.on_line("claude.system.init", &json!({}), false, 1);
        assert_eq!(b.end("prompt"), None);
        assert_eq!(b.on_update(&chunk("m1", "Hi"), true, 0), None);
        assert!(b.on_line("claude.result.success", &json!({}), true, 3).is_empty());
    }

    #[test]
    fn work_with_no_turn_after_a_restart_is_a_background_turn() {
        // The daemon restarted mid-turn: no system/init, but the model works with no acpmux turn.
        let mut b = BackgroundTurns::default();
        let started = b.on_update(&chunk("m1", "Still waiting."), false, 7).unwrap();
        assert_eq!(started["trigger"], "system");
        assert_eq!(started["id"], "bg-7");
        assert!(b.owns_message("m1"));
        let ended = b.on_line("claude.result.success", &json!({}), false, 9);
        assert_eq!(ended[0]["quiet"], true);
    }

    #[test]
    fn a_reply_past_the_kept_text_is_never_quiet() {
        let mut b = BackgroundTurns::default();
        b.on_update(&chunk("m1", &"\u{1F600}".repeat(SHORT_LINE)), false, 1).unwrap();
        b.on_update(&chunk("m1", "Done"), false, 0);
        let ended = b.on_line("claude.result.success", &json!({}), false, 3);
        assert_eq!(ended[0]["quiet"], false);
    }

    #[test]
    fn a_prompt_ends_the_running_one() {
        let mut b = BackgroundTurns::default();
        b.on_line("claude.system.init", &json!({}), false, 1);
        b.on_update(&chunk("m1", "Looking"), false, 0).unwrap();
        let ended = b.end("prompt").unwrap();
        assert_eq!(ended["reason"], "prompt");
        // Its result, now the prompt's turn's, ends nothing more.
        assert!(b.on_line("claude.result.success", &json!({}), true, 3).is_empty());
    }
}
