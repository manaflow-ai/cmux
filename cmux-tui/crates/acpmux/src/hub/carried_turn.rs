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

use super::subsession_runs::RunSlot;
use super::*;
use std::sync::atomic::Ordering;

/// A steer as it was sent (`steer_end.rs`): what the turn it starts shows, when its agent reads
/// it after the turn it was steered into ended.
#[derive(Debug, Clone)]
pub(super) struct SteerSent {
    pub(super) client: String,
    pub(super) text: String,
    pub(super) control: Control,
    /// What a continuation of the turn it starts needs (`auto_resume.rs`).
    pub(super) continues: Continues,
}

/// What a cut carried turn's continuation needs, as a prompt's own turn has it (`turns.rs`
/// `CutTurn`): the family sender its first steer spoke for, and its trust gate.
#[derive(Debug, Clone, Default)]
pub(super) struct Continues {
    pub(super) from: Option<String>,
    pub(super) trust_gate: bool,
}

/// An answer that ended its turn while the agent runs on with steers it read after.
#[derive(Debug, Clone, PartialEq)]
pub(super) struct Carried {
    /// The agent's count of its carries.
    pub(super) seq: u64,
    /// The steers carried (their prompt ids), oldest first.
    pub(super) prompt_ids: Vec<String>,
}

/// The turn that takes a turn's place as it ends (`Hub::next_carried`).
pub(super) struct NextTurn {
    pub(super) carried: Carried,
    pub(super) next: TurnInfo,
    pub(super) continues: Continues,
}

/// The carries' turns a session keeps for the steers read in them: only the newest can still be
/// read in, but a steer's answer may be handled after a few more turns went by.
const CARRIES_KEPT: usize = 64;

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

impl NextTurn {
    /// The ended turn's `turn_result` names the turn it carried into (`carriedTo`), so a restart
    /// before that turn's `turn_started` still runs it (`Hub::recover_carried`).
    pub(super) fn record(&self) -> Value {
        let t = &self.next;
        json!({
            "turnId": t.turn_id,
            "promptId": t.prompt_id,
            "prompt": t.prompt_preview,
            "client": t.client,
            "control": t.control.as_str(),
            "seq": self.carried.seq,
            "promptIds": self.carried.prompt_ids,
        })
    }

    /// The turn a `turn_result`'s `carriedTo` names ([`NextTurn::record`]).
    pub(super) fn from_record(record: &Value) -> Option<Self> {
        let text = |k: &str| record.get(k).and_then(Value::as_str).map(str::to_owned);
        let ids = record.get("promptIds").and_then(Value::as_array);
        let carried = Carried {
            seq: record.get("seq").and_then(Value::as_u64)?,
            prompt_ids: ids
                .map(|ids| ids.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                .unwrap_or_default(),
        };
        let control = Control::from_recorded(record.get("control").and_then(Value::as_str));
        let (client, prompt) =
            (text("client").unwrap_or_default(), text("prompt").unwrap_or_default());
        let next =
            TurnInfo::prompted(&client, &prompt, &text("turnId")?, &text("promptId")?, control);
        Some(Self { carried, next, continues: Continues::default() })
    }
}

impl Hub {
    /// The turn that takes `turn_id`'s place as it ends, when the agent's `result` carried
    /// steers and `turn_id` is still the session's turn (a detached one carries nothing), boxed.
    pub(super) fn next_carried(
        &self,
        session: &Session,
        turn_id: &str,
        result: &Result<Value, RpcError>,
    ) -> Option<Box<NextTurn>> {
        let carried = carried(result)?;
        let running = session.turn().filter(|t| t.turn_id == turn_id)?;
        if self.shutting_down() {
            return None;
        }
        let (next, continues) = self.carried_turn(session, Some(&running), &carried);
        Some(Box::new(NextTurn { carried, next, continues }))
    }

    /// The turn after `from` (the session's turn still) for what `carried` names: a new turn id,
    /// the first carried steer as its prompt, and a Web turn if any of them, or `from`, was one.
    /// The new turn is named for the carry before `from` ends (`carried_into`).
    pub(super) fn carried_turn(
        &self,
        session: &Session,
        from: Option<&TurnInfo>,
        carried: &Carried,
    ) -> (TurnInfo, Continues) {
        let turn_id = uuid::Uuid::now_v7().to_string();
        let mut now = session.steer_now.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let first = carried.prompt_ids.first();
        let sent = first.and_then(|p| now.sent.get(p)).cloned();
        let web = from.is_some_and(|t| t.control == Control::Web)
            || carried
                .prompt_ids
                .iter()
                .any(|p| now.sent.get(p).is_some_and(|s| s.control == Control::Web));
        now.carries.push_back((carried.seq, turn_id.clone()));
        while now.carries.len() > CARRIES_KEPT {
            now.carries.pop_front();
        }
        if let Some(from) = from {
            now.successors.push_back((from.turn_id.clone(), turn_id.clone()));
            while now.successors.len() > CARRIES_KEPT {
                now.successors.pop_front();
            }
        }
        drop(now);
        let from_control = from.map_or(Control::Local, |t| t.control);
        let control = match &sent {
            _ if web => Control::Web,
            Some(s) => s.control,
            None => from_control,
        };
        let (client, text, continues) = match sent {
            Some(s) => (s.client, s.text, s.continues),
            None => (
                from.map(|t| t.client.clone()).unwrap_or_default(),
                String::new(),
                Continues::default(),
            ),
        };
        let prompt_id = first.cloned().unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
        (TurnInfo::prompted(&client, &text, &turn_id, &prompt_id, control), continues)
    }

