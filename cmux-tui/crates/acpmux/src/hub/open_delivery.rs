//! Part of `Hub`; see `hub/mod.rs`. A message a peer's session took, from its acceptance until
//! nothing can lose it (review of #37284, sixth round: "make the copy the only proof").
//!
//! - Pinned: the attempt reads the peer's session (its id, its generation `createdAt`, the link)
//!   before it starts ([`pin`]) and names that generation in the request ([`name_generation`]);
//!   the answer is recorded against that pin and nothing read after it ([`accepted`]). A session
//!   purged and made again under the same id refuses it as stale.
//! - Open: an accepted message to a peer's session stays open (`Delivery::open_on_peer`): the
//!   machine may lose it with its disk (a VM back on an older snapshot, a session moved to a
//!   fresh machine). "Accepted" and "duplicate" only say the peer saw it; neither survives a
//!   restart from an older disk.
//! - Closed: only when the owner's own copy of the pinned session and generation holds the
//!   message's journal record (`queued` or `user_message` naming its prompt id) on disk
//!   ([`names_prompt`]; `peer_snapshot.rs` reports each copy's prompts once written, and a link's
//!   redelivery asks first). The copy goes back to any machine that lacks it
//!   (`peer_snapshot/restore.rs`), so from then on the machine cannot lose it.
//! - Delivered again on every link of the peer while open, under its own prompt id and pinned
//!   generation (`server/outbox.rs` `redeliver_open`): a machine that has it answers with its
//!   first outcome and nothing runs twice; a stale or refused one fails it, with the reason.
//! - Lapsed: open past `outbox::OPEN_ON_PEER_FOR_MS` it fails, saying so; never a quiet drop.

use super::Hub;
use super::outbox::{Delivery, Pin, State};
use serde_json::{Value, json};

/// The peer's session `target` names, as it is now: None for a session of this daemon, or one
/// no peer lists.
pub(crate) fn pin(hub: &Hub, target: &str) -> Option<Pin> {
    if hub.resolve(target).is_ok() {
        return None;
    }
    let (peer, session, row) = hub.resolve_remote(target)?;
    let generation = row.get("createdAt").and_then(Value::as_u64)?;
    Some(Pin {
        peer: peer.name.clone(),
        session,
        generation,
        link: (peer.generation, peer.link_epoch()),
    })
}

/// Names the pinned generation in `request` (`_meta.acpmux.sessionCreatedAt`).
pub(crate) fn name_generation(request: &mut Value, pin: Option<&Pin>) {
    let Some(pin) = pin else { return };
    if let Some(mux) = request.pointer_mut("/_meta/acpmux").and_then(Value::as_object_mut) {
        mux.insert("sessionCreatedAt".into(), json!(pin.generation));
    }
}

/// An attempt that started with `pin` was accepted: delivered, and open on the peer when it
/// went to a peer's session, whatever the answer (a duplicate too).
pub(crate) fn accepted(d: &mut Delivery, pin: Option<Pin>, answer: Value) {
    d.state = State::Delivered;
    d.open_on_peer = pin.is_some();
    d.pin = pin;
    d.error = None;
    d.accepted = Some(answer);
}

/// Whether `record` is the journal record of prompt `prompt_id`: it waits, or it ran.
pub(crate) fn names_prompt(record: &Value, prompt_id: &str) -> bool {
    !prompt_id.is_empty()
        && matches!(record.get("kind").and_then(Value::as_str), Some("queued" | "user_message"))
        && record.pointer("/msg/promptId").and_then(Value::as_str) == Some(prompt_id)
}

/// What a delivery again was answered.
pub(crate) enum Again {
    /// Taken (run now, or answered with its first outcome).
    Taken(Value),
    /// Refused for good: the session is gone there, or is another generation of it.
    Refused(String),
    /// Not answered (the link, a timeout): tried on the next link.
    Unknown,
}

/// A delivery again of open `d` was answered `again`: it stays open (only the copy closes it),
/// or fails, saying why. Answers whether it settled.
pub(crate) fn after_again(d: &mut Delivery, again: Again) -> bool {
    match again {
        Again::Taken(answer) => {
            d.accepted = Some(answer);
            false
        }
        Again::Refused(error) => {
            d.fail_open(error);
            true
        }
        Again::Unknown => false,
    }
}

/// The owner's copy of `d`'s pinned session holds its record (`held`): closed. Answers whether
/// it closed.
pub(crate) fn close_if_held(d: &mut Delivery, held: bool) -> bool {
    if !d.open_on_peer || !held {
        return false;
    }
    d.open_on_peer = false;
    true
}

impl Hub {
    /// The owner's copy of peer `peer`'s session `session`, generation `generation`, now holds
    /// `prompts`' journal records on disk: each one's open delivery closes. Called on the copies'
    /// thread after the write (`peer_snapshot.rs`); blocks only on the outbox's own write.
    pub(crate) fn close_captured(
        &self,
        peer: &str,
        session: &str,
        generation: u64,
        prompts: &[String],
    ) {
        for d in self.outbox.open_on_peers() {
            let pinned = d.pin.as_ref().is_some_and(|p| {
                (p.peer.as_str(), p.session.as_str(), p.generation) == (peer, session, generation)
            });
            if !pinned || !prompts.iter().any(|p| p == d.prompt_id()) {
                continue;
            }
            let path = self.outbox.attachments_path(&d);
            self.outbox.update(&d.id, |d| {
                if close_if_held(d, true) {
                    crate::attach::strip(&mut d.request);
                }
            });
            if let Some(path) = path {
                let _ = std::fs::remove_file(path);
            }
        }
    }
}
