use super::*;
use crate::store::FsStore;
use std::time::{Duration, SystemTime};

const DAY: u64 = 86_400_000;
const SID: &str = "019a0000-1111-7222-8333-444455556666";
const OTHER: &str = "019a0000-aaaa-7bbb-8ccc-ddddeeeeffff";
const CLAUDE_SID: &str = "6f1c2d3e-0000-4000-8000-000000000001";

struct Fixture {
    _dir: tempfile::TempDir,
    home: PathBuf,
    state: PathBuf,
    cloud: Cloud,
    now_ms: u64,
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_millis() as u64
}

fn put(home: &Path, rel: &str, bytes: &[u8], age_days: u64) -> PathBuf {
    let path = home.join(rel);
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(&path, bytes).unwrap();
    let when = SystemTime::now() - Duration::from_millis(age_days * DAY);
    std::fs::File::options().write(true).open(&path).unwrap().set_modified(when).unwrap();
    path
}

fn codex(sid: &str) -> String {
    format!(".codex/sessions/2026/01/02/rollout-2026-01-02T03-04-05-{sid}.jsonl")
}

fn claude(sid: &str) -> String {
    format!(".claude/projects/-home-me-proj/{sid}.jsonl")
}

fn fixture() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    let state = dir.path().join("state");
    let cloud = Cloud {
        store: Box::new(FsStore::new(dir.path().join("cloud")).unwrap()),
        key: seal::Key::generate().unwrap(),
        root_prefix: String::new(),
    };
    put(&home, &codex(SID), b"{\"type\":\"session_meta\"}\n{\"type\":\"turn\"}\n", 30);
    put(&home, &codex(OTHER), b"{\"type\":\"session_meta\",\"other\":1}\n", 30);
    put(&home, &claude(CLAUDE_SID), b"{\"type\":\"user\"}\n", 30);
    put(
        &home,
        &format!(".claude/projects/-home-me-proj/{CLAUDE_SID}/subagents/agent-1.jsonl"),
        b"{}\n",
        30,
    );
    // A live chat: modified now.
    put(&home, &codex("019a0000-2222-7222-8333-444455556666"), b"live\n", 0);
    // Not transcripts.
    put(&home, ".codex/sessions/2026/01/02/notes.jsonl", b"x", 30);
    put(&home, ".codex/config.toml", b"x", 30);
    Fixture { _dir: dir, home, state, cloud, now_ms: now_ms() }
}

fn policy(f: &Fixture, delete_local: bool) -> Policy {
    Policy { older_than_ms: 14 * DAY, delete_local, keep: HashSet::new(), now_ms: f.now_ms }
}

fn snapshot(home: &Path) -> BTreeMap<String, Vec<u8>> {
    scan(home).into_iter().map(|f| (f.rel, std::fs::read(f.path).unwrap())).collect()
}

#[test]
fn scan_finds_only_transcripts() {
    let f = fixture();
    let rels: Vec<String> = scan(&f.home).into_iter().map(|f| f.rel).collect();
    assert_eq!(rels.len(), 5, "{rels:?}");
    assert!(rels.iter().all(|r| r.ends_with(".jsonl") && !r.ends_with("notes.jsonl")));
}

#[test]
fn session_ids_from_paths() {
    assert_eq!(session_of(&codex(SID)).as_deref(), Some(SID));
    assert_eq!(session_of(&claude(CLAUDE_SID)).as_deref(), Some(CLAUDE_SID));
    let sub = format!(".claude/projects/-p/{CLAUDE_SID}/subagents/agent-1.jsonl");
    assert_eq!(session_of(&sub).as_deref(), Some(CLAUDE_SID));
    assert!(belongs_to(&codex(SID), SID) && !belongs_to(&codex(OTHER), SID));
    assert!(belongs_to(&sub, CLAUDE_SID) && belongs_to(&claude(CLAUDE_SID), CLAUDE_SID));
    assert!(!belongs_to(&claude(CLAUDE_SID), ""));
}

#[test]
fn dry_run_needs_no_cloud_and_changes_nothing() {
    let f = fixture();
    let before = snapshot(&f.home);
    let report = pass(&f.home, &f.state, None, &policy(&f, true), true, &|| false).unwrap();
    assert!(report.dry_run);
    assert_eq!(report.files, 5);
    assert_eq!(report.copied, 4, "{report:?}");
    assert_eq!(report.removed, 4);
    assert_eq!(report.skipped.get("recent"), Some(&1));
    assert_eq!(snapshot(&f.home), before);
    assert!(!f.state.join(LEDGER_FILE).exists(), "a dry run writes no ledger");
    // Outside a dry run, no cloud is an error, not a silent no-op.
    assert!(pass(&f.home, &f.state, None, &policy(&f, false), false, &|| false).is_err());
}

#[test]
fn copy_only_never_touches_the_files() {
    let f = fixture();
    let before = snapshot(&f.home);
    let report =
        pass(&f.home, &f.state, Some(&f.cloud), &policy(&f, false), false, &|| false).unwrap();
    assert_eq!((report.copied, report.removed), (4, 0), "{report:?}");
    assert_eq!(snapshot(&f.home), before);
    assert_eq!(report.root_blobs, Some(4));
    // Every copy reads back to the file's bytes.
    let ledger = Ledger::load(&f.state).unwrap();
    for (rel, entry) in &ledger.files {
        assert_eq!(read_back(&f.cloud, &entry.stub).unwrap(), before[rel]);
    }
    // Unchanged files are not sent again; a changed one is.
    let again =
        pass(&f.home, &f.state, Some(&f.cloud), &policy(&f, false), false, &|| false).unwrap();
    assert_eq!((again.copied, again.unchanged), (0, 4));
    put(&f.home, &codex(OTHER), b"{\"type\":\"session_meta\",\"other\":2}\n", 20);
    let changed =
        pass(&f.home, &f.state, Some(&f.cloud), &policy(&f, false), false, &|| false).unwrap();
    assert_eq!((changed.copied, changed.unchanged), (1, 3));
}

