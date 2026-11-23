use std::os::unix::fs::{PermissionsExt as _, symlink};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use super::*;

struct World {
    _tmp: tempfile::TempDir,
    home: PathBuf,
    record: PathBuf,
    outside: PathBuf,
    head: DirHead,
}

fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().join("home");
    let outside = tmp.path().join("outside");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&outside).unwrap();
    World {
        record: tmp.path().join("var-lib-cmux-agent-home"),
        head: DirHead { root: tmp.path().join("head") },
        home,
        outside,
        _tmp: tmp,
    }
}

fn ctx<'a>(world: &'a World, home: &Path, race: Option<RaceHook>) -> Ctx<'a> {
    Ctx {
        home: home.to_path_buf(),
        user: None,
        record: RecordStore { root: world.record.clone() },
        head: &world.head,
        device: "test".into(),
        machine: true,
        race,
    }
}

/// Publishes `files` as the accepted head at `generation`/`revision`.
fn publish(world: &World, generation: u64, revision: u64, files: &[(&str, &str)]) {
    let mut manifest = Manifest::new();
    for (path, text) in files {
        let sha256 = world.head.put_blob(generation, text.as_bytes()).unwrap();
        manifest.insert((*path).into(), Item { sha256, mode: 0o644 });
    }
    world.head.set(generation, Some(Accepted { revision, manifest })).unwrap();
}

