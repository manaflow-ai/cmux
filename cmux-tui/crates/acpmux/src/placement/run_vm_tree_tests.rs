use super::*;
use std::os::unix::fs::PermissionsExt as _;

fn git(dir: &Path, args: &[&str]) {
    let ok = std::process::Command::new("git").arg("-C").arg(dir).args(args).status().unwrap();
    assert!(ok.success(), "git {args:?}");
}

fn repo() -> tempfile::TempDir {
    let dir = tempfile::tempdir().unwrap();
    git(dir.path(), &["init", "-q"]);
    std::fs::write(dir.path().join(".gitignore"), "target/\n").unwrap();
    std::fs::write(dir.path().join("a.txt"), "a\n").unwrap();
    dir
}

fn mode(p: &Path) -> u32 {
    std::fs::symlink_metadata(p).unwrap().permissions().mode() & 0o7777
}

#[test]
fn a_listing_skips_git_and_ignored_paths() {
    let r = repo();
    let p = r.path();
    std::fs::create_dir_all(p.join("target/debug")).unwrap();
    std::fs::create_dir_all(p.join("d/e")).unwrap();
    let l = entries(p).unwrap();
    let names: Vec<&[u8]> = l.keys().map(Vec::as_slice).collect();
    assert_eq!(names, [&b".gitignore"[..], b"a.txt", b"d", b"d/e"]);
}

#[test]
fn the_delta_names_new_folders_changed_modes_and_removed_folders() {
    let r = repo();
    let p = r.path();
    std::fs::create_dir(p.join("old")).unwrap();
    let before = entries(p).unwrap();
    std::fs::remove_dir(p.join("old")).unwrap();
    std::fs::create_dir_all(p.join("new/inner")).unwrap();
    std::fs::set_permissions(p.join("a.txt"), std::fs::Permissions::from_mode(0o600)).unwrap();
    let d = delta(&before, &entries(p).unwrap());
    let paths = |v: &[PathMode]| v.iter().map(|m| (m.path.0.clone(), m.mode)).collect::<Vec<_>>();
    assert_eq!(paths(&d.files), [(b"a.txt".to_vec(), 0o600)]);
    let dirs: Vec<Vec<u8>> = d.dirs.iter().map(|m| m.path.0.clone()).collect();
    assert_eq!(dirs, [b"new".to_vec(), b"new/inner".to_vec()]);
    assert_eq!(d.gone, [B64(b"old".to_vec())]);
    assert!(delta(&before, &before).is_empty(), "nothing changed, nothing sent");
}

#[test]
fn applying_makes_folders_sets_modes_and_removes_only_empty_folders() {
    let r = repo();
    let p = r.path();
    std::fs::create_dir(p.join("gone")).unwrap();
    std::fs::create_dir(p.join("kept")).unwrap();
    std::fs::write(p.join("kept/f"), "f").unwrap();
    let pm = |path: &str, mode| PathMode { path: B64(path.as_bytes().to_vec()), mode };
    let d = TreeDelta {
        dirs: vec![pm("x", 0o700), pm("x/y", 0o755)],
        files: vec![pm("a.txt", 0o600), pm("missing", 0o600)],
        gone: vec![B64(b"gone".to_vec()), B64(b"kept".to_vec())],
    };
    apply(p, &d).unwrap();
    assert!(p.join("x/y").is_dir());
    assert_eq!(mode(&p.join("x")), 0o700);
    assert_eq!(mode(&p.join("a.txt")), 0o600);
    assert!(!p.join("gone").exists());
    assert!(p.join("kept/f").exists(), "a folder that still holds files stays");
}

#[test]
fn a_delta_round_trips_the_wire() {
    let d = TreeDelta { gone: vec![B64(b"\xff".to_vec())], ..Default::default() };
    let text = serde_json::to_string(&d).unwrap();
    assert_eq!(serde_json::from_str::<TreeDelta>(&text).unwrap(), d);
    assert_eq!(serde_json::to_string(&TreeDelta::default()).unwrap(), "{}");
}
