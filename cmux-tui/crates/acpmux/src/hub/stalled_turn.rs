//! Part of `Hub`; see `hub/mod.rs`. A running turn whose model went quiet for good.
//!
//! On huge-blue (2026-10-25) 72 Codex chats read `running` for a day: a broadcast woke old
//! reviewers while the machine was out of processes and its network timed out, each Codex
//! sent its model request and never heard back, and its app-server lived on with the turn
//! open. Nothing ended those turns: the agent never answered, Stop could not end a turn an
//! adopted host still ran (`hosts.rs` `turn_answer` did not take the forced end), and each
//! daemon restart rebuilt the turn as just started. So the session counts and the slots were
//! wrong, and a prompt queued behind such a turn waited forever.
//!
//! A turn that has shown no sign of its model at work (`tap.rs` `from_the_model`, as
//! `silentTurnMs` counts them) for `stalledTurnEndMs` (default 6 h; 0 off; four times that while
//! one of its tool calls has not ended, so a long command that prints nothing is not cut off,
//! and a tool that never ends does not hold the turn for good) ends here as failed,
//! `detail` `stalled`, unless someone holds it: a client that shows the chat, a permission or
//! secret waiting for the person, or its recorded owner (a sub-session's parent, the session a
//! `spawnedBy` tag names) running or waiting on this daemon. The agent gets the cancel, and the
//! turn ends right after through the forced end Stop uses (`cancel.rs`), so an agent that never
//! answers still lets go of it. The session is then ready, its queue held as after any failed
//! turn, and the idle harness exit (`idle.rs`) stops the agent after `idle_child` like any
//! unused one; the next prompt resumes the chat. Nothing is closed and nothing is decided by
//! name.
//!
//! The count starts when the prompt goes out and moves with every sign of the model. An adopted
//! turn's comes from its log (`hosts.rs` `open_work`), so a daemon restart neither restarts it
//! nor shows the turn as just started. The idle reaper's task (`idle.rs`) waits for the
//! earliest deadline; it stops with the daemon (`stop_idle_reaper`) and a deadline goes with
//! its turn. A turn held at its deadline is looked at again `RECHECK` later, never sooner.

use super::*;

/// How soon a turn held at its deadline (a client shows it, its owner is busy) is looked at again.
const RECHECK: std::time::Duration = std::time::Duration::from_secs(15 * 60);

/// How many periods a turn quiet inside a tool call that has not ended gets: a long command
/// that prints nothing is work, but a tool that never ends does not hold the turn for good.
const OPEN_TOOL_PERIODS: u64 = 4;

/// How long the stalled end waits for the agent to take the cancel before ending the turn anyway.
const CANCEL_SEND: std::time::Duration = std::time::Duration::from_secs(5);

/// Notes in `open` what one `session/update` says of the turn's tool calls: one starts, or ends
/// (`completed`, `failed`).
pub(super) fn track_tool(open: &mut std::collections::HashSet<String>, update: &Value) {
    let kind = update.get("sessionUpdate").and_then(Value::as_str);
    if !matches!(kind, Some("tool_call" | "tool_call_update")) {
        return;
    }
    let Some(id) = update.get("toolCallId").and_then(Value::as_str) else { return };
    match update.get("status").and_then(Value::as_str) {
        Some("completed" | "failed") => {
            open.remove(id);
        }
        // A call starts pending when it says nothing; an update without a status changes none.
        None if kind == Some("tool_call_update") => {}
        _ => {
            open.insert(id.to_owned());
        }
    }
}

impl Hub {
    /// A `session/update` from `session`'s agent (`tap.rs`): its open tool calls follow it. The
    /// last one ending brings the turn's deadline nearer: the reaper looks again.
    pub(super) fn note_tool_update(&self, session: &Session, update: &Value) {
        // Before its prompt is written the tools are not this turn's: a failover's old agent
        // still sending, the new agent's history replayed on load.
        if session.stalled_counted.lock().unwrap_or_else(|e| e.into_inner()).is_none() {
            return;
        }
        let mut open = session.open_tools.lock().unwrap_or_else(|e| e.into_inner());
        let was_open = !open.is_empty();
        track_tool(&mut open, update);
        if was_open && open.is_empty() {
            drop(open);
            // A tool call's end is a sign of work: stamped (again) before the reaper looks, so
            // the nearer deadline counts from now, whatever order the tap ran in.
            self.heard_now(session);
            self.idle_wake.notify_one();
        }
    }