    /// After `finish_turn` put `turn` in place of `from`: the turn starts, and its task runs it.
    /// One not in place (its agent was detached meanwhile) never starts.
    pub(super) fn start_carried(
        self: &Arc<Self>,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        from: &str,
        next: &NextTurn,
        slot: Option<RunSlot>,
    ) {
        let mut turn = next.next.clone();
        if session.turn().is_none_or(|t| t.turn_id != turn.turn_id) {
            return;
        }
        turn.turn_seq = self.begin_carried(session, from, &turn, &next.carried);
        let (hub, session, child) = (self.clone(), session.clone(), child.clone());
        let continues = Some(next.continues.clone());
        tokio::spawn(Box::pin(async move {
            hub.run_carried(session, child, turn, continues, slot).await
        }));
    }

    /// A carried turn a restart cut before its prompt went to the agent host, whose Claude Code
    /// runs it still (`hosts.rs` `recover_work`): it goes on, its prompt sent now. With `begin`
    /// (the turn before ended and named it in its `turn_result`, `carriedTo`) it starts first.
    /// The host's adapter answers that prompt at the turn's result, or at once when it owes
    /// none (`carry.rs` `adopt_carried`).
    pub(super) fn recover_carried(
        self: &Arc<Self>,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        mut turn: TurnInfo,
        begin: Option<(String, Carried)>,
    ) {
        {
            let mut running = session.turn.lock().unwrap_or_else(|e| e.into_inner());
            if running.is_some() {
                return;
            }
            *running = Some(turn.clone());
        }
        if let Some((from, carried)) = &begin {
            let mut now =
                session.steer_now.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            now.carries.push_back((carried.seq, turn.turn_id.clone()));
            now.successors.push_back((from.clone(), turn.turn_id.clone()));
            drop(now);
            turn.turn_seq = self.begin_carried(session, from, &turn, carried);
        }
        // As a recovered turn (`hosts.rs` `recover_work`): a Web turn in an agent the sandbox
        // did not start, or in a mode only a machine's Full-access setting allows, does not go on.
        let control = turn.control;
        session.floor.last_turn_web.store(control == Control::Web, Ordering::SeqCst);
        if control == Control::Web && session.floor.unsandboxed.load(Ordering::SeqCst) {
            self.remote_floor_cancel(session, "remote.unsandboxed_agent");
        }
        if self.full_access_hold(&session.meta(), control, None).is_err() {
            self.remote_floor_cancel(session, "remote.full_access_ended");
        }
        self.set_status(session, SessionStatus::Running);
        let (hub, session, child) = (self.clone(), session.clone(), child.clone());
        // A recovered turn is not continued (`auto_resume.rs`).
        tokio::spawn(Box::pin(
            async move { hub.run_carried(session, child, turn, None, None).await },
        ));
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
        // What a cut turn's continuation needs; `None` for a recovered turn, which is not
        // continued (`auto_resume.rs`).
        mut continues: Option<Continues>,
        // The run slot the first turn held (`subsession_runs.rs`): the agent runs until the
        // last of these turns ends.
        slot: Option<RunSlot>,
    ) {
        let guard = session.turn_lock.lock().await;
        loop {
            Self::hold_stalled_count(&session);
            self.set_status(&session, SessionStatus::Running);
            self.watch_silent_turn(&session, &turn.turn_id).await;
            // Debug builds only: `ACPMUX_TEST_CARRY_HOLD_MS` holds a carried turn before its
            // prompt goes out, so a test can restart the daemon there
            // (`tests/durable_agents/carried_restart.rs`). Bounded; release builds have no seam.
            #[cfg(debug_assertions)]
            if let Some(ms) =
                std::env::var("ACPMUX_TEST_CARRY_HOLD_MS").ok().and_then(|v| v.parse::<u64>().ok())
            {
                tokio::time::sleep(std::time::Duration::from_millis(ms.min(60_000))).await;
            }
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
            let next = self.next_carried(&session, &turn.turn_id, &result);
            let (prompt_id, turn_id) = (&turn.prompt_id, &turn.turn_id);
            // As a prompt's own turn (`turns.rs`): what the agent said, and whether a model
            // switch ended the turn already.
            let agent_error = result.as_ref().err().map(|e| e.message.clone());
            let detached = session.turn().is_none_or(|t| &t.turn_id != turn_id);
            let finished = self
                .finish_turn(
                    &session,
                    &child,
                    result,
                    prompt_id,
                    turn_id,
                    turn.turn_seq,
                    None,
                    next.as_deref(),
                )
                .await;
            // A connection error cut the turn off: it goes on by itself (`auto_resume.rs`).
            let cut = match (&finished, &continues) {
                (Err(e), Some(c)) if !detached && next.is_none() => {
                    Some(super::auto_resume::CutTurn {
                        from: c.from.as_deref(),
                        prompt_id,
                        turn_id,
                        control: turn.control,
                        trust_gate: c.trust_gate,
                        error: super::turn_errors::continuation_error(
                            agent_error.as_deref(),
                            &e.message,
                        ),
                    })
                }
                _ => None,
            };
            self.schedule_auto_resume(&session, turn_id, cut);
            let Some(next) = next else { break };
            let NextTurn { carried, next: mut next_turn, continues: next_continues } = *next;
            continues = Some(next_continues);
            if session.turn().is_none_or(|t| t.turn_id != next_turn.turn_id) {
                break;
            }
            next_turn.turn_seq = self.begin_carried(&session, turn_id, &next_turn, &carried);
            turn = next_turn;
        }
        // A route switch asked during these turns moves the chat now (`route_switch.rs`).
        if session.route_switch.load(Ordering::SeqCst) {
            let _ = self.restart_on_route(&session).await;
        }
        // Freed while the turn lock is held, as a turn's guard frees it (`TurnGuard`).
        drop(slot);
        drop(guard);
    }

