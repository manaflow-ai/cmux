//! A live chat's sealed segments compacted (`store/sealed_compact.rs`): every reader shows what
//! it showed before, page by page, and a crash at any point leaves a log that reads the same.

use super::*;
use crate::store::{EventRecord, HistoryRef, LocalStore, SessionMeta, Store};

/// The smallest segment a store rolls at (`LocalStore::new`).
const SEGMENT: u64 = 64 * 1024;

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
        "schema": crate::store::META_SCHEMA, "id": id, "name": "coordinator", "harness": "codex",
        "cwd": "/tmp", "status": "running", "createdAt": 1, "updatedAt": 2,
    }))
    .unwrap()
}

/// Records numbered in order, each `at` ten times its seq.
struct Log(Vec<EventRecord>);

impl Log {
    fn push(&mut self, dir: &str, kind: &str, msg: Value) -> u64 {
        let seq = self.0.len() as u64 + 1;
        self.0.push(EventRecord {
            seq,
            at: seq * 10,
            dir: dir.into(),
            kind: kind.into(),
            msg,
            host_seq: None,
        });
        seq
    }

    fn agent(&mut self, update: Value) -> u64 {
        let kind = update["sessionUpdate"].as_str().unwrap().to_owned();
        let msg = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "a", "update": update}});
        self.push("in", &kind, msg)
    }

    fn chunk(&mut self, kind: &str, text: &str) -> u64 {
        self.agent(json!({"sessionUpdate": kind, "content": {"type": "text", "text": text}}))
    }

    fn output(&mut self, id: &str, text: &str, status: Option<&str>, delta: &str) -> u64 {
        let mut update = json!({"sessionUpdate": "tool_call_update", "toolCallId": id,
            "content": [{"type": "content", "content": {"type": "text", "text": text}}],
            "_meta": {"terminal_output_delta": {"data": delta}}});
        if let Some(status) = status {
            update["status"] = json!(status);
        }
        self.agent(update)
    }
}

fn prose(n: usize, words: usize) -> String {
    const WORDS: &[&str] = &[
        "the", "build", "of", "acpmux", "on", "the", "fleet", "runner", "finished", "and", "the",
        "journal", "segment", "rolled", "over", "while", "the", "hub", "streamed",
    ];
    (0..words).map(|i| WORDS[(n * 7 + i * 3) % WORDS.len()]).collect::<Vec<_>>().join(" ")
}

/// A coordinator's chat as the disk bench streams it (`scripts/measure/chat-disk-growth.py`):
/// each turn a prompt, a thought, prose in runs of chunks, and three commands whose updates each
/// carry the whole output so far (codex-acp), the last one completed. Every fifth turn also runs a
/// command whose output arrives between chunks of the reply (a chunk on each side of an update),
/// and the last turn's command is still running.
fn coordinator_chat(turns: usize) -> Vec<EventRecord> {
    let mut log = Log(Vec::new());
    for turn in 0..turns {
        log.push("mux", "user_message", json!({"text": format!("coord: {turn}")}));
        log.push("mux", "turn_started", json!({"turnId": format!("t{turn}")}));
        log.chunk("agent_thought_chunk", "Checking the lanes");
        log.chunk("agent_thought_chunk", " and their reds.");
        for part in 0..3 {
            log.chunk("agent_message_chunk", &format!("{}. ", prose(turn + part, 30)));
        }
        let last = turn + 1 == turns;
        for call in 0..3 {
            let id = format!("call-{turn}-{call}");
            let command =
                format!("cargo test -p acpmux --lib hub::retention -- case_{turn}_{call}");
            log.agent(json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": format!("Run {command}"),
                "kind": "execute", "status": "in_progress", "rawInput": {"command": command}}));
            let mut out = String::new();
            for step in 0..4 {
                let piece: String = (0..6)
                    .map(|line| {
                        format!("test hub::retention::case_{turn}_{call}_{step}_{line} ... ok\n")
                    })
                    .collect();
                out.push_str(&piece);
                let running = last && call == 2;
                let status = (step == 3 && !running).then_some("completed");
                log.output(&id, &out, status, &piece);
            }
            log.chunk("agent_message_chunk", &format!("{}.\n", prose(turn + call + 5, 20)));
        }
        if turn % 5 == 4 {
            let id = format!("watch-{turn}");
            log.agent(json!({"sessionUpdate": "tool_call", "toolCallId": id, "title": "Watch CI",
                "kind": "execute", "status": "in_progress"}));
            log.output(&id, "queued\n", None, "queued\n");
            log.chunk("agent_message_chunk", "While CI runs, ");
            log.output(&id, "queued\nrunning\n", None, "running\n");
            log.chunk("agent_message_chunk", "the next lane starts.");
            log.output(&id, "queued\nrunning\ngreen\n", Some("completed"), "green\n");
        }
        if !last {
            log.push(
                "mux",
                "turn_result",
                json!({"turnId": format!("t{turn}"), "stopReason": "end_turn"}),
            );
        }
    }
    log.0
}

