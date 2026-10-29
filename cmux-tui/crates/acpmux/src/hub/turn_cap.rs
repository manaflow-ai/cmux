//! Part of `Hub`; see `hub/mod.rs`. The turn cap: a session that takes messages from many agents
//! (a coordinator) never ends its turn when every message steers into it (Leo, 2026-10-29: "You
//! never end a fucking turn. As soon as it comes in, it fucking, like, occupies you for another
//! fucking turn.").
//!
//! A session with a cap (`SessionMeta::turn_cap_ms`, else [`default_turn_cap_ms`]) whose running
//! turn is older than the cap stops taking other agents' steers: they wait in the queue, and the
//! next turn takes them together (`digest.rs`). The person's own steers still go in. The hub
//! steers one notice into that turn, once ([`NOTICE_KIND`]), when an agent's message is waiting
//! for it: on the first agent message past the cap, or at the cap when one waits already
//! ([`Hub::arm_turn_cap`]'s timer). The hub never cancels the turn itself.
//!
//! The timer: one per session, armed when a turn starts. It wakes once, at the cap, and ends; a
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
    /// Whether another agent's message (`agent`, from `digest::agent_sender`) that arrives now
    /// waits for the next turn instead of steering in: the running turn is past its cap. Any
    /// agent message past the cap asks for the notice, steer or not. The person's never waits.
    #[inline(never)]
    pub(super) fn turn_cap_holds(
        self: &Arc<Self>,
        session: &Arc<Session>,
        opts: &PromptOptions,
    ) -> bool {
        if super::digest::agent_sender(opts.provenance.as_ref(), opts.agent.as_deref()).is_none() {
            return false;
        }
        let Some((turn_id, cap)) = capped_turn(session, now_ms()) else { return false };
        self.turn_cap_notice(session, &turn_id, cap);
        true
    }

    /// Arms the cap's timer for turn `turn_id`, which starts now (module docs).
    pub(super) fn arm_turn_cap(self: &Arc<Self>, session: &Arc<Session>, turn_id: &str) {
        let mut timer = session.turn_cap_timer.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(previous) = timer.take() {
            previous.abort();
        }
        let Some(cap) = turn_cap_ms(&session.meta.lock().unwrap_or_else(|e| e.into_inner())) else {
            return;
        };
        let hub = Arc::downgrade(self);
        let weak: Weak<Session> = Arc::downgrade(session);
        let turn_id = turn_id.to_owned();
        let task = tokio::spawn(async move {
            tokio::time::sleep(std::time::Duration::from_millis(cap)).await;
            let (Some(hub), Some(session)) = (hub.upgrade(), weak.upgrade()) else { return };
            let Some((running, cap)) = capped_turn(&session, now_ms()) else { return };
            // Another agent's message waits (`queue.rs` keeps its sender as `run.agent`).
            let waiting = session
                .queue
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .iter()
                .any(|q| q.run.agent.is_some());
            if running == turn_id && waiting {
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
            let mut noticed = session.turn_cap_noticed.lock().unwrap_or_else(|e| e.into_inner());
            if noticed.as_deref() == Some(turn_id) {
                return;
            }
            *noticed = Some(turn_id.to_owned());
        }
        let opts = PromptOptions {
            prompt_id: Some(format!("turn-cap-{turn_id}")),
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

    /// Sets or clears (`None`) the session's own cap, in ms; 0 turns the cap off. Read at each
    /// message and turn start, so a running turn takes the new cap at once; its timer starts with
    /// the next turn.
    pub(crate) fn set_turn_cap(&self, session: &Session, cap_ms: Option<u64>) {
        session.meta.lock().unwrap_or_else(|e| e.into_inner()).turn_cap_ms = cap_ms;
        self.save_meta(session);
    }
}

#[cfg(test)]
#[path = "turn_cap_tests.rs"]
mod tests;
