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

/// What a reader that folds a page in order shows of each call (`mergeToolItem`): content
/// replaces, input and `_meta` keys merge (Codex's increments aside), every other field the record
/// names is set, the start is the first record's time and the end the first ending one's.
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
        call.entry("startedAt").or_insert(json!(rec.at));
        if matches!(update.get("status").and_then(Value::as_str), Some("completed" | "failed")) {
            call.entry("endedAt").or_insert(json!(rec.at));
        }
        for (key, value) in update {
            match (key.as_str(), value.as_object()) {
                ("rawInput" | "_meta", Some(parts)) => {
                    for (k, v) in parts
                        .iter()
                        .filter(|(k, _)| *k != "terminal_output_delta" && *k != "acpmux")
                    {
                        call.entry(key.clone()).or_insert_with(|| json!({}))[k] = v.clone();
                    }
                }
                _ => {
                    call.insert(key.clone(), value.clone());
                }
            }
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
    // A page that starts inside the running command (after its start) shows it from the same
    // time, with the same output.
    let start = log.iter().rev().find(|r| r.kind == "tool_call").unwrap().seq;
    let inside = hub
        .events_page("c", start, None, OPEN_LIMIT, Some(OPEN_BYTES), true, &transcript(true))
        .unwrap();
    let after: Vec<EventRecord> = log.iter().filter(|r| r.seq > start).cloned().collect();
    assert_eq!(fold(&inside.events), fold(&after));
    assert!(inside.events.len() < 4, "{} records", inside.events.len());
}

/// A page of some kinds only still reads the prompts between them: a call id a later prompt reuses
/// (cx-jzhka) never takes an earlier prompt's output out of the page.
#[test]
fn a_page_of_tool_updates_only_keeps_each_prompts_call_apart() {
    let hub = hub(Box::new(crate::store::MemoryStore::default()));
    hub.store.save(&meta("c")).unwrap();
    let prompt = |seq| EventRecord {
        seq,
        at: seq,
        dir: "mux".into(),
        kind: "user_message".into(),
        msg: json!({"text": "again"}),
        host_seq: None,
    };
    let call = |seq, text: &str, status: &str| {
        agent(
            seq,
            "tool_call_update",
            json!({"sessionUpdate": "tool_call_update", "toolCallId": "0", "status": status, "content": [{"type": "text", "text": text}]}),
        )
    };
    let log = vec![
        prompt(1),
        call(2, "first prompt's output", "in_progress"),
        prompt(3),
        call(4, "second prompt's output", "completed"),
    ];
    for rec in &log {
        hub.store.append("c", rec).unwrap();
    }
    let updates =
        EventFilter::parse(Some(&json!(["tool_call_update"]))).unwrap().omitting_superseded(true);
    let page = hub.events_page("c", 0, None, OPEN_LIMIT, Some(OPEN_BYTES), true, &updates).unwrap();
    assert_eq!(
        page.events,
        vec![log[1].clone(), log[3].clone()],
        "both prompts' calls keep their output"
    );
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
    let hub = hub(Box::new(LocalStore::new(sessions.clone(), 8 << 20).unwrap()));
    // The open, then older pages as the app's `loadOlder` reads them, until 10 prompts show.
    let measure = |label: &str, omit: bool| {
        let mut runs = Vec::new();
        let mut summary = String::new();
        for _ in 0..5 {
            let started = std::time::Instant::now();
            let open = hub
                .events_page("c", 0, None, OPEN_LIMIT, Some(OPEN_BYTES), true, &transcript(omit))
                .unwrap();
            let open_ms = started.elapsed().as_secs_f64() * 1000.0;
            let size = |page: &EventPage| -> usize {
                page.events.iter().map(|r| serde_json::to_vec(r).unwrap().len()).sum()
            };
            let (open_records, open_prompts, open_bytes) =
                (open.events.len(), prompts(&open), size(&open));
            let (mut shown, mut bytes, mut pages) = (open_prompts, open_bytes, 1usize);
            let mut oldest = open.events.first().map(|r| r.seq);
            let mut more = open.has_more;
            while shown < 10 && more {
                let Some(before) = oldest else { break };
                let page = hub
                    .events_page(
                        "c",
                        0,
                        Some(before),
                        OPEN_LIMIT,
                        Some(256 * 1024),
                        true,
                        &transcript(omit),
                    )
                    .unwrap();
                pages += 1;
                shown += prompts(&page);
                bytes += size(&page);
                oldest = page.events.first().map(|r| r.seq);
                more = page.has_more;
            }
            let total_ms = started.elapsed().as_secs_f64() * 1000.0;
            runs.push((open_ms, total_ms));
            summary = format!(
                "open page {open_records} records, {open_prompts} prompts, {open_bytes} bytes; {pages} pages and {bytes} bytes to show {shown} prompts"
            );
        }
        let median = |pick: fn(&(f64, f64)) -> f64| {
            let mut times: Vec<f64> = runs.iter().map(pick).collect();
            times.sort_by(f64::total_cmp);
            times[times.len() / 2]
        };
        let (open, total) = (median(|r| r.0), median(|r| r.1));
        println!("{label}: {summary}; median open {open:.1} ms, to 10 prompts {total:.1} ms");
    };
    measure("before", false);
    measure("after", true);
    let _ = std::fs::remove_dir_all(&root);
}

