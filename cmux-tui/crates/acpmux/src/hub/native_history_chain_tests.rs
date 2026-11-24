//! A chat resumed under new Claude ids pages back through every transcript it continued, oldest
//! first, with a divider at each join.

use super::super::Hub;
use super::super::native_history::handle;
use super::*;
use serde_json::{Value, json};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;

fn home(name: &str) -> PathBuf {
    let home =
        std::env::temp_dir().join(format!("acpmux-native-chain-{}-{name}", std::process::id()));
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
        "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    store.save(&meta).unwrap();
    Hub::new(cfg, store)
}

/// `turns` turns named `<label> <n>`, each a prompt, a tool call and its result and an answer;
/// a Claude Code compaction summary before turn `compact_at`, when given.
fn transcript(file: &Path, label: &str, turns: usize, compact_at: Option<usize>) {
    let mut f = std::io::BufWriter::new(std::fs::File::create(file).unwrap());
    for n in 0..turns {
        if compact_at == Some(n) {
            let summary = json!({"type": "user", "isCompactSummary": true,
                "timestamp": "2026-11-21T21:40:00.000Z",
                "message": {"role": "user", "content": "This session is being continued..."}});
            writeln!(f, "{summary}").unwrap();
        }
        let id = format!("toolu_{label}_{n}");
        let lines = [
            json!({"type": "user", "timestamp": "2026-11-21T21:50:00.000Z",
                "message": {"role": "user", "content": format!("{label} {n}")}}),
            json!({"type": "assistant", "timestamp": "2026-11-21T21:50:01.000Z",
                "message": {"role": "assistant", "content": [{"type": "tool_use", "id": id,
                    "name": "Bash", "input": {"command": format!("echo {n}")}}]}}),
            json!({"type": "user", "timestamp": "2026-11-21T21:50:02.000Z",
                "message": {"role": "user", "content": [{"type": "tool_result",
                    "tool_use_id": id, "content": "ok"}]}}),
            json!({"type": "assistant", "timestamp": "2026-11-21T21:50:03.000Z",
                "message": {"role": "assistant", "stop_reason": "end_turn",
                    "content": [{"type": "text", "text": format!("answer {n}")}]}}),
        ];
        for line in lines {
            writeln!(f, "{line}").unwrap();
        }
    }
}

fn file(home: &Path, id: &str) -> PathBuf {
    home.join(format!("projects/-work/{id}.jsonl"))
}

/// The chat runs under each id in turn, as restarts under new Claude ids record them.
fn run_under(hub: &Hub, ids: &[&str]) {
    let session = hub.resolve("chat").unwrap();
    let mut meta = session.meta.lock().unwrap();
    for id in ids {
        meta.set_agent_session_id(Some((*id).to_owned()), "claude");
    }
}

/// The seeded log's `native_history` cursor.
fn seeded(hub: &Hub) -> (u64, String) {
    let mut cursor = (0, String::new());
    hub.store
        .scan_kinds("chat", &["native_history"], &mut |rec| {
            cursor = (
                rec.msg["before"].as_u64().unwrap(),
                rec.msg["mark"].as_str().unwrap_or_default().to_owned(),
            );
            true
        })
        .unwrap();
    cursor
}

/// Every native page from `cursor` back, newest first, as the pane asks for them.
async fn page_all(hub: &Arc<Hub>, mut cursor: (u64, String)) -> Vec<Value> {
    let mut pages = Vec::new();
    while cursor.0 > 0 {
        let reply =
            handle(hub, &json!({"sessionId": "chat", "before": cursor.0, "mark": cursor.1}))
                .await
                .unwrap();
        let next = reply["before"].as_u64().unwrap();
        assert!(
            next < cursor.0 || reply.get("olderTranscript").is_some(),
            "a cursor moves back unless it starts an older transcript"
        );
        cursor = (next, reply["mark"].as_str().unwrap_or_default().to_owned());
        pages.push(reply);
        assert!(pages.len() < 64, "paging ends");
    }
    pages
}

