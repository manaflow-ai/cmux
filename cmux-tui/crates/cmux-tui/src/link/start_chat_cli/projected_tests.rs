//! `start-chat project`: the manifest of a walk, the mount id, the staged files, and a start
//! refused before anything is sent.

use std::path::Path;

use cmux_projfs::Kind;

use super::*;

fn write(top: &Path, relative: &str, bytes: &[u8]) {
    let path = top.join(relative);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, bytes).unwrap();
}

#[test]
fn the_manifest_lists_the_walk_with_its_folders_and_counts_the_skips() {
    let dir = tempfile::tempdir().unwrap();
    let top = std::fs::canonicalize(dir.path()).unwrap();
    write(&top, "src/deep/main.rs", b"fn main() {}");
    write(&top, "src/.env", b"KEY=1");
    write(&top, "node_modules/x.js", b"x");
    std::os::unix::fs::symlink("src/deep/main.rs", top.join("main")).unwrap();
    let listing = sync_cli::stat_listing(&top).unwrap();
    let (manifest, rewritten) = build(&top, &listing, 7).unwrap();
    assert!(rewritten.is_empty());
    let stat = |path: &str| manifest.entry(manifest.resolve(path).unwrap()).unwrap().stat.clone();
    assert_eq!(stat("src").kind, Kind::Dir);
    assert_eq!(stat("src/deep").kind, Kind::Dir);
    assert_eq!((stat("src/deep/main.rs").kind, stat("src/deep/main.rs").size), (Kind::File, 12));
    assert!(stat("src/.env").withheld, "a secret is listed, withheld");
    assert_eq!(stat("main").link.as_deref(), Some("src/deep/main.rs"));
    assert!(manifest.resolve("node_modules").is_none());
    assert_eq!(manifest.skipped(), 1);
    assert_eq!(manifest.total_bytes(), 12 + 5);
    let decoded = Manifest::decode(&manifest.encode().unwrap()).unwrap();
    assert_eq!(decoded.len(), manifest.len());
}

#[test]
fn the_mount_id_is_plain_and_one_per_place() {
    let key = "0F8FAD5B-D9CB-469F-A165-70867728950E";
    let id = mount_id(key, "chats/0f8fad5b-d9cb-469f-a165-70867728950e/1a2b3c4d");
    assert_eq!(id, "p-0f8fad5b-d9cb-469f-a165-70867728950e-1a2b3c4d");
    assert!(id.len() <= 64);
    assert!(id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-'));
}

#[test]
fn staged_files_are_private_and_written_whole() {
    let dir = tempfile::tempdir().unwrap();
    let staged = dir.path().join("m");
    let rewritten = BTreeMap::from([(".git/config".to_owned(), b"[core]\n".to_vec())]);
    stage(&staged, b"CMPF", &rewritten).unwrap();
    assert_eq!(std::fs::read(staged.join(MANIFEST)).unwrap(), b"CMPF");
    let kept: BTreeMap<String, String> =
        serde_json::from_slice(&std::fs::read(staged.join(REWRITTEN)).unwrap()).unwrap();
    assert_eq!(kept.len(), 1);
    use std::os::unix::fs::PermissionsExt as _;
    let mode = std::fs::metadata(staged.join(MANIFEST)).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
    let leftovers: Vec<_> = std::fs::read_dir(&staged).unwrap().collect();
    assert_eq!(leftovers.len(), 2, "no part file is left");
}

#[test]
fn a_folder_that_cannot_be_walked_is_refused_with_the_copy_as_fallback_and_no_record() {
    let dir = tempfile::tempdir().unwrap();
    let base = dir.path().join("projected");
    let copy = StartCopy {
        key: "0f8fad5b-d9cb-469f-a165-70867728950e".into(),
        account: "u1".into(),
        machine: "m1".into(),
        socket: dir.path().join("none.sock"),
        local: dir.path().join("missing").display().to_string(),
        subpath: String::new(),
        work_roots: vec!["/home/cmux".into()],
        acpmux_home: None,
        seed_only: false,
    };
    let answer = start(&copy, &base);
    assert_eq!(answer["ok"], false);
    assert_eq!(answer["code"], "walk_failed");
    assert_eq!(answer["fallback"], "copy");
    assert!(!base.exists() || std::fs::read_dir(&base).unwrap().next().is_none());
    // A folder that does walk, with no machine at the socket: nothing is kept either.
    write(dir.path(), "real/a.txt", b"a");
    let copy = StartCopy { local: dir.path().join("real").display().to_string(), ..copy };
    let answer = start(&copy, &base);
    assert_eq!(answer["ok"], false, "{answer}");
    assert_eq!(answer["fallback"], "copy");
    assert!(std::fs::read_dir(&base).unwrap().next().is_none(), "no record and no staging");
}
