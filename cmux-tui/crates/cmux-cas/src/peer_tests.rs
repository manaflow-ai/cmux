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
    let replies =
        respond(&server, &Message::Want { version: VERSION, ids: vec![id, absent], priority: 0 })
            .unwrap();
    assert_eq!(replies.len(), 2);
    assert_eq!(accept(&client, &replies[0]).unwrap(), Some(id));
    assert!(matches!(&replies[1], Message::Nope { ids, kind: None, .. } if *ids == vec![absent]));
}
