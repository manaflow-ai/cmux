//! Pages of a chat whose tool calls re-send their whole output (`store/superseded.rs`).

use super::*;
use crate::store::{EventRecord, LocalStore, PARSED_BYTES, PARSED_LINES, SessionMeta, Store};
use std::io::Write;

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

/// A page of a chat's prompts reads the log's copies of them (`store/kind_index.rs`), not the
/// log: read back from the end, the 16 prompts an open's `turnOpener` asks for walked the whole
/// log of a chat with fewer, 4 s for a 1 GB chat on a lane (Leo, 2026-11-06: "we need to have
/// things work a lot faster on load"). Its pages are the ones the read back gives, at every bound.
#[test]
fn a_page_of_prompts_reads_the_copies_not_the_log() {
    let root = std::env::temp_dir().join(format!("acpmux-prompt-page-{}", uuid::Uuid::now_v7()));
    let sessions = root.join("sessions");
    // Four turns of a long command's output; a steer and a queued prompt among them.
    let mut log = codex_chat(4, 120, 85, false);
    let steer_at = log.len() / 2;
    let mut steer = log[steer_at].clone();
    (steer.kind, steer.msg) = ("user_message".into(), json!({"text": "also this", "steer": true}));
    log.insert(steer_at, steer);
    let mut queued = log[steer_at].clone();
    (queued.kind, queued.msg) = ("queued".into(), json!({"text": "next", "pad": "q".repeat(500)}));
    log.insert(steer_at, queued);
    for (n, rec) in log.iter_mut().enumerate() {
        rec.seq = n as u64 + 1;
    }
    let last = log.last().unwrap().seq;
    let writer = LocalStore::new(sessions.clone(), 256 << 10).unwrap();
    writer.save(&meta("c")).unwrap();
    let memory = crate::store::MemoryStore::default();
    memory.save(&meta("c")).unwrap();
    for rec in &log {
        writer.append("c", rec).unwrap();
        memory.append("c", rec).unwrap();
    }
    writer.flush().unwrap();
    let local = hub(Box::new(LocalStore::new(sessions.clone(), 256 << 10).unwrap()));
    // `MemoryStore` keeps no copies: its pages are read back from the end.
    let back = hub(Box::new(memory));
    // A chat's log load makes the copies (`hub/log_load.rs`).
    local.store.scan_kinds("c", crate::store::INDEXED_KINDS, &mut |_| true).unwrap();
    let log_bytes: u64 = std::fs::read_dir(sessions.join("c").join("events"))
        .unwrap()
        .map(|e| e.unwrap().metadata().unwrap().len())
        .sum();
    let prompts = EventFilter::parse(Some(&json!(["user_message"]))).unwrap();
    let r0 = read_bytes();
    let page = local.events_page("c", 0, Some(last), 16, Some(OPEN_BYTES), true, &prompts).unwrap();
    let read = read_bytes() - r0;
    assert_eq!(page.events.len(), 5, "four prompts and the steer");
    assert!(!page.has_more);
    if cfg!(target_os = "linux") {
        assert!(read < log_bytes / 4, "a page of prompts read {read} of {log_bytes} bytes");
    }
    let queue = EventFilter::parse(Some(&json!(["queued", "user_message"])))
        .unwrap()
        .omitting_superseded(true);
    let steer_seq = log.iter().find(|r| r.msg.get("steer").is_some()).unwrap().seq;
    for filter in [&prompts, &queue] {
        for (after, before, limit, max) in [
            (0, Some(last), 16, Some(OPEN_BYTES)),
            (0, None, 2, Some(OPEN_BYTES)),
            (0, Some(steer_seq), 1, None),
            (0, Some(steer_seq + 1), 16, Some(1)),
            (steer_seq, None, 16, Some(OPEN_BYTES)),
            (0, Some(2), 16, None),
        ] {
            let read = |hub: &Arc<Hub>| {
                let page = hub.events_page("c", after, before, limit, max, true, filter).unwrap();
                (page.events, page.has_more)
            };
            assert_eq!(
                read(&local),
                read(&back),
                "after {after} before {before:?} limit {limit} max {max:?}"
            );
        }
    }
    let _ = std::fs::remove_dir_all(&root);
}

/// A hub started as a daemon starts (`Hub::new_deferred`): no chat's log is read yet, so no log
/// load has made copies of its prompts.
fn deferred_hub(sessions: &std::path::Path, segment_bytes: u64) -> Arc<Hub> {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut cfg: crate::config::Config = serde_json::from_value(json!({
        "harnesses": {"fake": {"argv": ["python3", fake]}},
        "defaultHarness": "fake",
    }))
    .unwrap();
    cfg.store.mode = crate::config::StoreMode::Memory;
    Hub::new_deferred(
        cfg,
        Box::new(LocalStore::new(sessions.to_path_buf(), segment_bytes).unwrap()),
        crate::mailbox::Mailbox::memory(),
    )
}

/// Writes `log` as chat `c` in segments of `segment_bytes`, numbered from 1; its bytes on disk.
fn write_chat(sessions: &std::path::Path, log: &mut [EventRecord], segment_bytes: u64) -> u64 {
    for (n, rec) in log.iter_mut().enumerate() {
        rec.seq = n as u64 + 1;
    }
    let writer = LocalStore::new(sessions.to_path_buf(), segment_bytes).unwrap();
    writer.save(&meta("c")).unwrap();
    for rec in log.iter() {
        writer.append("c", rec).unwrap();
    }
    writer.flush().unwrap();
    std::fs::read_dir(sessions.join("c").join("events"))
        .unwrap()
        .map(|e| e.unwrap().metadata().unwrap().len())
        .sum()
}

