//! `ext pack` as a reproducible build: the same commit packs to the same
//! sha256 wherever it is checked out, `--expect` refuses any other hash, and
//! `ext add` records the hash of what it fetched in the copy's marker
//! (DESIGN.md section 11: "the built hash is published; anyone can rebuild
//! and compare").

use std::path::Path;

use super::pack::{self, PackError, PackOptions};
use super::tests::{extension_repo, words};
use super::{Request, exit, parse, share, source};

fn options(dir: &Path, expect: Option<&str>) -> PackOptions {
    PackOptions {
        dir: dir.to_path_buf(),
        out: None,
        expect: expect.map(str::to_string),
        entry: None,
    }
}

#[test]
fn parses_expect_as_a_sha256() {
    let hash = "AB".repeat(32);
    assert_eq!(
        parse(&words(&format!("pack x --expect {hash}"))),
        Ok(Request::Pack(PackOptions {
            dir: "x".into(),
            out: None,
            expect: Some(hash.to_ascii_lowercase()),
            entry: None,
        }))
    );
    assert!(parse(&words("pack --expect")).is_err(), "no hash");
    assert!(parse(&words("pack --expect abc")).is_err(), "not 64 hex digits");
    assert!(parse(&words(&format!("pack --expect {}", "g".repeat(64)))).is_err(), "not hex");
}

/// Two checkouts of one commit, in different folders and at different
/// times, pack to one sha256; `sha256_of` gives it without writing; a
/// changed file is another hash.
#[test]
fn one_commit_packs_to_one_sha256_wherever_it_is_checked_out() {
    let root = tempfile::tempdir().unwrap();
    let upstream = extension_repo(root.path());
    let url = upstream.to_string_lossy().into_owned();
    let a = source::fetch(&url, &[], Some("widgets/hello"), &root.path().join("a")).unwrap();
    let b = source::fetch(&url, &[a.commit.clone()], Some("widgets/hello"), &root.path().join("b"))
        .unwrap();
    assert_eq!(a.commit, b.commit);
    // A later mtime on one copy changes nothing: the archive holds no times.
    let main = b.dir.join("dist/main.js");
    let body = std::fs::read(&main).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(1100));
    std::fs::write(&main, &body).unwrap();

    let before = pack::sha256_of(&a.dir).unwrap();
    assert!(!a.dir.join(pack::OUT_DIR).exists(), "sha256_of writes nothing");
    let first = pack::pack(&options(&a.dir, None)).unwrap();
    let second = pack::pack(&options(&b.dir, Some(&first.sha256))).unwrap();
    assert_eq!((first.sha256.as_str(), second.sha256.as_str()), (before.as_str(), before.as_str()));
    assert_eq!(pack::sha256_of(&a.dir).unwrap(), before, "release/ stays out of the hash");

    std::fs::write(&main, "// changed\n").unwrap();
    assert_ne!(pack::sha256_of(&b.dir).unwrap(), before, "other bytes, other hash");
}

/// `--expect` with another hash fails as a mismatch naming both hashes;
/// upper-case input matches.
#[test]
fn expect_refuses_another_hash() {
    let root = tempfile::tempdir().unwrap();
    let upstream = extension_repo(root.path());
    let dir = upstream.join("widgets/hello");
    let packed = pack::pack(&options(&dir, None)).unwrap();
    let upper = packed.sha256.to_ascii_uppercase();
    assert_eq!(pack::pack(&options(&dir, Some(&upper))).unwrap().sha256, packed.sha256);

    let other = "0".repeat(64);
    let Err(error @ PackError::Mismatch { .. }) = pack::pack(&options(&dir, Some(&other))) else {
        panic!("a mismatch")
    };
    let text = error.text();
    assert!(text.contains(&packed.sha256) && text.contains(&other), "{text}");
    assert_eq!(exit::NOT_REPRODUCED, 9);

    std::fs::write(dir.join("cmux-app.json"), "{").unwrap();
    assert!(matches!(pack::pack(&options(&dir, Some(&other))), Err(PackError::Invalid(_))));
}

/// The origin `ext add` records carries the fetched folder's pack hash.
#[test]
fn the_recorded_origin_names_the_built_hash() {
    let root = tempfile::tempdir().unwrap();
    let upstream = extension_repo(root.path());
    let url = upstream.to_string_lossy().into_owned();
    let fetched = source::fetch(&url, &[], Some("widgets/hello"), &root.path().join("c")).unwrap();
    let repo = cmux_cloud_start_core::machine_repo::parse("acme/widgets").unwrap();
    let sha = pack::sha256_of(&fetched.dir).unwrap();
    let origin = share::origin_json(&repo, &fetched, Some(&sha));
    assert_eq!(origin["sha256"], sha.as_str());
    assert_eq!(origin["commit"], fetched.commit.as_str());
    assert!(share::origin_json(&repo, &fetched, None)["sha256"].is_null());
}

/// `--entry FILE` checks against a signed registry entry; this build ships
/// no registry key, so any entry is refused as unsigned, before a mismatch.
#[test]
fn entry_needs_a_registry_signature() {
    let Ok(Request::Pack(parsed)) = parse(&words("pack x --entry e.sig")) else { panic!("pack") };
    assert_eq!(parsed.entry.as_deref(), Some(Path::new("e.sig")));
    assert!(parse(&words("pack --entry")).is_err(), "no file");

    let root = tempfile::tempdir().unwrap();
    let upstream = extension_repo(root.path());
    let dir = upstream.join("widgets/hello");
    let entry = root.path().join("e.sig");
    let mut with_entry = options(&dir, None);
    with_entry.entry = Some(entry.clone());
    let Err(PackError::Invalid(missing)) = pack::pack(&with_entry) else { panic!("no file") };
    assert!(missing.contains("no registry entry"), "{missing}");
    std::fs::write(&entry, r#"{"schema":1,"payload":"e30=","signatures":[]}"#).unwrap();
    let Err(PackError::Invalid(unsigned)) = pack::pack(&with_entry) else { panic!("unsigned") };
    assert!(unsigned.contains("not a registry entry cmux signed"), "{unsigned}");
}
