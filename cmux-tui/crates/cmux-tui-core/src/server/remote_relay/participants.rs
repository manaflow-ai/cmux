//! The system-only participant path of a paired install
//! (server-remote-conversations.md section 5, `participants.add_system`).
//! Only the daemon's own pairing path calls it: no client request reaches
//! it, and the local and agent handlers refuse every `remote_` participant
//! id, so no token, bind or op can create or impersonate a device.

use cmux_conversation::{Op, Participant, ParticipantKind};

use std::sync::Arc;

#[cfg(test)]
use super::super::conversations::commit_op;
use super::super::{Mux, MuxEvent};
use crate::conversation_store::{ConversationEvent, LOCAL_USER};
use crate::remote_relay_state::remote_participant;

/// The device participant of `install`: a human that is the same person as
/// the server's own user (decisions D-B, D-C).
fn device(install: &str, display_name: &str) -> Participant {
    Participant {
        id: remote_participant(install),
        kind: ParticipantKind::Human,
        display_name: display_name.to_string(),
        agent_class: None,
        acp_session: None,
        person: Some(LOCAL_USER.to_string()),
    }
}

impl Mux {
    /// `participants.add_system` for one conversation: add the device
    /// participant of `install` and publish the change. Idempotent per
    /// conversation and install. Tests place a device in one conversation
    /// with it; pairing uses [`Mux::pair_remote_install`].
    #[cfg(test)]
    pub(crate) fn add_remote_participant_system(
        &self,
        conversation: &str,
        install: &str,
        display_name: &str,
    ) -> anyhow::Result<()> {
        let op = Op::ParticipantsAdd { participant: device(install, display_name) };
        let key = format!("system-pair-{install}");
        commit_op(self, conversation, &key, LOCAL_USER, &op, &None)?;
        Ok(())
    }

    /// Pairing: add the device of `install` to every conversation of the
    /// server's own user that does not list it yet, in one transaction: all
    /// of them join or none does (no half-applied pairing). Returns how many
    /// conversations it joined.
    pub fn pair_remote_install(&self, install: &str, display_name: &str) -> anyhow::Result<usize> {
        let participant = remote_participant(install);
        let key = format!("system-pair-{install}");
        let outcomes = self.conversation_write_many(
            |store| {
                let mut ops = Vec::new();
                for summary in store.list()? {
                    let ids: Vec<&str> =
                        summary.participants.iter().map(|p| p.id.as_str()).collect();
                    if ids.contains(&LOCAL_USER) && !ids.contains(&participant.as_str()) {
                        let op = Op::ParticipantsAdd { participant: device(install, display_name) };
                        ops.push((summary.id, key.clone(), LOCAL_USER.to_string(), op));
                    }
                }
                let outcomes = store.apply_ops_atomically(&ops)?;
                Ok(ops.into_iter().map(|(id, ..)| id).zip(outcomes).collect::<Vec<_>>())
            },
            |outcomes| {
                outcomes
                    .iter()
                    .filter(|(_, outcome)| !outcome.replayed)
                    .map(|(conversation, outcome)| {
                        MuxEvent::Conversation(Arc::new(ConversationEvent::Changed {
                            conversation: conversation.clone(),
                            rev: outcome.result.rev,
                            transaction: None,
                            change: outcome.result.change.clone(),
                        }))
                    })
                    .collect()
            },
        )?;
        Ok(outcomes.len())
    }
}

/// True for an id only the system path may create (`remote_<install>`).
pub(in crate::server) fn is_device_id(id: &str) -> bool {
    id.starts_with("remote_")
}

/// The reject for a client that names a device participant.
pub(in crate::server) fn device_id_refused() -> anyhow::Error {
    crate::conversation_store::ConversationRejected(cmux_conversation::Reject::InvalidParticipant)
        .into()
}