    /// `session`'s model showed a sign of work now (`tap.rs`): its count starts again, and a
    /// stalled end decided before it is not carried out (`stalled_gen`).
    pub(super) fn heard_now(&self, session: &Session) {
        session.heard_at.store(self.clock_now() as i64, Ordering::Relaxed);
        session.stalled_gen.fetch_add(1, Ordering::SeqCst);
    }

    /// A new turn, or a new agent for it, whose prompt is not written yet: no count runs and no
    /// tool call of it is open.
    pub(super) fn hold_stalled_count(session: &Session) {
        *session.stalled_counted.lock().unwrap_or_else(|e| e.into_inner()) = None;
        session.open_tools.lock().unwrap_or_else(|e| e.into_inner()).clear();
        session.stalled_gen.fetch_add(1, Ordering::SeqCst);
    }

    /// `session`'s running turn starts its stalled count, its prompt written: now, or at
    /// `heard_ms` (Unix ms), the last sign of its model an adopted host's log holds (`hosts.rs`
    /// `recover_work`).
    pub(super) fn watch_stalled_turn(&self, session: &Session, heard_ms: Option<u64>) {
        let now = self.clock_now() as i64;
        let at = match heard_ms {
            Some(ms) => {
                let ago = crate::store::now_ms().saturating_sub(ms) as i64;
                now.saturating_sub(ago.saturating_mul(1_000_000))
            }
            None => now,
        };
        // A prompt just written starts with no tool call open; an adopted turn keeps the ones
        // its log holds (`recover_work` set them).
        if heard_ms.is_none() {
            session.open_tools.lock().unwrap_or_else(|e| e.into_inner()).clear();
        }
        session.heard_at.store(at, Ordering::Relaxed);
        session.stalled_recheck.store(0, Ordering::Relaxed);
        *session.stalled_counted.lock().unwrap_or_else(|e| e.into_inner()) =
            session.turn().map(|t| t.turn_id);
        session.stalled_gen.fetch_add(1, Ordering::SeqCst);
        self.idle_wake.notify_one();
    }

    /// The turn whose stalled count runs: `session`'s running turn, once its prompt was written.
    fn counted_turn(session: &Session) -> Option<TurnInfo> {
        let counted = session.stalled_counted.lock().unwrap_or_else(|e| e.into_inner()).clone();
        session.turn().filter(|t| counted.as_ref() == Some(&t.turn_id))
    }

    /// When the first running turn's stalled period ends, on the hub clock.
    pub(super) fn next_stalled_deadline(
        &self,
        stalled: std::time::Duration,
    ) -> Option<std::time::Duration> {
        if self.stopping.load(Ordering::SeqCst) {
            return None;
        }
        let period = stalled.as_nanos() as u64;
        self.sessions()
            .iter()
            .filter(|s| Self::counted_turn(s).is_some())
            .map(|s| Self::stalled_due(s, period))
            .min()
            .map(std::time::Duration::from_nanos)
    }

    /// When `session`'s turn is due, on the hub clock (ns): a period after its model's last
    /// sign (`OPEN_TOOL_PERIODS` inside a tool call that has not ended), and not before a
    /// recheck. The sign may be from before this daemon started (negative): the period is added
    /// first, so a turn quiet for longer than the daemon has run is due at once.
    fn stalled_due(session: &Session, period: u64) -> u64 {
        let in_tool = !session.open_tools.lock().unwrap_or_else(|e| e.into_inner()).is_empty();
        let period = if in_tool { period.saturating_mul(OPEN_TOOL_PERIODS) } else { period };
        let due = session.heard_at.load(Ordering::Relaxed).saturating_add(period as i64);
        (due.max(0) as u64).max(session.stalled_recheck.load(Ordering::Relaxed))
    }