fn put(home: &Path, relative: &str, text: &str) {
    let path = home.join(relative);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn read(home: &Path, relative: &str) -> Option<String> {
    std::fs::read_to_string(home.join(relative)).ok()
}

const NOTE: &str = ".claude/projects/p/memory/note.md";

fn empty(dir: &Path) -> bool {
    std::fs::read_dir(dir).unwrap().next().is_none()
}

#[test]
fn a_machine_with_its_own_claude_md_gets_it_back_on_revocation() {
    let w = world();
    put(&w.home, ".claude/CLAUDE.md", "the image's own\n");
    publish(&w, 1, 1, &[(".claude/CLAUDE.md", "the person's\n"), (NOTE, "remember\n")]);
    let out = pull(&ctx(&w, &w.home, None)).unwrap();
    assert_eq!(out.written, vec![".claude/CLAUDE.md".to_string(), NOTE.to_string()]);
    assert_eq!(read(&w.home, ".claude/CLAUDE.md").as_deref(), Some("the person's\n"));
    assert_eq!(read(&w.home, NOTE).as_deref(), Some("remember\n"));

    // Revoked: the head is gone and the generation moved.
    w.head.set(2, None).unwrap();
    let out = pull(&ctx(&w, &w.home, None)).unwrap();
    assert_eq!(out.restored, vec![".claude/CLAUDE.md".to_string()]);
    assert_eq!(out.deleted, vec![NOTE.to_string()]);
    assert_eq!(read(&w.home, ".claude/CLAUDE.md").as_deref(), Some("the image's own\n"));
    assert_eq!(read(&w.home, NOTE), None);
    assert!(empty(&w.record.join("originals")), "the original's copy is dropped once restored");
}

#[test]
fn a_paused_machine_resuming_after_revocation_deletes_carried_files_first() {
    let w = world();
    publish(&w, 1, 1, &[(NOTE, "remember\n")]);
    pull(&ctx(&w, &w.home, None)).unwrap();
    // An agent edited the carried file before the pause: deleted all the same.
    put(&w.home, NOTE, "remember, edited by an agent\n");
    // Paused while the person revoked it; on resume the start pulls first.
    w.head.set(2, None).unwrap();
    let out = pull(&ctx(&w, &w.home, None)).unwrap();
    assert_eq!(out.deleted, vec![NOTE.to_string()]);
    assert_eq!(read(&w.home, NOTE), None);
    let record = RecordStore { root: w.record }.load().unwrap();
    assert!(record.carried.is_empty() && record.base.is_empty());
    assert_eq!(record.generation, 2);
}

#[test]
fn resuming_under_a_newer_head_deletes_the_older_generations_files() {
    let w = world();
    put(&w.home, ".claude/CLAUDE.md", "mine\n");
    publish(&w, 1, 1, &[(".claude/CLAUDE.md", "gen1\n"), (NOTE, "old\n")]);
    pull(&ctx(&w, &w.home, None)).unwrap();
    // Revoked and turned on again: a new head at generation 2.
    publish(&w, 2, 1, &[(".claude/projects/p/memory/new.md", "fresh\n")]);
    let out = pull(&ctx(&w, &w.home, None)).unwrap();
    assert_eq!(out.deleted, vec![NOTE.to_string()]);
    assert_eq!(out.restored, vec![".claude/CLAUDE.md".to_string()]);
    assert_eq!(read(&w.home, NOTE), None);
    assert_eq!(read(&w.home, ".claude/CLAUDE.md").as_deref(), Some("mine\n"));
    assert_eq!(read(&w.home, ".claude/projects/p/memory/new.md").as_deref(), Some("fresh\n"));
}

#[test]
fn pull_merges_three_ways_and_puts_an_overlap_beside_the_file() {
    let w = world();
    publish(&w, 1, 1, &[(NOTE, "a\nb\nc\nd\ne\n")]);
    pull(&ctx(&w, &w.home, None)).unwrap();
    put(&w.home, NOTE, "A\nb\nc\nd\ne\n");
    publish(&w, 1, 2, &[(NOTE, "a\nb\nc\nd\nE\n")]);
    let out = pull(&ctx(&w, &w.home, None)).unwrap();
    assert_eq!(out.merged, vec![NOTE.to_string()]);
    assert_eq!(read(&w.home, NOTE).as_deref(), Some("A\nb\nc\nd\nE\n"));

    // Both change the same line: this machine's stays, the merge goes beside it.
    put(&w.home, NOTE, "A\nb\nmine\nd\nE\n");
    publish(&w, 1, 3, &[(NOTE, "a\nb\ntheirs\nd\nE\n")]);
    let out = pull(&ctx(&w, &w.home, None)).unwrap();
    assert_eq!(out.conflicts, vec![format!("{NOTE}.cmux-sync-conflict")]);
    assert_eq!(read(&w.home, NOTE).as_deref(), Some("A\nb\nmine\nd\nE\n"));
    let conflict = read(&w.home, &format!("{NOTE}.cmux-sync-conflict")).unwrap();
    assert!(conflict.contains("<<<<<<<") && conflict.contains("theirs"));
}

#[test]
fn an_accepted_proposal_reaches_every_devices_next_pull() {
    let w = world();
    publish(&w, 1, 1, &[]);
    let mac = w._tmp.path().join("mac");
    let mac_record = w._tmp.path().join("mac-record");
    std::fs::create_dir_all(&mac).unwrap();
    let mac_ctx = Ctx { record: RecordStore { root: mac_record }, ..ctx(&w, &mac, None) };
    pull(&mac_ctx).unwrap();
    put(&mac, NOTE, "learned on the Mac\n");
    put(&mac, ".claude/projects/p/memory/.env", "SECRET=1\n");
    let out = propose(&mac_ctx).unwrap();
    assert_eq!(out.proposed, vec![NOTE.to_string()], "a secret-named file is never carried");
    // Proposing never moves the head.
    assert_eq!(w.head.read().unwrap().head.unwrap().revision, 1);
    w.head.accept(out.proposal.as_deref().unwrap()).unwrap();

    let out = pull(&ctx(&w, &w.home, None)).unwrap();
    assert_eq!(out.written, vec![NOTE.to_string()]);
    assert_eq!(read(&w.home, NOTE).as_deref(), Some("learned on the Mac\n"));
}

#[test]
fn push_proposes_against_the_head_it_just_pulled() {
    let w = world();
    publish(&w, 1, 1, &[(NOTE, "one\n")]);
    pull(&ctx(&w, &w.home, None)).unwrap();
    publish(&w, 1, 5, &[(NOTE, "one\n"), (".claude/CLAUDE.md", "rules\n")]);
    put(&w.home, ".claude/projects/p/memory/turn.md", "from this turn\n");
    let out = push(&ctx(&w, &w.home, None)).unwrap();
    assert_eq!(out.written, vec![".claude/CLAUDE.md".to_string()]);
    assert_eq!(out.proposed, vec![".claude/projects/p/memory/turn.md".to_string()]);
    // Based on revision 5, so it applies as is.
    assert_eq!(w.head.accept(out.proposal.as_deref().unwrap()).unwrap(), 6);
}

#[test]
fn a_proposal_from_a_revoked_generation_is_refused() {
    let w = world();
    publish(&w, 1, 1, &[]);
    pull(&ctx(&w, &w.home, None)).unwrap();
    publish(&w, 2, 1, &[]);
    put(&w.home, NOTE, "late\n");
    assert!(propose(&ctx(&w, &w.home, None)).unwrap_err().to_string().contains("pull first"));
}

#[test]
fn the_head_cannot_carry_a_path_outside_the_allowlist() {
    let w = world();
    publish(&w, 1, 1, &[(".ssh/authorized_keys", "ssh-ed25519 AAAA attacker\n")]);
    assert!(pull(&ctx(&w, &w.home, None)).is_err());
    assert!(!w.home.join(".ssh").exists());
    for path in [
        "../x",
        ".claude/projects/p/memory/../../../x",
        "/etc/passwd",
        ".claude/CLAUDE.md.cmux-sync-part",
    ] {
        assert!(!carried(path), "{path}");
    }
}

#[test]
fn the_record_is_owner_only_and_out_of_the_agent_users_reach() {
    let w = world();
    put(&w.home, ".claude/CLAUDE.md", "own\n");
    publish(&w, 1, 1, &[(".claude/CLAUDE.md", "carried\n")]);
    pull(&ctx(&w, &w.home, None)).unwrap();
    let mode = |path: &Path| std::fs::metadata(path).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode(&w.record), 0o700);
    assert_eq!(mode(&w.record.join("originals")), 0o700);
    assert_eq!(mode(&w.record.join("record.json")), 0o600);
    let original = std::fs::read_dir(w.record.join("originals")).unwrap().next().unwrap().unwrap();
    assert_eq!(mode(&original.path()), 0o600);
    assert!(!w.record.starts_with(&w.home));

    // As root (a Cloud machine's cmux-vm-agent, and CI containers), check it
    // for real: a thread acting as another user can neither edit nor delete.
    // SAFETY: geteuid has no preconditions.
    if unsafe { libc::geteuid() } != 0 {
        eprintln!("not root: checked the record's permissions only");
        return;
    }
    let record = w.record.join("record.json");
    let (cannot_edit, cannot_delete) = std::thread::spawn(move || {
        set_fs_ids(65534, 65534).unwrap();
        let edit = std::fs::OpenOptions::new().write(true).open(&record);
        let delete = std::fs::remove_file(&record);
        (edit.is_err(), delete.is_err())
    })
    .join()
    .unwrap();
    assert!(cannot_edit && cannot_delete);
    assert!(w.record.join("record.json").exists());
}