/// The pages' rows oldest first: prompts as their text, dividers as `--- text`.
fn rows(pages: &[Value]) -> (Vec<String>, Vec<i64>) {
    let (mut rows, mut seqs) = (Vec::new(), Vec::new());
    for page in pages.iter().rev() {
        for event in page["events"].as_array().unwrap() {
            seqs.push(event["seq"].as_i64().unwrap());
            match event["kind"].as_str().unwrap() {
                "user_message" => rows.push(event["msg"]["text"].as_str().unwrap().to_owned()),
                "host_notice" => {
                    assert_eq!(event["msg"]["source"], "transcript");
                    rows.push(format!("--- {}", event["msg"]["text"].as_str().unwrap()));
                }
                _ => {}
            }
        }
    }
    (rows, seqs)
}

#[test]
fn the_chain_is_recorded_across_two_resumes() {
    let mut meta: crate::store::SessionMeta = serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "chat", "name": "chat",
        "harness": "claude", "cwd": "/w", "status": "idle", "createdAt": 1, "updatedAt": 1
    }))
    .unwrap();
    meta.set_agent_session_id(Some("a".into()), "claude");
    meta.set_agent_session_id(Some("b".into()), "claude");
    meta.set_agent_session_id(Some("c".into()), "claude");
    assert_eq!(meta.previous_agent_session_ids, ["a", "b"]);
    assert_eq!(older_ids(&meta, Some("c")), ["b", "a"]);
    assert_eq!(older_ids(&meta, Some("b")), ["a"]);
    assert!(older_ids(&meta, Some("a")).is_empty());
    assert!(older_ids(&meta, Some("stranger")).is_empty());
    assert!(older_ids(&meta, None).is_empty());
    // The same chain survives a save: it is the session's own record.
    let read: crate::store::SessionMeta =
        serde_json::from_value(serde_json::to_value(&meta).unwrap()).unwrap();
    assert_eq!(read.previous_agent_session_ids, ["a", "b"]);
}

#[test]
fn chained_marks_name_only_plain_ids_within_depth() {
    let mark = chain_mark(3, "abc-1", "v1:1:2:3:4:ff");
    assert_eq!(
        parse(&mark),
        Some(Chained { depth: 3, id: "abc-1".into(), inner: "v1:1:2:3:4:ff".into() })
    );
    assert_eq!(parse("v1:1:2:3:4:ff"), None);
    assert_eq!(parse("c1:0:abc:v1:x"), None, "depth 0 is the seeded transcript's own mark");
    assert_eq!(parse(&chain_mark(MAX_DEPTH + 1, "abc", "v1")), None);
    assert_eq!(parse("c1:1:../x:v1"), None, "an id names one file");
    assert_eq!(identity("v1:7:9:100:4:ff"), Some((7, 9)));
}

#[test]
fn every_band_sorts_below_the_newer_one_and_stays_safe_in_javascript() {
    let min_safe = -((1i64 << 53) - 1);
    let mut newer_low = seq(0, 1, 0);
    assert_eq!(newer_low, -(1i64 << 52) + (1 << 18));
    for depth in 1..=MAX_DEPTH {
        let high = seq(depth, 32 << 30, (1 << 18) - 1);
        let low = seq(depth, 0, 0);
        assert!(high < newer_low, "depth {depth} is below depth {}", depth - 1);
        assert!(low >= min_safe, "depth {depth} is a safe integer");
        assert!(seq(depth, 64, 0) > seq(depth, 0, (1 << 18) - 1), "a later page sorts after");
        newer_low = low;
    }
}