/// What a reader shows of records folded in order: each call as `mergeToolItem` folds it
/// (content replaces, input and `_meta` merge with Codex's increments aside, every other field
/// named is set, the start is the first record's time and the end the first ending one's), and
/// the rows: each prompt, and each run of message or thought chunks joined, a run ending at any
/// record of another kind (`rows/fold.rs`: a tool call update ends a reply too).
#[derive(Debug, PartialEq)]
struct Shown {
    calls: std::collections::BTreeMap<String, serde_json::Map<String, Value>>,
    rows: Vec<(String, String)>,
}

fn shown(records: &[EventRecord]) -> Shown {
    fold_shown(records, true)
}

/// [`shown`] as the web client folds a page (`direct.ts`): a tool call update does not end a
/// message there, and a page already leaves out updates later ones replace
/// (`store/superseded.rs`), between two chunks too.
fn shown_paged(records: &[EventRecord]) -> Shown {
    fold_shown(records, false)
}

fn fold_shown(records: &[EventRecord], updates_end_runs: bool) -> Shown {
    let mut calls = std::collections::BTreeMap::<String, serde_json::Map<String, Value>>::new();
    let mut rows: Vec<(String, String)> = Vec::new();
    let mut open: Option<String> = None;
    for rec in records {
        if rec.kind == "user_message" {
            rows.push(("prompt".into(), rec.msg["text"].as_str().unwrap_or_default().into()));
        }
        let chunk = matches!(rec.kind.as_str(), "agent_message_chunk" | "agent_thought_chunk");
        if !chunk && (updates_end_runs || rec.kind != "tool_call_update") {
            open = None;
        }
        let Some(update) = rec.msg.pointer("/params/update").and_then(Value::as_object) else {
            continue;
        };
        if chunk {
            let text = update
                .get("content")
                .and_then(|c| c.get("text"))
                .and_then(Value::as_str)
                .unwrap_or_default();
            match rows.last_mut() {
                Some((kind, joined))
                    if open.as_deref() == Some(rec.kind.as_str()) && *kind == rec.kind =>
                {
                    joined.push_str(text)
                }
                _ => rows.push((rec.kind.clone(), text.to_owned())),
            }
            open = Some(rec.kind.clone());
            continue;
        }
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
    Shown { calls, rows }
}

fn transcript() -> EventFilter {
    EventFilter::parse(Some(&json!(["transcript"]))).unwrap().omitting_superseded(true)
}

/// Every record of the log, in order.
fn all(store: &dyn Store, id: &str) -> Vec<EventRecord> {
    store.events(id, 0, usize::MAX).unwrap()
}

/// The log's segment files, by name, with their bytes.
fn segments(dir: &Path) -> std::collections::BTreeMap<String, Vec<u8>> {
    std::fs::read_dir(dir)
        .unwrap()
        .flatten()
        .filter(|e| e.file_name().to_string_lossy().ends_with(".ndjson"))
        .map(|e| (e.file_name().to_string_lossy().into_owned(), std::fs::read(e.path()).unwrap()))
        .collect()
}

fn write_chat(sessions: &Path, id: &str, log: &[EventRecord]) {
    let writer = LocalStore::new(sessions.to_path_buf(), SEGMENT).unwrap();
    writer.save(&meta(id)).unwrap();
    for rec in log {
        writer.append(id, rec).unwrap();
    }
    writer.flush().unwrap();
}

/// Each surviving record is the logged one, or the logged update with its content left out
/// (noted in `_meta.acpmux.supersededContent`); the seqs only lose some, never move.
fn assert_kept_as_logged(after: &[EventRecord], log: &[EventRecord]) {
    let by_seq: std::collections::HashMap<u64, &EventRecord> =
        log.iter().map(|r| (r.seq, r)).collect();
    for rec in after {
        let logged =
            by_seq.get(&rec.seq).unwrap_or_else(|| panic!("seq {} was never logged", rec.seq));
        if rec == *logged {
            continue;
        }
        assert_eq!(rec.kind, "tool_call_update", "only updates change: {rec:?}");
        let mut without = (*logged).clone();
        let update = without.msg.pointer_mut("/params/update").unwrap().as_object_mut().unwrap();
        assert!(update.remove("content").is_some(), "seq {} lost more than content", rec.seq);
        let mut noted = rec.clone();
        let meta =
            noted.msg.pointer_mut("/params/update/_meta/acpmux").unwrap().as_object_mut().unwrap();
        assert!(meta.remove("supersededContent").is_some());
        if meta.is_empty() {
            noted
                .msg
                .pointer_mut("/params/update/_meta")
                .unwrap()
                .as_object_mut()
                .unwrap()
                .remove("acpmux");
        }
        assert_eq!(noted, without, "seq {} changed beyond its content", rec.seq);
    }
}

/// A reader paging back from the newest record with `limit` and `max_bytes`: at every page, what
/// it holds shows what the log held over the same span. The pages and the first seq of each.
fn page_back(
    hub: &Hub,
    id: &str,
    logged: &[EventRecord],
    limit: usize,
    max_bytes: Option<usize>,
) -> Vec<u64> {
    let filter = transcript();
    let matching: Vec<EventRecord> = logged.iter().filter(|r| filter.matches(r)).cloned().collect();
    let mut held: Vec<EventRecord> = Vec::new();
    let mut firsts = Vec::new();
    let mut before = None;
    loop {
        let page = hub.events_page(id, 0, before, limit, max_bytes, true, &filter).unwrap();
        assert!(!page.events.is_empty(), "a page holds a record ({limit}, {max_bytes:?})");
        let first = page.events[0].seq;
        held.splice(0..0, page.events);
        let span: Vec<EventRecord> = matching.iter().filter(|r| r.seq >= first).cloned().collect();
        assert_eq!(
            shown_paged(&held),
            shown_paged(&span),
            "paged back to {first} ({limit}, {max_bytes:?})"
        );
        assert_eq!(page.has_more, matching.iter().any(|r| r.seq < first), "hasMore at {first}");
        firsts.push(first);
        if !page.has_more {
            return firsts;
        }
        before = Some(first);
    }
}

const PAGES: &[(usize, Option<usize>)] = &[
    // The app's open page and its older pages (webviews `direct.ts`).
    (400, Some(128 * 1024)),
    (2000, Some(1024 * 1024)),
    // By count alone, and tight byte bounds that stop pages inside a call.
    (50, None),
    (7, Some(4096)),
];

/// Leo's coordinator chat grew 3.2 MB an hour, and a live chat's log never shrank: a segment
/// that sealed now drops the updates later ones replace, and every page, the folded transcript,
/// a resume after a dropped seq and the open segment stay as they were.
#[test]
fn a_live_chats_sealed_segments_compact_and_every_page_shows_the_same() {
    let root = tempfile::tempdir().unwrap();
    let sessions = root.path().join("sessions");
    write_chat(&sessions, "live", &coordinator_chat(60));
    let events = sessions.join("live").join("events");
    let hub = hub(Box::new(LocalStore::new(sessions.clone(), SEGMENT).unwrap()));
    // The log as the hub holds it (it may log records of its own as it opens the chat).
    let pages_of = |logged: &[EventRecord]| -> Vec<Vec<u64>> {
        PAGES.iter().map(|(limit, bytes)| page_back(&hub, "live", logged, *limit, *bytes)).collect()
    };
    let _ = pages_of(&all(hub.store.as_ref(), "live"));
    let log = all(hub.store.as_ref(), "live");
    let before_pages = pages_of(&log);
    assert_eq!(all(hub.store.as_ref(), "live"), log, "nothing logged while paging");
    let before_files = segments(&events);
    assert!(before_files.len() >= 5, "{} segments", before_files.len());

    let stats = hub.compact_sealed("live", usize::MAX).unwrap();

    let after = all(hub.store.as_ref(), "live");
    assert_kept_as_logged(&after, &log);
    assert_eq!(shown(&after), shown(&log), "the whole transcript");
    assert!(stats.dropped > 0, "{stats:?}");
    // The sealed segments shrank; the one being written is as it was, byte for byte.
    let after_files = segments(&events);
    assert_eq!(after_files.keys().collect::<Vec<_>>(), before_files.keys().collect::<Vec<_>>());
    let newest = before_files.keys().last().unwrap();
    assert_eq!(after_files[newest], before_files[newest], "the open segment is untouched");
    let size = |files: &std::collections::BTreeMap<String, Vec<u8>>| {
        files.iter().filter(|(name, _)| *name != newest).map(|(_, b)| b.len()).sum::<usize>()
    };
    assert!(
        size(&after_files) * 10 < size(&before_files) * 7,
        "sealed segments {} -> {} bytes",
        size(&before_files),
        size(&after_files)
    );
    assert_eq!(
        stats.bytes_before - stats.bytes_after,
        (size(&before_files) - size(&after_files)) as u64
    );
    // Every page: what it shows is what the log showed over its span, and each reaches at least
    // as far back as it did.
    for ((limit, bytes), was) in PAGES.iter().zip(&before_pages) {
        let now = page_back(&hub, "live", &log, *limit, *bytes);
        assert!(
            now[0] <= was[0],
            "the newest page ({limit}, {bytes:?}) starts at {} (was {})",
            now[0],
            was[0]
        );
    }
    // A reader that resumes after a seq compaction dropped (an attach's `lastSeq`, a peer's
    // catch-up `afterSeq`) ends with the same transcript.
    let kept: std::collections::HashSet<u64> = after.iter().map(|r| r.seq).collect();
    let dropped: Vec<u64> = log.iter().map(|r| r.seq).filter(|s| !kept.contains(s)).collect();
    for &at in dropped.iter().step_by(dropped.len() / 7 + 1) {
        let mut seen: Vec<EventRecord> = log.iter().filter(|r| r.seq <= at).cloned().collect();
        let rest = hub
            .events_page("live", at, None, usize::MAX, None, false, &EventFilter::all())
            .unwrap();
        assert!(rest.events.iter().all(|r| r.seq > at));
        seen.extend(rest.events);
        assert_eq!(shown(&seen), shown(&log), "resumed after {at}");
    }
    // A second pass finds nothing more; a later seal compacts only the new segment.
    let again = hub.compact_sealed("live", usize::MAX).unwrap();
    assert_eq!(again.bytes_before, 0, "{again:?}");
    assert_eq!(segments(&events), after_files);
}

/// A fork shows its chat's records through a seq (`store/fork_view.rs`). A fork made while a
/// command ran references a seq inside the command's updates: what it shows of the command is
/// what it showed before the chat's segment compacted.
#[test]
fn a_fork_through_a_running_command_shows_the_same_after_its_chat_compacts() {
    let root = tempfile::tempdir().unwrap();
    let sessions = root.path().join("sessions");
    let log = coordinator_chat(30);
    write_chat(&sessions, "parent", &log);
    let hub = hub(Box::new(LocalStore::new(sessions.clone(), SEGMENT).unwrap()));
    // Through the second update of a command in the first segment.
    let call = log.iter().find(|r| r.kind == "tool_call").unwrap();
    let through = call.seq + 2;
    assert_eq!(log[through as usize - 1].kind, "tool_call_update");
    let mut fork = meta("fork");
    fork.history_from = Some(HistoryRef { session: "parent".into(), through_seq: through });
    hub.store.save(&fork).unwrap();
    let before = all(hub.store.as_ref(), "fork");
    assert!(before.iter().any(|r| r.seq == through));

    let stats = hub.compact_sealed("parent", usize::MAX).unwrap();
    assert!(stats.dropped > 0, "{stats:?}");

    let after = all(hub.store.as_ref(), "fork");
    assert_eq!(shown(&after), shown(&before), "the fork's history");
    assert_eq!(after.last().map(|r| r.seq), Some(through));
}

/// A crash at any point of a compaction leaves a log that reads as before: before the commit (its
/// copies beside the log), and between two segments' renames. The next pass finishes the work and
/// removes what the crash left.
#[test]
fn a_compaction_a_crash_cut_short_reads_the_same_and_finishes_next_time() {
    let root = tempfile::tempdir().unwrap();
    let sessions = root.path().join("sessions");
    let id = "sealed-compaction-crash";
    let log = coordinator_chat(40);
    write_chat(&sessions, id, &log);
    let events = sessions.join(id).join("events");
    let original = segments(&events);
    let store = LocalStore::new(sessions.clone(), SEGMENT).unwrap();

    // Before the commit: the compacted copies are on disk beside the log, never read.
    let staged = store.stage_sealed(id, &[], usize::MAX).unwrap().expect("sealed segments");
    std::mem::forget(staged);
    let reopened = LocalStore::new(sessions.clone(), SEGMENT).unwrap();
    assert_eq!(all(&reopened, id), log, "a crash before the commit keeps the log as it was");
    assert_eq!(segments(&events), original);

    // Between two renames: the disk then holds one compacted segment and the rest as they were.
    let crash = tempfile::tempdir().unwrap();
    let (from, to) = (sessions.join(id), crash.path().join("sessions").join(id));
    crate::store::between_segments_once(
        id,
        Box::new(move || {
            std::fs::create_dir_all(to.join("events")).unwrap();
            for entry in std::fs::read_dir(from.join("events")).unwrap().flatten() {
                std::fs::copy(entry.path(), to.join("events").join(entry.file_name())).unwrap();
            }
            std::fs::copy(from.join("session.json"), to.join("session.json")).unwrap();
        }),
    );
    let staged = reopened.stage_sealed(id, &[], usize::MAX).unwrap().expect("sealed segments");
    assert!(reopened.commit_sealed(id, staged).unwrap());
    let done = all(&reopened, id);
    assert_eq!(shown(&done), shown(&log));
    // No copy is left beside the finished log.
    let leftovers: Vec<String> = std::fs::read_dir(&events)
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .filter(|n| n.contains(".ndjson."))
        .collect();
    assert!(leftovers.is_empty(), "{leftovers:?}");

    let crashed_sessions = crash.path().join("sessions");
    let crashed = LocalStore::new(crashed_sessions.clone(), SEGMENT).unwrap();
    let half = all(&crashed, id);
    assert_kept_as_logged(&half, &log);
    assert_eq!(shown(&half), shown(&log), "the log the crash left reads the same");
    let half_files = segments(&crashed_sessions.join(id).join("events"));
    let changed = half_files.iter().filter(|(name, bytes)| original[*name] != **bytes).count();
    assert_eq!(changed, 1, "one segment was in place when it crashed");
    // The next pass compacts the rest, to the same log a pass with no crash wrote.
    let staged = crashed.stage_sealed(id, &[], usize::MAX).unwrap().expect("sealed segments");
    assert!(crashed.commit_sealed(id, staged).unwrap());
    assert_eq!(all(&crashed, id), done);
}

/// Through the journal (the daemon's store): a compaction checkpoints the journal first, so a kill
/// after it replays nothing the compaction dropped back into the log.
#[test]
fn a_kill_after_a_compaction_replays_no_dropped_record() {
    use cmux_journal::{Crash, SimStorage};
    let home = tempfile::tempdir().unwrap();
    let journal = SimStorage::new(11);
    let config = crate::config::StoreConfig { segment_bytes: SEGMENT, ..Default::default() };
    let journal_config = cmux_journal::Config {
        retry_min: std::time::Duration::from_millis(1),
        retry_max: std::time::Duration::from_millis(5),
        ..cmux_journal::Config::default()
    };
    let open = |journal: &SimStorage| {
        crate::store::open_with_journal(
            &config,
            home.path(),
            Arc::new(journal.clone()),
            journal_config.clone(),
        )
        .unwrap()
    };
    let store = open(&journal);
    let log = coordinator_chat(40);
    store.save(&meta("j")).unwrap();
    for rec in &log {
        store.append("j", rec).unwrap();
    }
    assert!(store.wait_durable(std::time::Duration::from_secs(10)).unwrap());
    let staged = store.stage_sealed("j", &[], usize::MAX).unwrap().expect("sealed segments");
    assert!(store.commit_sealed("j", staged).unwrap());
    let compacted = all(store.as_ref(), "j");
    assert!(compacted.len() < log.len(), "{} of {} records", compacted.len(), log.len());
    // More records after it, then a kill.
    let mut tail = coordinator_chat(42).split_off(log.len());
    for rec in &mut tail {
        store.append("j", rec).unwrap();
    }
    assert!(store.wait_durable(std::time::Duration::from_secs(10)).unwrap());
    let killed = journal.restart(Crash::Process);
    drop(store);
    let store = open(&killed);
    let mut expected = compacted.clone();
    expected.extend(tail.iter().cloned());
    assert_eq!(all(store.as_ref(), "j"), expected, "each record once, none dropped back in");
}
