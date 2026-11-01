//! A chat seeded from a Claude Code transcript's newest page pages its older turns in from the
//! transcript (`_acpmux/native_history`), back to its first, each once.

use super::super::Hub;
use super::{fit_reply, handle, native_seq, page_reply, result_bytes};
use crate::adopt_replay::{ClaudePage, PastTurn};
use crate::adopt_tools::PastTool;
use crate::rpc::MAX_MESSAGE_BYTES;
use serde_json::{Value, json};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;

fn home(name: &str) -> PathBuf {
    let home =
        std::env::temp_dir().join(format!("acpmux-native-history-{}-{name}", std::process::id()));
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

/// `turns` turns, each a prompt, a tool call and its result, a progress line of `pad` bytes and
/// an answer.
fn transcript(file: &Path, turns: usize, pad: usize) {
    let mut f = std::io::BufWriter::new(std::fs::File::create(file).unwrap());
    let filler = "x".repeat(pad);
    for n in 0..turns {
        let id = format!("toolu_{n}");
        let lines = [
            json!({"type": "user", "timestamp": "2026-10-29T10:00:00.000Z",
                "message": {"role": "user", "content": format!("prompt {n}")}}),
            json!({"type": "assistant", "timestamp": "2026-10-29T10:00:01.000Z",
                "message": {"role": "assistant", "content": [{"type": "tool_use", "id": id,
                    "name": "Bash", "input": {"command": format!("echo {n}")}}]}}),
            json!({"type": "user", "timestamp": "2026-10-29T10:00:02.000Z",
                "message": {"role": "user", "content": [{"type": "tool_result",
                    "tool_use_id": id, "content": "ok"}]}}),
            json!({"type": "progress", "data": filler}),
            json!({"type": "assistant", "timestamp": "2026-10-29T10:00:03.000Z",
                "message": {"role": "assistant", "stop_reason": "end_turn",
                    "content": [{"type": "text", "text": format!("answer {n}")}]}}),
        ];
        for line in lines {
            writeln!(f, "{line}").unwrap();
        }
    }
}

/// The seeded log's prompts and its `native_history` cursor with its mark.
fn seeded(hub: &Hub) -> (Vec<String>, (u64, String)) {
    let (mut prompts, mut cursor) = (Vec::new(), (0, String::new()));
    hub.store
        .scan_kinds("chat", &["user_message", "native_history"], &mut |rec| {
            if rec.kind == "user_message" {
                prompts.push(rec.msg["text"].as_str().unwrap_or_default().to_owned());
            } else {
                let mark = rec.msg["mark"].as_str().expect("a seeded cursor has a mark");
                cursor = (rec.msg["before"].as_u64().unwrap(), mark.to_owned());
            }
            true
        })
        .unwrap();
    (prompts, cursor)
}

fn prompts_of(events: &[Value]) -> Vec<String> {
    events
        .iter()
        .filter(|e| e["kind"] == "user_message")
        .map(|e| e["msg"]["text"].as_str().unwrap().to_owned())
        .collect()
}

async fn page(hub: &Arc<Hub>, (before, mark): &(u64, String)) -> Value {
    handle(hub, &json!({"sessionId": "chat", "before": before, "mark": mark})).await.unwrap()
}

/// The cursor a reply gives for the page before it.
fn next(reply: &Value) -> (u64, String) {
    (reply["before"].as_u64().unwrap(), reply["mark"].as_str().unwrap_or_default().to_owned())
}

#[tokio::test]
async fn paging_back_to_zero_reads_every_turn_once() {
    let home = home("paging");
    let hub = hub(&home);
    let file = home.join("projects/-work/s1.jsonl");
    // 700 turns: the seeded page holds the newest 200, and three older pages the rest.
    transcript(&file, 700, 16);
    let session = hub.resolve("chat").unwrap();
    hub.replay_adopted(&session, "claude", file.clone()).await;
    let (mut all, mut cursor) = seeded(&hub);
    assert_eq!(all.first().map(String::as_str), Some("prompt 500"));
    assert!(cursor.0 > 0);
    let mut newer_seq = 1i64;
    let mut pages = 0;
    while cursor.0 > 0 {
        let before = cursor.0;
        let reply = page(&hub, &cursor).await;
        let events = reply["events"].as_array().unwrap().clone();
        assert!(!events.is_empty(), "a page before {before} holds turns");
        let seqs: Vec<i64> = events.iter().map(|e| e["seq"].as_i64().unwrap()).collect();
        assert!(seqs.windows(2).all(|w| w[0] < w[1]), "a page's records are in order");
        assert!(*seqs.last().unwrap() < newer_seq, "an older page sorts before the newer one");
        assert!(seqs[0] >= -(1i64 << 52), "a safe integer in JavaScript");
        newer_seq = seqs[0];
        // A turn's end names its start.
        let mut started = None;
        for event in &events {
            match event["kind"].as_str().unwrap() {
                "turn_started" => started = event["seq"].as_i64(),
                "turn_end" | "turn_result" => assert_eq!(event["msg"]["turnSeq"].as_i64(), started),
                _ => {}
            }
        }
        assert!(events.iter().any(|e| e["kind"] == "tool_call"));
        let mut older = prompts_of(&events);
        older.extend(all);
        all = older;
        cursor = next(&reply);
        assert!(cursor.0 < before, "the cursor moves back: {} after {before}", cursor.0);
        assert_eq!(cursor.1.is_empty(), cursor.0 == 0, "a cursor above 0 has a mark");
        pages += 1;
    }
    let every: Vec<String> = (0..700).map(|n| format!("prompt {n}")).collect();
    assert_eq!(all, every, "every turn once, in order");
    assert_eq!(pages, 3);
    // Nothing was written to the log.
    assert_eq!(seeded(&hub).0.len(), 200);
    let _ = std::fs::remove_dir_all(home);
}

#[tokio::test]
async fn a_page_read_again_has_the_same_seqs() {
    let home = home("again");
    let hub = hub(&home);
    let file = home.join("projects/-work/s1.jsonl");
    transcript(&file, 260, 16);
    let session = hub.resolve("chat").unwrap();
    hub.replay_adopted(&session, "claude", file.clone()).await;
    let (_, cursor) = seeded(&hub);
    let (first, second) = (page(&hub, &cursor).await, page(&hub, &cursor).await);
    assert_eq!(first["events"], second["events"]);
    assert_eq!(first["events"][0]["seq"].as_i64(), Some(native_seq(cursor.0, 0)));
    let _ = std::fs::remove_dir_all(home);
}

#[tokio::test]
async fn a_watched_chat_pages_its_watched_transcript() {
    let home = home("watched");
    let hub = hub(&home);
    // Not where the Claude store would put it: the watch names it.
    let file = home.join("elsewhere.jsonl");
    transcript(&file, 260, 16);
    let session = hub.resolve("chat").unwrap();
    session.meta.lock().unwrap().watching = Some(crate::store::Watching {
        family: "claude".into(),
        file: file.clone(),
        offset: std::fs::metadata(&file).unwrap().len(),
        codex_items: false,
        open: None,
    });
    let start =
        crate::adopt_replay::newest_prompt_start(&file, crate::adopt_replay::PAGE_TURNS).unwrap();
    let reply =
        page(&hub, &(start, super::mark(&mut std::fs::File::open(&file).unwrap(), start).unwrap()))
            .await;
    let prompts = prompts_of(reply["events"].as_array().unwrap());
    let want: Vec<String> = (0..60).map(|n| format!("prompt {n}")).collect();
    assert_eq!(prompts, want);
    assert_eq!(reply["before"], 0);
    session.meta.lock().unwrap().watching = None;
    let _ = std::fs::remove_dir_all(home);
}

#[tokio::test]
async fn a_cursor_must_be_a_native_history_one() {
    let home = home("refused");
    let hub = hub(&home);
    for params in [
        json!({"sessionId": "chat"}),
        json!({"sessionId": "chat", "before": 0, "mark": "1-0"}),
        json!({"sessionId": "chat", "before": 10}),
    ] {
        assert!(handle(&hub, &params).await.is_err(), "{params}");
    }
    // A chat whose transcript is not in its store has no native history.
    assert!(
        handle(&hub, &json!({"sessionId": "chat", "before": 10, "mark": "1-0"})).await.is_err()
    );
    let _ = std::fs::remove_dir_all(home);
}

/// A transcript replaced since its cursor was read (cut, rotated, another conversation written
/// there) does not page the new file's turns in as the chat's older ones: the cursor is refused.
#[tokio::test]
async fn a_cursor_into_a_replaced_transcript_is_refused() {
    let home = home("replaced");
    let hub = hub(&home);
    let file = home.join("projects/-work/s1.jsonl");
    transcript(&file, 260, 16);
    let session = hub.resolve("chat").unwrap();
    hub.replay_adopted(&session, "claude", file.clone()).await;
    let (_, cursor) = seeded(&hub);
    // Appending keeps the cursor good: the bytes it starts are still there.
    std::fs::OpenOptions::new().append(true).open(&file).unwrap().write_all(b"{}\n").unwrap();
    assert!(page(&hub, &cursor).await["turns"].as_u64().unwrap() > 0);
    // Truncating the seeded tail invalidates the cursor even if its older boundary is intact.
    let original = std::fs::read(&file).unwrap();
    std::fs::OpenOptions::new().write(true).open(&file).unwrap().set_len(cursor.0 + 1).unwrap();
    let params = json!({"sessionId": "chat", "before": cursor.0, "mark": cursor.1});
    let refused = handle(&hub, &params).await.unwrap_err();
    assert_eq!(refused.data.as_ref().unwrap()["reason"], "transcriptRead.stale");
    std::fs::write(&file, &original).unwrap();
    // Another, longer transcript in its place.
    transcript(&file, 400, 24);
    assert!(std::fs::metadata(&file).unwrap().len() > cursor.0);
    let params = json!({"sessionId": "chat", "before": cursor.0, "mark": cursor.1});
    let refused = handle(&hub, &params).await.unwrap_err();
    assert_eq!(refused.data.as_ref().unwrap()["reason"], "transcriptRead.stale");
    // A cut one, shorter than the cursor.
    transcript(&file, 3, 16);
    let refused = handle(&hub, &params).await.unwrap_err();
    assert_eq!(refused.data.as_ref().unwrap()["reason"], "transcriptRead.stale");
    let _ = std::fs::remove_dir_all(home);
}

/// The pre-mark daemon persisted only a byte cursor. Opening that chat after upgrading must
/// still reach its older turns, and the first reply upgrades subsequent reads to marked cursors.
#[tokio::test]
async fn a_persisted_legacy_seed_pages_and_returns_a_mark() {
    let home = home("legacy");
    let hub = hub(&home);
    let file = home.join("projects/-work/s1.jsonl");
    transcript(&file, 700, 16);
    let session = hub.resolve("chat").unwrap();
    let before =
        crate::adopt_replay::newest_claude_page(&file, crate::adopt_replay::PAGE_TURNS).start;
    hub.append(&session, "mux", "native_history", json!({"family": "claude", "before": before}));
    for params in [
        json!({"sessionId": "chat", "before": before}),
        json!({"sessionId": "chat", "before": before, "mark": null}),
    ] {
        let reply = handle(&hub, &params).await.unwrap();
        let prompts = prompts_of(reply["events"].as_array().unwrap());
        assert_eq!(prompts.first().map(String::as_str), Some("prompt 300"));
        assert_eq!(prompts.last().map(String::as_str), Some("prompt 499"));
        let cursor = next(&reply);
        assert!(cursor.0 > 0 && !cursor.1.is_empty());
        let older = page(&hub, &cursor).await;
        assert!(older["before"].as_u64().unwrap() < cursor.0);
        // Only the persisted unmarked seed is eligible, not a page's newly issued cursor.
        assert!(handle(&hub, &json!({"sessionId": "chat", "before": cursor.0})).await.is_err());
    }
    for params in [
        json!({"sessionId": "chat", "before": before - 1}),
        json!({"sessionId": "chat", "before": before, "mark": 42}),
        json!({"sessionId": "chat", "before": before, "mark": ""}),
        json!({"sessionId": "chat", "before": before, "mark": "invalid"}),
    ] {
        let refused = handle(&hub, &params).await.unwrap_err();
        assert_eq!(refused.data.as_ref().unwrap()["reason"], "transcriptRead.stale");
    }
    let _ = std::fs::remove_dir_all(home);
}

#[tokio::test]
async fn a_marked_seed_cannot_be_downgraded_to_an_unmarked_cursor() {
    let home = home("legacy-downgrade");
    let hub = hub(&home);
    let file = home.join("projects/-work/s1.jsonl");
    transcript(&file, 260, 16);
    let session = hub.resolve("chat").unwrap();
    hub.replay_adopted(&session, "claude", file).await;
    let (_, cursor) = seeded(&hub);
    let refused =
        handle(&hub, &json!({"sessionId": "chat", "before": cursor.0})).await.unwrap_err();
    assert_eq!(refused.data.as_ref().unwrap()["reason"], "transcriptRead.stale");
    let _ = std::fs::remove_dir_all(home);
}

/// A single turn can contain many individually-small tool inputs whose ACP events together exceed
/// one frame. The native page keeps every event and its sequence, but uses the existing explicit
/// omission marker on the largest payloads so the cursor still advances and the client never
/// retries a `message.too_large` reply forever.
#[test]
fn a_large_single_turn_reply_is_bounded_without_dropping_events() {
    let home = home("bounded-single-turn");
    let hub = hub(&home);
    let session = hub.resolve("chat").unwrap();
    let mut turn = PastTurn {
        prompt: "large turn".into(),
        prompt_at: Some(1),
        answer: "done".into(),
        answer_at: Some(2),
        ..PastTurn::default()
    };
    // 400 calls is the native transcript parser's per-turn bound. Each call is below the
    // individual-event frame threshold; together they make the unbounded reply exceed it.
    for n in 0..400 {
        turn.tools.push(PastTool {
            id: format!("tool-{n}"),
            call: json!({
                "kind": "execute",
                "title": "large input",
                "rawInput": {"command": "x".repeat(80_000)}
            }),
            done: json!({"status": "completed"}),
            started_at: Some(1),
            ended_at: Some(2),
            proposed: None,
        });
    }
    let raw = page_reply(&session, 1, ClaudePage { turns: vec![turn], start: 0, read: 1 }, None);
    assert!(result_bytes(&raw) > MAX_MESSAGE_BYTES - (1 << 20));
    let event_count = raw["events"].as_array().unwrap().len();
    let bounded = fit_reply(raw);
    let events = bounded["events"].as_array().unwrap();
    assert_eq!(events.len(), event_count);
    assert!(events.iter().any(|event| event["msg"]["_meta"]["acpmux"]["omitted"].is_object()));
    let rpc = crate::rpc::Message::ok(json!("native-history"), bounded).to_line();
    assert!(rpc.len() <= MAX_MESSAGE_BYTES, "native history RPC is {} bytes", rpc.len());
    let _ = std::fs::remove_dir_all(home);
}

/// Several turns can each fit on their own while the page's ACP representation exceeds one
/// frame. The handler must reduce the page to whole turns, return a usable byte cursor, and keep
/// every prompt exactly once as the caller follows that cursor to zero.
#[tokio::test]
async fn oversized_native_pages_keep_rpc_bounds_and_continuations() {
    let home = home("bounded-continuation");
    let hub = hub(&home);
    let file = home.join("projects/-work/s1.jsonl");
    let mut out = std::io::BufWriter::new(std::fs::File::create(&file).unwrap());
    let content = "x".repeat(75_000);
    // Three older turns each have roughly 6 MiB of raw Write input and roughly 12 MiB of ACP
    // call content (rawInput plus the display diff). Two turns exceed the 14 MiB result budget,
    // while each turn remains well below the individual-event frame limit.
    for n in 0..3 {
        writeln!(
            out,
            "{}",
            json!({
                "type": "user",
                "timestamp": "2026-10-29T10:00:00.000Z",
                "message": {"role": "user", "content": format!("large prompt {n}")}
            })
        )
        .unwrap();
        let blocks: Vec<Value> = (0..100)
            .map(|t| {
                json!({
                    "type": "tool_use",
                    "id": format!("toolu_{n}_{t}"),
                    "name": "Write",
                    "input": {"file_path": format!("/tmp/{n}-{t}.txt"), "content": content}
                })
            })
            .collect();
        writeln!(
            out,
            "{}",
            json!({
                "type": "assistant",
                "timestamp": "2026-10-29T10:00:01.000Z",
                "message": {"role": "assistant", "content": blocks}
            })
        )
        .unwrap();
        let results: Vec<Value> = (0..100)
            .map(|t| {
                json!({"type": "tool_result", "tool_use_id": format!("toolu_{n}_{t}"),
                    "content": "File updated successfully"})
            })
            .collect();
        writeln!(out, "{}", json!({"type": "user", "message": {"content": results}})).unwrap();
        writeln!(
            out,
            "{}",
            json!({
                "type": "assistant",
                "timestamp": "2026-10-29T10:00:02.000Z",
                "message": {
                    "role": "assistant",
                    "stop_reason": "end_turn",
                    "content": [{"type": "text", "text": format!("large answer {n}")}]
                }
            })
        )
        .unwrap();
    }
    // The newest page is seeded with these small turns; the three large turns remain native-only.
    for n in 3..203 {
        writeln!(
            out,
            "{}",
            json!({
                "type": "user",
                "timestamp": "2026-10-29T10:00:00.000Z",
                "message": {"role": "user", "content": format!("prompt {n}")}
            })
        )
        .unwrap();
        writeln!(
            out,
            "{}",
            json!({
                "type": "assistant",
                "timestamp": "2026-10-29T10:00:01.000Z",
                "message": {
                    "role": "assistant",
                    "stop_reason": "end_turn",
                    "content": [{"type": "text", "text": format!("answer {n}")}]
                }
            })
        )
        .unwrap();
    }
    drop(out);
    let session = hub.resolve("chat").unwrap();
    hub.replay_adopted(&session, "claude", file.clone()).await;
    let (mut prompts, mut cursor) = seeded(&hub);
    let raw_page = crate::adopt_replay::claude_page_with_turns(
        &file,
        Some(cursor.0),
        crate::adopt_replay::PAGE_TURNS,
    );
    let raw = page_reply(&session, cursor.0, raw_page, None);
    // The larger transport budget can carry this page without trimming; the continuation
    // assertions below cover whole-turn paging and the RPC bound.
    assert!(!raw["events"].as_array().unwrap().is_empty(), "fixture should contain events");
    let mut pages = 0;
    while cursor.0 > 0 {
        let reply = page(&hub, &cursor).await;
        let rpc = crate::rpc::Message::ok(json!("native-history"), reply.clone()).to_line();
        assert!(rpc.len() <= MAX_MESSAGE_BYTES, "native history RPC is {} bytes", rpc.len());
        let events = reply["events"].as_array().unwrap();
        assert!(
            events.iter().all(|event| event["msg"]["_meta"]["acpmux"]["omitted"].is_null()),
            "whole turns that fit must not omit payloads"
        );
        let mut older = prompts_of(events);
        older.extend(prompts);
        prompts = older;
        let next_cursor = next(&reply);
        assert!(next_cursor.0 < cursor.0, "native cursor did not move back");
        cursor = next_cursor;
        pages += 1;
        assert!(pages <= 8, "large-turn continuation made too many pages");
    }
    let expected: Vec<String> = (0..203)
        .map(|n| if n < 3 { format!("large prompt {n}") } else { format!("prompt {n}") })
        .collect();
    assert_eq!(prompts, expected, "native continuation skipped or duplicated a prompt");
    let _ = std::fs::remove_dir_all(home);
}

/// The PR's harness (run with `--ignored --nocapture`): a ~400 MB synthetic Claude Code
/// transcript of tool-heavy turns, adopted, then its older pages read one after another; each
/// page is timed from the request to its reply.
#[tokio::test]
#[ignore = "bench: writes a 400 MB transcript"]
async fn bench_older_native_page_of_a_400_mb_transcript() {
    let home = home("bench");
    let hub = hub(&home);
    let file = home.join("projects/-work/s1.jsonl");
    {
        let mut f = std::io::BufWriter::new(std::fs::File::create(&file).unwrap());
        let output = "o".repeat(20 << 10);
        for n in 0..810 {
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
    hub.replay_adopted(&session, "claude", file.clone()).await;
    let (_, mut cursor) = seeded(&hub);
    let mut times = Vec::new();
    let mut turns = 0;
    while cursor.0 > 0 && times.len() < 12 {
        let before = cursor.0;
        let started = std::time::Instant::now();
        let reply = page(&hub, &cursor).await;
        let ms = started.elapsed().as_secs_f64() * 1e3;
        let bytes = serde_json::to_string(&reply).unwrap().len();
        times.push(ms);
        turns += reply["turns"].as_u64().unwrap();
        println!(
            "BENCH page={} before={before} turns={} read_mb={:.1} reply_kb={} ms={ms:.1}",
            times.len(),
            reply["turns"],
            reply["read"].as_f64().unwrap() / 1e6,
            bytes / 1024,
        );
        cursor = next(&reply);
    }
    let mut sorted = times.clone();
    sorted.sort_by(f64::total_cmp);
    println!(
        "BENCH transcript_mb={:.1} pages={} turns={turns} median_ms={:.1} max_ms={:.1}",
        len as f64 / 1e6,
        times.len(),
        sorted[sorted.len() / 2],
        sorted.last().unwrap(),
    );
    let _ = std::fs::remove_dir_all(home);
}