/// Leo's chat: adopted from one Claude transcript (`mid`), which continued another (`old`); then
/// its agent came back under a new id (`new`). Scrolling up reads `mid` and then `old`, oldest
/// first, a divider at the join, every seq in order across both.
#[tokio::test]
async fn a_resumed_chat_pages_back_through_its_earlier_transcript() {
    let home = home("order");
    let hub = hub(&home);
    transcript(&file(&home, "old"), "old", 230, None);
    transcript(&file(&home, "mid"), "mid", 260, None);
    run_under(&hub, &["old", "mid"]);
    let session = hub.resolve("chat").unwrap();
    hub.replay_adopted(&session, "claude", file(&home, "mid")).await;
    let seed = seeded(&hub);
    assert!(seed.0 > 0);
    // The agent restarts under a new id: the seeded cursor still reads `mid`.
    run_under(&hub, &["new"]);
    assert_eq!(session.meta().previous_agent_session_ids, ["old", "mid"]);
    let pages = page_all(&hub, seed).await;
    let (got, seqs) = rows(&pages);
    assert!(seqs.windows(2).all(|w| w[0] < w[1]), "oldest first across transcripts");
    assert!(*seqs.last().unwrap() < 1, "below every logged record");
    let mut want: Vec<String> = (0..230).map(|n| format!("old {n}")).collect();
    want.push("--- resumed 21:50Z".into());
    // The seeded page held `mid`'s newest 200.
    want.extend((0..60).map(|n| format!("mid {n}")));
    assert_eq!(got, want);
    let hop = pages.iter().find_map(|p| p.get("olderTranscript")).expect("a reply names the hop");
    assert_eq!(hop["agentSessionId"], "old");
    assert_eq!(hop["depth"], 1);
    let _ = std::fs::remove_dir_all(home);
}

/// An earlier transcript deleted from disk is a divider, never an error, and paging goes on to
/// the one before it.
#[tokio::test]
async fn a_missing_earlier_transcript_is_a_divider() {
    let home = home("missing");
    let hub = hub(&home);
    transcript(&file(&home, "first"), "first", 3, None);
    transcript(&file(&home, "cur"), "cur", 210, None);
    run_under(&hub, &["first", "gone", "cur"]);
    let session = hub.resolve("chat").unwrap();
    hub.replay_adopted(&session, "claude", file(&home, "cur")).await;
    let (got, _) = rows(&page_all(&hub, seeded(&hub)).await);
    let mut want: Vec<String> = (0..3).map(|n| format!("first {n}")).collect();
    want.push("--- earlier transcript not found".into());
    want.push("--- resumed 21:50Z".into());
    want.extend((0..10).map(|n| format!("cur {n}")));
    assert_eq!(got, want);
    // With nothing older on disk at all, the dividers end the scrollback.
    std::fs::remove_file(file(&home, "first")).unwrap();
    let (got, _) = rows(&page_all(&hub, seeded(&hub)).await);
    let gone = "--- earlier transcript not found";
    assert_eq!(got[..3], [gone, gone, "--- resumed 21:50Z"]);
    assert_eq!(got.len(), 13);
    let _ = std::fs::remove_dir_all(home);
}

/// A chained cursor names only the chat's own earlier ids.
#[tokio::test]
async fn a_chained_cursor_to_a_stranger_transcript_is_refused() {
    let home = home("stranger");
    let hub = hub(&home);
    transcript(&file(&home, "other"), "other", 3, None);
    run_under(&hub, &["mine"]);
    let len = std::fs::metadata(file(&home, "other")).unwrap().len();
    let mut input = std::fs::File::open(file(&home, "other")).unwrap();
    let inner = super::super::native_history::mark(&mut input, len).unwrap();
    let params =
        json!({"sessionId": "chat", "before": len, "mark": chain_mark(1, "other", &inner)});
    let refused = handle(&hub, &params).await.unwrap_err();
    assert_eq!(refused.data.as_ref().unwrap()["reason"], "transcriptRead.stale");
    let _ = std::fs::remove_dir_all(home);
}

/// A Claude Code compaction inside a transcript is a "compacted" divider before the turn after it.
#[tokio::test]
async fn a_compaction_is_a_divider_where_it_happened() {
    let home = home("compact");
    let hub = hub(&home);
    transcript(&file(&home, "s"), "s", 230, Some(10));
    run_under(&hub, &["s"]);
    let session = hub.resolve("chat").unwrap();
    hub.replay_adopted(&session, "claude", file(&home, "s")).await;
    let (got, _) = rows(&page_all(&hub, seeded(&hub)).await);
    let mut want: Vec<String> = (0..10).map(|n| format!("s {n}")).collect();
    want.push("--- compacted".into());
    want.extend((10..30).map(|n| format!("s {n}")));
    assert_eq!(got, want, "the summary itself is never a prompt");
    let _ = std::fs::remove_dir_all(home);
}