#[test]
fn a_link_on_the_way_is_refused_before_any_write() {
    let w = world();
    symlink(&w.outside, w.home.join(".claude")).unwrap();
    publish(&w, 1, 1, &[(NOTE, "x\n")]);
    assert!(pull(&ctx(&w, &w.home, None)).is_err());
    assert!(empty(&w.outside));
}

/// Swaps `home/.claude/projects/p/memory` (or `.claude`) for a link to
/// `outside` the `nth` time the run touches `key`.
fn race_on(
    key: &'static str,
    nth: usize,
    home: PathBuf,
    swap: &'static str,
    outside: PathBuf,
) -> Arc<dyn Fn(&str) + Send + Sync> {
    let seen = AtomicUsize::new(0);
    Arc::new(move |at: &str| {
        if at == key && seen.fetch_add(1, Ordering::SeqCst) + 1 == nth {
            let path = home.join(swap);
            std::fs::rename(&path, home.join("moved-aside")).unwrap();
            symlink(&outside, &path).unwrap();
        }
    })
}

#[test]
fn a_link_planted_during_a_sync_is_not_followed() {
    let w = world();
    put(&w.home, NOTE, "base\n");
    publish(&w, 1, 1, &[(NOTE, "from the head\n")]);
    // First touch is the plan's read, second the write: swap between them.
    let race = race_on(NOTE, 2, w.home.clone(), ".claude/projects/p/memory", w.outside.clone());
    assert!(pull(&ctx(&w, &w.home, Some(race))).is_err());
    assert!(empty(&w.outside), "nothing was written through the link");
}

#[test]
fn a_link_planted_while_keeping_an_original_is_not_followed() {
    let w = world();
    std::fs::write(w.outside.join("secret"), "outside secret\n").unwrap();
    put(&w.home, ".claude/CLAUDE.md", "own\n");
    publish(&w, 1, 1, &[(".claude/CLAUDE.md", "carried\n")]);
    let home = w.home.clone();
    let secret = w.outside.join("secret");
    let race: RaceHook = Arc::new(move |at: &str| {
        if at == ".claude/CLAUDE.md" {
            let path = home.join(".claude/CLAUDE.md");
            if !path.is_symlink() {
                std::fs::remove_file(&path).unwrap();
                symlink(&secret, &path).unwrap();
            }
        }
    });
    assert!(pull(&ctx(&w, &w.home, Some(race))).is_err());
    let kept = w.record.join("originals");
    let leaked = kept.exists()
        && std::fs::read_dir(&kept)
            .unwrap()
            .any(|entry| std::fs::read(entry.unwrap().path()).unwrap() == b"outside secret\n");
    assert!(!leaked, "the link's target was never read into the record");
    assert_eq!(std::fs::read_to_string(w.outside.join("secret")).unwrap(), "outside secret\n");
}

#[test]
fn a_link_planted_before_a_restore_is_not_followed() {
    let w = world();
    put(&w.home, ".claude/CLAUDE.md", "own\n");
    publish(&w, 1, 1, &[(".claude/CLAUDE.md", "carried\n")]);
    pull(&ctx(&w, &w.home, None)).unwrap();
    w.head.set(2, None).unwrap();
    let race = race_on(".claude/CLAUDE.md", 1, w.home.clone(), ".claude", w.outside.clone());
    assert!(pull(&ctx(&w, &w.home, Some(race))).is_err(), "the restore stops at the link");
    assert!(empty(&w.outside), "the original was not written through the link");
    // The record still lists the carried file, so the next start tries again.
    let record = RecordStore { root: w.record }.load().unwrap();
    assert!(record.carried.contains_key(".claude/CLAUDE.md"));
}
