//! An adopted or watched Claude Code chat shows its newest turns, read from the transcript's end
//! (`adopt_replay_page.rs`), and records where its older turns begin (`native_history`).

use super::super::Hub;
use serde_json::{Value, json};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;

fn home(name: &str) -> PathBuf {
    let home =
        std::env::temp_dir().join(format!("acpmux-adopt-page-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&home);
    std::fs::create_dir_all(home.join("projects/-work")).unwrap();
    home
}

fn hub(home: &Path) -> Arc<Hub> {
    let cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"claude": {"kind": "claude-stdio", "argv": ["claude"],
            "env": {"CLAUDE_CONFIG_DIR": home}}},
        "defaultHarness": "claude", "store": {"mode": "memory"}
    }))
    .unwrap();
    let store = crate::store::open(&cfg.store, home).unwrap();
    let meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "chat", "name": "chat",
        "harness": "claude", "cwd": home, "status": "idle",
        "createdAt": 1, "updatedAt": 1, "agentSessionId": "s1"
    }))
    .unwrap();
    store.save(&meta).unwrap();
    Hub::new(cfg, store)
}

/// `turns` turns, each a prompt, a progress line of `pad` bytes and an answer.
fn transcript(file: &Path, turns: usize, pad: usize) {
    let mut f = std::io::BufWriter::new(std::fs::File::create(file).unwrap());
    let filler = "x".repeat(pad);
    for n in 0..turns {
        let prompt = json!({"type": "user", "timestamp": "2026-10-29T10:00:00.000Z",
            "message": {"role": "user", "content": format!("prompt {n}")}});
        let answer = json!({"type": "assistant", "timestamp": "2026-10-29T10:00:01.000Z",
            "message": {"role": "assistant", "stop_reason": "end_turn",
                "content": [{"type": "text", "text": format!("answer {n}")}]}});
        writeln!(f, "{prompt}").unwrap();
        writeln!(f, "{}", json!({"type": "progress", "data": filler})).unwrap();
        writeln!(f, "{answer}").unwrap();
    }
}

/// The chat's prompts as its log shows them, and its `native_history` records.
fn history(hub: &Hub) -> (Vec<String>, Vec<Value>) {
    let (mut prompts, mut cursors) = (Vec::new(), Vec::new());
    hub.store
        .scan_kinds("chat", &["user_message", "native_history"], &mut |rec| {
            let msg = rec.msg.clone();
            if rec.kind == "user_message" {
                prompts.push(msg["text"].as_str().unwrap_or_default().to_owned());
            } else {
                cursors.push(msg);
            }
            true
        })
        .unwrap();
    (prompts, cursors)
}

#[tokio::test]
async fn an_adopted_big_claude_transcript_shows_its_newest_turns_read_from_the_end() {
    let home = home("adopt");
    let hub = hub(&home);
    let file = home.join("projects/-work/s1.jsonl");
    // 260 turns of 64 KiB, about 17 MB: more than one page reads.
    transcript(&file, 260, 64 << 10);
    let session = hub.resolve("chat").unwrap();
    hub.replay_adopted(&session, "claude", file.clone()).await;
    let (prompts, cursors) = history(&hub);
    assert_eq!(prompts.last().map(String::as_str), Some("prompt 259"));
    let first: usize = prompts[0].strip_prefix("prompt ").unwrap().parse().unwrap();
    let want: Vec<String> = (first..260).map(|n| format!("prompt {n}")).collect();
    assert_eq!(prompts, want, "the newest turns, in order");
    assert!(first > 60, "a page reads a bounded tail, not the newest 200 turns: from {first}");
    // Where the older turns begin: the offset of the first shown prompt's line.
    assert_eq!(cursors.len(), 1, "{cursors:?}");
    let before = cursors[0]["before"].as_u64().unwrap();
    let text = std::fs::read(&file).unwrap();
    let line = &text[before as usize..];
    let line = &line[..line.iter().position(|&b| b == b'\n').unwrap()];
    let record: Value = serde_json::from_slice(line).unwrap();
    assert_eq!(record["message"]["content"], prompts[0]);
    let _ = std::fs::remove_dir_all(home);
}

