//! Auto mode: a chat's Cloud copy becomes a session of this daemon (`auto_session/import.rs`).
//!
//! The copy arrives as a bundle, imported as a moved chat is (`transfer.rs` `import_into`).
//! What Auto mode adds: the chat's last holder may have gone away mid-turn, so the log's open
//! turn is settled `outcome_unknown` here and its `machine_takeover` continuation queued ahead
//! of everything that waited ([`Cut::Takeover`]), before the chat's queue runs.

use super::*;
use crate::auto_session::import::{Arrival, InFlight};
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
        // before left behind. Published frozen and kept so (`hold`): it is only prepared until
        // the holder loop accepts it (`auto_activate`), so a copy that lost the chat meanwhile
        // runs nothing.
        let plain = (super::transfer::Live::No, None, true, false, None);
        let session = self.import_placing(bundle, None, plain, true, true).await?;
        if arrival.settle {
            self.settle_takeover(&session, arrival.in_flight.as_ref());
        }
        self.restore_queue(&session);
        self.drop_unsent_subagent_retries(&session);
        // Its queued prompts wait for `auto_activate`, the continuation first.
        if !arrival.draft.trim().is_empty() {
            let _ = self.set_composer_draft(&session, &arrival.draft);
        }
        self.save_meta(&session);
        Ok(session)
    }

    /// Ends the turn the copy's log started and never settled: `turn_result failed
    /// outcome_unknown`, and its continuation queued. `in_flight` is told to the agent when it
    /// names that turn. Returns the continuation's prompt id.
    fn settle_takeover(
        &self,
        session: &Arc<Session>,
        in_flight: Option<&InFlight>,
    ) -> Option<String> {
        let OpenTurn { seq, turn_id, prompt_id, trigger, .. } = self.open_turn(session, 0)??;
        let told = in_flight
            .filter(|tool| turn_id.as_str() == Some(tool.turn_id.as_str()))
            .map(|tool| (tool.name.as_str(), tool.args.as_str()));
        let continued = turn_id
            .as_str()
            .and_then(|turn| self.log_continuation_told(session, turn, Cut::Takeover, told));
        let error = "the machine this turn ran on went away before the turn settled";
        let result = json!({
            "status": "failed", "detail": "outcome_unknown", "turnSeq": seq, "turnId": turn_id,
            "promptId": prompt_id, "trigger": trigger, "error": error, "errorText": error,
        });
        self.append_unknown_outcome(session, result);
        self.save_meta(session);
        continued
    }
}
