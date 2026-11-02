//! Part of `Hub`; see `hub/mod.rs`. A failover (`turns.rs`) only moves a chat onto a fallback
//! profile that can start, and never leaves it on one that cannot.
//!
//! The `cmux` profile, which `claude` falls back to when it names no fallback of its own, runs
//! through the local CodeRouter. On a machine where the router is not running, a failover onto
//! it moved the chat for good: every later turn failed in its first second with "the local
//! CodeRouter is not running", while the chat looked idle. So:
//!
//! - a fallback whose route cannot start now (`route_refusal`) is skipped, and the turn's error
//!   says so;
//! - a fallback that moved the chat and then could not start moves it back at once;
//! - a chat a failover left on a profile whose route cannot start goes back to the profile it
//!   came from at its next turn (`back_from_fallback`), also one an older build moved: the
//!   `failover` record in its log names that profile.
//!
//! A chat whose fallback works stays on it: going back while the fallback works would send every
//! turn to an account that just hit its limit first, and a move between profiles with their own
//! Claude stores starts a fresh conversation from the transcript each time.

use super::*;
use cmux_json::JsonSet as _;

impl Hub {
    /// Why a spawn of profile `harness` for this chat could not start on its route now (the
    /// route is gone, serves another family, or is a local router that is down), else `None`:
    /// the check `apply_route` makes at a spawn, with nothing recorded.
    pub(super) async fn route_refusal(
        &self,
        meta: &SessionMeta,
        harness: &str,
    ) -> Option<RpcError> {
        let profile = self.config.read().await.harnesses.get(harness).cloned()?;
        let workspace = meta.session_env.get("CMUX_WORKSPACE_ID").map(String::as_str);
        let mut env = profile.env.clone();
        self.apply_route_for(harness, Some(&meta.id), workspace, true, &profile, &mut env)
            .await
            .err()
    }

    /// Move the chat onto profile `to` after a failover (`back`: back to the profile it came
    /// from), logged as one. The last harness's /context breakdown and usage limits are not the
    /// new one's.
    pub(super) fn move_profile(
        &self,
        session: &Session,
        to: &str,
        reason: &str,
        turn_id: &str,
        back: bool,
    ) {
        let from = session.meta().harness;
        let mut msg = json!({"from": from, "to": to, "reason": reason, "turnId": turn_id});
        if back {
            msg.set("back", json!(true));
        }
        self.append(session, "mux", "failover", msg);
        {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            m.harness = to.to_owned();
            m.context_breakdown = None;
            m.usage_limits = None;
        }
        self.save_meta(session);
    }

    /// A chat whose agent could not start (`e`) because its profile's route cannot start, and
    /// that a failover put on that profile, goes back to the profile it came from when that one
    /// can start. True when it moved: its start is tried again.
    pub(super) async fn back_from_fallback(
        &self,
        session: &Session,
        e: &RpcError,
        turn_id: &str,
    ) -> bool {
        let meta = session.meta();
        let current = meta.harness.clone();
        // Only a profile some other profile falls back to can be a failover's target.
        let target = self
            .config
            .read()
            .await
            .harnesses
            .values()
            .any(|p| p.fallback.as_deref() == Some(current.as_str()));
        if !target || self.route_refusal(&meta, &current).await.is_none() {
            return false;
        }
        let Some(from) = self.failed_over_from(&session.id, &current) else { return false };
        if from == current
            || !self.config.read().await.harnesses.contains_key(&from)
            || self.route_refusal(&meta, &from).await.is_some()
        {
            return false;
        }
        tracing::info!(session = %session.id, from = %current, to = %from, "the fallback cannot start: back to the profile the failover came from");
        self.move_profile(session, &from, &e.message, turn_id, true);
        true
    }

    /// The profile the newest failover in the log moved the chat from, when it moved it onto
    /// `current` (one that moved it back, or elsewhere, names none).
    fn failed_over_from(&self, id: &str, current: &str) -> Option<String> {
        let mut from = None;
        let skip = |dir: &[u8], kind: &[u8]| dir != b"mux" || kind != b"failover";
        let _ = self.store.scan_back(id, 0, u64::MAX, &skip, &mut |rec| {
            if rec.kind != "failover" {
                return true;
            }
            let back = rec.msg.get("back").and_then(Value::as_bool).unwrap_or(false);
            if !back && rec.msg.get("to").and_then(Value::as_str) == Some(current) {
                from = rec.msg.get("from").and_then(Value::as_str).map(str::to_owned);
            }
            false
        });
        from
    }
}