    /// Ends every turn whose model has said nothing for `stalled` and that nobody holds.
    pub(super) fn settle_stalled_turns(&self, stalled: std::time::Duration) {
        if self.stopping.load(Ordering::SeqCst) {
            return;
        }
        let now = self.clock_now();
        let period = stalled.as_nanos() as u64;
        for session in self.sessions() {
            // Read first: anything that moves the count after it bumps it (`stalled_gen`).
            let generation = session.stalled_gen.load(Ordering::SeqCst);
            let Some(turn) = Self::counted_turn(&session) else { continue };
            if Self::stalled_due(&session, period) > now {
                continue;
            }
            if self.turn_held(&session) {
                let recheck = RECHECK.min(stalled).as_nanos() as u64;
                session.stalled_recheck.store(now.saturating_add(recheck), Ordering::Relaxed);
                continue;
            }
            let heard = session.heard_at.load(Ordering::Relaxed);
            let silent_ms = (now as i64).saturating_sub(heard).max(0) as u64 / 1_000_000;
            tracing::warn!(session = %session.id, turn = %turn.turn_id, silent_ms, "the agent has shown no sign of work for stalledTurnEndMs: ending its turn");
            // A turn nothing took the end of (no task waits on it) is tried again a period later.
            session.stalled_recheck.store(now.saturating_add(period), Ordering::Relaxed);
            let answer =
                json!({"stopReason": "cancelled", "_meta": {"acpmux": {"stalledMs": silent_ms}}});
            // Off this pass, so a wedged host never holds the reaper: the agent of this very
            // turn gets the cancel (bounded), then the turn ends whether it answered or not.
            // Both only while nothing moved its count since (`stalled_gen`): no sign of its
            // model, no new agent (a failover keeps the turn id but starts the count again), no
            // other turn.
            let session = session.clone();
            let turn_id = turn.turn_id;
            tokio::spawn(async move {
                let ours = |s: &Session| {
                    s.stalled_gen.load(Ordering::SeqCst) == generation
                        && Self::counted_turn(s).is_some_and(|t| t.turn_id == turn_id)
                };
                let _ = tokio::time::timeout(CANCEL_SEND, async {
                    let child = session.child.lock().await.clone();
                    if ours(&session)
                        && let (Some(child), Some(sid)) = (child, session.meta().agent_session_id)
                    {
                        let _ =
                            child.notify(method::SESSION_CANCEL, json!({"sessionId": sid})).await;
                    }
                })
                .await;
                if ours(&session) {
                    session.steer_end.send_replace(Some((turn_id, answer)));
                }
            });
        }
    }

    /// Someone still holds `session`'s turn: a client that shows the chat, a question for the
    /// person, or its recorded owner busy here.
    fn turn_held(&self, session: &Session) -> bool {
        let shown = session.attached.load(Ordering::SeqCst) > session.hidden.load(Ordering::SeqCst);
        shown
            || session.status() == SessionStatus::Waiting
            || !session.pending_permissions().is_empty()
            || self.secrets.waiting_in(&session.id)
            || self.owner_busy(session)
    }

    /// The session that started `session` (a sub-session's parent, its `spawnedBy` tag) is on
    /// this daemon and running or waiting: it may be waiting on this turn.
    fn owner_busy(&self, session: &Session) -> bool {
        let m = session.meta();
        let owner = match &m.subsession {
            Some(link) => Some(link.started_by.clone()),
            None => live_tags(&m)
                .get(super::views::SPAWNED_BY_TAG)
                .and_then(Value::as_str)
                .map(str::to_owned),
        };
        let Some(owner) = owner.filter(|o| *o != m.id) else { return false };
        let owner = self.sessions.lock().unwrap_or_else(|e| e.into_inner()).get(&owner).cloned();
        owner.is_some_and(|o| matches!(o.status(), SessionStatus::Running | SessionStatus::Waiting))
    }

    /// The error a stalled turn fails with (`finish_turn`), from its forced answer.
    pub(super) fn stalled_error(answer: &Value) -> Option<RpcError> {
        let ms = answer.pointer("/_meta/acpmux/stalledMs").and_then(Value::as_u64)?;
        let text = format!(
            "the agent showed no sign of work for {}; acpmux ended the turn (stalledTurnEndMs)",
            quiet_for(ms)
        );
        Some(RpcError::new(-32000, text).with_data(json!({"detail": "stalled", "stalledMs": ms})))
    }
}

/// `ms` as a person says it: `6h 0m`, `12m`, `40s`.
fn quiet_for(ms: u64) -> String {
    let s = ms / 1000;
    match s {
        3600.. => format!("{}h {}m", s / 3600, s % 3600 / 60),
        60.. => format!("{}m", s / 60),
        _ => format!("{s}s"),
    }
}
