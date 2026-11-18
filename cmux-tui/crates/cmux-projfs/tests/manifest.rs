//! Manifest building, encoding, hostile decoding and deltas.

use cmux_projfs::manifest::{FORMAT_VERSION, MAGIC, ROOT};
use cmux_projfs::{Builder, Delta, Kind, Manifest, ManifestError, Stat};

const T: i64 = 1_700_000_000_123_456_789;

fn sample() -> Manifest {
    let mut b = Builder::new("/Users/me/proj");
    // Deliberately out of order: children before parents.
    b.add("src/main.rs", Stat::file(0o644, 120, T, T + 1)).unwrap();
    b.add("README.md", Stat::file(0o644, 10, T, T)).unwrap();
    b.add("src/lib/mod.rs", Stat::file(0o600, 7, T, T)).unwrap();
    b.add("src", Stat::dir(0o755, T, T)).unwrap();
    b.add("src/lib", Stat::dir(0o700, T, T)).unwrap();
    b.add("link", Stat::symlink("src/main.rs", T, T)).unwrap();
    let mut secret = Stat::file(0o600, 33, T, T);
    secret.withheld = true;
    b.add("certs.key", secret).unwrap();
    let mut hashed = Stat::file(0o644, 5, T, T);
    hashed.hash = Some([7u8; 32]);
    b.add("src/hashed.txt", hashed).unwrap();
    b.add("empty", Stat::dir(0o755, T, T)).unwrap();
    b.add_skipped(4);
    b.build().unwrap()
}

#[test]
fn builder_indexes_paths_parent_first_with_sorted_children() {
    let m = sample();
    assert_eq!(m.len(), 10);
    assert_eq!(m.root_label(), "/Users/me/proj");
    assert_eq!(m.skipped(), 4);
    let names: Vec<&str> = m.children(ROOT).map(|i| m.entry(i).unwrap().name.as_str()).collect();
    assert_eq!(names, ["README.md", "certs.key", "empty", "link", "src"]);
    for (i, e) in m.entries().iter().enumerate().skip(1) {
        assert!((e.parent as usize) < i, "parent before child");
    }
    let main = m.resolve("src/main.rs").unwrap();
    assert_eq!(m.path_of(main).unwrap(), "src/main.rs");
    assert_eq!(m.entry(main).unwrap().stat.ctime_ns, T + 1);
    let deep = m.resolve("src/lib/mod.rs").unwrap();
    assert_eq!(m.entry(deep).unwrap().stat.mode, 0o600);
    assert_eq!(m.lookup(m.resolve("src").unwrap(), "lib"), m.resolve("src/lib"));
    assert_eq!(m.resolve(""), Some(ROOT));
    assert_eq!(m.resolve("src/nope"), None);
    assert_eq!(m.resolve("../x"), None);
    assert_eq!(m.total_bytes(), 120 + 10 + 7 + 33 + 5);
    assert!(m.entry(m.resolve("certs.key").unwrap()).unwrap().stat.withheld);
    assert_eq!(m.entry(m.resolve("link").unwrap()).unwrap().stat.kind, Kind::Symlink);
}

#[test]
fn encode_decode_round_trip() {
    let mut m = sample();
    m.apply_delta("README.md", Delta::Gone).unwrap();
    let bytes = m.encode().unwrap();
    assert_eq!(&bytes[..4], &MAGIC);
    let back = Manifest::decode(&bytes).unwrap();
    assert_eq!(back, m);
    assert_eq!(back.resolve("README.md"), None, "gone survives the round trip");
    assert_eq!(
        back.entry(back.resolve("src/hashed.txt").unwrap()).unwrap().stat.hash,
        Some([7u8; 32])
    );
}

