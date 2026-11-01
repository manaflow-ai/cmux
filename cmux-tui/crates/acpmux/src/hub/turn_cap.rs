//! Part of `Hub`; see `hub/mod.rs`. The turn cap: a session that takes messages from many agents
//! (a coordinator) never ends its turn when every message steers into it (Leo, 2026-10-29: "You
//! never end a fucking turn. As soon as it comes in, it fucking, like, occupies you for another
//! fucking turn.").
//!
//! A session with a cap (`SessionMeta::turn_cap_ms`, else [`default_turn_cap_ms`]) whose running
//! turn is older than the cap stops taking other agents' steers: they wait in the queue, and the
//! next turn takes them together (`digest.rs`); one sent with `interrupt` stops nothing. The
//! person's own steers still go in, and so does the queue's Send now. The hub steers one notice
//! into that turn, once ([`NOTICE_KIND`]; the turn it went into is saved in the session's meta, so
//! a turn a restart adopts gets no second), when an agent's message is waiting for it: on the
//! first agent message past the cap, or at the cap when one waits already, queued or in the inbox
//! with no notice carrying it ([`Hub::arm_turn_cap`]'s timer). The notice goes only into the turn it names ([`notice_reaches`], checked again as it is
//! written; one logged but never written leaves `steer_withdrawn`). The hub never cancels
//! the turn itself.
//!
//! The timer: one per session, armed when a turn starts (a prompt's, a carried one's, or one a
//! restart adopts, `carried_turn.rs`, `hosts.rs`). It wakes once, at the cap, and ends; a
//! turn that starts before then aborts the previous turn's timer (`Session::turn_cap_timer`). It
//! holds the session weakly, so a closed session's timer does nothing.

use super::*;
use std::sync::Weak;

/// The cap a coordinator session gets when it set none itself (the `coordinator` setting, which
/// [`default_turn_cap_ms`] reads once it lands).
#[allow(dead_code)] // read by `default_turn_cap_ms` with the coordinator setting
pub const COORDINATOR_TURN_CAP_MS: u64 = 20 * 60 * 1000;

/// The provenance kind of the notice (`prompt_provenance.rs`): hub-set, never a client's.
pub const NOTICE_KIND: &str = "turn_cap";

/// The cap a session's other settings give it when it set none itself: none today. The
/// coordinator setting gives [`COORDINATOR_TURN_CAP_MS`] here, the one place that links the two.
pub(crate) fn default_turn_cap_ms(_meta: &SessionMeta) -> Option<u64> {
    None
}

/// The session's cap: its own `turnCapMs` (0 turns it off), else [`default_turn_cap_ms`].
pub(crate) fn turn_cap_ms(meta: &SessionMeta) -> Option<u64> {
    match meta.turn_cap_ms {
        Some(0) => None,
        Some(ms) => Some(ms),
        None => default_turn_cap_ms(meta),
    }
}

/// The running turn's id and the cap when that turn is at or past the cap at `now` (Unix ms).
fn capped_turn(session: &Session, now: u64) -> Option<(String, u64)> {
    let cap = turn_cap_ms(&session.meta.lock().unwrap_or_else(|e| e.into_inner()))?;
    let turn = session.turn()?;
    (now.saturating_sub(turn.started_at) >= cap).then_some((turn.turn_id, cap))
}

/// Whether `provenance` is the notice's.
pub(super) fn is_notice(provenance: Option<&Value>) -> bool {
    provenance.and_then(|p| p.get("kind")).and_then(Value::as_str) == Some(NOTICE_KIND)
}

/// Whether the running turn is past its cap now: it takes no other agent's message, an inbox
/// digest of them included (`inbox_digest.rs`).
pub(super) fn past_cap(session: &Session) -> bool {
    capped_turn(session, now_ms()).is_some()
}

/// Whether a steer with `provenance` may go into turn `turn_id`: anything but the notice, and the
/// notice only into the turn it names while that turn still runs. A notice for a turn that ended
/// never reaches the next one: checked here before it is logged, and again as it is written
/// (`steer_end.rs` `agent_prompt_hook`, `bound`).
pub(super) fn notice_reaches(session: &Session, provenance: Option<&Value>, turn_id: &str) -> bool {
    if !is_notice(provenance) {
        return true;
    }
    provenance.and_then(|p| p.get("turnId")).and_then(Value::as_str) == Some(turn_id)
        && session.turn().is_some_and(|t| t.turn_id == turn_id)
}

/// The notice's words.
pub(super) fn notice_text(cap_ms: u64) -> String {
    let minutes = cap_ms.div_ceil(60_000);
    format!(
        "Turn cap reached ({minutes} min): finish the current step and end your turn; your inbox digest comes next turn."
    )
}

/// The refusal of a steer-only prompt that cannot steer now; `capped`: because the running turn is
/// past its cap.
pub(super) fn steer_unavailable(capped: bool) -> RpcError {
    let why = if capped {
        "steer.unavailable: the running turn is past its turn cap; other agents' messages wait for its next turn"
    } else {
        "steer.unavailable: the session has no running turn that its agent can steer"
    };
    RpcError::invalid_params(why)
        .with_data(json!({"reason": "steer.unavailable", "turnCap": capped}))
}