/// A page of a chat's newest prompts costs its newest turns whatever state the chat's copies are
/// in (review of #40573): none yet (an open's attach asks `waitLogs: false`, ahead of the log load;
/// a cold archive takes them with the log), good ones (a log load made them), or stale ones (a
/// compaction replaced their segments, an upgrade changed their kinds, a damaged file). A segment
/// without a good copy is read back from its end, as before; one with a good copy reads the copy.
/// Every page is the same.
#[test]
fn a_page_of_newest_prompts_costs_the_newest_turns_whatever_its_copies() {
    let root = std::env::temp_dir().join(format!("acpmux-prompt-copies-{}", uuid::Uuid::now_v7()));
    let sessions = root.join("sessions");
    // A long prefix of large turns, then 17 short ones: a page of 16 prompts is all in the tail.
    let mut log = codex_chat(20, 200, 85, false);
    log.extend(codex_chat(17, 2, 10, false));
    let log_bytes = write_chat(&sessions, &mut log, 64 << 10);
    let all: Vec<_> = log.iter().filter(|r| r.kind == "user_message").cloned().collect();
    let newest = all[all.len() - 16..].to_vec();
    let hub = deferred_hub(&sessions, 64 << 10);
    let prompts = EventFilter::parse(Some(&json!(["user_message"]))).unwrap();
    let page = |state: &str| {
        let r0 = read_bytes();
        let page = hub.events_page("c", 0, None, 16, Some(OPEN_BYTES), true, &prompts).unwrap();
        let read = read_bytes() - r0;
        assert_eq!(page.events, newest, "{state}");
        assert!(page.has_more, "{state}");
        if cfg!(target_os = "linux") {
            assert!(read < log_bytes / 4, "{state}: the page read {read} of {log_bytes} bytes");
        }
    };
    let copies = sessions.join("c").join(crate::store::KIND_INDEX_DIR);
    assert!(!copies.exists(), "a deferred start reads no log");
    page("no copies");
    // A log load makes them (`hub/log_load.rs`).
    hub.store.scan_kinds("c", crate::store::INDEXED_KINDS, &mut |_| true).unwrap();
    page("good copies");
    for entry in std::fs::read_dir(&copies).unwrap() {
        std::fs::write(entry.unwrap().path(), b"{}\n").unwrap();
    }
    page("stale copies");
    let _ = std::fs::remove_dir_all(&root);
}

/// With good copies a page of prompts still stops where its page is full: the copies are read
/// newest first, so long pasted prompts far back cost nothing (review of #40573, F2).
#[test]
fn a_page_of_prompts_reads_its_copies_newest_first() {
    let root = std::env::temp_dir().join(format!("acpmux-prompt-newest-{}", uuid::Uuid::now_v7()));
    let sessions = root.join("sessions");
    // 40 pasted prompts of 40 KB each, then 17 short turns.
    let mut log: Vec<EventRecord> = (0..40)
        .map(|n| EventRecord {
            seq: 0,
            at: 0,
            dir: "mux".into(),
            kind: "user_message".into(),
            msg: json!({"text": format!("paste {n} {}", "p".repeat(40 << 10))}),
            host_seq: None,
        })
        .collect();
    log.extend(codex_chat(17, 2, 10, false));
    let log_bytes = write_chat(&sessions, &mut log, 64 << 10);
    let hub = deferred_hub(&sessions, 64 << 10);
    hub.store.scan_kinds("c", crate::store::INDEXED_KINDS, &mut |_| true).unwrap();
    let prompts = EventFilter::parse(Some(&json!(["user_message"]))).unwrap();
    let r0 = read_bytes();
    let page = hub.events_page("c", 0, None, 16, Some(OPEN_BYTES), true, &prompts).unwrap();
    let read = read_bytes() - r0;
    assert_eq!(page.events.len(), 16);
    assert!(page.events.iter().all(|r| !r.msg["text"].as_str().unwrap().starts_with("paste")));
    if cfg!(target_os = "linux") {
        assert!(read < log_bytes / 4, "the page read {read} of {log_bytes} bytes");
    }
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

/// The web pane's older page (`direct.ts` `olderPage`: before a seq, `OLDER_PAGE_RECORDS` 2,000
/// records, `OLDER_PAGE_BYTES` 1 MiB, the transcript and a local pane's preset approval cards),
/// at each depth (`OLDER_PAGE_DEPTHS`, default 0.02,0.5,0.98), `OLDER_PAGE_REPS` times (3), cold
/// (every file of the chat dropped from the page cache first) then warm: its time, records, the
/// bytes its read took (`rchar`) and the lines and bytes it parsed. One line per measurement.
///
/// The log is generated (`gen_codex_log`), `OLDER_PAGE_GEN_BYTES` of it (default 1 GiB), into a
/// temp dir this test owns: `cargo test -p acpmux --release -- --ignored --nocapture --exact
/// hub::paging::paging_tests::older_page_perf`. A copy of a real chat's folder instead:
/// `OLDER_PAGE_SESSIONS=<dir holding it> OLDER_PAGE_ID=<chat id>` (the store opens it as any).
#[test]
#[ignore = "a measurement, not a check"]
fn older_page_perf() {
    let env = |name: &str| std::env::var(name).ok();
    let reps: usize = env("OLDER_PAGE_REPS").and_then(|v| v.parse().ok()).unwrap_or(3);
    let depths: Vec<f64> = env("OLDER_PAGE_DEPTHS")
        .unwrap_or_else(|| "0.02,0.5,0.98".into())
        .split(',')
        .filter_map(|d| d.trim().parse().ok())
        .collect();
    let root =
        std::env::temp_dir().join(format!("acpmux-older-page-perf-{}", uuid::Uuid::now_v7()));
    let (sessions, id, source) = match env("OLDER_PAGE_SESSIONS") {
        Some(sessions) => (
            std::path::PathBuf::from(sessions),
            env("OLDER_PAGE_ID").expect("OLDER_PAGE_ID"),
            "copy",
        ),
        None => {
            let bytes = env("OLDER_PAGE_GEN_BYTES").and_then(|v| v.parse().ok()).unwrap_or(1 << 30);
            let sessions = root.join("sessions");
            let t0 = std::time::Instant::now();
            let made = gen_codex_log(&sessions, "c", bytes);
            let gen_ms = t0.elapsed().as_secs_f64() * 1000.0;
            let shares = kind_shares(&sessions.join("c").join("events"));
            println!(
                "older_page_gen asked_bytes={bytes} bytes={} records={} segments={} prompts={} approvals={} gen_ms={gen_ms:.0} {shares}",
                made.bytes, made.records, made.segments, made.prompts, made.approvals,
            );
            (sessions, "c".to_owned(), "generated")
        }
    };
    let hub = deferred_hub(&sessions, 8 << 20);
    // The chat's log load, as a daemon's first read of it does (`hub/log_load.rs`): it makes the
    // log's copies of the kinds it reads (`store/kind_index.rs`).
    let chat = hub.resolve(&id).unwrap();
    let t0 = std::time::Instant::now();
    hub.load_session_log(&chat);
    println!("older_page_load source={source} ms={:.0}", t0.elapsed().as_secs_f64() * 1000.0);
    let last = chat.meta().last_seq;
    let chat_dir = sessions.join(&id);
    for depth in depths {
        let before = ((last as f64) * (1.0 - depth)).max(2.0) as u64;
        // The web pane's ask (`direct.ts` `olderPage`, `attachParams.ts` `PRESET_APPROVAL_KINDS`),
        // read as `_acpmux/events` reads it.
        let params = json!({
            "sessionId": id,
            "beforeSeq": before,
            "limit": 2000,
            "maxBytes": 1 << 20,
            "kinds": ["transcript", "preset_approval_request", "preset_approval_decision"],
        });
        let ask = crate::server::events_page_ask(&params).unwrap();
        for rep in 0..reps {
            for cache in ["cold", "warm"] {
                if cache == "cold" {
                    drop_from_page_cache(&chat_dir);
                }
                let (r0, l0, b0, t0) = (
                    read_bytes(),
                    PARSED_LINES.with(std::cell::Cell::get),
                    PARSED_BYTES.with(std::cell::Cell::get),
                    std::time::Instant::now(),
                );
                let page = hub
                    .events_page(
                        &id,
                        ask.after,
                        ask.before,
                        ask.limit,
                        ask.max_bytes,
                        ask.before.is_some(),
                        &ask.filter,
                    )
                    .unwrap();
                let ms = t0.elapsed().as_secs_f64() * 1000.0;
                println!(
                    "older_page source={source} depth={depth} before={before} rep={rep} cache={cache} ms={ms:.1} records={} has_more={} read_mb={:.1} parsed_lines={} parsed_mb={:.1}",
                    page.events.len(),
                    page.has_more,
                    (read_bytes() - r0) as f64 / 1e6,
                    PARSED_LINES.with(std::cell::Cell::get) - l0,
                    (PARSED_BYTES.with(std::cell::Cell::get) - b0) as f64 / 1e6,
                );
            }
        }
    }
    std::fs::remove_dir_all(&root).ok();
}

/// Every file under `dir` (a chat's segments and copies) dropped from the page cache, so the next
/// read of it is cold. Linux only; elsewhere the reads stay warm.
fn drop_from_page_cache(dir: &std::path::Path) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            drop_from_page_cache(&path);
            continue;
        }
        let Ok(file) = std::fs::File::open(&path) else { continue };
        // Dirty pages stay cached: write them first.
        file.sync_data().ok();
        #[cfg(target_os = "linux")]
        {
            use std::os::fd::AsRawFd;
            // SAFETY: the descriptor is open for the call; the advice changes no file content.
            unsafe {
                libc::posix_fadvise(file.as_raw_fd(), 0, 0, libc::POSIX_FADV_DONTNEED);
            }
        }
    }
}

