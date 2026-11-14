//! A Codex state DB that cannot be read for a moment falls back to the rollout files, and that
//! fallback resumes each file where the last file scan stopped.
//!
//! Every Codex process writes its state DB about once a second, and each write rescans the root.
//! A read that fails (the DB locked, past the read deadline on a busy Mac, a WAL without its
//! shared-memory file) falls back to the rollouts. The database scan before it kept no read state
//! per file, so each fallback read every rollout from byte 0: 356 MB of rollouts per store change,
//! in every acpmux daemon on the Mac, kept each idle daemon at 5-10% CPU (2026-11-07).

use cmux_chat_index::{AdapterKind, ChatIndex, ChatRoot, RootSource};
use rusqlite::Connection;
use std::io::{Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

const SESSION: &str = "019a0000-0000-7000-8000-000000000001";
const COUNTED: &str = r#""type":"user_message""#;
const NOT_COUNTED: &str = r#""type":"user_massage""#;

fn root(codex: &Path) -> ChatRoot {
    ChatRoot {
        harness: AdapterKind::Codex,
        path: codex.to_path_buf(),
        real_path: codex.canonicalize().unwrap(),
        source: RootSource::Default,
        aliases: Vec::new(),
        accounts: Vec::new(),
    }
}

fn filler(n: usize) -> String {
    format!(
        r#"{{"timestamp":"2026-11-07T10:00:{:02}.000Z","type":"response_item","payload":{{"type":"reasoning","summary":"{}"}}}}"#,
        n % 60,
        "x".repeat(120)
    )
}

/// A rollout whose one typed prompt sits past the head print (`HeadPrint::MAX`, 4096 bytes), so
/// rewriting it in place leaves the head unchanged. Returns the file and the prompt's offset.
fn rollout(codex: &Path) -> (PathBuf, u64) {
    let dir = codex.join("sessions/2026/11/07");
    std::fs::create_dir_all(&dir).unwrap();
    let file = dir.join(format!("rollout-2026-11-07T10-00-00-{SESSION}.jsonl"));
    let mut text = format!(
        r#"{{"timestamp":"2026-11-07T10:00:00.000Z","type":"session_meta","payload":{{"id":"{SESSION}","timestamp":"2026-11-07T10:00:00.000Z","cwd":"/work/app","originator":"codex_cli_rs"}}}}"#
    );
    text.push('\n');
    for n in 0..40 {
        text.push_str(&filler(n));
        text.push('\n');
    }
    assert!(text.len() > 4096, "the prompt must sit past the head print");
    let prompt = format!(
        r#"{{"timestamp":"2026-11-07T10:01:00.000Z","type":"event_msg","payload":{{{COUNTED},"message":"fix the build"}}}}"#
    );
    let at = text.len();
    text.push_str(&prompt);
    text.push('\n');
    std::fs::write(&file, &text).unwrap();
    let offset = at + prompt.find(COUNTED).unwrap();
    (file, offset as u64)
}

/// An empty Codex state DB in WAL mode, with the tables the index reads.
fn codex_db(codex: &Path) -> Connection {
    let conn = Connection::open(codex.join("state_5.sqlite")).unwrap();
    let _: String = conn.query_row("pragma journal_mode=wal", [], |row| row.get(0)).unwrap();
    conn.execute_batch(
        "create table threads (
            id text primary key, rollout_path text not null, created_at integer not null,
            updated_at integer not null, source text, cwd text not null, title text not null,
            has_user_event integer not null default 0, archived integer not null default 0,
            first_user_message text not null default '', agent_nickname text, agent_role text,
            created_at_ms integer, updated_at_ms integer, thread_source text,
            preview text not null default '', name text, originator text);
         create table thread_spawn_edges (
            parent_thread_id text not null, child_thread_id text not null primary key,
            status text not null);",
    )
    .unwrap();
    conn
}

fn prompt_count(index: &ChatIndex) -> Option<u64> {
    index
        .chats()
        .into_iter()
        .find(|chat| chat.entry.session_id == SESSION)
        .and_then(|chat| chat.entry.message_count)
}

#[test]
fn a_failed_db_read_resumes_the_rollouts_where_the_last_file_scan_stopped() {
    let home = tempfile::tempdir().unwrap();
    let codex = home.path().join(".codex");
    let (file, prompt_at) = rollout(&codex);
    let wal = codex.join("state_5.sqlite-wal");

    // No state DB yet: the rollouts are the store, read to their end.
    let mut index = ChatIndex::new(vec![root(&codex)]);
    index.rescan_all();
    assert_eq!(prompt_count(&index), Some(1), "the rollout's prompt is counted");

    // Codex makes its state DB: the root reads the database from now on.
    let db = codex_db(&codex);
    index.paths_changed(std::slice::from_ref(&wal));
    assert_eq!(prompt_count(&index), None, "the empty database lists no chat");

    // The DB cannot be read (a WAL without its shared-memory file), so the root falls back to
    // the rollouts. Before that, the bytes already read change in place (same length, head
    // untouched) and one line is appended: a resumed read keeps its count, a read from byte 0
    // counts nothing.
    drop(db);
    std::fs::write(&wal, b"").unwrap();
    assert!(!codex.join("state_5.sqlite-shm").exists());
    let mut f = std::fs::OpenOptions::new().read(true).write(true).open(&file).unwrap();
    f.seek(SeekFrom::Start(prompt_at)).unwrap();
    f.write_all(NOT_COUNTED.as_bytes()).unwrap();
    f.seek(SeekFrom::End(0)).unwrap();
    writeln!(f, "{}", filler(41)).unwrap();
    drop(f);

    index.paths_changed(std::slice::from_ref(&wal));
    assert_eq!(
        prompt_count(&index),
        Some(1),
        "the fallback read the rollout again from byte 0 instead of resuming after the database scan"
    );
}