/// Which conversation the chat's agent resumes, as it was before a failover's fallback started:
/// a fallback on another Claude store drops the id and marks the chat to get its transcript
/// (`lifecycle.rs` `cold_start`) before its process starts, so a start that then fails would
/// leave the chat's own profile to begin a fresh conversation.
pub(super) struct ConversationMark {
    agent_session_id: Option<String>,
    agent_session_family: Option<String>,
    previous_agent_session_ids: Vec<String>,
    retired_agent_session_ids: Vec<String>,
    claude_unstored: bool,
    claude_profile: Option<String>,
    rehydrate: bool,
}

impl ConversationMark {
    pub(super) fn of(session: &Session) -> Self {
        let m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
        Self {
            agent_session_id: m.agent_session_id.clone(),
            agent_session_family: m.agent_session_family.clone(),
            previous_agent_session_ids: m.previous_agent_session_ids.clone(),
            retired_agent_session_ids: m.retired_agent_session_ids.clone(),
            claude_unstored: m.claude_unstored,
            claude_profile: m.claude_profile.clone(),
            rehydrate: session.rehydrate.load(std::sync::atomic::Ordering::SeqCst),
        }
    }

    /// Put it back (`Hub::move_profile` saves it with the move).
    pub(super) fn restore(self, session: &Session) {
        {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            m.agent_session_id = self.agent_session_id;
            m.agent_session_family = self.agent_session_family;
            m.previous_agent_session_ids = self.previous_agent_session_ids;
            m.retired_agent_session_ids = self.retired_agent_session_ids;
            m.claude_unstored = self.claude_unstored;
            m.claude_profile = self.claude_profile;
        }
        session.rehydrate.store(self.rehydrate, std::sync::atomic::Ordering::SeqCst);
    }
}

/// The key of the note in a turn error's data: a bound route's failure already puts its own
/// `fallback` there (`route_switch.rs` `route_failure`).
const NOTE_KEY: &str = "fallbackProfile";

/// The turn's own error `e`, marked (`data.fallbackProfile`) with the fallback `to` that could not take
/// the turn (`why`) and the profile `from` the chat stays on. Its message stays the agent's own
/// until the turn ends: `finish_turn` reads it as it was (a dead process's stderr line, a limit,
/// a sign-in), then [`say_fallback`] adds the note.
pub(super) fn fallback_not_started(e: &RpcError, from: &str, to: &str, why: &str) -> RpcError {
    let mut out = e.clone();
    let note = json!({"profile": to, "error": why, "stays": from});
    match &mut out.data {
        Some(Value::Object(data)) => {
            data.insert(NOTE_KEY.into(), note);
        }
        None => out.data = Some(Value::Object([(NOTE_KEY.to_owned(), note)].into_iter().collect())),
        // Data that is no object stays as it was, without the note.
        Some(_) => {}
    }
    out
}

/// A turn's error that [`fallback_not_started`] marked says, after its own reason, that the
/// fallback could not take the turn, and why.
pub(super) fn say_fallback(e: &mut RpcError) {
    let Some(note) = e.data.as_ref().and_then(|d| d.get(NOTE_KEY)) else { return };
    let text = |k: &str| note.get(k).and_then(Value::as_str).unwrap_or("?").to_owned();
    let (to, why, from) = (text("profile"), text("error"), text("stays"));
    e.message = format!(
        "{} (the fallback profile {to} cannot start: {why}; the chat stays on {from})",
        e.message
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_turn_error_names_the_fallback_that_could_not_start() {
        let e = RpcError::new(-32603, "agent process closed");
        let mut out =
            fallback_not_started(&e, "claude", "cmux", "the local CodeRouter is not running");
        // The message stays the agent's own until the turn ends, so it still reads as a dead
        // process (`recovery::dead_process`), whose stderr line `finish_turn` adds.
        assert_eq!(out.message, "agent process closed");
        assert!(crate::recovery::dead_process(&out));
        assert_eq!(out.data.as_ref().unwrap()[NOTE_KEY]["profile"], "cmux");
        say_fallback(&mut out);
        assert!(out.message.starts_with("agent process closed"), "{}", out.message);
        assert!(out.message.contains("cmux cannot start"), "{}", out.message);
        assert!(out.message.contains("CodeRouter is not running"), "{}", out.message);
        assert!(out.message.contains("stays on claude"), "{}", out.message);
        // Data the error had stays.
        let e = e.with_data(json!({"reason": "limit"}));
        let out = fallback_not_started(&e, "claude", "cmux", "down");
        let data = out.data.unwrap();
        assert_eq!(data["reason"], "limit");
        assert_eq!(data[NOTE_KEY]["error"], "down");
        // An error no fallback marked keeps its message.
        let mut plain = RpcError::new(-32603, "agent process closed");
        say_fallback(&mut plain);
        assert_eq!(plain.message, "agent process closed");
    }
}
