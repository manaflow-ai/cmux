//! Part of `Hub`; see `hub/mod.rs`. A turn ends when its agent ends it (Leo, 2026-10-29: "why
//! the fuck are you still depicted as thinking for 11 hours? This feels like we're not reading
//! the data correctly. Because you're, like, you clearly just ended some fucking turns, and it
//! still fucking shows this.").
//!
//! Claude Code runs a steer it had not read when its turn ended as a turn of its own. Its
//! adapter now answers the turn's prompt at that end, marked `_meta.claude.carried: {seq,
//! promptIds}` (claude_stdio `carry.rs`): the turn ends there, and the next one starts at once,
//! with its own turnId and startedAt, for the turn Claude Code runs now. Its prompt is the first
//! steer it carried, its `turn_started` names them all (`carried`), and its task holds the turn
//! lock like any turn's: queued prompts wait for it, steers go into it. Its `session/prompt`
//! (`_meta.carried: true`) writes nothing; the adapter answers it at that turn's result, which
//! may carry again. A steer read after the carry names the turn it went into (`turnId` in its
//! answer), so a send that waits answers with that turn's reply (`cli/steer_reply.rs`).
//!
//! Only Claude's adapter carries: codex-acp folds a steer into the running turn
//! (`steer_end.rs`), unchanged.

use super::*;
use std::sync::atomic::Ordering;

/// A steer as it was sent (`steer_end.rs`): what the turn it starts shows, when its agent reads
/// it after the turn it was steered into ended.
#[derive(Debug, Clone)]
pub(super) struct SteerSent {
    pub(super) client: String,
    pub(super) text: String,
    pub(super) control: Control,
}

/// An answer that ended its turn while the agent runs on with steers it read after.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Carried {
    /// The agent's count of its carries.
    pub(super) seq: u64,
    /// The steers carried (their prompt ids), oldest first.
    pub(super) prompt_ids: Vec<String>,
}

/// How long a steer read after a carry waits for its turn to be named: the turn that carried
/// it names the next one before it ends, so this is only a bound.
const CARRIED_WAIT: std::time::Duration = std::time::Duration::from_secs(10);

/// The carry an agent's answer reports (`_meta.claude.carried`), if any. A failed turn carries
/// nothing.
pub(super) fn carried(result: &Result<Value, RpcError>) -> Option<Carried> {
    let carried = result.as_ref().ok()?.pointer("/_meta/claude/carried")?;
    let seq = carried.get("seq").and_then(Value::as_u64)?;
    let ids = carried.get("promptIds").and_then(Value::as_array);
    let prompt_ids = ids
        .map(|ids| ids.iter().filter_map(Value::as_str).map(str::to_owned).collect())
        .unwrap_or_default();
    Some(Carried { seq, prompt_ids })
}

/// The carry a steer's `steered` answer names: it was read after the turn it was steered into
/// ended.
pub(super) fn steer_carry(answer: &Result<Value, RpcError>) -> Option<u64> {
    answer.as_ref().ok()?.pointer("/_meta/claude/carried").and_then(Value::as_u64)
}

impl Hub {
    /// The turn after `from` (the session's turn still) for what `carried` names: a new turn id,
    /// the first carried steer as its prompt, and a Web turn if any of them, or `from`, was one.
    /// Each carried steer is named as in it now, before `from` ends (`carried_into`).
    pub(super) fn carried_turn(
        &self,
        session: &Session,
        from: Option<&TurnInfo>,
        carried: &Carried,
    ) -> TurnInfo {
        let turn_id = uuid::Uuid::now_v7().to_string();
        let mut now = session.steer_now.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let first = carried.prompt_ids.first();
        let sent = first.and_then(|p| now.sent.get(p)).cloned();
        let web = from.is_some_and(|t| t.control == Control::Web)
            || carried
                .prompt_ids
                .iter()
                .any(|p| now.sent.get(p).is_some_and(|s| s.control == Control::Web));
        for p in &carried.prompt_ids {
            now.carried.insert(p.clone(), (turn_id.clone(), carried.seq));
        }
        drop(now);
        let from_control = from.map_or(Control::Local, |t| t.control);
        let control = match &sent {
            _ if web => Control::Web,
            Some(s) => s.control,
            None => from_control,
        };
        let (client, text) = match sent {
            Some(s) => (s.client, s.text),
            None => (from.map(|t| t.client.clone()).unwrap_or_default(), String::new()),
        };
        let prompt_id = first.cloned().unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
        TurnInfo::prompted(&client, &text, &turn_id, &prompt_id, control)
    }

    /// After `finish_turn` put `turn` in place of `from`: the turn starts, and its task runs it.
    /// One not in place (its agent was detached meanwhile) never starts.
    pub(super) fn start_carried(
        self: &Arc<Self>,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        from: &str,
        mut turn: TurnInfo,
        carried: &Carried,
    ) {
        if session.turn().is_none_or(|t| t.turn_id != turn.turn_id) {
            return;
        }
        turn.turn_seq = self.begin_carried(session, from, &turn, carried);
        let (hub, session, child) = (self.clone(), session.clone(), child.clone());
        tokio::spawn(async move { hub.run_carried(session, child, turn).await });
    }