/// Each kind group's share of the log's bytes, as the real Codex chat's were measured: load
/// replays, `codex.response`, other raw harness lines, `tool_call_update` records, and the rest.
fn kind_shares(events: &std::path::Path) -> String {
    let mut by = [0u64; 5];
    for entry in std::fs::read_dir(events).unwrap() {
        let bytes = std::fs::read(entry.unwrap().path()).unwrap();
        for line in bytes.split_inclusive(|b| *b == b'\n') {
            let head = &line[..line.len().min(200)];
            let kind = memchr::memmem::find(head, b"\"kind\":\"")
                .map(|at| {
                    let rest = &head[at + 8..];
                    &rest[..memchr::memchr(b'"', rest).unwrap_or(rest.len())]
                })
                .unwrap_or_default();
            let group = if kind.ends_with(b".replay") {
                0
            } else if kind == b"codex.response" {
                1
            } else if kind.starts_with(b"codex.") {
                2
            } else if kind == b"tool_call_update" {
                3
            } else {
                4
            };
            by[group] += line.len() as u64;
        }
    }
    let total = by.iter().sum::<u64>().max(1) as f64;
    let pct = |n: u64| n as f64 * 100.0 / total;
    format!(
        "replay_pct={:.1} codex_response_pct={:.1} other_raw_pct={:.1} tool_call_update_pct={:.1} rest_pct={:.1}",
        pct(by[0]),
        pct(by[1]),
        pct(by[2]),
        pct(by[3]),
        pct(by[4])
    )
}

/// What [`gen_codex_log`] wrote.
struct GenLog {
    bytes: u64,
    records: u64,
    segments: usize,
    prompts: usize,
    approvals: usize,
}

/// A fixed-seed splitmix64: every run writes the same log.
struct SplitMix(u64);

impl SplitMix {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }

    /// A number in `lo..=hi`.
    fn range(&mut self, lo: usize, hi: usize) -> usize {
        lo + (self.next() % (hi - lo + 1) as u64) as usize
    }

    fn chance(&mut self, percent: u64) -> bool {
        self.next() % 100 < percent
    }
}

/// The real Codex chat's bytes by group (353,235 records, 4.73 GiB): load replays 49.8%, raw
/// harness lines 47.9% (`codex.response`, about 1.5 MB each, and small `codex.<method>` lines),
/// `tool_call_update` snapshots 1.5%, the rest under 1%. The groups between transcript records
/// (replays, responses, other raw lines, other wire records) are written to these shares of the
/// generator's own count, which undercounts a small line's envelope: the small raw lines' 2.7%
/// come out near the real 2.4% (`kind_shares` prints what was written).
const GEN_SHARES: [f64; 4] = [0.498, 0.455, 0.027, 0.005];
const GEN_REPLAY: usize = 0;
const GEN_RESPONSE: usize = 1;
const GEN_RAW: usize = 2;
const GEN_TRANSCRIPT: usize = 4;
/// Seqs per transcript record, as in the real chat (about 1 in 100).
const GEN_SEQS_PER_TRANSCRIPT: u64 = 100;

/// Writes Codex-shaped chat `id` of about `target` bytes under `sessions`, through the store's
/// append path in 8 MiB segments, as the daemon writes one: per turn a prompt, its start, a
/// thought, commands whose `tool_call_update`s each re-send their output so far, a plan now and
/// then, an answer and its result, every seventh turn a preset approval card and its answer; one
/// transcript record per 100 seqs, and between them load replays, raw `codex.response` lines and
/// small `codex.<method>` lines and other wire records to the real chat's shares
/// ([`GEN_SHARES`]). Deterministic: a fixed seed. Ends at the end of the turn that reaches
/// `target`.
fn gen_codex_log(sessions: &std::path::Path, id: &str, target: u64) -> GenLog {
    let store = LocalStore::new(sessions.to_path_buf(), 8 << 20).unwrap();
    let mut m = meta(id);
    m.status = crate::store::SessionStatus::Idle;
    store.save(&m).unwrap();
    let mut log = Gen {
        store: &store,
        id,
        rng: SplitMix(0x5EED_0F_C0DE_C0DE),
        words: gen_words(),
        seq: 0,
        bytes: 0,
        by: [0; 5],
        replays: 0,
    };
    let (mut prompts, mut approvals) = (0, 0);
    while log.bytes < target {
        let turn = log.turn_records(prompts);
        approvals += turn.iter().filter(|r| r.kind.starts_with("preset_approval")).count();
        prompts += 1;
        for rec in turn {
            while (log.seq + 1) % GEN_SEQS_PER_TRANSCRIPT != 0 {
                log.filler();
            }
            log.put(GEN_TRANSCRIPT, rec);
        }
    }
    m.last_seq = log.seq;
    m.event_count = log.seq;
    store.save(&m).unwrap();
    store.flush().unwrap();
    let events = sessions.join(id).join("events");
    let files: Vec<u64> =
        std::fs::read_dir(&events).unwrap().map(|e| e.unwrap().metadata().unwrap().len()).collect();
    GenLog {
        bytes: files.iter().sum(),
        records: log.seq,
        segments: files.len(),
        prompts,
        approvals,
    }
}

