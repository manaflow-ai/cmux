//! The system-only participant path of a paired install
//! (server-remote-conversations.md section 5, `participants.add_system`).
//! Only the daemon's own pairing path calls it: no client request reaches
//! it, and the local and agent handlers refuse every `remote_` participant
//! id, so no token, bind or op can create or impersonate a device.

use cmux_conversation::{Op, Participant, ParticipantKind};

use super::super::conversations::commit_op;
use super::super::Mux;
use crate::conversation_store::LOCAL_USER;
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
    /// conversation and install.
    pub(crate) fn add_remote_participant_system(
        &self,
        conversation: &str,
        install: &str,
        display_name: &str,
    ) -> anyhow::Result<()> {
        let _ = (conversation, install, display_name);
        unimplemented!("red: server-remote-conversations.md policy not implemented yet")
    }

    /// Pairing: add the device of `install` to every conversation of the
    /// server's own user that does not list it yet. Returns how many
    /// conversations it joined.
    pub fn pair_remote_install(&self, install: &str, display_name: &str) -> anyhow::Result<usize> {
        let _ = (install, display_name);
        unimplemented!("red: server-remote-conversations.md policy not implemented yet")
    }
}

/// True for an id only the system path may create (`remote_<install>`).
pub(in crate::server) fn is_device_id(id: &str) -> bool {
        let _ = id;
        false
    }

/// The reject for a client that names a device participant.
pub(in crate::server) fn device_id_refused() -> anyhow::Error {
    crate::conversation_store::ConversationRejected(cmux_conversation::Reject::InvalidParticipant)
        .into()
}
