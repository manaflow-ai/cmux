//! Pages of a chat whose tool calls re-send their whole output (`store/superseded.rs`).

use super::*;
use crate::store::{EventRecord, LocalStore, SessionMeta, Store};

/// The app's open page (webviews `direct.ts`: `limit` 400, `OPEN_PAGE_BYTES` 128 KiB).
const OPEN_LIMIT: usize = 400;
const OPEN_BYTES: usize = 128 * 1024;

fn hub(store: Box<dyn Store>) -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    Hub::new(cfg, store)
}

fn meta(id: &str) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": id, "name": "codex chat", "harness": "codex",
        "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 2,
    }))
    .unwrap()
}

fn agent(seq: u64, kind: &str, update: Value) -> EventRecord {
    let msg = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a", "update": update}});
    EventRecord { seq, at: seq, dir: "in".into(), kind: kind.into(), msg, host_seq: None }
}

/// A Codex chat as codex-acp logs it: per turn a prompt, a command whose `steps` updates each
/// carry its whole output so far (and the increment, `terminal_output_delta`), its end, and an
/// answer. The last turn's command is still running when `running`.
fn codex_chat(turns: usize, steps: usize, step_bytes: usize, running: bool) -> Vec<EventRecord> {
    let mut out = Vec::new();
    let mut seq = 0;
    let mut next = || {
        seq += 1;
        seq
    };
    for turn in 0..turns {
        let id = format!("call_{turn}");
        let prompt = json!({"text": format!("prompt {turn}")});
        out.push(EventRecord {
            seq: next(),
            at: 0,
            dir: "mux".into(),
            kind: "user_message".into(),
            msg: prompt,
            host_seq: None,
        });
        out.push(agent(next(), "tool_call", json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": "cargo test", "kind": "execute", "status": "in_progress"})));
        let mut output = String::new();
        for step in 0..steps {
            let piece = format!("{step:06} {}\n", "o".repeat(step_bytes.saturating_sub(8)));
            output.push_str(&piece);
            let mut update = json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "_meta": {"terminal_output_delta": {"data": piece}}});
            if step % 8 == 0 {
                update["content"] =
                    json!([{"type": "content", "content": {"type": "text", "text": output}}]);
            }
            out.push(agent(next(), "tool_call_update", update));
        }
        if running && turn + 1 == turns {
            break;
        }
        out.push(agent(next(), "tool_call_update", json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed", "rawOutput": {"exit_code": 0}, "content": [{"type": "content", "content": {"type": "text", "text": output}}]})));
        out.push(agent(next(), "agent_message_chunk", json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": format!("answer {turn}")}})));
    }
    out
}

/// What a reader that folds a page in order shows of each call: ACP content replaces, every other
/// field the update names is set.
fn fold(
    records: &[EventRecord],
) -> std::collections::BTreeMap<String, serde_json::Map<String, Value>> {
    let mut calls = std::collections::BTreeMap::<String, serde_json::Map<String, Value>>::new();
    for rec in records {
        let Some(update) = rec.msg.pointer("/params/update").and_then(Value::as_object) else {
            continue;
        };
        let Some(id) = update.get("toolCallId").and_then(Value::as_str) else { continue };
        let call = calls.entry(id.to_owned()).or_default();
        for (key, value) in update.iter().filter(|(k, _)| *k != "_meta") {
            call.insert(key.clone(), value.clone());
        }
    }
    calls
}

fn prompts(page: &EventPage) -> usize {
    page.events.iter().filter(|r| r.kind == "user_message").count()
}

fn transcript(omit: bool) -> EventFilter {
    EventFilter::parse(Some(&json!(["transcript"]))).unwrap().omitting_superseded(omit)
}

/// Leo, 2026-10-29: "as in i want ours to load fast too". A Codex chat's open page held a few
/// snapshots of its last command; it now holds every turn, each call ending as logged.
#[test]
fn a_codex_chats_open_page_holds_its_turns_not_snapshots_of_one_command() {
    let hub = hub(Box::new(crate::store::MemoryStore::default()));
    hub.store.save(&meta("c")).unwrap();
    let log = codex_chat(6, 160, 96, true);
    for rec in &log {
        hub.store.append("c", rec).unwrap();
    }
    let open = |omit| {
        hub.events_page("c", 0, None, OPEN_LIMIT, Some(OPEN_BYTES), true, &transcript(omit))
            .unwrap()
    };
    // As the page was: the bound goes to the running command's snapshots.
    let old = open(false);
    assert!(prompts(&old) < 2, "{} prompts in the page", prompts(&old));
    let page = open(true);
    assert_eq!(prompts(&page), 6, "every turn's prompt is in the open page");
    assert!(!page.has_more, "nothing older that the page needs");
    let page_calls = fold(&page.events);
    let log_calls = fold(&log);
    assert_eq!(page_calls, log_calls, "every call ends as logged, the running one too");
    // Each finished call: its start and end. The running one: its start and newest snapshot, and
    // the increments after it.
    let updates = page.events.iter().filter(|r| r.kind == "tool_call_update").count();
    assert!(updates < 5 + 8, "{updates} updates in the page");
    // Older pages and a page by count alone read every record; so does a forward read.
    let all = hub.events_page("c", 0, None, 100_000, None, true, &transcript(false)).unwrap();
    assert_eq!(all.events.len(), log.len());
    let forward =
        hub.events_page("c", 0, None, 100_000, Some(OPEN_BYTES), false, &transcript(true)).unwrap();
    assert!(forward.events.iter().zip(&log).all(|(a, b)| a == b));
}

/// The open page's measurements (the PR's Performance table): run with
/// `cargo test -p acpmux --release -- --ignored --nocapture open_page_perf`.
#[test]
#[ignore = "a measurement, not a check"]
fn open_page_perf() {
    let root = std::env::temp_dir().join(format!("acpmux-open-page-perf-{}", uuid::Uuid::now_v7()));
    let sessions = root.join("sessions");
    let writer = LocalStore::new(sessions.clone(), 8 << 20).unwrap();
    writer.save(&meta("c")).unwrap();
    // 20 commands x 400 updates, each re-sending its output so far (34 KB at the end).
    for rec in codex_chat(20, 400, 85, false) {
        writer.append("c", &rec).unwrap();
    }
    let disk = || -> u64 {
        std::fs::read_dir(sessions.join("c").join("events"))
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| e.file_name().to_string_lossy().ends_with(".ndjson"))
            .map(|e| e.metadata().unwrap().len())
            .sum()
    };
    let hub = hub(Box::new(LocalStore::new(sessions.clone(), 8 << 20).unwrap()));
    let measure = |label: &str, omit: bool| {
        let mut times = Vec::new();
        let mut page = EventPage::default();
        for _ in 0..7 {
            let started = std::time::Instant::now();
            page = hub
                .events_page("c", 0, None, OPEN_LIMIT, Some(OPEN_BYTES), true, &transcript(omit))
                .unwrap();
            times.push(started.elapsed().as_secs_f64() * 1000.0);
        }
        times.sort_by(f64::total_cmp);
        let bytes: usize = page.events.iter().map(|r| serde_json::to_vec(r).unwrap().len()).sum();
        println!(
            "{label}: log {} bytes on disk; open page {} records, {} prompts of 20, {bytes} bytes; median {:.1} ms",
            disk(),
            page.events.len(),
            prompts(&page),
            times[times.len() / 2]
        );
    };
    measure("before", false);
    let started = std::time::Instant::now();
    let stats = writer.compact_sealed_log("c").unwrap();
    println!(
        "sealed segments compacted in {:.0} ms: {stats:?}",
        started.elapsed().as_secs_f64() * 1000.0
    );
    measure("after", true);
    let _ = std::fs::remove_dir_all(&root);
}