/// 1 MiB of command-output-like text (words, lines of about 80 characters) records take slices of.
fn gen_words() -> String {
    const WORDS: &str = "test result: ok. running Compiling acpmux v0.1.0 warning: unused \
        src/hub/paging.rs: Finished release target(s) in 12.3s passed; 0 failed; ignored; measured; \
        filtered out; fn let = { } () -> Result<()> error[E0425]: cannot find value this scope --> \
        | ^ note: help: consider importing use crate::store::EventRecord;";
    let words: Vec<&str> = WORDS.split_whitespace().collect();
    let mut rng = SplitMix(7);
    let mut text = String::with_capacity((1 << 20) + 64);
    let mut line = 0;
    while text.len() < 1 << 20 {
        let word = words[rng.range(0, words.len() - 1)];
        text.push_str(word);
        line += word.len() + 1;
        if line > 80 {
            text.push('\n');
            line = 0;
        } else {
            text.push(' ');
        }
    }
    text
}

struct Gen<'a> {
    store: &'a LocalStore,
    id: &'a str,
    rng: SplitMix,
    words: String,
    seq: u64,
    /// About the bytes written, all and by group (`GEN_REPLAY` .. `GEN_TRANSCRIPT`).
    bytes: u64,
    by: [u64; 5],
    replays: u64,
}

impl Gen<'_> {
    /// `len` bytes of the text, from a random place.
    fn text(&mut self, len: usize) -> String {
        let len = len.min(self.words.len());
        let at = self.rng.range(0, self.words.len() - len);
        self.words[at..at + len].to_owned()
    }

    /// Appends `rec` as the next seq, through the store's append path.
    fn put(&mut self, group: usize, mut rec: EventRecord) {
        self.seq += 1;
        (rec.seq, rec.at) = (self.seq, 1_763_000_000_000 + self.seq * 40);
        // About its line: its strings and an envelope (the shares are measured after).
        let bytes = gen_string_bytes(&rec.msg) + rec.kind.len() as u64 + 120;
        self.store.append(self.id, &rec).unwrap();
        self.bytes += bytes;
        self.by[group] += bytes;
    }

    /// One record between transcript records: of the group furthest under its share.
    fn filler(&mut self) {
        let total = self.bytes as f64;
        let owed = |g: usize| GEN_SHARES[g] * total - self.by[g] as f64;
        let group = (0..GEN_SHARES.len()).max_by(|a, b| owed(*a).total_cmp(&owed(*b))).unwrap();
        let rec = match group {
            GEN_REPLAY => self.replay(),
            GEN_RESPONSE => self.response(),
            GEN_RAW => {
                const METHODS: &[&str] = &[
                    "thread/tokenUsage/updated",
                    "account/rateLimits/updated",
                    "turn/diff/updated",
                    "turn/started",
                    "turn/completed",
                    "hook/started",
                    "hook/completed",
                ];
                let method = METHODS[self.rng.range(0, METHODS.len() - 1)];
                let len = self.rng.range(300, 2000);
                let msg = json!({"jsonrpc": "2.0", "method": method, "params": {"threadId": "thr_1", "data": self.text(len)}});
                EventRecord {
                    seq: 0,
                    at: 0,
                    dir: "in".into(),
                    kind: format!("codex.{method}"),
                    msg,
                    host_seq: None,
                }
            }
            _ => {
                if self.rng.chance(50) {
                    agent(
                        0,
                        "usage_update",
                        json!({"sessionUpdate": "usage_update", "used": self.seq, "size": 272_000}),
                    )
                } else {
                    let msg = json!({"jsonrpc": "2.0", "id": self.seq, "result": {"stopReason": "end_turn"}});
                    EventRecord {
                        seq: 0,
                        at: 0,
                        dir: "in".into(),
                        kind: "response".into(),
                        msg,
                        host_seq: None,
                    }
                }
            }
        };
        self.put(group, rec);
    }

    /// A load replay: a reply or thought chunk, or a call or its update with its output.
    fn replay(&mut self) -> EventRecord {
        self.replays += 1;
        let call = format!("call_r{}", self.replays / 8);
        if self.rng.chance(60) {
            let kind =
                if self.rng.chance(70) { "agent_message_chunk" } else { "agent_thought_chunk" };
            let len = self.rng.range(300, 2000);
            let text = self.text(len);
            return agent(
                0,
                &format!("{kind}.replay"),
                json!({"sessionUpdate": kind, "content": {"type": "text", "text": text}}),
            );
        }
        let len = self.rng.range(4 << 10, 44 << 10);
        let output = self.text(len);
        let content = json!([{"type": "content", "content": {"type": "text", "text": output}}]);
        if self.rng.chance(25) {
            agent(
                0,
                "tool_call.replay",
                json!({"sessionUpdate": "tool_call", "toolCallId": call, "title": "cargo test", "kind": "execute", "status": "completed", "rawInput": {"command": ["bash", "-lc", "cargo test"]}, "content": content}),
            )
        } else {
            agent(
                0,
                "tool_call_update.replay",
                json!({"sessionUpdate": "tool_call_update", "toolCallId": call, "status": "completed", "content": content}),
            )
        }
    }

    /// A raw `codex.response`: a thread's items, 1.2 to 1.8 MB.
    fn response(&mut self) -> EventRecord {
        let want = self.rng.range(1_200_000, 1_800_000);
        let (mut items, mut size) = (Vec::new(), 0);
        while size < want {
            let len = self.rng.range(1000, 8000);
            let text = self.text(len);
            let n = items.len();
            items.push(if self.rng.chance(50) {
                json!({"type": "agentMessage", "id": format!("item_{n}"), "text": text})
            } else {
                json!({"type": "commandExecution", "id": format!("item_{n}"), "command": "cargo test", "aggregatedOutput": text, "exitCode": 0, "status": "completed"})
            });
            size += len + 100;
        }
        let msg = json!({"jsonrpc": "2.0", "id": self.seq, "result": {"thread": {"id": "thr_1", "turns": [{"id": "turn_1", "status": "completed", "items": items}]}}});
        EventRecord {
            seq: 0,
            at: 0,
            dir: "in".into(),
            kind: "codex.response".into(),
            msg,
            host_seq: None,
        }
    }

    /// Prompt `turn`'s transcript records, in order.
    fn turn_records(&mut self, turn: usize) -> Vec<EventRecord> {
        let mux = |kind: &str, msg: Value| EventRecord {
            seq: 0,
            at: 0,
            dir: "mux".into(),
            kind: kind.into(),
            msg,
            host_seq: None,
        };
        let chunk = |kind: &str, text: String| {
            agent(
                0,
                kind,
                json!({"sessionUpdate": kind, "content": {"type": "text", "text": text}}),
            )
        };
        let prompt = format!("p{turn}");
        let mut out = Vec::new();
        let len = self.rng.range(80, 1500);
        out.push(mux(
            "user_message",
            json!({"text": format!("prompt {turn}: {}", self.text(len)), "promptId": prompt}),
        ));
        out.push(mux("turn_started", json!({"turnId": format!("t{turn}"), "promptId": prompt})));
        let len = self.rng.range(200, 1200);
        out.push(chunk("agent_thought_chunk", self.text(len)));
        let approval = turn % 7 == 3;
        let card = json!({"preset": "unattended", "digest": format!("d{turn}"), "harness": "codex", "model": "gpt-5", "effort": "high", "policy": "approve-all", "host": "", "description": "a preset"});
        if approval {
            out.push(mux("preset_approval_request", card));
        }
        for call in 0..self.rng.range(2, 6) {
            let id = format!("call_{turn}_{call}");
            out.push(agent(
                0,
                "tool_call",
                json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": "cargo test -p acpmux", "kind": "execute", "status": "in_progress", "rawInput": {"command": ["bash", "-lc", "cargo test -p acpmux"]}}),
            ));
            let mut output = String::new();
            for _ in 0..self.rng.range(2, 8) {
                let len = self.rng.range(2 << 10, 10 << 10);
                let piece = self.text(len);
                output.push_str(&piece);
                out.push(agent(
                    0,
                    "tool_call_update",
                    json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "in_progress", "content": [{"type": "content", "content": {"type": "text", "text": output}}], "_meta": {"terminal_output_delta": {"data": piece}}}),
                ));
            }
            out.push(agent(
                0,
                "tool_call_update",
                json!({"sessionUpdate": "tool_call_update", "toolCallId": id, "status": "completed", "rawOutput": {"exit_code": 0}, "content": [{"type": "content", "content": {"type": "text", "text": output}}]}),
            ));
            if self.rng.chance(50) {
                let len = self.rng.range(100, 800);
                out.push(chunk("agent_message_chunk", self.text(len)));
            }
            if call == 0 && self.rng.chance(50) {
                out.push(agent(
                    0,
                    "plan",
                    json!({"sessionUpdate": "plan", "entries": [{"content": "run the tests", "priority": "high", "status": "completed"}, {"content": "fix what fails", "priority": "medium", "status": "in_progress"}]}),
                ));
            }
        }
        if approval {
            out.push(mux(
                "preset_approval_decision",
                json!({"preset": "unattended", "digest": format!("d{turn}"), "outcome": "approved"}),
            ));
        }
        for _ in 0..self.rng.range(1, 3) {
            let len = self.rng.range(200, 1500);
            out.push(chunk("agent_message_chunk", self.text(len)));
        }
        out.push(mux("turn_result", json!({"status": "completed", "turnId": format!("t{turn}")})));
        out
    }
}

