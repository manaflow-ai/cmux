//! Both ends of `cas/1`: what to ask for, how to answer, and what to keep.
//!
//! The asking side reads a manifest, computes [`want`] (its chunks the local store lacks) and
//! sends `WANT`; the answering side runs every message it reads through [`respond`] and writes
//! back what it returns; the asking side runs every `DATA` through [`accept`], which keeps a
//! chunk only under the id it hashes to. The flow is the one `cmux-session-pack`'s `ship.rs`
//! already used for a session ("the receiver states what it holds; each chunk is checked against
//! its id"), per chunk and on any stream.

use crate::Result;
use crate::id::{Id, IdScheme, hex};
use crate::manifest::Manifest;
use crate::store::ChunkStore;
use crate::wire::{Message, VERSION};

/// The chunks of `manifest` that `store` lacks, each once.
pub fn want(store: &dyn ChunkStore, manifest: &Manifest) -> Result<Vec<Id>> {
    Ok(manifest.chunk_ids()?.into_iter().filter(|id| !store.has(id)).collect())
}

/// What this end sends back for `message`, from `store`:
///
/// - `WANT`: a `DATA` for each id held, then one `NOPE` for the ids not held;
/// - a kind this build does not speak: `NOPE` naming that kind and this build's version, so the
///   newer sender falls back (lockstep);
/// - `HAVE`, `DATA`, `NOPE`: nothing (they are the asking side's to act on).
pub fn respond(store: &dyn ChunkStore, message: &Message) -> Result<Vec<Message>> {
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

/// Keeps a `DATA`'s chunk in `store` when its bytes hash to its id under `scheme`, and returns
/// the id; any other message is `None`. A chunk that does not hash to its id is an error: the
/// peer that sent it is lying or broken, and the caller drops it.
pub fn accept(store: &dyn ChunkStore, scheme: &IdScheme, message: &Message) -> Result<Option<Id>> {
    let Message::Data { id, bytes, .. } = message else { return Ok(None) };
    store
        .receive(scheme, id, bytes)
        .map_err(|e| format!("peer sent a bad chunk {}: {e}", hex(id)))?;
    Ok(Some(*id))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cdc::Params;
    use crate::cdc::tests::noise;
    use crate::store::MemStore;

    /// Fetches `manifest` from `server` into `client` over encoded frames; returns the payload
    /// bytes that crossed the wire.
    fn fetch(server: &MemStore, client: &MemStore, scheme: &IdScheme, manifest: &Manifest) -> u64 {
        let ids = want(client, manifest).unwrap();
        let mut moved = 0;
        for batch in ids.chunks(64) {
            let ask = Message::Want { version: VERSION, ids: batch.to_vec(), priority: 0 };
            let ask = Message::decode(&ask.encode().unwrap()).unwrap();
            for reply in respond(server, &ask).unwrap() {
                let body = reply.encode().unwrap();
                moved += body.len() as u64;
                accept(client, scheme, &Message::decode(&body).unwrap()).unwrap();
            }
        }
        moved
    }

    /// Two archive versions: the same 4 MiB middle between different heads and tails.
    fn versions() -> (Vec<u8>, Vec<u8>) {
        let middle = noise(100, 4 << 20);
        let v1 = [noise(101, 1 << 20), middle.clone(), noise(102, 1 << 20)].concat();
        let v2 = [noise(201, 1_300_000), middle, noise(202, 700_000)].concat();
        (v1, v2)
    }

    #[test]
    fn dedup_ratio_on_two_archive_versions() {
        let scheme = IdScheme::Public;
        let (v1, v2) = versions();
        let server = MemStore::new();
        let client = MemStore::new();
        let m1 = Manifest::build("archive", &scheme, &[("a", 0o644, &v1)], Params::CAS_V1, &server)
            .unwrap();
        let m2 = Manifest::build("archive", &scheme, &[("a", 0o644, &v2)], Params::CAS_V1, &server)
            .unwrap();
        // The client installs v1 whole, then updates to v2.
        fetch(&server, &client, &scheme, &m1);
        assert_eq!(m1.assemble(&client, &scheme).unwrap(), v1);
        let lacking = want(&client, &m2).unwrap();
        let lacking_bytes: u64 = m2
            .entries
            .iter()
            .flat_map(|e| &e.chunks)
            .filter(|(id, _)| lacking.contains(&crate::unhex(id).unwrap()))
            .map(|(_, len)| *len)
            .sum();
        let moved = fetch(&server, &client, &scheme, &m2);
        assert_eq!(m2.assemble(&client, &scheme).unwrap(), v2);
        let shared = v2.len() as u64 - lacking_bytes;
        let ratio = shared as f64 / v2.len() as f64;
        let middle_share = f64::from(4u32 << 20) / v2.len() as f64;
        eprintln!(
            "dedup: v2 {} bytes, {} chunks ({} lacking); {} bytes reused ({:.1} %, the shared middle is {:.1} %); {} bytes on the wire",
            v2.len(),
            m2.chunk_ids().unwrap().len(),
            lacking.len(),
            shared,
            ratio * 100.0,
            middle_share * 100.0,
            moved
        );
        // The shared middle is reused but for the chunk at each of its edges (at most 256 KiB
        // apiece), and only the new head and tail cross the wire.
        assert!(shared + (512 << 10) >= 4 << 20, "only {shared} bytes reused");
        assert!(moved < lacking_bytes + 4096 * lacking.len() as u64);
        assert!(moved < (v2.len() as u64) * 45 / 100, "{moved} bytes moved");
    }

    #[test]
    fn a_lying_peer_is_refused_and_a_missing_chunk_is_nope() {
        let scheme = IdScheme::Public;
        let client = MemStore::new();
        let id = scheme.id(b"real");
        let lie = Message::Data { version: VERSION, id, bytes: b"fake".to_vec() };
        assert!(accept(&client, &scheme, &lie).is_err());
        assert!(!client.has(&id));
        let server = MemStore::new();
        server.put(&scheme, b"real").unwrap();
        let absent = scheme.id(b"absent");
        let replies = respond(
            &server,
            &Message::Want { version: VERSION, ids: vec![id, absent], priority: 0 },
        )
        .unwrap();
        assert_eq!(replies.len(), 2);
        assert_eq!(accept(&client, &scheme, &replies[0]).unwrap(), Some(id));
        assert!(
            matches!(&replies[1], Message::Nope { ids, kind: None, .. } if *ids == vec![absent])
        );
    }

    #[test]
    fn keyed_stores_do_not_serve_each_other() {
        let bytes = noise(7, 50_000);
        let alice = IdScheme::Keyed([0xa1; 32]);
        let bob = IdScheme::Keyed([0xb0; 32]);
        let alice_store = MemStore::new();
        let m = Manifest::build(
            "attachment",
            &alice,
            &[("x.png", 0o644, &bytes)],
            Params::CAS_V1,
            &alice_store,
        )
        .unwrap();
        // Bob holds the same bytes under his key; none of Alice's ids are among his.
        let bob_store = MemStore::new();
        Manifest::build(
            "attachment",
            &bob,
            &[("x.png", 0o644, &bytes)],
            Params::CAS_V1,
            &bob_store,
        )
        .unwrap();
        assert_eq!(want(&bob_store, &m).unwrap(), m.chunk_ids().unwrap());
        // Asked for Alice's ids, Bob's store answers NOPE: no cross-user equality.
        let replies = respond(
            &bob_store,
            &Message::Want { version: VERSION, ids: m.chunk_ids().unwrap(), priority: 0 },
        )
        .unwrap();
        assert!(matches!(replies.as_slice(), [Message::Nope { .. }]));
        // And Alice's bytes sent as a public chunk do not verify under her key's id.
        let public_id = IdScheme::Public.id(&bytes);
        assert!(alice_store.receive(&alice, &public_id, &bytes).is_err());
    }
}
