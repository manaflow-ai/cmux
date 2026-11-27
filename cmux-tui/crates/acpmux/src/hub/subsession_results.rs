//! What a sub-session's parent chat reads of it (`subsessions.rs`), whichever way it was started:
//! the `start_session` tool, or `acpmux new|run --parent` from a shell, where the child may be of
//! another harness family than its parent (a Claude chat's Codex child, say).
//!
//! Both are `mux` records of kind `subsession` (`RECORD_KIND`) on the parent's log, the same
//! record the parent already gets when a child closes or reopens; there is no other event family:
//!
//! - `{event: "started", childSessionId, shortName, startedBy, depth, harness, model, effort,
//!   title, prompt, state: "running"}` once the child's first prompt is accepted. `model` and
//!   `effort` are the child's current ones, else what the start asked for, else null.
//! - `{event: "turn_ended", childSessionId, shortName, startedBy, depth, harness, model, effort,
//!   title, state, result}` at the end of each of the child's turns, written where the turn's
//!   end is recorded (`Hub::record_last_turn`, every path: a finished, failed, unstarted, quit or
//!   unknown turn), so once per turn and in turn order. `state` is `done` (it completed),
//!   `failed` or `cancelled`; `result` is `{state, turnId, stopReason, reply, error}`: `reply` is
//!   the turn's agent text (its last 2000 bytes, from memory: no log read on the turn's path),
//!   null when it said nothing, and `error` the failed turn's message.
//!
//! Each record's text (title, prompt, reply, error) is masked (`secret_scan`): the parent's log
//! is read by another chat's agent and by its clients. Nothing here prompts the parent: its agent
//! reads a child with `get_session` or `wait_for_sessions`, or `acpmux run --parent` prints the
//! reply in its shell.

use super::subsessions::RECORD_KIND;
use super::*;
use cmux_json::JsonSet as _;

/// Longest prompt a `started` record quotes, in characters.
const MAX_PROMPT_CHARS: usize = 500;
/// The most of a turn's agent text the session keeps (`hub/permissions.rs`, `preview`).
const PREVIEW_BYTES: usize = 2000;

/// A turn's end `status` (`turn_result`) as a sub-session's state.
fn end_state(status: Option<&str>) -> &'static str {
    match status {
        Some("completed") => "done",
        Some("cancelled") => "cancelled",
        _ => "failed",
    }
}

impl Hub {
    /// The fields every `subsession` record of `child` carries: its link to the parent, its
    /// harness, model, effort and title. `asked` is the model and effort the start asked for.
    fn subsession_fields(m: &SessionMeta, asked: (Option<&str>, Option<&str>)) -> Value {
        let link = m.subsession.as_ref();
        let effort = super::model_options::current_effort(m).or_else(|| {
            let id = super::model_options::resolve_config_id(m, "effort");
            super::model_options::current_option(m, &id)
        });
        let title = m.title.as_deref().unwrap_or(&m.name);
        json!({
            "childSessionId": m.id,
            "shortName": link.map(|l| &l.short_name),
            "startedBy": link.map(|l| &l.started_by),
            "depth": link.map_or(0, |l| l.depth),
            "harness": m.harness,
            "model": super::model_options::current_model(m).or(asked.0.map(str::to_owned)),
            "effort": effort.or(asked.1.map(str::to_owned)),
            "title": crate::secret_scan::mask(title),
        })
    }

    /// Tells `parent` that `child` started on `prompt`: when its first prompt is accepted.
    pub(super) fn subsession_started(
        &self,
        parent: &Session,
        child: &Session,
        prompt: &str,
        asked: (Option<String>, Option<String>),
    ) {
        let asked = (asked.0.as_deref(), asked.1.as_deref());
        let mut record = Self::subsession_fields(&child.meta(), asked);
        record.set("event", json!("started"));
        record.set("state", json!("running"));
        record.set("prompt", json!(super::session::masked_preview(prompt, MAX_PROMPT_CHARS)));
        self.append(parent, "mux", RECORD_KIND, record);
    }

    /// Tells `child`'s parent how the turn that just ended (`turn_result`, its record) went,
    /// with its typed result. Nothing for a session that is no sub-session, or whose parent is
    /// gone.
    pub(super) fn subsession_turn_ended(&self, child: &Session, turn_result: &Value) {
        // Every session's turn passes here: only a sub-session's copies its meta.
        let link = child.meta.lock().unwrap_or_else(|e| e.into_inner()).subsession.clone();
        let Some(link) = link else { return };
        let Ok(parent) = self.resolve(&link.started_by) else { return };
        let m = child.meta();
        let text = |key: &str| turn_result.get(key).and_then(Value::as_str);
        let state = end_state(text("status"));
        let error = text("errorText").or_else(|| text("error")).map(crate::secret_scan::mask);
        let mut record = Self::subsession_fields(&m, (None, None));
        record.set("event", json!("turn_ended"));
        record.set("state", json!(state));
        record.set(
            "result",
            json!({
                "state": state,
                "turnId": turn_result.get("turnId"),
                "stopReason": turn_result.get("stopReason"),
                "reply": m.preview.as_deref().and_then(reply_text),
                "error": error,
            }),
        );
        self.append(&parent, "mux", RECORD_KIND, record);
    }
}

/// A turn's agent text (`SessionMeta::preview`) as a result's reply: masked, null when the turn
/// said nothing. A preview the session cut to its last [`PREVIEW_BYTES`] keeps 1997 to 2000 of
/// them (the cut moves to a character boundary), so one that long may start inside a word, maybe
/// a secret whose cut head the scanner would not know: that word goes, and the reply starts with
/// `…`. One cut word and nothing else is only `…`. A preview of that length that was not cut
/// loses its first word too, which costs a word and hides nothing.
fn reply_text(preview: &str) -> Option<String> {
    let text = preview.trim();
    if text.is_empty() {
        return None;
    }
    if preview.len() + 3 < PREVIEW_BYTES {
        return Some(crate::secret_scan::mask(text));
    }
    let rest = text.split_once(char::is_whitespace).map_or("", |(_, rest)| rest.trim_start());
    Some(format!("…{}", crate::secret_scan::mask(rest)))
}

#[cfg(test)]
mod tests {
    use super::{PREVIEW_BYTES, end_state, reply_text};

    #[test]
    fn a_reply_is_the_turns_text_without_a_cut_head() {
        assert_eq!(reply_text("  done.  "), Some("done.".to_owned()));
        assert_eq!(reply_text(" "), None);
        // A cut preview (1997 to 2000 bytes) loses its first, maybe cut, word.
        let cut = format!("tail-of-a-cut-word {}", "x".repeat(PREVIEW_BYTES - 22));
        assert_eq!(cut.len(), PREVIEW_BYTES - 3);
        let reply = reply_text(&cut).unwrap();
        assert!(reply.starts_with("…x") && !reply.contains("tail-of"), "{reply}");
        // One cut word: only that something was said.
        assert_eq!(reply_text(&"é".repeat(PREVIEW_BYTES / 2)).as_deref(), Some("…"));
        // Below the cut: whole.
        let short = format!("a {}", "é".repeat(900));
        assert_eq!(reply_text(&short).as_deref(), Some(short.as_str()));
    }

    #[test]
    fn a_turn_end_is_done_failed_or_cancelled() {
        assert_eq!(end_state(Some("completed")), "done");
        assert_eq!(end_state(Some("cancelled")), "cancelled");
        assert_eq!(end_state(Some("failed")), "failed");
        assert_eq!(end_state(None), "failed");
    }
}