#[tokio::test]
async fn a_watched_claude_transcript_starts_at_its_newest_page() {
    let home = home("watch");
    let hub = hub(&home);
    let file = home.join("projects/-work/s1.jsonl");
    transcript(&file, 260, 64 << 10);
    let len = std::fs::metadata(&file).unwrap().len();
    let session = hub.resolve("chat").unwrap();
    hub.begin_watch(&session, "claude", file.clone());
    // The watch reads to the end of the transcript, then waits for more.
    tokio::time::timeout(std::time::Duration::from_secs(20), async {
        while session.meta().watching.is_some_and(|w| w.offset < len) {
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("the watch reads the transcript");
    let (prompts, cursors) = history(&hub);
    assert_eq!(prompts.last().map(String::as_str), Some("prompt 259"));
    assert!(!prompts.iter().any(|p| p == "prompt 0"), "starts at the newest page: {prompts:?}");
    assert_eq!(cursors.len(), 1, "{cursors:?}");
    session.meta.lock().unwrap().watching = None;
    let _ = std::fs::remove_dir_all(home);
}

/// The open-time harness of the PR (run with `--ignored --nocapture`): adopting a ~420 MB
/// synthetic Claude Code transcript of tool-heavy turns, timed from the replay's start until the
/// chat's log holds its newest turn and an attach-sized tail page is read.
#[tokio::test]
#[ignore = "bench: writes a 420 MB transcript"]
async fn bench_adopt_open_of_a_420_mb_transcript() {
    let home = home("bench");
    let hub = hub(&home);
    let file = home.join("projects/-work/s1.jsonl");
    {
        let mut f = std::io::BufWriter::new(std::fs::File::create(&file).unwrap());
        let output = "o".repeat(20 << 10);
        for n in 0..850 {
            let prompt = json!({"type": "user", "timestamp": "2026-10-29T10:00:00.000Z",
                "message": {"role": "user", "content": format!("prompt {n}")}});
            writeln!(f, "{prompt}").unwrap();
            for t in 0..12 {
                let id = format!("toolu_{n}_{t}");
                let call = json!({"type": "assistant", "timestamp": "2026-10-29T10:00:01.000Z",
                    "message": {"role": "assistant", "content": [{"type": "tool_use", "id": id,
                        "name": "Bash", "input": {"command": format!("echo {n} {t}")}}]}});
                let result = json!({"type": "user", "timestamp": "2026-10-29T10:00:02.000Z",
                    "message": {"role": "user", "content": [{"type": "tool_result",
                        "tool_use_id": id, "content": output}]},
                    "toolUseResult": {"stdout": output, "stderr": "", "interrupted": false}});
                writeln!(f, "{call}").unwrap();
                writeln!(f, "{result}").unwrap();
            }
            let answer = json!({"type": "assistant", "timestamp": "2026-10-29T10:00:03.000Z",
                "message": {"role": "assistant", "stop_reason": "end_turn",
                    "content": [{"type": "text", "text": format!("answer {n}")}]}});
            writeln!(f, "{answer}").unwrap();
        }
    }
    let len = std::fs::metadata(&file).unwrap().len();
    let session = hub.resolve("chat").unwrap();
    let started = std::time::Instant::now();
    hub.replay_adopted(&session, "claude", file.clone()).await;
    let replayed = started.elapsed();
    let filter = super::super::paging::EventFilter::default();
    let page = hub.events_page("chat", 0, None, 400, Some(128 << 10), true, &filter);
    let opened = started.elapsed();
    let (prompts, _) = history(&hub);
    let mut count = 0usize;
    hub.store
        .scan("chat", 0, &mut |_| {
            count += 1;
            true
        })
        .unwrap();
    println!(
        "BENCH transcript_mb={:.1} replay_ms={} open_ms={} turns={} records={} last={:?} page_ok={}",
        len as f64 / 1e6,
        replayed.as_millis(),
        opened.as_millis(),
        prompts.len(),
        count,
        prompts.last(),
        page.is_ok(),
    );
    assert_eq!(prompts.last().map(String::as_str), Some("prompt 849"));
    let _ = std::fs::remove_dir_all(home);
}
