//! Auto mode: a chat's Cloud copy becomes a session of this daemon (`auto_session/import.rs`).
//!
//! The copy arrives as a bundle, imported as a moved chat is (`transfer.rs` `import_into`).
//! What Auto mode adds: the chat's last holder may have gone away mid-turn, so the log's open
//! turn is settled `outcome_unknown` here and its continuation queued ahead of everything that
//! waited, before the chat's queue runs: `machine_takeover` for a takeover
//! ([`Cut::Takeover`]), `moved` for a chat that came home with a turn open ([`Cut::Move`]). A
//! chat its holder gave (the person moved it) has no open turn: the giver stopped it and logged
//! the `moved` continuation, which the restored queue runs here.

use super::*;
use crate::auto_session::import::{Arrival, CutBy, InFlight};
use crate::hub::auto_resume::Cut;

impl Hub {
    /// The chat `id` when it is a session of this daemon.
    pub(crate) fn auto_local(&self, id: &str) -> Option<Arc<Session>> {
        self.session_by_id(id)
    }

    /// Imports the Cloud copy in `bundle` as the chat `arrival.id`.
    ///
    /// A chat of that id that is here already is replaced whole, log and all, under the same
    /// id: the Cloud's copy is the chat. The caller has read and checked the whole copy by
    /// then, so what can still fail is local.
    pub(crate) async fn import_auto(
        self: &Arc<Self>,
        bundle: &Path,
        arrival: &Arrival,
    ) -> Result<Arc<Session>, RpcError> {
        if let Some(old) = self.session_by_id(&arrival.id) {
            // Checked before the chat that is here goes, so a copy this machine cannot run
            // leaves that chat as it was.
            if !self.config.read().await.harnesses.contains_key(&arrival.harness) {
                let harness = &arrival.harness;
                let text = format!("agent {harness:?} is not configured on this host");
                return Err(RpcError::invalid_params(text));
            }
            self.kill(&old, true).await?;
        }
        // Not `live`: its queue stays empty, so nothing runs when the import publishes it. The
        // copy is the chat: its agent's own files replace any that are here (`the_chat`), and
        // so does cmux-harness's journal (`replace_durable`), which a chat that ran here
        // before left behind.
        let plain = (false, None, true, false, None);
        let session = self.import_placing(bundle, None, plain, true).await?;
        // Held as a chat still arriving while its open turn is settled and its queue comes
        // back, so no new prompt runs ahead of the continuation.
        *session.moving.lock().unwrap_or_else(|e| e.into_inner()) =
            Some(transfer_out::IMPORTING.to_owned());
        self.settle_arrived(&session, arrival.cut, arrival.in_flight.as_ref());
        self.restore_queue(&session);
        self.drop_unsent_subagent_retries(&session);
        // Its queued prompts run now, the continuation first (`queue.rs` `resume_queues`, as
        // after a move in).
        self.end_move(&session);
        self.resume_queues();
        if !arrival.draft.trim().is_empty() {
            let _ = self.set_composer_draft(&session, &arrival.draft);
        }
        self.save_meta(&session);
        Ok(session)
    }

    /// Ends the turn the copy's log started and never settled: `turn_result failed
    /// outcome_unknown`, and its continuation queued, once (a continuation the log holds
    /// already is not logged again, `restart_resume.rs`). `by` says what cut the turn off, for
    /// the continuation's words. `in_flight` is told to the agent when it names that turn.
    /// Returns the continuation's prompt id; None when the log left no turn open.
    fn settle_arrived(
        &self,
        session: &Arc<Session>,
        by: CutBy,
        in_flight: Option<&InFlight>,
    ) -> Option<String> {
        let OpenTurn { seq, turn_id, prompt_id, trigger, .. } = self.open_turn(session, 0)??;
        let told = in_flight
            .filter(|tool| turn_id.as_str() == Some(tool.turn_id.as_str()))
            .map(|tool| (tool.name.as_str(), tool.args.as_str()));
        let (cut, error) = match by {
            CutBy::Takeover => {
                (Cut::Takeover, "the machine this turn ran on went away before the turn settled")
            }
            CutBy::Move => {
                (Cut::Move, "this chat moved to another machine before the turn settled")
            }
        };
        let continued =
            turn_id.as_str().and_then(|turn| self.log_continuation_told(session, turn, cut, told));
        let result = json!({
            "status": "failed", "detail": "outcome_unknown", "turnSeq": seq, "turnId": turn_id,
            "promptId": prompt_id, "trigger": trigger, "error": error, "errorText": error,
        });
        self.append_unknown_outcome(session, result);
        self.save_meta(session);
        continued
    }
}