    /// The session's turn if it is `turn` or a turn carried on from it (`carried_turn`), else
    /// `None`: a Stop that saw `turn` stops what its agent runs now (`cancel.rs`).
    pub(super) fn carried_on(session: &Session, turn: &TurnInfo) -> Option<TurnInfo> {
        session.turn().filter(|current| Self::succeeds(session, &turn.turn_id, &current.turn_id))
    }

    /// Whether turn `to` is turn `from` or a turn carried on from it (`carried_turn`).
    pub(super) fn succeeds(session: &Session, from: &str, to: &str) -> bool {
        let now = session.steer_now.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut id = from;
        // Each step moves to a newer entry, so this ends within the kept entries.
        for _ in 0..=now.successors.len() {
            if id == to {
                return true;
            }
            match now.successors.iter().find(|(f, _)| f == id) {
                Some((_, next)) => id = next,
                None => return false,
            }
        }
        false
    }

    /// The turn a steer read in carry `seq`'s turn went into, once the turn before named it
    /// (`carried_turn`): `None` past [`CARRIED_WAIT`].
    pub(super) async fn carried_into(session: &Session, seq: u64) -> Option<String> {
        let deadline = tokio::time::Instant::now() + CARRIED_WAIT;
        loop {
            // Notified by `finish_turn` as it puts the next turn in place, after it was named.
            let moved = session.queue_moved.notified();
            tokio::pin!(moved);
            moved.as_mut().enable();
            let into = {
                let now =
                    session.steer_now.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                now.carries.iter().rev().find(|(s, _)| *s == seq).map(|(_, t)| t.clone())
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

    /// A Stop captures the turn, then waits for the writer: if that turn carried on meanwhile,
    /// the Stop is for the turn its agent runs now, never for one that started on its own.
    #[tokio::test]
    async fn a_stop_that_saw_the_turn_before_a_carry_stops_the_carried_turn() {
        use crate::config::{Config, StoreMode};
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let cfg =
            json!({"harnesses": {"fake": {"argv": ["python3", fake]}}, "defaultHarness": "fake"});
        let mut cfg: Config = serde_json::from_value(cfg).unwrap();
        cfg.store.mode = StoreMode::Memory;
        let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
        let hub = Hub::new(cfg, store);
        let req = NewRequest { cwd: Some(std::env::temp_dir()), ..NewRequest::default() };
        let s = hub.new_session(req).await.unwrap();
        let set = |t: Option<TurnInfo>| *s.turn.lock().unwrap_or_else(|e| e.into_inner()) = t;
        let one = TurnInfo::prompted("test", "work", "t-1", "p-1", Control::Local);
        set(Some(one.clone()));
        let on = |t: &TurnInfo| Hub::carried_on(&s, t).map(|t| t.turn_id);
        assert_eq!(on(&one).as_deref(), Some("t-1"));
        let two = hub.carried_turn(&s, Some(&one), &Carried { seq: 1, prompt_ids: vec![] }).0;
        set(Some(two.clone()));
        let three = hub.carried_turn(&s, Some(&two), &Carried { seq: 2, prompt_ids: vec![] }).0;
        set(Some(three.clone()));
        assert_eq!(on(&one), Some(three.turn_id.clone()), "carried on twice");
        assert_eq!(on(&two), Some(three.turn_id.clone()));
        // A queued prompt's turn started on its own: not the work that Stop saw.
        set(Some(TurnInfo::prompted("test", "next", "t-queued", "p-q", Control::Local)));
        assert_eq!(on(&one), None);
        set(None);
        assert_eq!(on(&one), None);
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