    /// The carried turn's start: counted, and logged as `turn_started` after `from`'s end.
    fn begin_carried(&self, session: &Session, from: &str, turn: &TurnInfo, c: &Carried) -> u64 {
        {
            let mut m = session.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            m.turn_count += 1;
            m.preview = Some(String::new());
        }
        if turn.control == Control::Web {
            session.floor.last_turn_web.store(true, Ordering::SeqCst);
        }
        let msg = json!({
            "prompt": turn.prompt_preview,
            "client": turn.client,
            "promptId": turn.prompt_id,
            "turnId": turn.turn_id,
            "control": turn.control.as_str(),
            "trustGate": false,
            "carried": {"fromTurnId": from, "promptIds": c.prompt_ids},
        });
        let seq = self.append(session, "mux", "turn_started", msg).seq;
        let mut running = session.turn.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(t) = running.as_mut().filter(|t| t.turn_id == turn.turn_id) {
            t.turn_seq = seq;
        }
        seq
    }

    /// Runs carried turns until one ends with nothing carried: each holds the turn lock (its
    /// queue waited since `finish_turn` put it in place), and its prompt waits for the turn
    /// Claude Code runs now.
    async fn run_carried(
        self: Arc<Self>,
        session: Arc<Session>,
        child: Arc<ChildAgent>,
        mut turn: TurnInfo,
    ) {
        let guard = session.turn_lock.lock().await;
        loop {
            Self::hold_stalled_count(&session);
            self.set_status(&session, SessionStatus::Running);
            self.watch_silent_turn(&session, &turn.turn_id).await;
            let result = match session.meta().agent_session_id {
                Some(sid) => {
                    let params =
                        json!({"sessionId": sid, "prompt": [], "_meta": {"carried": true}});
                    let on_sent = || self.watch_stalled_turn(&session, None);
                    let id = &turn.turn_id;
                    super::steer_end::agent_prompt_hook(
                        &session, &child, params, id, false, None, false, on_sent,
                    )
                    .await
                }
                None => Err(RpcError::internal("no agent session")),
            };
            let next = carried(&result).filter(|_| !self.shutting_down()).map(|c| {
                let next = self.carried_turn(&session, session.turn().as_ref(), &c);
                (c, next)
            });
            let in_place = next.as_ref().map(|(_, t)| t.clone());
            let (prompt_id, turn_id) = (&turn.prompt_id, &turn.turn_id);
            let _ = self
                .finish_turn(
                    &session,
                    &child,
                    result,
                    prompt_id,
                    turn_id,
                    turn.turn_seq,
                    None,
                    in_place,
                )
                .await;
            self.schedule_auto_resume(&session, turn_id, None);
            let Some((c, mut next)) = next else { break };
            if session.turn().is_none_or(|t| t.turn_id != next.turn_id) {
                break;
            }
            next.turn_seq = self.begin_carried(&session, turn_id, &next, &c);
            turn = next;
        }
        // A route switch asked during these turns moves the chat now (`route_switch.rs`).
        if session.route_switch.load(Ordering::SeqCst) {
            let _ = self.restart_on_route(&session).await;
        }
        drop(guard);
    }

    /// The turn a steer read after carry `seq` went into, once the turn that carried it named it
    /// (`carried_turn`): `None` past [`CARRIED_WAIT`].
    pub(super) async fn carried_into(
        session: &Session,
        prompt_id: &str,
        seq: u64,
    ) -> Option<String> {
        let deadline = tokio::time::Instant::now() + CARRIED_WAIT;
        loop {
            // Notified by `finish_turn` as it puts the next turn in place, after it was named.
            let moved = session.queue_moved.notified();
            tokio::pin!(moved);
            moved.as_mut().enable();
            let into = {
                let now =
                    session.steer_now.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                now.carried.get(prompt_id).filter(|(_, s)| *s >= seq).map(|(t, _)| t.clone())
            };
            if into.is_some() {
                return into;
            }
            if tokio::time::timeout_at(deadline, moved).await.is_err() {
                return None;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_an_answer_that_carried_starts_a_turn() {
        let carried_answer = Ok(json!({
            "stopReason": "end_turn",
            "_meta": {"claude": {"subtype": "success", "carried": {"seq": 2, "promptIds": ["p-a", "p-b"]}}},
        }));
        let want = Carried { seq: 2, prompt_ids: vec!["p-a".into(), "p-b".into()] };
        assert_eq!(carried(&carried_answer), Some(want));
        // Claude's turn that ended with nothing unread, and codex-acp's answers, carry nothing.
        let plain =
            Ok(json!({"stopReason": "end_turn", "_meta": {"claude": {"subtype": "success"}}}));
        assert_eq!(carried(&plain), None);
        assert_eq!(carried(&Ok(json!({"stopReason": "end_turn"}))), None);
        assert_eq!(carried(&Err(RpcError::internal("agent process closed"))), None);
    }

    #[test]
    fn a_steer_read_after_a_carry_names_it() {
        let read_after = Ok(json!({"stopReason": "steered", "_meta": {"claude": {"carried": 3}}}));
        assert_eq!(steer_carry(&read_after), Some(3));
        assert_eq!(steer_carry(&Ok(json!({"stopReason": "steered"}))), None);
        // codex-acp answers a steer with the turn's end.
        assert_eq!(steer_carry(&Ok(json!({"stopReason": "end_turn"}))), None);
    }
}