/// About the bytes `value`'s strings take in its JSON (the generator's own count; the log's
/// shares are measured from its files).
fn gen_string_bytes(value: &Value) -> u64 {
    match value {
        Value::String(s) => s.len() as u64 + 2,
        Value::Array(items) => items.iter().map(gen_string_bytes).sum::<u64>() + 2,
        Value::Object(map) => {
            map.iter().map(|(k, v)| k.len() as u64 + 4 + gen_string_bytes(v)).sum::<u64>() + 2
        }
        _ => 8,
    }
}

/// A raw harness line as a harness adapter logs it (`<harness>.<method>`, `codex_app_server.rs`
/// `tap_kind`, `claude_stdio` `logged_kind`), carrying `bytes` of payload.
fn raw_line(kind: &str, bytes: usize) -> EventRecord {
    let msg = json!({"jsonrpc": "2.0", "id": 7, "result": {"output": "r".repeat(bytes)}});
    EventRecord { seq: 0, at: 0, dir: "in".into(), kind: kind.into(), msg, host_seq: None }
}

/// The bytes `events` take as the log writes them.
fn page_bytes(events: &[EventRecord]) -> u64 {
    events.iter().map(|r| serde_json::to_vec(r).unwrap().len() as u64).sum()
}

/// Leo, 2026-11-16: "how about speeding up the scrolling up of chats?". An older page of a chat's
/// transcript passes raw harness lines unparsed, whatever harness wrote them: a real Codex chat's
/// `codex.response` lines (about 1.5 MB each, half its log) were each parsed and then left out,
/// and an older page took 2.7 to 7.4 s.
#[test]
fn an_older_page_parses_no_raw_harness_lines() {
    let root = std::env::temp_dir().join(format!("acpmux-older-raw-{}", uuid::Uuid::now_v7()));
    let sessions = root.join("sessions");
    let raw = ["codex.response", "claude.assistant", "zed9.response"];
    let mut log = Vec::new();
    for n in 0..20_000usize {
        if n % 100 == 0 {
            log.push(agent(0, "agent_message_chunk", json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": format!("answer {n}")}})));
        } else {
            log.push(raw_line(raw[n % raw.len()], 14 << 10));
        }
    }
    write_chat(&sessions, &mut log, 8 << 20);
    let hub = deferred_hub(&sessions, 8 << 20);
    let before = log.len() as u64 / 2;
    let b0 = PARSED_BYTES.with(std::cell::Cell::get);
    let page =
        hub.events_page("c", 0, Some(before), 20, Some(1 << 20), true, &transcript(true)).unwrap();
    let parsed = PARSED_BYTES.with(std::cell::Cell::get) - b0;
    let older: Vec<u64> = log
        .iter()
        .filter(|r| r.kind == "agent_message_chunk" && r.seq < before)
        .map(|r| r.seq)
        .collect();
    let want = older[older.len() - 20..].to_vec();
    assert_eq!(page.events.iter().map(|r| r.seq).collect::<Vec<_>>(), want);
    let own = page_bytes(&page.events);
    assert!(parsed <= 4 * own, "the page of {own} bytes parsed {parsed} bytes");
    std::fs::remove_dir_all(&root).ok();
}

/// Pages of `log`, written as chat `c` under `sessions`, read back from before each of `befores`:
/// what each record says (two logs' seqs differ; their records' words need not).
fn transcript_pages(
    sessions: &std::path::Path,
    log: &mut [EventRecord],
    befores: &[u64],
) -> Vec<Vec<(String, String, Value)>> {
    write_chat(sessions, log, 64 << 10);
    let hub = deferred_hub(sessions, 64 << 10);
    befores
        .iter()
        .map(|before| {
            let page = hub
                .events_page("c", 0, Some(*before), 40, Some(OPEN_BYTES), true, &transcript(true))
                .unwrap();
            page.events.into_iter().map(|r| (r.dir, r.kind, r.msg)).collect()
        })
        .collect()
}

/// Raw harness lines among a Codex chat's records change no page: its pages read with them are
/// the pages read without them, record for record.
#[test]
fn raw_harness_lines_change_no_page() {
    let root = std::env::temp_dir().join(format!("acpmux-raw-pages-{}", uuid::Uuid::now_v7()));
    let mut chat = codex_chat(12, 40, 64, false);
    let mut mixed = Vec::new();
    for (n, rec) in chat.iter().enumerate() {
        mixed.push(rec.clone());
        let kind = ["codex.response", "codex.turn/diff/updated", "codex.hook/started"][n % 3];
        mixed.push(raw_line(kind, 512));
    }
    let n = chat.len() as u64;
    let befores = [n + 1, n * 3 / 4, n / 2, n / 4];
    let without = transcript_pages(&root.join("plain"), &mut chat, &befores);
    // The mixed log holds the chat's record `k` (from 1) at seq `2k - 1`.
    let mixed_befores: Vec<u64> = befores.iter().map(|b| 2 * b - 1).collect();
    let with = transcript_pages(&root.join("mixed"), &mut mixed, &mixed_befores);
    assert!(without.iter().all(|page| !page.is_empty()));
    assert_eq!(with, without);
    std::fs::remove_dir_all(&root).ok();
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

/// A reply whose session detail alone passes one message still fits (Astra review of #28754):
/// the records go as stubs first, then the detail's own fields, largest first, each named.
#[test]
fn a_reply_fits_one_message_whatever_holds_its_bytes() {
    let event = |seq: u64, text: &str| json!({"seq": seq, "kind": "agent_message_chunk", "msg": {"text": text}});
    let mut reply = json!({
        "session": {"sessionId": "s", "status": "idle", "configOptions": "c".repeat(MAX_REPLY_BYTES), "models": "m".repeat(5 << 20), "pending": [{"rawInput": "p".repeat(1 << 20)}]},
        "events": [event(1, "a"), event(2, &"x".repeat(3 << 20))],
        "turnOpener": event(0, "go"),
    });
    fit_reply(&mut reply);
    let bytes = serde_json::to_string(&reply).unwrap().len();
    assert!(bytes <= MAX_REPLY_BYTES, "{bytes}");
    // The large record is a stub; the small ones are as they were, never a larger stub.
    assert_eq!(reply["events"][1]["msg"]["_meta"]["acpmux"]["omitted"]["reason"], "too_large");
    assert_eq!(reply["events"][0]["msg"]["text"], "a");
    assert_eq!(reply["turnOpener"]["msg"]["text"], "go");
    // Then the largest detail field went, and only as much as the reply needed.
    let session = &reply["session"];
    assert_eq!(session["configOptions"], Value::Null);
    assert_eq!(session["models"].as_str().map(str::len), Some(5 << 20));
    assert_eq!(session["_meta"]["acpmux"]["omitted"]["fields"], json!(["configOptions"]));
    assert_eq!(
        (session["sessionId"].clone(), session["status"].clone()),
        (json!("s"), json!("idle"))
    );

    // Nor can a value the agent set in the summary (a session_info_update title) keep a chat
    // from opening: past the detail, any field but the chat's identity goes to its empty value.
    let mut titled = json!({
        "session": {"sessionId": "s", "status": "idle", "cwd": "/w", "title": "t".repeat(MAX_REPLY_BYTES), "tags": ["a"], "models": "m".repeat(1 << 20)},
        "events": [event(1, "a")],
        "turnOpener": null,
    });
    fit_reply(&mut titled);
    let bytes = serde_json::to_string(&titled).unwrap().len();
    assert!(bytes <= MAX_REPLY_BYTES, "{bytes}");
    let session = &titled["session"];
    assert_eq!(session["title"], "");
    assert_eq!(session["models"], Value::Null);
    assert_eq!(session["tags"], json!(["a"]), "a small field stays");
    assert_eq!((session["sessionId"].clone(), session["cwd"].clone()), (json!("s"), json!("/w")));
    assert_eq!(session["_meta"]["acpmux"]["omitted"]["fields"], json!(["models", "title"]));

    // Not even the agent's own session id: the receipt that carries it goes last, after every
    // other field (the title here), and the chat's sessionId stays.
    let mut receipt = json!({
        "session": {"sessionId": "s", "status": "idle", "title": "t", "sessionReceipt": {"agentSessionId": "x".repeat(MAX_REPLY_BYTES)}},
        "events": [],
        "turnOpener": null,
    });
    fit_reply(&mut receipt);
    let bytes = serde_json::to_string(&receipt).unwrap().len();
    assert!(bytes <= MAX_REPLY_BYTES, "{bytes}");
    let session = &receipt["session"];
    assert_eq!(session["sessionReceipt"], json!({}));
    assert_eq!(
        (session["sessionId"].clone(), session["status"].clone(), session["title"].clone()),
        (json!("s"), json!("idle"), json!(""))
    );
    assert_eq!(session["_meta"]["acpmux"]["omitted"]["fields"], json!(["title", "sessionReceipt"]));

    // Nor a record's envelope: an agent names its own sessionUpdate, which becomes the kind.
    let mut kind = json!({
        "session": {"sessionId": "s", "status": "idle"},
        "events": [{"seq": 7, "at": 1, "dir": "in", "kind": "k".repeat(MAX_REPLY_BYTES), "msg": {"a": 1}}],
        "turnOpener": null,
    });
    fit_reply(&mut kind);
    let bytes = serde_json::to_string(&kind).unwrap().len();
    assert!(bytes <= MAX_REPLY_BYTES, "{bytes}");
    assert_eq!(
        kind["events"][0],
        json!({"seq": 7, "at": 1, "dir": "in", "kind": "", "msg": {"a": 1}})
    );
    assert_eq!(kind["session"], json!({"sessionId": "s", "status": "idle"}));

    // A page counts a record's envelope as written: a kind of NULs is six bytes a character.
    let nuls = EventRecord {
        seq: 1,
        at: 1,
        dir: "in".into(),
        kind: format!("claude.{}", "\0".repeat(169)),
        msg: Value::Null,
        host_seq: None,
    };
    let written = serde_json::to_string(&nuls).unwrap().len();
    assert!(record_bytes(&nuls) >= written, "{} < {written}", record_bytes(&nuls));

    // A reply that fits is left exactly as it is.
    let small =
        json!({"session": {"sessionId": "s"}, "events": [event(1, "a")], "turnOpener": null});
    let mut same = small.clone();
    fit_reply(&mut same);
    assert_eq!(same, small);
}

#[test]
fn the_prompt_index_holds_every_prompt_cut_short_oldest_first() {
    let hub = hub(Box::new(crate::store::MemoryStore::default()));
    hub.store.save(&meta("c")).unwrap();
    let mut log = codex_chat(30, 4, 64, false);
    // A long pasted prompt, a steer and its id travel cut to the index's shape.
    let long = "x".repeat(10_000);
    let next = log.last().unwrap().seq + 1;
    log.push(EventRecord {
        seq: next,
        at: next,
        dir: "mux".into(),
        kind: "user_message".into(),
        msg: json!({"text": long, "promptId": "p-long", "images": [{"data": "AAAA"}], "pasted": [[0, 10]]}),
        host_seq: None,
    });
    log.push(EventRecord {
        seq: next + 1,
        at: next + 1,
        dir: "mux".into(),
        kind: "user_message".into(),
        msg: json!({"text": "steer", "steer": true, "promptId": "p-steer"}),
        host_seq: None,
    });
    for rec in &log {
        hub.store.append("c", rec).unwrap();
    }
    let all = hub.prompt_index("c", None).unwrap();
    assert_eq!(all.len(), 32);
    assert!(all.windows(2).all(|pair| pair[0].seq < pair[1].seq), "oldest first");
    assert_eq!(all[0].msg, json!({"text": "prompt 0"}));
    let cut = &all[30].msg;
    assert_eq!(cut["promptId"], "p-long");
    assert_eq!(cut["text"].as_str().unwrap().chars().count(), PROMPT_INDEX_TEXT_CHARS);
    assert!(cut.get("images").is_none() && cut.get("pasted").is_none());
    assert_eq!(all[31].msg["steer"], true);
    // `before` bounds it, as the pane asks for what precedes its open page.
    let older = hub.prompt_index("c", Some(all[10].seq)).unwrap();
    assert_eq!(older.len(), 10);
    assert_eq!(older.last().unwrap().seq, all[9].seq);
}

/// The prompt index reads the log's copies of its prompts (`store/kind_index.rs`), not the log: a
/// long chat's tool output is most of its bytes, and reading all of them held the rail's every
/// pending tick blank for 10 s on a 566 MB log, past a peer's 30 s read deadline on longer ones
/// (Leo, 2026-11-03: "the hover previews ... aren't loading past the first bits"). Each segment's
/// bytes are blanked once its copy is made: the same file and length, so only the copies still
/// hold the prompts.
#[test]
fn the_prompt_index_reads_the_logs_copies_of_its_prompts() {
    let root =
        std::env::temp_dir().join(format!("acpmux-prompt-index-copies-{}", uuid::Uuid::now_v7()));
    let store = LocalStore::new(root.clone(), 16 << 10).unwrap();
    store.save(&meta("c")).unwrap();
    for rec in codex_chat(40, 6, 400, false) {
        store.append("c", &rec).unwrap();
    }
    store.flush().unwrap();
    let hub = hub(Box::new(store));
    let all = hub.prompt_index("c", None).unwrap();
    assert_eq!(all.len(), 40);
    // A daemon's log load makes the copies (`hub/log_load.rs`); this scan stands for it.
    hub.store.scan_kinds("c", &["user_message"], &mut |_| true).unwrap();
    let events = root.join("c").join("events");
    let segments: Vec<_> = std::fs::read_dir(&events).unwrap().map(|e| e.unwrap().path()).collect();
    assert!(segments.len() > 3, "{} segments", segments.len());
    for path in &segments {
        let len = std::fs::metadata(path).unwrap().len() as usize;
        let mut blank = " ".repeat(len - 1);
        blank.push('\n');
        std::fs::OpenOptions::new()
            .write(true)
            .open(path)
            .unwrap()
            .write_all(blank.as_bytes())
            .unwrap();
    }
    let read = hub.prompt_index("c", None).unwrap();
    assert_eq!(
        read.iter().map(|r| r.seq).collect::<Vec<_>>(),
        all.iter().map(|r| r.seq).collect::<Vec<_>>()
    );
    assert_eq!(read[0].msg, json!({"text": "prompt 0"}));
    // `before` still bounds it.
    let older = hub.prompt_index("c", Some(all[10].seq)).unwrap();
    assert_eq!(older.len(), 10);
    let _ = std::fs::remove_dir_all(&root);
}

/// How long the rail waits for a long chat's every prompt: paging the transcript back (the pane's
/// `loadOlder`, 400 records a page) against one prompt index read.
#[test]
#[ignore = "a measurement, not a check"]
fn prompt_index_perf() {
    let root =
        std::env::temp_dir().join(format!("acpmux-prompt-index-perf-{}", uuid::Uuid::now_v7()));
    let sessions = root.join("sessions");
    let writer = LocalStore::new(sessions.clone(), 8 << 20).unwrap();
    writer.save(&meta("c")).unwrap();
    // 1,000 turns, each a command with 40 updates re-sending its output so far.
    for rec in codex_chat(1000, 40, 200, false) {
        writer.append("c", &rec).unwrap();
    }
    let hub = hub(Box::new(LocalStore::new(sessions.clone(), 8 << 20).unwrap()));
    let mut paged = Vec::new();
    let mut indexed = Vec::new();
    let mut pages_read = 0;
    for _ in 0..3 {
        let started = std::time::Instant::now();
        let mut page = hub
            .events_page("c", 0, None, OPEN_LIMIT, Some(OPEN_BYTES), true, &transcript(true))
            .unwrap();
        let mut pages = 1;
        let mut shown = prompts(&page);
        while page.has_more {
            let before = page.events.first().map(|r| r.seq);
            page = hub
                .events_page("c", 0, before, OPEN_LIMIT, Some(256 * 1024), true, &transcript(true))
                .unwrap();
            pages += 1;
            shown += prompts(&page);
        }
        assert_eq!(shown, 1000);
        paged.push(started.elapsed().as_secs_f64() * 1000.0);
        pages_read = pages;
        let started = std::time::Instant::now();
        assert_eq!(hub.prompt_index("c", None).unwrap().len(), 1000);
        indexed.push(started.elapsed().as_secs_f64() * 1000.0);
    }
    let best = |runs: &[f64]| runs.iter().copied().fold(f64::INFINITY, f64::min);
    println!(
        "every prompt of 1000 turns: paging back {pages_read} pages {:.1} ms; prompt index 1 read {:.1} ms",
        best(&paged),
        best(&indexed)
    );
    std::fs::remove_dir_all(&root).ok();
}

/// An update of the chat's own (`sub` None) or of subagent `sub` (`_meta.acpmux.subagent`, as
/// `subagents.rs` tags it).
fn update_of(seq: u64, sub: Option<&str>, text: &str) -> EventRecord {
    let mut rec = agent(
        seq,
        "agent_message_chunk",
        json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}),
    );
    if let Some(sub) = sub {
        rec.msg["params"]["_meta"] = json!({"acpmux": {"subagent": sub}});
    }
    rec
}

/// A subagent pane's read of an old subagent's own records (webviews `readSubagentLog`, a forward
/// page from the start with `subagent`) parses that subagent's lines, not the chat's whole log
/// after them: opening a finished subagent of a long chat cost a parse of every later line, on
/// every page of its read (Leo, 2026-11-05: "things just don't open up fast enough on the right.
/// / links. subagents. all").
#[test]
fn a_subagent_page_parses_only_its_subagents_lines() {
    let root = std::env::temp_dir().join(format!("acpmux-subagent-page-{}", uuid::Uuid::now_v7()));
    let sessions = root.join("sessions");
    let mut seq = 0;
    let mut next = || {
        seq += 1;
        seq
    };
    let mut log = Vec::new();
    // The subagent ran early on: 20 updates among the chat's first ones.
    for n in 0..20 {
        log.push(update_of(next(), None, &format!("chat {n}")));
        log.push(update_of(next(), Some("sub-old"), &format!("sub-old {n}")));
    }
    // Then a long chat after it, with another subagent, whose words name the old one.
    for n in 0..5000 {
        let sub = (n % 7 == 0).then_some("sub-new");
        log.push(update_of(next(), sub, &format!("later {n}: \"sub-old\" is done")));
    }
    {
        let writer = LocalStore::new(sessions.clone(), 8 << 20).unwrap();
        writer.save(&meta("c")).unwrap();
        for rec in &log {
            writer.append("c", rec).unwrap();
        }
    }
    let hub = hub(Box::new(LocalStore::new(sessions.clone(), 8 << 20).unwrap()));
    let filter = transcript(true).of_subagent(Some("sub-old"));
    let parsed_before = PARSED_LINES.with(std::cell::Cell::get);
    let page = hub.events_page("c", 0, None, OPEN_LIMIT, Some(256 * 1024), false, &filter).unwrap();
    let parsed = PARSED_LINES.with(std::cell::Cell::get) - parsed_before;
    let want: Vec<u64> = log
        .iter()
        .filter(|r| r.msg.pointer("/params/_meta/acpmux/subagent") == Some(&json!("sub-old")))
        .map(|r| r.seq)
        .collect();
    assert_eq!(page.events.iter().map(|r| r.seq).collect::<Vec<_>>(), want);
    assert!(!page.has_more);
    // Its own 20 lines, never the chat's other 5,020.
    assert!(parsed <= 20, "the page parsed {parsed} of {} lines", log.len());
    // A page past its first records reads on from there, as the pane's next page does.
    let rest =
        hub.events_page("c", want[9], None, OPEN_LIMIT, Some(256 * 1024), false, &filter).unwrap();
    assert_eq!(rest.events.iter().map(|r| r.seq).collect::<Vec<_>>(), want[10..].to_vec());
    std::fs::remove_dir_all(&root).ok();
}

/// A subagent pane's read of an old subagent as the chat grows (the PR's Performance table): run
/// with `cargo test -p acpmux --release --lib -- --ignored --nocapture subagent_page_perf`.
#[test]
#[ignore = "a measurement, not a check"]
fn subagent_page_perf() {
    for later in [2_000usize, 20_000, 100_000] {
        let root =
            std::env::temp_dir().join(format!("acpmux-subagent-perf-{}", uuid::Uuid::now_v7()));
        let sessions = root.join("sessions");
        let mut seq = 0;
        {
            let writer = LocalStore::new(sessions.clone(), 8 << 20).unwrap();
            writer.save(&meta("c")).unwrap();
            for n in 0..40 {
                seq += 1;
                writer
                    .append("c", &update_of(seq, (n % 2 == 1).then_some("sub-old"), "early"))
                    .unwrap();
            }
            // About 1 KB a line, as a busy chat's updates are.
            let text = "x".repeat(900);
            for n in 0..later {
                seq += 1;
                let sub = (n % 7 == 0).then_some("sub-new");
                writer.append("c", &update_of(seq, sub, &text)).unwrap();
            }
        }
        let hub = hub(Box::new(LocalStore::new(sessions.clone(), 8 << 20).unwrap()));
        let filter = transcript(true).of_subagent(Some("sub-old"));
        let mut runs = Vec::new();
        for _ in 0..5 {
            let started = std::time::Instant::now();
            let page = hub
                .events_page("c", 0, None, OPEN_LIMIT, Some(256 * 1024), false, &filter)
                .unwrap();
            runs.push(started.elapsed().as_secs_f64() * 1000.0);
            assert_eq!(page.events.len(), 20);
        }
        runs.sort_by(f64::total_cmp);
        println!(
            "subagent page after {later} later lines: median {:.1} ms (min {:.1})",
            runs[2], runs[0]
        );
        std::fs::remove_dir_all(&root).ok();
    }
}
