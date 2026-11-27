use cmux_projection::manifest::{Item, Kind, Manifest};
use serde_json::json;

use super::*;

fn file(path: &str, size: u64, mtime_ns: i64) -> Item {
    Item { path: path.into(), kind: Kind::File, mode: 0o644, size, mtime_ns, link: None }
}

fn manifest(items: Vec<Item>) -> Manifest {
    Manifest::build(0, items).unwrap()
}

#[test]
fn picks_instructions_then_dirty_newest_first_then_the_newest() {
    let listed = manifest(vec![
        file("src/old.rs", 10, 1),
        file("src/edited.rs", 10, 50),
        file("src/edited_later.rs", 10, 60),
        file("src/recent.rs", 10, 90),
        file("src/recent2.rs", 10, 80),
        file("CLAUDE.md", 10, 2),
        file("AGENTS.md", 10, 3),
        file(".claude/settings.json", 10, 4),
        file(".codex/config.toml", 10, 5),
        file("docs/CLAUDE.md", 10, 6),
    ]);
    let dirty = vec!["src/edited.rs".to_owned(), "gone.rs".into(), "src/edited_later.rs".into()];
    let picked = pick(&listed, &dirty);
    assert_eq!(
        picked[..8],
        [
            "AGENTS.md",
            "CLAUDE.md",
            ".claude/settings.json",
            ".codex/config.toml",
            "src/edited_later.rs",
            "src/edited.rs",
            "src/recent.rs",
            "src/recent2.rs",
        ]
    );
    // Every file once, all of them under the caps.
    assert_eq!(picked.len(), 10);
    let unique: std::collections::HashSet<_> = picked.iter().collect();
    assert_eq!(unique.len(), picked.len());
}

#[test]
fn stops_at_the_file_cap() {
    let items = (0..500).map(|n| file(&format!("f/{n:03}.rs"), 1, n)).collect();
    let picked = pick(&manifest(items), &[]);
    assert_eq!(picked.len(), MAX_FILES);
    // The newest first.
    assert_eq!(picked[0], "f/499.rs");
    assert_eq!(picked[MAX_FILES - 1], format!("f/{:03}.rs", 500 - MAX_FILES));
}

#[test]
fn skips_a_file_past_the_bytes_left_and_takes_the_next_that_fits() {
    let listed = manifest(vec![
        file("AGENTS.md", MAX_BYTES - 100, 1),
        file("huge.bin", 1000, 9),
        file("small.rs", 50, 8),
        file("also_small.rs", 50, 7),
        file("one_too_many.rs", 1, 6),
    ]);
    let picked = pick(&listed, &["huge.bin".to_owned()]);
    assert_eq!(picked, ["AGENTS.md", "small.rs", "also_small.rs"]);
}

#[test]
fn an_empty_folder_picks_nothing() {
    assert!(pick(&manifest(vec![]), &[]).is_empty());
}

#[test]
fn an_old_machine_s_unknown_op_is_not_a_failure() {
    let unknown = json!({"ok": false, "error_code": "projection.unknown_op", "error": "unknown"});
    assert_eq!(outcome(Err(unknown)), Ok(None));
    // A machine from before projection ops answers with no code at all.
    assert_eq!(outcome(Err(json!({"ok": false, "error": "unknown command"}))), Ok(None));
    let refused = json!({"ok": false, "error_code": "projection.unknown", "error": "not mounted"});
    assert_eq!(outcome(Err(refused.clone())), Err(refused));
    let done = json!({"ok": true, "data": {"files": 3, "bytes": 30}});
    assert_eq!(outcome(Ok(done)), Ok(Some(json!({"files": 3, "bytes": 30}))));
}

#[test]
fn on_unless_turned_off() {
    assert!(enabled_by(None));
    assert!(enabled_by(Some("1")));
    assert!(enabled_by(Some("")));
    assert!(!enabled_by(Some("0")));
    assert!(!enabled_by(Some("false")));
    assert!(!enabled_by(Some("off")));
}

#[test]
fn dirty_lists_changed_and_untracked_files_relative_to_the_folder() {
    let top = tempfile::tempdir().unwrap();
    let git = |args: &[&str]| {
        let out = std::process::Command::new("git")
            .arg("-C")
            .arg(top.path())
            .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"])
            .args(args)
            .output()
            .unwrap();
        assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
    };
    git(&["init", "-q"]);
    std::fs::create_dir(top.path().join("sub")).unwrap();
    std::fs::write(top.path().join("sub/kept.rs"), "a").unwrap();
    std::fs::write(top.path().join("sub/edited.rs"), "a").unwrap();
    git(&["add", "."]);
    git(&["commit", "-q", "-m", "one"]);
    std::fs::write(top.path().join("sub/edited.rs"), "b").unwrap();
    std::fs::write(top.path().join("sub/new.rs"), "c").unwrap();
    let mut found = dirty(&top.path().join("sub"));
    found.sort();
    assert_eq!(found, ["edited.rs", "new.rs"]);
    // Outside a repository: nothing, no error.
    let plain = tempfile::tempdir().unwrap();
    assert!(dirty(plain.path()).is_empty());
}

/// The picker's cost on a large folder (the PR's duress number): 300k files.
#[test]
fn picking_from_a_large_folder() {
    let items = (0..300_000).map(|n| file(&format!("d{}/f{n}.rs", n % 3000), 100, n)).collect();
    let listed = manifest(items);
    let started = std::time::Instant::now();
    let picked = pick(&listed, &["d1/f1.rs".to_owned()]);
    eprintln!("hot-pick: 300000 files in {} us", started.elapsed().as_micros());
    assert_eq!(picked.len(), MAX_FILES);
    assert_eq!(picked[0], "d1/f1.rs");
}