#[test]
fn builder_rejects_bad_paths_duplicates_and_orphans() {
    let f = || Stat::file(0o644, 1, T, T);
    let mut b = Builder::new("x");
    for bad in ["/abs", "a/../b", "..", ".", "a//b", "a/", "", "a\0b", &"n".repeat(256)] {
        assert!(matches!(b.add(bad, f()), Err(ManifestError::BadPath { .. })), "{bad:?} accepted");
    }
    b.add("a", f()).unwrap();
    assert_eq!(b.add("a", f()), Err(ManifestError::Duplicate("a".into())));
    let mut bad_link = f();
    bad_link.link = Some("x".into());
    assert!(matches!(b.add("l", bad_link), Err(ManifestError::BadStat { .. })));
    let mut no_link = Stat::symlink("t", T, T);
    no_link.link = None;
    assert!(matches!(b.add("l2", no_link), Err(ManifestError::BadStat { .. })));
    assert!(b.root_stat(f()).is_err());

    let mut orphan = Builder::new("x");
    orphan.add("dir/file", f()).unwrap();
    assert_eq!(orphan.build(), Err(ManifestError::MissingParent("dir/file".into())));

    let mut under_file = Builder::new("x");
    under_file.add("file", f()).unwrap();
    under_file.add("file/child", f()).unwrap();
    assert_eq!(under_file.build(), Err(ManifestError::MissingParent("file/child".into())));
}

#[test]
fn decode_refuses_newer_versions_and_garbage() {
    let good = sample().encode().unwrap();
    let mut newer = good.clone();
    newer[4..6].copy_from_slice(&(FORMAT_VERSION + 1).to_le_bytes());
    assert_eq!(
        Manifest::decode(&newer),
        Err(ManifestError::NewerVersion { found: FORMAT_VERSION + 1, supported: FORMAT_VERSION })
    );
    assert_eq!(Manifest::decode(b""), Err(ManifestError::NotAManifest));
    assert_eq!(Manifest::decode(b"JUNKJUNK"), Err(ManifestError::NotAManifest));
    for cut in [5, 6, 7, good.len() / 2, good.len() - 1] {
        assert!(Manifest::decode(&good[..cut]).is_err(), "truncated at {cut} decoded");
    }
}

/// Encodes a raw body (bypassing the encoder's own guarantees) as a manifest.
fn wrap(body: &[u8]) -> Vec<u8> {
    let mut out = MAGIC.to_vec();
    out.extend_from_slice(&FORMAT_VERSION.to_le_bytes());
    out.extend_from_slice(&zstd::stream::encode_all(body, 1).unwrap());
    out
}

fn raw_entry(out: &mut Vec<u8>, name: &str, parent: u32, kind: u8) {
    out.extend_from_slice(&(name.len() as u32).to_le_bytes());
    out.extend_from_slice(name.as_bytes());
    out.extend_from_slice(&parent.to_le_bytes());
    out.push(kind);
    out.push(0);
    out.extend_from_slice(&0o644u32.to_le_bytes());
    out.extend_from_slice(&0u64.to_le_bytes());
    out.extend_from_slice(&0i64.to_le_bytes());
    out.extend_from_slice(&0i64.to_le_bytes());
}

fn raw_body(entries: &[(&str, u32, u8)], claimed_count: u32) -> Vec<u8> {
    let mut b = Vec::new();
    b.extend_from_slice(&0u32.to_le_bytes());
    b.extend_from_slice(&0u64.to_le_bytes());
    b.extend_from_slice(&claimed_count.to_le_bytes());
    for (name, parent, kind) in entries {
        raw_entry(&mut b, name, *parent, *kind);
    }
    b
}

#[test]
fn decode_rejects_out_of_range_and_inconsistent_trees() {
    let ok = raw_body(&[("", 0, 1), ("a", 0, 0)], 2);
    assert!(Manifest::decode(&wrap(&ok)).is_ok());
    let cases: [(&str, Vec<u8>); 8] = [
        ("parent out of range", raw_body(&[("", 0, 1), ("a", 9, 0)], 2)),
        ("parent after child", raw_body(&[("", 0, 1), ("a", 2, 0), ("d", 0, 1)], 3)),
        ("parent is a file", raw_body(&[("", 0, 1), ("f", 0, 0), ("x", 1, 0)], 3)),
        ("unsorted siblings", raw_body(&[("", 0, 1), ("b", 0, 0), ("a", 0, 0)], 3)),
        ("duplicate siblings", raw_body(&[("", 0, 1), ("a", 0, 0), ("a", 0, 0)], 3)),
        ("count beyond body", raw_body(&[("", 0, 1)], 1_000_000)),
        ("root not a dir", raw_body(&[("", 0, 0)], 1)),
        ("bad name", raw_body(&[("", 0, 1), ("..", 0, 0)], 2)),
    ];
    for (what, body) in cases {
        assert!(Manifest::decode(&wrap(&body)).is_err(), "{what} decoded");
    }
    let split =
        raw_body(&[("", 0, 1), ("d", 0, 1), ("e", 0, 1), ("x", 1, 0), ("y", 2, 0), ("z", 1, 0)], 6);
    assert!(Manifest::decode(&wrap(&split)).is_err(), "non-contiguous children decoded");
    let mut trailing = ok;
    trailing.push(0);
    assert!(Manifest::decode(&wrap(&trailing)).is_err(), "trailing bytes decoded");
}