/// Bytes this thread has read (Linux `rchar`): other tests' reads are not counted.
fn read_bytes() -> u64 {
    std::fs::read_to_string("/proc/thread-self/io")
        .ok()
        .and_then(|io| {
            io.lines().find(|l| l.starts_with("rchar:"))?.split_whitespace().nth(1)?.parse().ok()
        })
        .unwrap_or(0)
}

/// A restored chat's first open, phase by phase: run with
/// `cargo test -p acpmux --release -- --ignored --nocapture cold_open_perf`.
#[test]
#[ignore = "a measurement, not a check"]
fn cold_open_perf() {
    let turns: usize =
        std::env::var("COLD_OPEN_TURNS").ok().and_then(|v| v.parse().ok()).unwrap_or(100);
    cold_opens(turns, 3, true);
}

/// A restored chat's log load reads the copies of what it reads, not its log
/// (`store/kind_index.rs`): the first start after an upgrade reads the log once, the next ones
/// a small part of it. Counted on Linux, where a thread's reads are known.
#[test]
fn a_restored_chats_log_load_reads_the_copies_not_its_log() {
    let (log_bytes, reads) = cold_opens(6, 2, false);
    if cfg!(target_os = "linux") {
        assert!(reads[0] >= log_bytes, "the first load read {} of {log_bytes} bytes", reads[0]);
        assert!(reads[1] < log_bytes / 4, "a restored load read {} of {log_bytes} bytes", reads[1]);
    }
}

/// `runs` fresh hubs over one Codex-shaped log of `turns` turns, each loading the chat's log and
/// its open page; the log's bytes and what each load read.
fn cold_opens(turns: usize, runs: usize, print: bool) -> (u64, Vec<u64>) {
    let root = std::env::temp_dir().join(format!("acpmux-cold-open-{}", uuid::Uuid::now_v7()));
    let sessions = root.join("sessions");
    {
        let writer = LocalStore::new(sessions.clone(), 8 << 20).unwrap();
        let mut m = meta("c");
        m.status = crate::store::SessionStatus::Idle;
        // Each turn ends with its result, as a chat's log does (the log load reads back to it).
        let mut log = Vec::new();
        for rec in codex_chat(turns, 400, 85, false) {
            let answer = rec.kind == "agent_message_chunk";
            log.push(rec);
            if answer {
                let mut end = log.last().unwrap().clone();
                (end.dir, end.kind, end.msg) =
                    ("mux".into(), "turn_result".into(), json!({"status": "completed"}));
                log.push(end);
            }
        }
        for (n, rec) in log.iter_mut().enumerate() {
            (rec.seq, rec.at) = (n as u64 + 1, n as u64 + 1);
        }
        for rec in &log {
            writer.append("c", rec).unwrap();
        }
        m.last_seq = log.last().unwrap().seq;
        m.event_count = log.len() as u64;
        writer.save(&m).unwrap();
        writer.flush().unwrap();
    }
    let log_bytes: u64 = std::fs::read_dir(sessions.join("c").join("events"))
        .unwrap()
        .map(|e| e.unwrap().metadata().unwrap().len())
        .sum();
    // The first start after an upgrade reads the log and copies what a log load reads; the next
    // ones read the copies (`store/kind_index.rs`).
    let mut reads = Vec::new();
    for _ in 0..runs {
        let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
        let mut cfg: crate::config::Config = serde_json::from_value(json!({
            "harnesses": {"fake": {"argv": ["python3", fake]}},
            "defaultHarness": "fake",
        }))
        .unwrap();
        cfg.store.mode = crate::config::StoreMode::Memory;
        let (r0, t0) = (read_bytes(), std::time::Instant::now());
        let hub = Hub::new_deferred(
            cfg,
            Box::new(LocalStore::new(sessions.clone(), 8 << 20).unwrap()),
            crate::mailbox::Mailbox::memory(),
        );
        let s = hub.resolve("c").unwrap();
        let (r1, t1) = (read_bytes(), std::time::Instant::now());
        hub.load_session_log(&s);
        let (r2, t2) = (read_bytes(), std::time::Instant::now());
        let page = hub
            .events_page("c", 0, None, OPEN_LIMIT, Some(OPEN_BYTES), true, &transcript(true))
            .unwrap();
        let (r3, t3) = (read_bytes(), std::time::Instant::now());
        let ms = |a: std::time::Instant, b: std::time::Instant| (b - a).as_secs_f64() * 1000.0;
        reads.push(r2 - r1);
        if !print {
            continue;
        }
        println!(
            "cold open: log {:.1} MB; start {:.1} ms {:.1} MB read; chat log load {:.1} ms {:.1} MB read; open page {:.1} ms {:.1} MB read, {} records",
            log_bytes as f64 / 1e6,
            ms(t0, t1),
            (r1 - r0) as f64 / 1e6,
            ms(t1, t2),
            (r2 - r1) as f64 / 1e6,
            ms(t2, t3),
            (r3 - r2) as f64 / 1e6,
            page.events.len()
        );
    }
    let _ = std::fs::remove_dir_all(&root);
    (log_bytes, reads)
}
