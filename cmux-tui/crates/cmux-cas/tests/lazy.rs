use cmux_cas::lazy::{DirSource, Lazy, Node};
use cmux_cas::manifest::Manifest;
use cmux_cas::{Id, pack, store};
use std::collections::BTreeMap;
use std::sync::atomic::Ordering::Relaxed;

fn bytes(seed: u8, n: usize) -> Vec<u8> {
    let mut x = u32::from(seed) + 1;
    (0..n)
        .map(|_| {
            x = x.wrapping_mul(1664525).wrapping_add(1013904223);
            (x >> 24) as u8
        })
        .collect()
}

/// A tree published as one pack under `dir/packs`, and the lazy view of it on an empty store.
fn fixture(dir: &std::path::Path) -> (Lazy<DirSource>, BTreeMap<String, Vec<u8>>) {
    let mut files = BTreeMap::new();
    let mut raw = BTreeMap::new();
    for (i, p) in ["a/one.bin", "a/b/two.bin", "three.bin"].iter().enumerate() {
        let b = bytes(i as u8, 400_000 + i * 50_000);
        raw.insert((*p).to_owned(), b.clone());
        files.insert((*p).to_owned(), (b, i == 2));
    }
    let mut w = pack::Writer::default();
    let m = Manifest::build(&files, |id, piece| w.push(id, &store::encode(piece, 1)?)).unwrap();
    let (pack_bytes, idx) = w.finish();
    let packs = dir.join("packs");
    std::fs::create_dir_all(&packs).unwrap();
    std::fs::write(packs.join(format!("{}.pack", idx.pack.unwrap().hex())), &pack_bytes).unwrap();
    let src = DirSource { dir: packs, rtt: std::time::Duration::ZERO };
    (Lazy::new(m, vec![idx], store::Store::new(dir.join("store")), src), raw)
}

#[test]
fn list_and_stat_fetch_nothing() {
    let d = tempfile::tempdir().unwrap();
    let (l, raw) = fixture(d.path());
    let root: Vec<_> = l.list("").unwrap().into_iter().map(|e| e.name).collect();
    assert_eq!(root, ["a", "three.bin"]);
    assert_eq!(l.stat("a/b"), Some(Node::Dir));
    assert_eq!(
        l.stat("three.bin"),
        Some(Node::File { size: raw["three.bin"].len() as u64, exec: true })
    );
    assert_eq!(l.stat("nope"), None);
    assert_eq!(l.stats().requests.load(Relaxed), 0);
}

#[test]
fn read_fetches_only_covering_frames_and_matches() {
    let d = tempfile::tempdir().unwrap();
    let (l, raw) = fixture(d.path());
    let want = &raw["a/one.bin"];
    let got = l.read("a/one.bin", 1000, 5000).unwrap();
    assert_eq!(got, want[1000..6000]);
    assert!(l.stats().requests.load(Relaxed) >= 1);
    let after_first = l.stats().chunks.load(Relaxed);
    assert!((after_first as usize) < l.manifest().distinct_chunks().len());
    // the same bytes again move nothing
    let reqs = l.stats().requests.load(Relaxed);
    assert_eq!(l.read("a/one.bin", 1000, 5000).unwrap(), want[1000..6000]);
    assert_eq!(l.stats().requests.load(Relaxed), reqs);
    // past the end is short, not an error
    assert_eq!(l.read("a/one.bin", want.len() as u64 - 3, 10).unwrap(), want[want.len() - 3..]);
}

#[test]
fn prefetch_restores_everything_verified() {
    let d = tempfile::tempdir().unwrap();
    let (l, raw) = fixture(d.path());
    let mut cur = 0;
    while !l.prefetch(&mut cur, 64 << 10).unwrap() {}
    for (p, b) in &raw {
        l.verify(p).unwrap();
        assert_eq!(l.read(p, 0, u64::MAX).unwrap(), *b);
    }
}

#[test]
fn a_corrupt_pack_is_refused() {
    let d = tempfile::tempdir().unwrap();
    let (l, _) = fixture(d.path());
    let packs = d.path().join("packs");
    for e in std::fs::read_dir(&packs).unwrap() {
        let p = e.unwrap().path();
        let mut b = std::fs::read(&p).unwrap();
        for x in b.iter_mut().step_by(97) {
            *x ^= 0xff;
        }
        std::fs::write(&p, b).unwrap();
    }
    assert!(l.read("a/one.bin", 0, 100).is_err());
    assert!(!l.manifest().files.is_empty());
    let _ = Id::of(b"");
}
