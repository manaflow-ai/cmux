//! Auto mode: what a holder that gives a chat the person moved asks of the hub
//! (`auto_session/runtime/give.rs`).
//!
//! The turn that runs is stopped the way a move by hand interrupts one
//! (`transfer_out.rs`, `_acpmux/transfer_begin {interrupt}`): its continuation is logged first
//! ([`Cut::Move`]), so the chat's copy carries it and the turn goes on where the chat lands. A
//! give that does not happen queues that continuation here, told that the chat stayed.

use super::auto_resume::Cut;
use super::*;

/// How long a turn that was told to stop may take to end before the give is called off: what a
/// move by hand allows a turn it interrupted.
// timeout: past it the give is called off and the turn keeps running; nothing is lost.
const STOP_WAIT: std::time::Duration = std::time::Duration::from_secs(20);

/// The log record of a move that did not happen: `{to, why, text}`, `text` for the person.
const NOT_MOVED: &str = "auto_not_moved";

/// What came of stopping a chat's turn for a give.
pub(crate) struct TurnStop {
    /// No turn of the chat runs here now.
    pub stopped: bool,
    /// The prompt id of the continuation logged for the turn that was cut off. None when no
    /// turn ran, or the turn gets none (the person had pressed Stop).
    pub carried: Option<String>,
}

impl Hub {
    /// Cuts the running turn `running` off for a move: logs its continuation (`how`), gives it
    /// the head of the queue as a record of its own, and stops the turn. Returns the
    /// continuation's prompt id; None when the turn gets none. A move by hand and an Auto
    /// give both stop a turn here.
    pub(super) async fn cut_turn_to_move(
        self: &Arc<Self>,
        session: &Arc<Session>,
        running: &str,
        how: Cut,
    ) -> Option<String> {
        let carried = self.log_continuation(session, running, how);
        // Its place at the head, as a record of its own: a guarded target drops the
        // provenance that would put it there (`transfer_guard.rs` `guarded_record`).
        if let Some(id) = &carried {
            let order: Vec<String> = std::iter::once(id.clone())
                .chain(
                    session
                        .queue
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .iter()
                        .map(|q| q.prompt_id.clone()),
                )
                .collect();
            self.append(session, "mux", "queue_order", json!({"promptId": id, "order": order}));
        }
        match &carried {
            Some(id) => self.cancel_turn_for_replacement(session, running, id).await,
            None => self.cancel_turn(session, running).await,
        }
        carried
    }

    /// Stops the turn the chat runs, for a give. The chat is frozen by then
    /// ([`Self::auto_hold`]), so nothing starts behind the turn. A chat that compacts is not
    /// stopped, as a move by hand refuses it: a Stop then withdraws the person's queued
    /// prompts.
    pub(crate) async fn auto_stop_turn(self: &Arc<Self>, session: &Arc<Session>) -> TurnStop {
        let mut carried = None;
        if let Some(running) = session.turn().map(|t| t.turn_id) {
            let child = session.child.lock().await.clone();
            let compacting = session.compacting.load(std::sync::atomic::Ordering::SeqCst)
                || child.is_some_and(|c| c.translator.as_ref().is_some_and(|t| t.is_compacting()));
            if compacting {
                return TurnStop { stopped: false, carried: None };
            }
            carried = self.cut_turn_to_move(session, &running, Cut::Move).await;
        }
        // The turn's task holds the lock until the turn has ended and its result is logged. A
        // turn recovered from an agent host runs before its task takes it (`hosts.rs`).
        let stopped = match tokio::time::timeout(STOP_WAIT, session.turn_lock.lock()).await {
            Ok(_ended) => session.turn().is_none(),
            Err(_) => false,
        };
        TurnStop { stopped, carried }
    }

    /// The give did not happen: the continuation `carried` joins the queue here, at its head,
    /// and says the chat stayed (`transfer_out.rs` `queue_carried`). Call it once the chat may
    /// run here again.
    pub(crate) fn auto_stay(self: &Arc<Self>, session: &Arc<Session>, carried: &str) {
        self.queue_carried(session, carried);
    }

    /// Writes into the chat's log that it was not moved `to` where the person asked, and why
    /// (`text`, in plain words).
    pub(crate) fn auto_tell_not_moved(&self, session: &Session, to: &str, why: &str, text: &str) {
        self.append(session, "mux", NOT_MOVED, json!({"to": to, "why": why, "text": text}));
    }
}
