//! Both ends of a `cas/1` [`wire`](crate::wire) link: what to ask for, how to answer, and what to
//! keep.
//!
//! The asking side reads a manifest, computes [`want`] (its chunks the local [`Store`] lacks,
//! [`plan::want`]) and sends `WANT`; the answering side runs every message it reads through
//! [`respond`] and writes back what it returns; the asking side runs every `DATA` through
//! [`accept`], which keeps a chunk only under the id it hashes to. This is the peer path beside
//! the R2 pack floor ([`pack`](crate::pack)): the same chunks, the same check, any byte stream.

use crate::manifest::Manifest;
use crate::wire::{Message, VERSION};
use crate::{Id, Result, Store, plan};

/// The chunks of `manifest` that `store` lacks, each once, in first-appearance order.
pub fn want(store: &Store, manifest: &Manifest) -> Vec<Id> {
    plan::want(manifest, |id| store.has(id)).into_iter().map(|c| c.id).collect()
}

/// What this end sends back for `message`, from `store`:
///
/// - `WANT`: a `DATA` for each id held, then one `NOPE` for the ids not held;
/// - a kind this build does not speak: `NOPE` naming that kind and this build's version, so the
///   newer sender falls back (lockstep);
/// - `HAVE`, `DATA`, `NOPE`: nothing (they are the asking side's to act on).
pub fn respond(store: &Store, message: &Message) -> Result<Vec<Message>> {
    Ok(match message {
        Message::Want { ids, .. } => {
            let mut out = Vec::with_capacity(ids.len());
            let mut lacking = Vec::new();
            for id in ids {
                if store.has(id) {
                    out.push(Message::Data { version: VERSION, id: *id, bytes: store.get(id)? });
                } else {
                    lacking.push(*id);
                }
            }
            if !lacking.is_empty() {
                out.push(Message::Nope {
                    version: VERSION,
                    ids: lacking,
                    kind: None,
                    reason: String::new(),
                });
            }
            out
        }
        Message::Unknown { version, kind } => vec![Message::Nope {
            version: VERSION,
            ids: Vec::new(),
            kind: Some(*kind),
            reason: format!(
                "cas/{VERSION} does not speak message kind {kind} (from cas/{version})"
            ),
        }],
        Message::Have { .. } | Message::Data { .. } | Message::Nope { .. } => Vec::new(),
    })
}

/// Keeps a `DATA`'s chunk in `store` when its bytes hash to its id, and returns the id; any other
/// message is `None`. A chunk that does not hash to its id is an error: the peer that sent it is
/// lying or broken, and the caller drops it.
pub fn accept(store: &Store, message: &Message) -> Result<Option<Id>> {
    let Message::Data { id, bytes, .. } = message else { return Ok(None) };
    store.put(id, bytes).map_err(|e| format!("peer sent a bad chunk {id}: {e}"))?;
    Ok(Some(*id))
}

#[cfg(test)]
#[path = "peer_tests.rs"]
mod tests;
