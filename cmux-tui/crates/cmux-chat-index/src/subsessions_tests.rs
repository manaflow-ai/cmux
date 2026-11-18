use std::fs;
use std::path::Path;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use super::*;
use crate::entry::Resume;

fn chat(harness: AdapterKind, id: &str, source: &Path) -> ChatEntry {
    ChatEntry {
        harness,
        session_id: id.to_owned(),
        title: None,
        title_source: None,
        cwd: None,
        created_ms: None,
        updated_ms: 0,
        message_count: None,
        source_path: source.to_path_buf(),
        originator: None,
        archived: false,
        resume: Resume::Adopt,
    }
}

fn now_ms() -> i64 {
    i64::try_from(SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis()).unwrap()
}

fn set_mtime(path: &Path, ago: Duration) {
    let file = fs::File::options().write(true).open(path).unwrap();
    file.set_modified(SystemTime::now() - ago).unwrap();
}

/// A Claude Code session with subagents: `a1` (finished), `a2` (running, started by the chat),
/// `a3` (started by `a2`, idle for an hour), and a stray file that is no agent.
fn claude_session(dir: &Path) -> std::path::PathBuf {
    let transcript = dir.join("s1.jsonl");
    fs::write(&transcript, "{}\n").unwrap();
    let subs = dir.join("s1").join("subagents");
    fs::create_dir_all(&subs).unwrap();
    let agent = |id: &str, meta: &str, ago: Duration| {
        let log = subs.join(format!("agent-{id}.jsonl"));
        let meta_path = subs.join(format!("agent-{id}.meta.json"));
        fs::write(&log, "{}\n").unwrap();
        fs::write(&meta_path, meta).unwrap();
        set_mtime(&log, ago);
        set_mtime(&meta_path, ago);
    };
    agent(
        "a1",
        r#"{"agentType":"Explore","description":"Find the parser","spawnDepth":1,"finished":true}"#,
        Duration::from_secs(30),
    );
    agent(
        "a2",
        r#"{"agentType":"general-purpose","description":"Fix the build\nand more","spawnDepth":1}"#,
        Duration::from_secs(5),
    );
    agent(
        "a3",
        r#"{"agentType":"general-purpose","description":"Review it","parentAgentId":"a2","spawnDepth":2}"#,
        Duration::from_secs(3600),
    );
    fs::write(subs.join("agent-a1.prefix.json"), "{}").unwrap();
    fs::write(subs.join("notes.txt"), "x").unwrap();
    transcript
}

#[test]
fn claude_subagents_nest_by_their_parent_agent_with_their_state() {
    let dir = tempfile::tempdir().unwrap();
    let transcript = claude_session(dir.path());
    let found = subsessions(&chat(AdapterKind::ClaudeCode, "s1", &transcript), now_ms());
    let ids: Vec<&str> = found.iter().map(|s| s.id.as_str()).collect();
    assert_eq!(ids, ["a2", "a1", "a3"], "newest first");
    let by = |id: &str| found.iter().find(|s| s.id == id).unwrap();
    assert_eq!(by("a1").state, SubSessionState::Done);
    assert_eq!(by("a1").parent_id, None);
    assert_eq!(by("a1").kind.as_deref(), Some("Explore"));
    assert_eq!(by("a2").state, SubSessionState::Running);
    assert_eq!(by("a2").title.as_deref(), Some("Fix the build"), "one line");
    assert_eq!(by("a3").parent_id.as_deref(), Some("a2"));
    assert_eq!(by("a3").depth, 2);
    assert_eq!(by("a3").state, SubSessionState::Idle, "not finished, not moving");
}

#[test]
fn a_session_without_subagents_or_another_harness_has_none() {
    let dir = tempfile::tempdir().unwrap();
    let transcript = dir.path().join("lonely.jsonl");
    fs::write(&transcript, "{}\n").unwrap();
    assert!(
        subsessions(&chat(AdapterKind::ClaudeCode, "lonely", &transcript), now_ms()).is_empty()
    );
    let transcript = claude_session(dir.path());
    assert!(subsessions(&chat(AdapterKind::Gemini, "s1", &transcript), now_ms()).is_empty());
}

