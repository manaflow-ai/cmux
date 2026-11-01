//! The person takes over a chat its manager runs (agent pane: "Chief is managing this chat",
//! Take over). `_acpmux/agent_hold {sessionId, held: true}` tags the chat [`HOLD_TAG`]; from then
//! on every message its manager sends it is held by the pair guard (`agent_pairs.rs`), as a pause
//! with reason `taken_over`, kept through a restart in both logs. The person's own prompts into
//! the chat go in as usual and release nothing. `held: false` (Hand back) removes the tag and
//! delivers what was held, in order.
//!
//! A chat's manager is the session that started it (its sub-session parent, `startedBy`, or
//! lineage parent, `spawnedBy`), the session that first gave it work (`delegator`), or, for a
//! chat a Chief started (`mux.parent` = `optchat-chief[:<home>]`), any turn of that Chief
//! (`cmux.chief` = `<home>`). Messages from other agents pass as before.
//!
//! Only the person sets or clears the hold: the method is the person's on this machine
//! (`server/agent_messages.rs`), and `_acpmux/tag` refuses the tag to anyone else
//! (`person.rs`), so a manager cannot lift its own hold.

use super::*;

/// The tag on a chat the person took over.
pub const HOLD_TAG: &str = "acpmux.agentHold";
/// The tag a Chief's turn sessions carry, valued with the Chief's home id
/// (optchat-chief `acpmux.rs` `CHIEF_TAG`).
const CHIEF_TAG: &str = "cmux.chief";
/// The tag on every session a Chief started (cmux_chief::rules::PARENT_TAG).
const CHIEF_PARENT_TAG: &str = "mux.parent";
const CHIEF_PARENT: &str = "optchat-chief";

/// Who manages a chat, read from its meta.
struct Managers {
    sessions: Vec<String>,
    /// A Chief started it: `Some(home)`, or `Some(None)` for a parent tag naming no home.
    chief: Option<Option<String>>,
}

fn managers(meta: &crate::store::SessionMeta) -> Managers {
    let mut sessions = Vec::new();
    sessions.extend(meta.subsession.as_ref().map(|l| l.started_by.clone()));
    sessions.extend(meta.lineage.as_ref().map(|l| l.parent.clone()));
    sessions.extend(meta.delegator.clone());
    let chief = meta.tags.get(CHIEF_PARENT_TAG).and_then(|t| {
        let rest = t.value.strip_prefix(CHIEF_PARENT)?;
        if rest.is_empty() {
            Some(None)
        } else {
            rest.strip_prefix(':').map(|home| Some(home.to_owned()))
        }
    });
    Managers { sessions, chief }
}

impl Hub {
    /// Whether the person took over `session`.
    pub(crate) fn agent_held(session: &Session) -> bool {
        session
            .meta
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .tags
            .contains_key(HOLD_TAG)
    }

    /// Whether `sender` manages `receiver` (see the module docs).
    pub(crate) fn manages(sender: &Session, receiver: &Session) -> bool {
        let Managers { sessions, chief } =
            managers(&receiver.meta.lock().unwrap_or_else(std::sync::PoisonError::into_inner));
        if sessions.contains(&sender.id) {
            return true;
        }
        let Some(home) = chief else { return false };
        let sender_home = sender
            .meta
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .tags
            .get(CHIEF_TAG)
            .map(|t| t.value.clone());
        match (home, sender_home) {
            (_, None) => false,
            (None, Some(_)) => true,
            (Some(home), Some(sender_home)) => home == sender_home,
        }
    }

    /// Whether a message from `sender` into `receiver` waits for the person: the person took
    /// `receiver` over and `sender` manages it.
    pub(crate) fn held_for_person(sender: &Session, receiver: &Session) -> bool {
        Self::agent_held(receiver) && Self::manages(sender, receiver)
    }

    /// `_acpmux/agent_hold {sessionId, held}`: the person takes `session` over (`held`), or hands
    /// it back, which delivers its managers' held messages, in order.
    pub fn agent_hold(
        self: &Arc<Self>,
        session: &Arc<Session>,
        held: bool,
    ) -> Result<Value, RpcError> {
        let was = Self::agent_held(session);
        if held {
            let mut set = serde_json::Map::new();
            set.insert(HOLD_TAG.to_owned(), json!("person"));
            self.set_tags(session, Some(&set), &[], None);
        } else {
            self.set_tags(session, None, &[HOLD_TAG.to_owned()], None);
        }
        if was != held {
            self.append(session, "mux", "agent_hold", json!({"held": held}));
        }
        let (resumed, delivered) =
            if held { (0, 0) } else { self.agent_pair_resume_inner(&session.id, None, "handback") };
        Ok(
            json!({"sessionId": session.id, "held": held, "resumed": resumed, "delivered": delivered}),
        )
    }
}