impl Hub {
    /// Whether a prompt that arrives now and is another agent's message (`digest::agent_sender`
    /// of its `provenance` and `agent`) waits for the next turn instead of steering in: the
    /// running turn is past its cap. Any agent message past the cap asks for the notice, steer or
    /// not. The person's never waits.
    #[inline(never)]
    pub(super) fn turn_cap_holds(
        self: &Arc<Self>,
        session: &Arc<Session>,
        provenance: Option<&Value>,
        agent: Option<&str>,
    ) -> bool {
        if super::digest::agent_sender(provenance, agent).is_none() {
            return false;
        }
        let Some((turn_id, cap)) = capped_turn(session, now_ms()) else { return false };
        self.turn_cap_notice(session, &turn_id, cap);
        true
    }

    /// Sends the notice when the running turn is past its cap: an agent message was just queued
    /// behind it ([`Hub::turn_cap_notice`] sends one per turn).
    pub(super) fn turn_cap_recheck(self: &Arc<Self>, session: &Arc<Session>) {
        if let Some((turn_id, cap)) = capped_turn(session, now_ms()) {
            self.turn_cap_notice(session, &turn_id, cap);
        }
    }

    /// Arms the cap's timer for turn `turn_id`, the session's turn, which starts now (module
    /// docs). A turn a restart adopts started before: its cap counts from that start.
    pub(super) fn arm_turn_cap(self: &Arc<Self>, session: &Arc<Session>, turn_id: &str) {
        let mut timer = session.turn_cap_timer.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(previous) = timer.take() {
            previous.abort();
        }
        let Some(cap) = turn_cap_ms(&session.meta.lock().unwrap_or_else(|e| e.into_inner())) else {
            return;
        };
        let started = session.turn().filter(|t| t.turn_id == turn_id).map(|t| t.started_at);
        let wait = cap.saturating_sub(started.map_or(0, |at| now_ms().saturating_sub(at)));
        let hub = Arc::downgrade(self);
        let weak: Weak<Session> = Arc::downgrade(session);
        let turn_id = turn_id.to_owned();
        let task = tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(wait)).await;
            let (Some(hub), Some(session)) = (hub.upgrade(), weak.upgrade()) else { return };
            let Some((running, cap)) = capped_turn(&session, now_ms()) else { return };
            // Another agent's message waits: queued (`queue.rs` keeps its sender as `run.agent`),
            // or in the inbox with no notice carrying it (`inbox.rs`), which steers none into a
            // turn past its cap.
            let queued = session
                .queue
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .iter()
                .any(|q| q.run.agent.is_some());
            let held = session
                .inbox
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .items
                .iter()
                .any(|i| !i.noticed);
            if running == turn_id && (queued || held) {
                hub.turn_cap_notice(&session, &running, cap);
            }
        });
        *timer = Some(task.abort_handle());
    }

    /// Steers the notice into turn `turn_id`, once for that turn. A session whose agent does not
    /// steer gets none: no message steers into its turn anyway.
    fn turn_cap_notice(self: &Arc<Self>, session: &Arc<Session>, turn_id: &str, cap: u64) {
        if !session.steering.load(Ordering::SeqCst) {
            return;
        }
        {
            // The turn is read under the meta lock (nothing takes the meta lock under the turn's),
            // so an attempt for a turn that has ended never replaces a later turn's marker.
            let mut meta = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            if meta.turn_cap_noticed.as_deref() == Some(turn_id)
                || session.turn().is_none_or(|t| t.turn_id != turn_id)
            {
                return;
            }
            meta.turn_cap_noticed = Some(turn_id.to_owned());
        }
        // Saved before it goes, so a turn a restart adopts gets no second one.
        self.save_meta(session);
        let opts = PromptOptions {
            prompt_id: Some(format!("turn-cap-{turn_id}")),
            // One the log holds already (sent before a restart whose meta save was lost) is
            // answered from the log, never sent again (`prompt_ledger.rs` `logged_prompt`).
            resend: true,
            // Into this turn or nowhere: a turn that ended meanwhile needs no notice.
            steer_only: true,
            provenance: Some(json!({"kind": NOTICE_KIND, "turnId": turn_id, "capMs": cap})),
            ..PromptOptions::default()
        };
        let blocks = vec![json!({"type": "text", "text": notice_text(cap)})];
        let (hub, session) = (self.clone(), session.clone());
        tokio::spawn(async move {
            if let Err(e) = hub.prompt_with(&session, blocks, "acpmux", true, opts).await {
                tracing::info!(session = %session.id, "turn cap notice not steered: {}", e.message);
            }
        });
    }

    /// [`Hub::set_turn_cap_answered`] for the tests (`turn_cap_tests.rs`).
    #[cfg(test)]
    pub(crate) fn set_turn_cap(&self, session: &Session, cap_ms: Option<u64>) {
        // A failed save is logged there; no request waits for this one.
        let _ = self.set_turn_cap_answered(session, cap_ms);
    }

    /// Sets or clears (`None`) the session's own cap, in ms; 0 turns the cap off. Read at each
    /// message and turn start, so a running turn takes the new cap at once; its timer starts with
    /// the next turn. `_acpmux/set_turn_cap` is answered only once the cap is saved
    /// (`meta_save.rs`).
    pub(crate) fn set_turn_cap_answered(
        &self,
        session: &Session,
        cap_ms: Option<u64>,
    ) -> Result<(), RpcError> {
        session.meta.lock().unwrap_or_else(|e| e.into_inner()).turn_cap_ms = cap_ms;
        self.save_meta_answered(session)
    }
}

// The tests gate turns with a named pipe (`libc::mkfifo`), which only Unix has.
#[cfg(all(test, unix))]
#[path = "turn_cap_tests.rs"]
mod tests;
