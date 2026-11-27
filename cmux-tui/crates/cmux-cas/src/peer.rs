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
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn noise(seed: u64, n: usize) -> Vec<u8> {
        let mut s = seed | 1;
        (0..n)
            .map(|_| {
                s ^= s << 13;
                s ^= s >> 7;
                s ^= s << 17;
                s as u8
            })
            .collect()
    }

    /// Fetches `manifest` from `server` into `client` over encoded frames; returns the frame
    /// bytes that crossed the wire.
    fn fetch(server: &Store, client: &Store, manifest: &Manifest) -> u64 {
        let ids = want(client, manifest);
        let mut moved = 0;
        for batch in ids.chunks(64) {
            let ask = Message::Want { version: VERSION, ids: batch.to_vec(), priority: 0 };
            let ask = Message::decode(&ask.encode().unwrap()).unwrap();
            for reply in respond(server, &ask).unwrap() {
                let body = reply.encode().unwrap();
                moved += body.len() as u64;
                accept(client, &Message::decode(&body).unwrap()).unwrap();
            }
        }
        moved
    }

    fn tree(bytes: Vec<u8>) -> BTreeMap<String, (Vec<u8>, bool)> {
        BTreeMap::from([("archive".to_owned(), (bytes, false))])
    }

    #[test]
    fn an_update_over_the_wire_moves_only_the_new_chunks() {
        let (s, c) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let (server, client) = (Store::new(s.path()), Store::new(c.path()));
        // Two archive versions: the same 4 MiB middle between different heads and tails.
        let middle = noise(100, 4 << 20);
        let v1 = [noise(101, 1 << 20), middle.clone(), noise(102, 1 << 20)].concat();
        let v2 = [noise(201, 1_300_000), middle, noise(202, 700_000)].concat();
        let put = |id, b: &[u8]| server.put(&id, b);
        let m1 = Manifest::build(&tree(v1), put).unwrap();
        let m2 = Manifest::build(&tree(v2.clone()), put).unwrap();
        // The client installs v1 whole, then updates to v2.
        fetch(&server, &client, &m1);
        let lacking = plan::want(&m2, |id| client.has(id));
        let lacking_bytes: u64 = lacking.iter().map(|c| u64::from(c.len)).sum();
        let moved = fetch(&server, &client, &m2);
        assert!(want(&client, &m2).is_empty());
        let shared = v2.len() as u64 - lacking_bytes;
        eprintln!(
            "peer: v2 {} bytes, {} chunks ({} lacking); {shared} bytes reused; {moved} bytes on the wire",
            v2.len(),
            m2.distinct_chunks().len(),
            lacking.len(),
        );
        // The shared middle is reused but for the chunk at each of its edges (at most 256 KiB
        // apiece); only the new head and tail cross the wire, plus a few bytes of framing each.
        assert!(shared + (512 << 10) >= 4 << 20, "only {shared} bytes reused");
        assert!(moved < lacking_bytes + 64 * lacking.len() as u64);
        assert!(moved < (v2.len() as u64) * 45 / 100, "{moved} bytes moved");
    }

    #[test]
    fn a_lying_peer_is_refused_and_a_missing_chunk_is_nope() {
        let (s, c) = (tempfile::tempdir().unwrap(), tempfile::tempdir().unwrap());
        let (server, client) = (Store::new(s.path()), Store::new(c.path()));
        let id = Id::of(b"real");
        let lie = Message::Data { version: VERSION, id, bytes: b"fake".to_vec() };
        assert!(accept(&client, &lie).is_err());
        assert!(!client.has(&id));
        server.put(&id, b"real").unwrap();
        let absent = Id::of(b"absent");
        let replies = respond(
            &server,
            &Message::Want { version: VERSION, ids: vec![id, absent], priority: 0 },
        )
        .unwrap();
        assert_eq!(replies.len(), 2);
        assert_eq!(accept(&client, &replies[0]).unwrap(), Some(id));
        assert!(
            matches!(&replies[1], Message::Nope { ids, kind: None, .. } if *ids == vec![absent])
        );
    }
}