#[test]
fn codex_home_offloads_and_every_chat_opens() {
    let f = fixture();
    let before = snapshot(&f.home);
    let report =
        pass(&f.home, &f.state, Some(&f.cloud), &policy(&f, true), false, &|| false).unwrap();
    assert_eq!((report.copied, report.removed), (4, 4), "{report:?}");
    // The live chat stays; the others left a tombstone stub.
    let left: Vec<String> = scan(&f.home).into_iter().map(|f| f.rel).collect();
    assert_eq!(left.len(), 1);
    assert!(stub::stub_path(&f.home.join(codex(SID))).exists());
    assert!(needs_restore(&f.home, &f.state, SID));
    // Fetch on open, by session id: only that chat comes back, byte for byte.
    assert_eq!(restore(&f.home, &f.state, &f.cloud, SID).unwrap(), 1);
    assert_eq!(std::fs::read(f.home.join(codex(SID))).unwrap(), before[&codex(SID)]);
    assert!(!stub::stub_path(&f.home.join(codex(SID))).exists());
    assert!(!needs_restore(&f.home, &f.state, SID));
    assert!(!f.home.join(codex(OTHER)).exists());
    assert_eq!(restore(&f.home, &f.state, &f.cloud, CLAUDE_SID).unwrap(), 2);
    // Undo brings back the rest.
    assert_eq!(restore_all(&f.home, &f.state, &f.cloud).unwrap(), 1);
    assert_eq!(snapshot(&f.home), before);
    // Restored files count as copied, not sent again.
    let after =
        pass(&f.home, &f.state, Some(&f.cloud), &policy(&f, false), false, &|| false).unwrap();
    assert_eq!(after.copied, 0, "{after:?}");
}

#[test]
fn kept_sessions_are_copied_not_removed() {
    let f = fixture();
    let mut p = policy(&f, true);
    p.keep.insert(SID.to_string());
    let report = pass(&f.home, &f.state, Some(&f.cloud), &p, false, &|| false).unwrap();
    assert_eq!((report.copied, report.removed), (4, 3), "{report:?}");
    assert!(f.home.join(codex(SID)).exists());
    assert_eq!(report.skipped.get("kept"), Some(&1));
}

#[test]
fn a_bad_copy_is_never_a_reason_to_delete() {
    let f = fixture();
    pass(&f.home, &f.state, Some(&f.cloud), &policy(&f, false), false, &|| false).unwrap();
    // Corrupt the copy of one file in the store.
    let ledger = Ledger::load(&f.state).unwrap();
    let blob = &ledger.files[&codex(SID)].stub.blob;
    let at = f._dir.path().join("cloud").join(&blob[..2]).join(blob);
    std::fs::write(&at, b"not the copy").unwrap();
    let report =
        pass(&f.home, &f.state, Some(&f.cloud), &policy(&f, true), false, &|| false).unwrap();
    assert_eq!(report.skipped.get("read-back failed"), Some(&1), "{report:?}");
    assert!(f.home.join(codex(SID)).exists());
    assert_eq!(report.removed, 3);
}

#[test]
fn a_file_changed_after_its_copy_is_not_removed() {
    let f = fixture();
    pass(&f.home, &f.state, Some(&f.cloud), &policy(&f, false), false, &|| false).unwrap();
    // Same size and mtime as the ledger, other bytes: the hash check at removal catches it.
    let path = f.home.join(codex(SID));
    let meta = std::fs::metadata(&path).unwrap();
    let mut bytes = std::fs::read(&path).unwrap();
    bytes[0] = b'[';
    std::fs::write(&path, &bytes).unwrap();
    std::fs::File::options()
        .write(true)
        .open(&path)
        .unwrap()
        .set_modified(meta.modified().unwrap())
        .unwrap();
    let report =
        pass(&f.home, &f.state, Some(&f.cloud), &policy(&f, true), false, &|| false).unwrap();
    assert_eq!(report.skipped.get("changed"), Some(&1), "{report:?}");
    assert_eq!(std::fs::read(&path).unwrap(), bytes);
}

#[test]
fn transcripts_root_is_its_own() {
    let f = fixture();
    assert_ne!(root_pair(&f.cloud), f.cloud.root_pair());
}

#[test]
fn a_removed_files_copy_is_rooted_before_the_pass_ends() {
    let f = fixture();
    // Stop right after the first file is handled: the end-of-pass root never runs for the rest.
    let calls = std::cell::Cell::new(0);
    let stop = || {
        calls.set(calls.get() + 1);
        calls.get() > 1
    };
    let report = pass(&f.home, &f.state, Some(&f.cloud), &policy(&f, true), false, &stop).unwrap();
    assert_eq!(report.removed, 1, "{report:?}");
    let ledger = Ledger::load(&f.state).unwrap();
    let removed: Vec<&Entry> =
        ledger.files.values().filter(|e| e.removed_at_ms.is_some()).collect();
    assert_eq!(removed.len(), 1);
    let cloud_dir = f._dir.path().join("cloud");
    let tree_sha =
        std::fs::read_to_string(cloud_dir.join("roots").join(root_pair(&f.cloud))).unwrap();
    let tree = String::from_utf8(f.cloud.store.get(&tree_sha).unwrap()).unwrap();
    assert!(tree.lines().any(|l| l == removed[0].stub.blob), "{tree}");
}
