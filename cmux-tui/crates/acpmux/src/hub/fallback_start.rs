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
            msg["back"] = json!(true);
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

/// The turn's own error `e`, saying that its fallback `to` could not take the turn (`why`) and
/// that the chat stays on `from`.
pub(super) fn fallback_not_started(e: &RpcError, from: &str, to: &str, why: &str) -> RpcError {
    let mut out = e.clone();
    out.message = format!(
        "{} (the fallback profile {to} cannot start: {why}; the chat stays on {from})",
        e.message
    );
    let note = json!({"profile": to, "error": why});
    match out.data.as_mut().and_then(Value::as_object_mut) {
        Some(data) => {
            data.insert("fallback".into(), note);
        }
        None if out.data.is_none() => out.data = Some(json!({"fallback": note})),
        None => {}
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_turn_error_names_the_fallback_that_could_not_start() {
        let e = RpcError::new(-32603, "API Error: 429 rate limit");
        let out = fallback_not_started(&e, "claude", "cmux", "the local CodeRouter is not running");
        assert!(out.message.starts_with("API Error: 429 rate limit"), "{}", out.message);
        assert!(out.message.contains("cmux cannot start"), "{}", out.message);
        assert!(out.message.contains("stays on claude"), "{}", out.message);
        assert_eq!(out.data.unwrap()["fallback"]["profile"], "cmux");
        // Data the error had stays.
        let e = e.with_data(json!({"reason": "limit"}));
        let out = fallback_not_started(&e, "claude", "cmux", "down");
        let data = out.data.unwrap();
        assert_eq!(data["reason"], "limit");
        assert_eq!(data["fallback"]["error"], "down");
    }
}
