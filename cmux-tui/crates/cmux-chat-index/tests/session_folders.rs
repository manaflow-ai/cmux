//! `session_folders`: a root watched as its session folders plus its own entries misses no
//! file the index reads. Every path `classify_path` keeps is either inside one of the folders
//! or one of the root's own entries.

use cmux_chat_index::{AdapterKind, PathRole, classify_path, session_folders};
use std::path::Path;

#[test]
fn every_codex_file_the_index_reads_is_in_a_session_folder_or_the_roots_own_entry() {
    let root = Path::new("/home/u/.codex");
    let folders = session_folders(AdapterKind::Codex).expect("Codex is watched by its folders");
    let read = [
        "sessions/2026/11/12/rollout-2026-11-12T00-00-00-0199c0de.jsonl",
        "archived_sessions/rollout-2026-01-01T00-00-00-0199c0de.jsonl.zst",
        "archived_sessions/2025/04/01/rollout-2025-04-01T00-00-00-x.json",
        "state_5.sqlite",
        "state_5.sqlite-wal",
        "state_6.sqlite",
        "session_index.jsonl",
    ];
    for rel in read {
        let path = root.join(rel);
        assert_ne!(classify_path(AdapterKind::Codex, root, &path), PathRole::Ignore, "{rel}");
        let first = rel.split('/').next().unwrap();
        let own_entry = !rel.contains('/');
        assert!(own_entry || folders.contains(&first), "{rel} is outside the watched folders");
    }
    let not_read = [
        "logs_2.sqlite",
        "logs_2.sqlite-wal",
        "goals_1.sqlite-wal",
        "state_5.sqlite-shm",
        "history.jsonl",
        "log/codex-tui.log",
        "shell_snapshots/x.sh",
        "sqlite/state_5.sqlite",
        "cache/sessions/rollout-x.jsonl",
    ];
    for rel in not_read {
        let path = root.join(rel);
        assert_eq!(classify_path(AdapterKind::Codex, root, &path), PathRole::Ignore, "{rel}");
    }
}

#[test]
fn other_roots_are_watched_whole() {
    assert_eq!(session_folders(AdapterKind::ClaudeCode), None);
}
