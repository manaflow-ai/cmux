//! A long chat's turns cost their own records, not the chat's length (Leo, 2026-11-06: "we need
//! to be able to work with a 1 million event chat ... it's not like you're reading 1 million
//! events on each turn"). Each read below runs per turn, per prompt or per open; each read the
//! whole log (a million-record chat's log is 1.3 GB) until it took the log's copies of its kinds
//! (`store/kind_index.rs`) or a saved fold (`time_breakdown.rs`). A new read of that kind that
//! reads the whole log fails here: add its kinds to `INDEXED_KINDS`, or read from the end.

use super::*;
use crate::store::{EventRecord, LocalStore, SessionMeta, SessionStatus, Store};

/// Bytes this thread has read (Linux `rchar`): other tests' reads are not counted.
fn read_bytes() -> u64 {
    std::fs::read_to_string("/proc/thread-self/io")
        .ok()
        .and_then(|io| {
            io.lines().find(|l| l.starts_with("rchar:"))?.split_whitespace().nth(1)?.parse().ok()
        })
        .unwrap_or(0)
}

fn record(seq: u64, dir: &str, kind: &str, msg: Value) -> EventRecord {
    EventRecord { seq, at: seq, dir: dir.into(), kind: kind.into(), msg, host_seq: None }
}

/// `turns` finished turns, each a prompt, its start, 100 answer chunks and its end.
fn long_log(turns: u64) -> Vec<EventRecord> {
    let mut log = Vec::new();
    let mut seq = 0;
    let mut push = |dir: &str, kind: &str, msg: Value| {
        seq += 1;
        log.push(record(seq, dir, kind, msg));
    };
    let chunk = "word ".repeat(60);
    for turn in 0..turns {
        let (prompt, id) = (format!("p{turn}"), format!("t{turn}"));
        push("mux", "user_message", json!({"text": "go on", "promptId": prompt, "turnId": id}));
        push("mux", "turn_started", json!({"promptId": prompt, "turnId": id}));
        for _ in 0..100 {
            let update = json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": chunk}});
            push(
                "in",
                "agent_message_chunk",
                json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a", "update": update}}),
            );
        }
        push(
            "mux",
            "turn_result",
            json!({"status": "completed", "turnId": id, "promptId": prompt}),
        );
    }
    log
}

fn hub_over(sessions: &std::path::Path) -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    Hub::new_deferred(
        cfg,
        Box::new(LocalStore::new(sessions.to_path_buf(), 8 << 20).unwrap()),
        crate::mailbox::Mailbox::memory(),
    )
}

#[test]
fn a_long_chats_per_turn_reads_never_read_its_whole_log() {
    if !cfg!(target_os = "linux") {
        return; // A thread's reads are counted on Linux only.
    }
    let over = per_turn_reads(200, false);
    assert!(
        over.is_empty(),
        "whole-log reads on a long chat's per-turn paths:\n{}",
        over.join("\n")
    );
}

/// The same reads on a chat of `LONG_CHAT_TURNS` turns (default 9,800: a million records), each
/// timed: run with `cargo test -p acpmux --release --lib -- --ignored --nocapture
/// long_chat_perf`.
#[test]
#[ignore = "a measurement, not a check"]
fn long_chat_perf() {
    let turns = std::env::var("LONG_CHAT_TURNS").ok().and_then(|v| v.parse().ok()).unwrap_or(9_800);
    per_turn_reads(turns, true);
}

/// Each per-turn read of a chat of `turns` turns, the ones over a tenth of its log named.
fn per_turn_reads(turns: u64, print: bool) -> Vec<String> {
    let root = std::env::temp_dir().join(format!("acpmux-long-chat-{}", uuid::Uuid::now_v7()));
    let sessions = root.join("sessions");
    {
        let writer = LocalStore::new(sessions.clone(), 8 << 20).unwrap();
        let log = long_log(turns);
        for rec in &log {
            writer.append("c", rec).unwrap();
        }
        let mut meta: SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "c", "name": "long chat", "harness": "fake",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
        }))
        .unwrap();
        meta.status = SessionStatus::Idle;
        meta.last_seq = log.last().unwrap().seq;
        meta.event_count = log.len() as u64;
        writer.save(&meta).unwrap();
        writer.flush().unwrap();
    }
    let log_bytes: u64 = std::fs::read_dir(sessions.join("c").join("events"))
        .unwrap()
        .map(|e| e.unwrap().metadata().unwrap().len())
        .sum();
    let budget = log_bytes / 10;

    let hub = hub_over(&sessions);
    let s = hub.resolve("c").unwrap();
    // Once per chat, ever: the log load makes the copies of the indexed kinds, and the first
    // Session Info folds the log and saves the fold.
    hub.load_session_log(&s);
    let folded = hub.session_detail(&s)["timeBreakdown"].clone();
    assert!(folded.is_object(), "{folded}");

    let mut over = Vec::new();
    let mut measure = |what: &str, read: &mut dyn FnMut()| {
        let (before, started) = (read_bytes(), std::time::Instant::now());
        read();
        let bytes = read_bytes() - before;
        if print {
            println!(
                "{what}: {:.1} ms, {:.2} MB read of a {:.0} MB log ({} records)",
                started.elapsed().as_secs_f64() * 1000.0,
                bytes as f64 / 1e6,
                log_bytes as f64 / 1e6,
                turns * 103
            );
        }
        if bytes > budget {
            over.push(format!("{what} read {bytes} bytes of a {log_bytes}-byte log"));
        }
    };
    measure("a resent prompt's state (prompt_ledger.rs)", &mut || {
        assert!(!hub.knows_prompt(&s, "never-sent", true));
    });
    measure("a child's offer result at its turn end (offer_results.rs)", &mut || {
        assert!(hub.started_by_offer(&s, "a-child").is_none());
    });
    measure("a withdraw (withdraw.rs)", &mut || {
        assert!(hub.find_withdrawn(&s, false, "never-sent").is_none());
    });
    measure("a retry's held prompts (auto_resume.rs)", &mut || {
        let _ = hub.held_by(&s, "p1", "t1");
    });
    measure("the chat's process table (processes.rs)", &mut || {
        let _ = hub.any_process_running(&s);
    });
    measure("a sent team message (team_sent.rs)", &mut || {
        assert!(!hub.sent_team_message("c", "never-sent"));
    });
    measure("machine_info's secrets (machine_info.rs)", &mut || {
        let _ = hub.machine_info(&s);
    });
    // A later daemon's first open of the chat: Session Info from the saved fold.
    let later = hub_over(&sessions);
    let again = later.resolve("c").unwrap();
    later.load_session_log(&again);
    measure("a later daemon's Session Info (views.rs time_breakdown_of)", &mut || {
        let saved = later.session_detail(&again)["timeBreakdown"].clone();
        assert_eq!(saved, folded, "the saved fold is the log's");
    });
    let _ = std::fs::remove_dir_all(&root);
    over
}
