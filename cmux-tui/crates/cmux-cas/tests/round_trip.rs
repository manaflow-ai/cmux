//! A client holding build N-1 fetches only what N added, from a pack by Range GETs, assembles N
//! bit-exact, and opens the signed pointer naming it.

use base64::Engine as _;
use cmux_cas::manifest::Manifest;
use cmux_cas::{Store, assemble, pack, plan, pointer, store};
use ring::signature::{Ed25519KeyPair, KeyPair as _};
use std::collections::BTreeMap;

fn noise(n: usize, seed: u64) -> Vec<u8> {
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

#[test]
fn update_moves_only_the_change_and_assembles_bit_exact() {
    let producer = tempfile::tempdir().unwrap();
    let pstore = Store::new(producer.path());
    let mut v1 = BTreeMap::new();
    v1.insert("assets/app-1.js".to_owned(), (noise(3 << 20, 1), false));
    v1.insert("assets/vendor.js".to_owned(), (noise(2 << 20, 2), false));
    v1.insert("index.html".to_owned(), (b"<html>1</html>".to_vec(), false));
    let mut v2 = v1.clone();
    let mut app = v1["assets/app-1.js"].0.clone();
    app.splice(1 << 20..1 << 20, noise(4000, 9));
    v2.remove("assets/app-1.js");
    v2.insert("assets/app-2.js".to_owned(), (app, false));
    v2.insert("index.html".to_owned(), (b"<html>2</html>".to_vec(), false));
    let put = |id, b: &[u8]| pstore.put(&id, b);
    let m1 = Manifest::build(&v1, put).unwrap();
    let m2 = Manifest::build(&v2, put).unwrap();

    // The client holds v1's chunks.
    let client = tempfile::tempdir().unwrap();
    let cstore = Store::new(client.path().join("chunks"));
    for c in m1.distinct_chunks() {
        cstore.put(&c.id, &pstore.get(&c.id).unwrap()).unwrap();
    }

    let want = plan::want(&m2, |id| cstore.has(id));
    let want_bytes: u64 = want.iter().map(|c| u64::from(c.len)).sum();
    assert!(want_bytes * 10 < m2.size(), "{want_bytes} of {}", m2.size());

    let (pack_bytes, index) = pack::write(&pstore, &m2.distinct_chunks()).unwrap();
    let (ranges, missing) = pack::ranges(&[index], &want, pack::GAP);
    assert!(missing.is_empty());
    let read: u64 = ranges.iter().map(pack::Range::len).sum();
    assert!(read * 5 < pack_bytes.len() as u64, "{read} of {}", pack_bytes.len());
    for r in &ranges {
        let bytes = &pack_bytes[usize::try_from(r.start).unwrap()..usize::try_from(r.end).unwrap()];
        pack::receive(&cstore, r, bytes).unwrap();
    }

    let out = client.path().join("tree");
    assemble::assemble(&cstore, &m2, &out).unwrap();
    for (path, (bytes, _)) in &v2 {
        assert_eq!(&std::fs::read(out.join(path)).unwrap(), bytes, "{path}");
    }
    let bytes = m2.to_bytes().unwrap();
    assert_eq!(Manifest::from_bytes(&bytes, &m2.id().unwrap()).unwrap(), m2);
    assert!(Manifest::from_bytes(&bytes, &m1.id().unwrap()).is_err());

    // A tampered chunk is refused.
    let mut bad = store::encode(b"hello", 3).unwrap();
    *bad.last_mut().unwrap() ^= 1;
    assert!(cstore.receive(&cmux_cas::Id::of(b"hello"), &bad).is_err());

    // The signed pointer.
    let rng = ring::rand::SystemRandom::new();
    let pkcs8 = Ed25519KeyPair::generate_pkcs8(&rng).unwrap();
    let kp = Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap();
    let raw: [u8; 32] = kp.public_key().as_ref().try_into().unwrap();
    let kid = cmux_signed_envelope::key_id(&raw);
    let p = pointer::Pointer {
        purpose: pointer::PURPOSE.to_owned(),
        channel: "web/every-merge".to_owned(),
        manifest: m2.id().unwrap(),
        packs: vec![],
        sequence: 2,
    };
    let payload = serde_json::to_vec(&p).unwrap();
    let b64 = base64::engine::general_purpose::STANDARD;
    let env = serde_json::json!({"schema": 1, "payload": b64.encode(&payload),
        "signatures": [{"key_id": kid, "sig": b64.encode(kp.sign(&payload).as_ref())}]});
    let body = serde_json::to_vec(&env).unwrap();
    let keys = vec![(kid, raw)];
    assert_eq!(pointer::open(&body, &keys, "web/every-merge").unwrap(), p);
    assert!(pointer::open(&body, &keys, "web/nightly").is_err());
    assert!(pointer::open(&body, &[], "web/every-merge").is_err());
}

#[test]
fn hostile_paths_are_refused() {
    for path in ["../x", "/etc/passwd", "a//b", "a/./b", "a\\b"] {
        let mut t = BTreeMap::new();
        t.insert(path.to_owned(), (b"x".to_vec(), false));
        assert!(Manifest::build(&t, |_, _| Ok(())).is_err(), "{path}");
    }
}