#[test]
fn a_parent_past_the_cap_leaves_its_child_under_the_chat() {
    let dir = tempfile::tempdir().unwrap();
    let transcript = dir.path().join("big.jsonl");
    fs::write(&transcript, "{}\n").unwrap();
    let subs = dir.path().join("big").join("subagents");
    fs::create_dir_all(&subs).unwrap();
    // The parent is the oldest, so the cap drops it; its child is the newest.
    for i in 0..=MAX_SUBSESSIONS {
        let id = format!("n{i:04}");
        let meta = if i == 0 {
            r#"{"description":"parent","spawnDepth":1,"finished":true}"#.to_owned()
        } else {
            format!(
                r#"{{"description":"c{i}","parentAgentId":"n0000","spawnDepth":2,"finished":true}}"#
            )
        };
        let path = subs.join(format!("agent-{id}.meta.json"));
        fs::write(&path, meta).unwrap();
        set_mtime(&path, Duration::from_secs(10_000 - u64::try_from(i).unwrap()));
    }
    let found = subsessions(&chat(AdapterKind::ClaudeCode, "big", &transcript), now_ms());
    assert_eq!(found.len(), MAX_SUBSESSIONS);
    assert!(found.iter().all(|s| s.id != "n0000"));
    assert!(found.iter().all(|s| s.parent_id.is_none()), "no child names a parent left out");
}

fn codex_home(dir: &Path) -> std::path::PathBuf {
    let conn = rusqlite::Connection::open(dir.join("state_5.sqlite")).unwrap();
    let now = now_ms();
    conn.execute_batch(&format!(
        "CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT, name TEXT, agent_nickname TEXT,
            agent_role TEXT, updated_at_ms INTEGER);
         CREATE TABLE thread_spawn_edges (parent_thread_id TEXT NOT NULL,
            child_thread_id TEXT NOT NULL PRIMARY KEY, status TEXT NOT NULL);
         INSERT INTO threads VALUES ('root', 'main', NULL, NULL, NULL, {now});
         INSERT INTO threads VALUES ('c1', '', NULL, 'Boyle', 'worker', {now});
         INSERT INTO threads VALUES ('c2', 'Write the tests\nfully', 'Tests', NULL, NULL, {old});
         INSERT INTO threads VALUES ('g1', '', NULL, 'Socrates', NULL, {old});
         INSERT INTO threads VALUES ('other', '', NULL, 'Elsewhere', NULL, {now});
         INSERT INTO thread_spawn_edges VALUES ('root', 'c1', 'open');
         INSERT INTO thread_spawn_edges VALUES ('root', 'c2', 'closed');
         INSERT INTO thread_spawn_edges VALUES ('c1', 'g1', 'failed');
         INSERT INTO thread_spawn_edges VALUES ('g1', 'root', 'open');
         INSERT INTO thread_spawn_edges VALUES ('x', 'other', 'open');",
        old = now - 3_600_000,
    ))
    .unwrap();
    drop(conn);
    let rollout = dir.join("sessions/2026/11/18/rollout-root.jsonl");
    fs::create_dir_all(rollout.parent().unwrap()).unwrap();
    fs::write(&rollout, "{}\n").unwrap();
    rollout
}

#[test]
fn codex_spawned_threads_nest_by_their_spawn_edges() {
    let dir = tempfile::tempdir().unwrap();
    let rollout = codex_home(dir.path());
    let found = subsessions(&chat(AdapterKind::Codex, "root", &rollout), now_ms());
    let by = |id: &str| found.iter().find(|s| s.id == id).unwrap();
    assert_eq!(
        found.len(),
        3,
        "the chat's own subtree only, and the cycle back to it ends: {found:?}"
    );
    assert_eq!(by("c1").parent_id, None);
    assert_eq!(by("c1").title.as_deref(), Some("Boyle"));
    assert_eq!(by("c1").kind.as_deref(), Some("worker"));
    assert_eq!(by("c1").state, SubSessionState::Running);
    assert_eq!(by("c2").title.as_deref(), Some("Tests"), "the name before the nickname and title");
    assert_eq!(by("c2").state, SubSessionState::Done);
    assert_eq!(by("g1").parent_id.as_deref(), Some("c1"));
    assert_eq!(by("g1").depth, 2);
    assert_eq!(by("g1").state, SubSessionState::Failed);
    // The thread whose source is the database itself finds the same home.
    let same = subsessions(
        &chat(AdapterKind::Codex, "root", &dir.path().join("state_5.sqlite")),
        now_ms(),
    );
    assert_eq!(same.len(), 3);
}

#[test]
fn a_codex_home_without_spawn_edges_has_none() {
    let dir = tempfile::tempdir().unwrap();
    let conn = rusqlite::Connection::open(dir.path().join("state_5.sqlite")).unwrap();
    conn.execute_batch("CREATE TABLE threads (id TEXT PRIMARY KEY, title TEXT);").unwrap();
    drop(conn);
    let db = dir.path().join("state_5.sqlite");
    assert!(subsessions(&chat(AdapterKind::Codex, "root", &db), now_ms()).is_empty());
}