/// A small deterministic generator, so the fuzz loop is the same every run.
struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        self.0 >> 33
    }
}

#[test]
fn flipped_bytes_never_panic() {
    let m = sample();
    let compressed = m.encode().unwrap();
    // Flip bytes in the compressed form (mostly checksum or frame errors) and in the raw body
    // (re-compressed, so the parser itself sees the damage).
    let mut body_form = Vec::new();
    {
        // Rebuild the raw body by decompressing what the encoder wrote.
        body_form.extend_from_slice(&zstd::stream::decode_all(&compressed[6..]).unwrap());
    }
    let mut rng = Lcg(0x5eed);
    for round in 0..4000 {
        let mut damaged = if round % 2 == 0 { compressed.clone() } else { body_form.clone() };
        let flips = 1 + rng.next() % 4;
        for _ in 0..flips {
            let at = (rng.next() as usize) % damaged.len();
            damaged[at] ^= 1 << (rng.next() % 8);
        }
        if round % 7 == 0 {
            let keep = (rng.next() as usize) % damaged.len();
            damaged.truncate(keep);
        }
        let input = if round % 2 == 0 { damaged } else { wrap(&damaged) };
        let result = std::panic::catch_unwind(|| Manifest::decode(&input));
        assert!(result.is_ok(), "decode panicked in round {round}");
        if let Ok(Ok(decoded)) = result {
            // Whatever decodes must be internally consistent: every path resolves to itself.
            for i in 0..decoded.len() as u32 {
                let path = decoded.path_of(i).unwrap();
                let e = decoded.entry(i).unwrap();
                if !e.gone && decoded.resolve(&path).is_some() {
                    assert_eq!(decoded.resolve(&path), Some(i));
                }
            }
        }
    }
}

#[test]
fn apply_delta_replaces_stat_or_marks_gone() {
    let mut m = sample();
    let main = m.resolve("src/main.rs").unwrap();
    let newer = Stat::file(0o644, 999, T + 10, T + 10);
    assert_eq!(m.apply_delta("src/main.rs", Delta::Stat(newer.clone())), Ok(Some(main)));
    assert_eq!(m.entry(main).unwrap().stat, newer);
    assert_eq!(
        m.apply_delta("src/main.rs", Delta::Stat(newer.clone())),
        Ok(None),
        "same stat is a no-op"
    );

    assert_eq!(
        m.apply_delta("README.md", Delta::Stat(Stat::symlink("src", T, T))).map(|i| i.is_some()),
        Ok(true)
    );
    assert!(matches!(
        m.apply_delta("src", Delta::Stat(Stat::file(0o644, 1, T, T))),
        Err(ManifestError::BadStat { .. })
    ));
    assert_eq!(
        m.apply_delta("new-file", Delta::Gone),
        Err(ManifestError::NotInManifest("new-file".into()))
    );

    let src = m.resolve("src").unwrap();
    assert_eq!(m.apply_delta("src", Delta::Gone), Ok(Some(src)));
    assert_eq!(m.resolve("src"), None);
    assert_eq!(m.resolve("src/lib/mod.rs"), None, "a gone directory takes its subtree");
    assert_eq!(m.apply_delta("src/lib", Delta::Gone), Ok(None), "already gone");
    assert!(
        m.apply_delta("src/main.rs", Delta::Stat(newer)).is_err(),
        "cannot revive under a gone parent"
    );
    assert_eq!(m.total_bytes(), 33, "only certs.key is still a live file");

    assert!(m.apply_delta("", Delta::Gone).is_err(), "the root cannot go");
    assert!(m.apply_delta("/abs", Delta::Gone).is_err());
}
