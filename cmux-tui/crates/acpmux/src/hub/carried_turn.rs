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
    /// The line it leaves on the summary as the turn it starts (`prompt_line.rs`).
    pub(super) line: String,
    pub(super) control: Control,
    /// What a continuation of the turn it starts needs (`auto_resume.rs`).
    pub(super) continues: Continues,
}

/// What a cut carried turn's continuation needs, as a prompt's own turn has it (`turns.rs`
/// `CutTurn`): the family sender its first steer spoke for, and its trust gate. And whether it
/// runs on lane reports only, as a prompt's turn may (`lane_reports.rs`): then it reports nothing.
#[derive(Debug, Clone, Default)]
pub(super) struct Continues {
    pub(super) from: Option<String>,
    pub(super) trust_gate: bool,
    /// A steer's: it is a lane report. A carried turn's: every steer it carried is one.
    pub(super) reports: bool,
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

/// The carried turns' successions kept with no steer waiting (`trim_successors`), for a Stop
/// that saw a turn a few carries back.
const SUCCESSORS_KEPT: usize = 64;

/// The most kept while steers wait: each carry reads at least one of them, so this bounds only
/// a chat sent more steers in one turn than this.
const SUCCESSORS_MAX: usize = 100_000;

/// Drops the successions no waiting steer can name.
pub(super) fn trim_successors(successors: &mut std::collections::VecDeque<(String, String)>) {
    while successors.len() > SUCCESSORS_KEPT {
        successors.pop_front();
    }
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
    /// `control` is the turn's as it is now: a Web steer may have raised it (`check_steer`).
    pub(super) fn record(&self, control: Control) -> Value {
        let t = &self.next;
        json!({
            "turnId": t.turn_id,
            "promptId": t.prompt_id,
            "prompt": t.prompt_preview,
            "promptLine": t.masked_preview,
            "client": t.client,
            "control": control.as_str(),
            "trustGate": self.continues.trust_gate,
            "reportsOnly": self.continues.reports,
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
        let mut next =
            TurnInfo::prompted(&client, &prompt, &text("turnId")?, &text("promptId")?, control);
        // Its line as the turn showed it (`prompt_line.rs`); an older record has none.
        if let Some(line) = text("promptLine") {
            next.show(&line);
        }
        let flag = |k: &str| record.get(k).and_then(Value::as_bool).unwrap_or(false);
        let continues =
            Continues { from: None, trust_gate: flag("trustGate"), reports: flag("reportsOnly") };
        Some(Self { carried, next, continues })
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
        // Also while the daemon stops: the turn's end names the next one, which the next daemon
        // runs on (`recover_carried`).
        let running = session.turn().filter(|t| t.turn_id == turn_id)?;
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
        // On lane reports only when every steer it carried is one.
        let reports = !carried.prompt_ids.is_empty()
            && carried
                .prompt_ids
                .iter()
                .all(|p| now.sent.get(p).is_some_and(|s| s.continues.reports));
        now.carries.push_back((carried.seq, turn_id.clone()));
        while now.carries.len() > CARRIES_KEPT {
            now.carries.pop_front();
        }
        if let Some(from) = from {
            now.successors.push_back((from.turn_id.clone(), turn_id.clone()));
            // A steer still waiting may name a turn many carries back: kept while any waits.
            if now.waiting.is_empty() {
                trim_successors(&mut now.successors);
            }
            while now.successors.len() > SUCCESSORS_MAX {
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
        let (client, text, line, continues) = match sent {
            Some(s) => (s.client, s.text, s.line, s.continues),
            None => (
                from.map(|t| t.client.clone()).unwrap_or_default(),
                String::new(),
                String::new(),
                Continues::default(),
            ),
        };
        let continues = Continues { reports, ..continues };
        let prompt_id = first.cloned().unwrap_or_else(|| uuid::Uuid::now_v7().to_string());
        let turn = TurnInfo::prompted(&client, &text, &turn_id, &prompt_id, control);
        (turn.shown_as(&line), continues)
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
        // The turn as it is now: a Web steer may have raised its control since it was put in
        // place (`check_steer`).
        let Some(mut turn) = session.turn().filter(|t| t.turn_id == next.next.turn_id) else {
            return;
        };
        turn.turn_seq = self.begin_carried(session, from, &turn, &next.carried, &next.continues);
        // The daemon stops: the next one runs it on from the log (`recover_carried`).
        if self.shutting_down() {
            return;
        }
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
        continues: Continues,
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
            turn.turn_seq = self.begin_carried(session, from, &turn, carried, &continues);
        } else {
            // Started before the restart: its cap counts from its start (`turn_cap.rs`).
            self.arm_turn_cap(session, &turn.turn_id);
        }
        self.recovered_floor(session, turn.control);
        self.set_status(session, SessionStatus::Running);
        let (hub, session, child) = (self.clone(), session.clone(), child.clone());
        // A recovered turn is not continued (`auto_resume.rs`).
        tokio::spawn(Box::pin(
            async move { hub.run_carried(session, child, turn, None, None).await },
        ));
    }

    /// As a recovered turn (`hosts.rs` `recover_work`): a Web turn in an agent the sandbox did
    /// not start, or in a mode only a machine's Full-access setting allows, does not go on.
    pub(super) fn recovered_floor(&self, session: &Session, control: Control) {
        session.floor.last_turn_web.store(control == Control::Web, Ordering::SeqCst);
        if control == Control::Web && session.floor.unsandboxed.load(Ordering::SeqCst) {
            self.remote_floor_cancel(session, "remote.unsandboxed_agent");
        }
        if self.full_access_hold(&session.meta(), control, None).is_err() {
            self.remote_floor_cancel(session, "remote.full_access_ended");
        }
    }

    /// The carried turn's start: counted, logged as `turn_started` after `from`'s end, and its
    /// own turn cap armed (`turn_cap.rs`): the turn before's timer ends with it.
    fn begin_carried(
        self: &Arc<Self>,
        session: &Arc<Session>,
        from: &str,
        turn: &TurnInfo,
        c: &Carried,
        continues: &Continues,
    ) -> u64 {
        self.clear_deferred_unread(session);
        self.end_foreground_subagents(session);
        {
            let mut m = session.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            m.turn_count += 1;
            m.preview = Some(String::new());
        }
        // A turn on lane reports only reports nothing (`lane_reports.rs`).
        self.lane_turn_on(session, continues.reports);
        if turn.control == Control::Web {
            session.floor.last_turn_web.store(true, Ordering::SeqCst);
        }
        let msg = json!({
            "prompt": turn.prompt_preview,
            "promptLine": turn.masked_preview,
            "client": turn.client,
            "promptId": turn.prompt_id,
            "turnId": turn.turn_id,
            "control": turn.control.as_str(),
            "trustGate": continues.trust_gate,
            "carried": {"fromTurnId": from, "promptIds": c.prompt_ids},
        });
        let seq = self.append(session, "mux", "turn_started", msg).seq;
        {
            let mut running = session.turn.lock().unwrap_or_else(|e| e.into_inner());
            if let Some(t) = running.as_mut().filter(|t| t.turn_id == turn.turn_id) {
                t.turn_seq = seq;
            }
        }
        self.arm_turn_cap(session, &turn.turn_id);
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
        // Closes before this point were before these turns (`respawn_stopped_agent`).
        let stops = session.stops.load(Ordering::SeqCst);
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
                        &session, &child, params, id, false, false, None, false, None, on_sent,
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
                        not_before: super::auto_resume::reset_hint::error_reset_at(
                            e.data.as_ref(),
                            super::now_ms(),
                        ),
                        error: super::turn_errors::continuation_error(
                            agent_error.as_deref(),
                            &e.message,
                        ),
                    })
                }
                _ => None,
            };
            self.schedule_auto_resume(&session, turn_id, cut);
            // A Stop that ended the agent of this turn starts it again now, as a prompt's turn
            // does (`cancel.rs`), with the turn lock still held.
            self.respawn_stopped_agent(&session, turn_id, stops).await;
            let Some(next) = next else { break };
            let NextTurn { carried, next: next_turn, continues: next_continues } = *next;
            // As it is now (`start_carried`).
            let Some(mut next_turn) = session.turn().filter(|t| t.turn_id == next_turn.turn_id)
            else {
                break;
            };
            next_turn.turn_seq =
                self.begin_carried(&session, turn_id, &next_turn, &carried, &next_continues);
            continues = Some(next_continues);
            turn = next_turn;
            // The daemon stops: the next one runs this turn on from the log (`recover_carried`).
            if self.shutting_down() {
                break;
            }
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

    async fn chat() -> (Arc<Hub>, Arc<Session>) {
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
        (hub, s)
    }

    #[tokio::test]
    async fn a_carried_turn_waits_for_its_own_end_before_turning_unread() {
        let (hub, s) = chat().await;
        s.subagents.lock().unwrap().annotate_live(
            &mut json!({"sessionId": s.id, "update": {
                "sessionUpdate": "subagent_spawned", "subagentSessionId": "background",
                "background": true
            }}),
            true,
        );
        hub.refresh_work_below(&s);
        hub.mark_unread_unless_work_below(&s);
        assert!(!s.meta().unread, "the previous turn still has background work");

        let from = TurnInfo::prompted("test", "work", "t-1", "p-1", Control::Local);
        let carried = Carried { seq: 1, prompt_ids: vec![] };
        let (next, continues) = hub.carried_turn(&s, Some(&from), &carried);
        *s.turn.lock().unwrap() = Some(next.clone());
        hub.begin_carried(&s, &from.turn_id, &next, &carried, &continues);
        hub.end_background_subagents(&s);
        assert!(!s.meta().unread, "the carried turn is still running");

        hub.mark_unread_unless_work_below(&s);
        assert!(s.meta().unread, "the carried turn's own end earns its unread dot");
    }

    /// A steer still waits on a turn many carries back (one steer read per carried turn): its
    /// forced Stop still reaches it (`succeeds`), past the successions kept with none waiting.
    #[tokio::test]
    async fn a_waiting_steer_keeps_its_turns_succession_past_many_carries() {
        let (hub, s) = chat().await;
        s.steer_now.lock().unwrap().waiting.insert("p-old".into(), None);
        let first = TurnInfo::prompted("test", "work", "t-0", "p-0", Control::Local);
        let mut turn = first.clone();
        for seq in 0..(SUCCESSORS_KEPT as u64 + 10) {
            turn = hub.carried_turn(&s, Some(&turn), &Carried { seq, prompt_ids: vec![] }).0;
        }
        assert!(Hub::succeeds(&s, "t-0", &turn.turn_id), "the succession was dropped");
        // Answered: the old successions go.
        let mut now = s.steer_now.lock().unwrap();
        now.waiting.clear();
        trim_successors(&mut now.successors);
        drop(now);
        assert!(!Hub::succeeds(&s, "t-0", &turn.turn_id));
    }

    /// A Stop of a turn that carried on holds for the carried turn: a connection error there is
    /// not continued (`auto_resume.rs`).
    #[tokio::test]
    async fn a_stop_holds_across_a_carry() {
        let (hub, s) = chat().await;
        let one = TurnInfo::prompted("test", "work", "t-1", "p-1", Control::Local);
        *s.turn.lock().unwrap() = Some(one.clone());
        hub.stop_auto_resume(&s);
        let two = hub.carried_turn(&s, Some(&one), &Carried { seq: 1, prompt_ids: vec![] }).0;
        hub.take_turn(&s, "t-1", Some(two.clone()));
        hub.schedule_auto_resume(&s, "t-1", None);
        assert!(hub.stopped_for_test(&s, &two.turn_id), "the Stop did not hold for the next turn");
    }

    /// A restart reads a carried turn from its record with the line it showed (`prompt_line.rs`),
    /// never the envelope of the message it carried; an older record without one, its client's.
    #[test]
    fn a_carried_turns_record_keeps_the_line_it_showed() {
        let envelope = "[cmux agent message] from coord-deputy (acp:abc)\nMessage id: m1\n---\nMerged #1\n--- end of message m1 ---";
        let mut t = TurnInfo::prompted("cmux", envelope, "t-2", "p-2", Control::Local);
        t.show("coord-deputy: Merged #1");
        let next = NextTurn {
            carried: Carried { seq: 1, prompt_ids: vec!["p-2".into()] },
            next: t,
            continues: Continues::default(),
        };
        let back = NextTurn::from_record(&next.record(Control::Local)).unwrap();
        assert_eq!(back.next.masked_preview, "coord-deputy: Merged #1");
        let old = json!({"turnId": "t-3", "promptId": "p-3", "prompt": "[coord] Fix it", "client": "acpmux-cli#1", "seq": 2});
        assert_eq!(NextTurn::from_record(&old).unwrap().next.masked_preview, "coord: Fix it");
    }

    /// A carried turn whose steers were all lane reports runs on reports only: it reports
    /// nothing upward (`lane_reports.rs`), as a prompt's turn on reports does. One with any
    /// other steer, or with none named, does.
    #[tokio::test]
    async fn a_carried_turn_on_lane_reports_only_reports_nothing_upward() {
        let (hub, s) = chat().await;
        let sent = |reports| SteerSent {
            client: "test".into(),
            text: "steer".into(),
            line: "steer".into(),
            control: Control::Local,
            continues: Continues { reports, ..Continues::default() },
        };
        {
            let mut now = s.steer_now.lock().unwrap();
            now.sent.insert("p-r1".into(), sent(true));
            now.sent.insert("p-r2".into(), sent(true));
            now.sent.insert("p-task".into(), sent(false));
        }
        let mut from = TurnInfo::prompted("test", "work", "t-0", "p-0", Control::Local);
        let cases: [(&[&str], bool); 3] =
            [(&["p-r1", "p-r2"], true), (&["p-r1", "p-task"], false), (&[], false)];
        for (seq, (ids, want)) in cases.into_iter().enumerate() {
            let prompt_ids = ids.iter().map(|p| p.to_string()).collect();
            let carried = Carried { seq: seq as u64, prompt_ids };
            let (next, continues) = hub.carried_turn(&s, Some(&from), &carried);
            *s.turn.lock().unwrap() = Some(next.clone());
            hub.begin_carried(&s, &from.turn_id, &next, &carried, &continues);
            let turn = s.meta().turn_count;
            assert_eq!(hub.lane_turn_reports_only(&s.id, turn), want, "{ids:?}");
            from = next;
        }
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
