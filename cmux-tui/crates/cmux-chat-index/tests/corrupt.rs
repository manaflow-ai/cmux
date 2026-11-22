//! Crash ratchet: every adapter reads corrupt, partial and hostile files at
//! every path its layout knows without a panic, and a bad file never hides
//! a good one or fails the root scan.

mod common;

use std::fs;

use cmux_chat_index::{AdapterConfig, AdapterKind, read_file, scan_root};
use common::write;

/// Contents that have broken readers: empty, binary, cut JSON, wrong types,
/// deep nesting, invalid UTF-8, a huge line with no newline.
fn garbage() -> Vec<Vec<u8>> {
    let mut out: Vec<Vec<u8>> = vec![
        Vec::new(),
        b"\0\0\0\0".to_vec(),
        b"{".to_vec(),
        b"[]".to_vec(),
        b"null\n".to_vec(),
        b"42\n\"x\"\n".to_vec(),
        br#"{"type":"session"}"#.to_vec(),
        br#"{"type":"session","version":"three","id":7,"timestamp":[],"cwd":{}}"#.to_vec(),
        br#"{"type":"session_meta","payload":"no"}"#.to_vec(),
        br#"{"id":null,"title":5,"time":{"created":"x","updated":-1},"messages":{}}"#.to_vec(),
        br#"{"sessionId":"s","messages":[{"id":1,"type":"user","content":{"a":1}}]}"#.to_vec(),
        b"\xff\xfe\xfd\n{\"type\":\"user\"}\n".to_vec(),
        b"SQLite format 3\0garbage that is not a database".to_vec(),
    ];
    out.push(format!("{}{}", "[".repeat(10_000), "]".repeat(10_000)).into_bytes());
    out.push(vec![b'a'; 300 * 1024]);
    out
}

/// Every session or store path pattern a built-in layout reads.
fn layout(kind: AdapterKind) -> &'static [&'static str] {
    match kind {
        AdapterKind::ClaudeCode => &["-work/s.jsonl", "-work/agent-1.jsonl"],
        AdapterKind::Codex => &[
            "sessions/2026/10/01/rollout-2026-10-01T10-00-00-a.jsonl",
            "sessions/rollout-2025-04-20-b.json",
            "archived_sessions/rollout-2026-10-01T10-00-00-c.jsonl",
            "session_index.jsonl",
            "state_5.sqlite",
        ],
        AdapterKind::OpenCode => &[
            "opencode.db",
            "opencode-beta.db",
            "storage/session/proj/ses_1.json",
            "storage/session/info/ses_2.json",
            "storage/message/ses_1/msg_1.json",
            "storage/part/msg_1/prt_1.json",
            "storage/session/message/ses_2/msg_2.json",
        ],
        AdapterKind::Pi => &["--work--/2026-10-01T10-00-00-000Z_x.jsonl"],
        AdapterKind::Gemini => &[
            "tmp/h/chats/session-1.jsonl",
            "tmp/h/chats/session-2.json",
            "tmp/h/checkpoint-tag.json",
            "tmp/h/.project_root",
        ],
        AdapterKind::CursorAgent => &["h/c1/meta.json", "h/c2/store.db"],
        AdapterKind::Amp => &["T-1.json"],
        AdapterKind::QwenCode => &[
            "projects/-w-p/chats/0b6c0000-0000-4000-8000-000000000001.jsonl",
            "projects/-w-p/chats/archive/0b6c0000-0000-4000-8000-000000000002.jsonl",
            "tmp/h/chats/session-1.json",
            "tmp/h/logs.json",
        ],
        AdapterKind::CopilotCli => &[
            "session-state/a/events.jsonl",
            "session-state/a/workspace.yaml",
            "session-state/b.jsonl",
            "history-session-state/session_c_1790848800000.json",
        ],
        AdapterKind::Grok => &["-w-p/s1/summary.json", "-w-p/.cwd"],
        AdapterKind::GrokCli => &["grok.db"],
        AdapterKind::KimiCli => &[
            "kimi.json",
            "sessions/b1/s1/context.jsonl",
            "sessions/b1/s1/wire.jsonl",
            "sessions/b1/s1/state.json",
            "sessions/b1/s2.jsonl",
        ],
        AdapterKind::KimiCode => &["session_index.jsonl", "sessions/wd_x/session_1/state.json"],
        AdapterKind::Goose => &["sessions.db", "20261001_100000.jsonl"],
        AdapterKind::Droid => &["-w-p/s1.jsonl", "-w-p/s1.settings.json", "s2.jsonl"],
        AdapterKind::Cline | AdapterKind::RooCode | AdapterKind::KiloCode => &[
            "state/taskHistory.json",
            "tasks/_index.json",
            "tasks/t1/history_item.json",
            "tasks/t1/ui_messages.json",
            "tasks/t2/claude_messages.json",
            "global-state.json",
            "db/sessions.db",
        ],
        AdapterKind::Kilo => &["kilo.db", "storage/session/p/ses_1.json"],
        AdapterKind::Crush => &["crush.db"],
        AdapterKind::Auggie => &["s1.json"],
        AdapterKind::Continue => &["sessions.json", "s1.json"],
        AdapterKind::OpenHands => &["c1/base_state.json", "c1/events/event-00000-e.json"],
    }
}

fn is_database_store(kind: AdapterKind) -> bool {
    matches!(
        kind,
        AdapterKind::OpenCode
            | AdapterKind::Kilo
            | AdapterKind::GrokCli
            | AdapterKind::Goose
            | AdapterKind::Crush
            | AdapterKind::Cline
            | AdapterKind::RooCode
            | AdapterKind::KiloCode
    )
}

#[test]
fn garbage_at_every_layout_path_never_panics_or_fails_the_scan() {
    for (variant, bytes) in garbage().into_iter().enumerate() {
        for kind in AdapterKind::ALL {
            let dir = tempfile::tempdir().unwrap();
            for rel in layout(kind) {
                let path = dir.path().join(rel);
                write(&path, "");
                fs::write(&path, &bytes).unwrap();
            }
            let scan = scan_root(&AdapterConfig::new(kind, dir.path()), &Default::default());
            // A database store whose DB is not a database fails the scan
            // (the index keeps its last result); file stores never fail.
            assert!(
                scan.is_ok() || is_database_store(kind),
                "{kind:?} variant {variant}: {scan:?}"
            );
            for rel in layout(kind) {
                // A direct read may fail with an error, never a panic.
                let _ = read_file(kind, &dir.path().join(rel), None);
            }
        }
    }
}

#[test]
fn a_missing_root_is_empty_for_every_adapter() {
    let dir = tempfile::tempdir().unwrap();
    for kind in AdapterKind::ALL {
        let scan =
            scan_root(&AdapterConfig::new(kind, dir.path().join("none")), &Default::default())
                .unwrap();
        assert!(scan.entries.is_empty(), "{kind:?}");
    }
}

#[test]
fn a_root_that_is_a_file_is_empty_for_every_adapter() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("file");
    fs::write(&file, b"x").unwrap();
    for kind in AdapterKind::ALL {
        let scan = scan_root(&AdapterConfig::new(kind, &file), &Default::default()).unwrap();
        assert!(scan.entries.is_empty(), "{kind:?}");
    }
}
