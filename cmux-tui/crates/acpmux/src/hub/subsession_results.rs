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
//!   title, state, result}` at the end of each of the child's turns. `state` is `done` (it
//!   completed), `failed` or `cancelled`; `result` is `{state, turnId, stopReason, reply, error}`:
//!   `reply` is the child's last agent message of the turn (masked, at most 4000 characters, null
//!   when it said nothing) and `error` the failed turn's message (masked).
//!
//! Each record's text is masked (`secret_scan`): the parent's log is read by another chat's agent
//! and by its clients. Nothing here prompts the parent: its agent reads a child with
//! `get_session` or `wait_for_sessions`, or `acpmux run --parent` prints the reply in its shell.

use super::subsessions::RECORD_KIND;
use super::*;

/// Longest prompt a `started` record quotes, in characters.
const MAX_PROMPT_CHARS: usize = 500;

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
        let title = m.title.as_deref().map(crate::secret_scan::mask);
        json!({
            "childSessionId": m.id,
            "shortName": link.map(|l| &l.short_name),
            "startedBy": link.map(|l| &l.started_by),
            "depth": link.map_or(0, |l| l.depth),
            "harness": m.harness,
            "model": super::model_options::current_model(m).or(asked.0.map(str::to_owned)),
            "effort": effort.or(asked.1.map(str::to_owned)),
            "title": title.unwrap_or_else(|| m.name.clone()),
        })
    }

    /// Tells `parent` that `child` started on `prompt`.
    pub(super) fn subsession_started(
        &self,
        parent: &Session,
        child: &Session,
        prompt: &str,
        asked: (Option<&str>, Option<&str>),
    ) {
        let mut record = Self::subsession_fields(&child.meta(), asked);
        record["event"] = json!("started");
        record["state"] = json!("running");
        record["prompt"] = json!(super::session::masked_preview(prompt, MAX_PROMPT_CHARS));
        self.append(parent, "mux", RECORD_KIND, record);
    }

    /// Tells `child`'s parent how its turn that just ended went, with its typed result. Nothing
    /// for a session that is no sub-session, or whose parent is gone. Off the turn's path: the
    /// reply is read from the child's log.
    pub(super) fn subsession_turn_ended(self: &Arc<Self>, child: &Arc<Session>) {
        let m = child.meta();
        let (Some(link), Some(last)) = (m.subsession.clone(), m.last_turn.clone()) else {
            return;
        };
        let Ok(parent) = self.resolve(&link.started_by) else { return };
        let (hub, child) = (self.clone(), child.clone());
        tokio::spawn(async move {
            let state = end_state(last.get("status").and_then(Value::as_str));
            let error = last.get("errorText").and_then(Value::as_str).map(crate::secret_scan::mask);
            let mut record = Self::subsession_fields(&child.meta(), (None, None));
            record["event"] = json!("turn_ended");
            record["state"] = json!(state);
            record["result"] = json!({
                "state": state,
                "turnId": last.get("turnId"),
                "stopReason": last.get("stopReason"),
                "reply": hub.last_reply(&child),
                "error": error,
            });
            hub.append(&parent, "mux", RECORD_KIND, record);
        });
    }
}

#[cfg(test)]
mod tests {
    use super::end_state;

    #[test]
    fn a_turn_end_is_done_failed_or_cancelled() {
        assert_eq!(end_state(Some("completed")), "done");
        assert_eq!(end_state(Some("cancelled")), "cancelled");
        assert_eq!(end_state(Some("failed")), "failed");
        assert_eq!(end_state(None), "failed");
    }
}
