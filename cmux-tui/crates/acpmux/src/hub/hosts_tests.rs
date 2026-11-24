//! Adopting a host after a restart reads its chat's log (`open_work`, `last_host_seq`, the
//! remote env check, the process table). Those reads parse only the records they fold: a long
//! log is mostly closed turns' agent output (big-red, 2026-10-27: 84 hosted chats, 30 GB of
//! logs, a full core for minutes after each restart).

use super::*;
use crate::config::{Config, StoreMode};
use crate::store::{EventRecord, PARSED_LINES};

/// Sessions and closed turns per session the bench builds; each turn streams `UPDATES` tool
/// updates of about 1.5 KB, as a coding agent's log does.
const SESSIONS: usize = 4;
const TURNS: u64 = 50;
const UPDATES: u64 = 200;

struct Log {
    records: Vec<EventRecord>,
    host_seq: u64,
}

impl Log {
    fn push(&mut self, dir: &str, kind: &str, msg: Value, from_host: bool) {
        let host_seq = from_host.then(|| {
            self.host_seq += 1;
            self.host_seq
        });
        let seq = self.records.len() as u64 + 1;
        self.records.push(EventRecord {
            seq,
            at: 1_000 + seq,
            dir: dir.into(),
            kind: kind.into(),
            msg,
            host_seq,
        });
    }

    fn update(&mut self, update: Value) {
        self.update_of("own", update);
    }

    /// An update under `session_id`: the chat's own, or a subagent's.
    fn update_of(&mut self, session_id: &str, update: Value) {
        let kind = update["sessionUpdate"].as_str().unwrap().to_owned();
        let msg = json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": update}});
        self.push("in", &kind, msg, true);
    }

    fn turn(&mut self, turn: u64, updates: u64) {
        let id = format!("t{turn}");
        self.push(
            "mux",
            "turn_started",
            json!({"turnId": id, "promptId": format!("p{turn}"), "prompt": "go", "client": "cli"}),
            false,
        );
        self.push("out", "session/prompt", json!({"jsonrpc": "2.0", "id": turn, "method": "session/prompt", "params": {"sessionId": "own"}}), true);
        let text = "x".repeat(1500);
        for n in 0..updates {
            let status = if n + 1 == updates { "completed" } else { "in_progress" };
            self.update(json!({"sessionUpdate": "tool_call_update", "toolCallId": format!("c{turn}"), "status": status, "content": [{"type": "content", "content": {"type": "text", "text": text}}]}));
        }
    }

    fn end_turn(&mut self, turn: u64) {
        self.push(
            "in",
            "response",
            json!({"jsonrpc": "2.0", "id": turn, "result": {"stopReason": "end_turn"}}),
            true,
        );
        self.push(
            "mux",
            "turn_result",
            json!({"turnId": format!("t{turn}"), "status": "completed"}),
            false,
        );
    }

    fn ask(&mut self, id: u64, answered: bool) {
        self.push("in", "session/request_permission", json!({"jsonrpc": "2.0", "id": id, "method": "session/request_permission", "params": {"sessionId": "own", "options": [{"optionId": "always", "kind": "allow_always"}]}}), true);
        self.push("mux", "permission_request", json!({"permissionId": format!("perm{id}"), "agentRequestId": id, "request": {"options": [{"optionId": "always", "kind": "allow_always"}]}}), false);
        if answered {
            self.push("mux", "permission_decision", json!({"permissionId": format!("perm{id}"), "outcome": {"outcome": "selected", "optionId": "always"}}), false);
            self.push("out", "response", json!({"jsonrpc": "2.0", "id": id, "result": {}}), true);
        }
    }
}

/// A chat whose agent ran `TURNS` closed turns (an answered permission, a Codex legacy subagent
/// and a background process among them) under one host, and is in a turn with a tool in flight,
/// a steer, a subagent's update and an unanswered permission when the daemon stops.
fn hosted_log() -> Log {
    hosted_log_of(TURNS, UPDATES)
}

/// `hosted_log` with `turns` closed turns of `updates` updates each.
fn hosted_log_of(turns: u64, updates: u64) -> Log {
    let mut log = Log { records: Vec::new(), host_seq: 0 };
    log.push("mux", "host_started", json!({"incarnation": "old"}), false);
    log.turn(9_000, 3);
    log.end_turn(9_000);
    log.push("mux", "host_started", json!({"incarnation": "inc"}), false);
    for turn in 0..turns {
        log.turn(turn, updates);
        if turn == 1 {
            log.ask(5_000, true);
            log.update(json!({"sessionUpdate": "tool_call", "toolCallId": "spawn", "status": "completed", "rawInput": {"prompt": "dig"}, "_meta": {"codex": {"collaboration": {"tool": "spawnAgent", "receiverThreadIds": ["sub"]}}}}));
        }
        if turn == 2 {
            log.push("in", "background_task_update", json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "own", "update": {"sessionUpdate": "background_task_update", "toolCallId": "bg", "taskId": "bg", "state": "running", "command": "serve"}}}), true);
        }
        log.end_turn(turn);
    }
    log.turn(turns, 2);
    log.update(json!({"sessionUpdate": "tool_call", "toolCallId": "open", "title": "Run tests", "status": "in_progress"}));
    log.update_of("sub", json!({"sessionUpdate": "tool_call", "toolCallId": "sub-call", "title": "Sub", "status": "in_progress"}));
    log.push("out", "session/prompt", json!({"jsonrpc": "2.0", "id": 77, "method": "session/prompt", "params": {"sessionId": "own", "_meta": {"steer": true}}}), true);
    log.push(
        "in",
        "response",
        json!({"jsonrpc": "2.0", "id": 77, "result": {"stopReason": "steered"}}),
        true,
    );
    log.ask(6_000, false);
    // Two fenced lines the host took (protocol 3); the harness has only the first.
    let note =
        |method: &str, params: Value| json!({"jsonrpc": "2.0", "method": method, "params": params});
    for (method, params) in [
        (agent_host::QUEUED_METHOD, json!({"receipt": 41})),
        (agent_host::WRITTEN_METHOD, json!({"receipt": 41, "written": true})),
        (agent_host::QUEUED_METHOD, json!({"receipt": 42})),
    ] {
        log.push("out", method, note(method, params), true);
    }
    log.update(json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "working"}}));
    log
}

/// A hub over `sessions` chats that each hold `log`, written after the hub loaded so its start
/// settles nothing in them: the log is as the previous daemon left it.
async fn hub_with(sessions: usize, log: &Log) -> (Arc<Hub>, std::path::PathBuf) {
    hub_with_meta(sessions, log, json!({})).await
}

/// ``hub_with``, each chat's meta also holding `extra`'s fields.
async fn hub_with_meta(sessions: usize, log: &Log, extra: Value) -> (Arc<Hub>, std::path::PathBuf) {
    let root = std::env::temp_dir().join(format!("acpmux-adopt-reads-{}", uuid::Uuid::now_v7()));
    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let store = crate::store::open(&cfg.store, &root).unwrap();
    for n in 0..sessions {
        let id = format!("chat{n}");
        let mut meta = json!({
            "schema": crate::store::META_SCHEMA, "id": id, "name": id, "harness": "claude",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2,
        });
        for (k, v) in extra.as_object().into_iter().flatten() {
            meta[k] = v.clone();
        }
        store.save(&serde_json::from_value(meta).unwrap()).unwrap();
    }
    drop(store);
    let hub = Hub::new(cfg.clone(), crate::store::open(&cfg.store, &root).unwrap());
    for n in 0..sessions {
        let id = format!("chat{n}");
        for record in &log.records {
            hub.store.append(&id, record).unwrap();
        }
        hub.store.close_log(&id);
        // These direct store appends stand in for the previous daemon's append path. The
        // already-loaded session must know their settled end before recovery snapshots it.
        let session = hub.resolve(&id).unwrap();
        session.seq.store(log.records.last().map_or(0, |record| record.seq), Ordering::SeqCst);
    }
    (hub, root)
}

/// The bench: the reads an adoption makes of `SESSIONS` hosted chats' logs, as lines parsed and
/// time taken. Every line of every log was parsed four times; now only the folded ones are.
#[tokio::test]
async fn adoption_reads_parse_only_the_records_they_fold() {
    let log = hosted_log();
    let (hub, root) = hub_with(SESSIONS, &log).await;
    let lines = (SESSIONS * log.records.len()) as u64;
    let bytes: u64 = (0..SESSIONS)
        .flat_map(|n| {
            std::fs::read_dir(root.join("sessions").join(format!("chat{n}")).join("events"))
                .unwrap()
        })
        .map(|e| e.unwrap().metadata().unwrap().len())
        .sum();
    let parsed_before = PARSED_LINES.with(std::cell::Cell::get);
    let started = std::time::Instant::now();
    let mut resumed = Vec::new();
    for n in 0..SESSIONS {
        let session = hub.resolve(&format!("chat{n}")).unwrap();
        let _ = hub.remote_host_env_current(&session, "inc");
        let after = hub.last_host_seq(&session, "inc");
        let work = hub.open_work(&session, "inc");
        hub.rebuild_processes(&session);
        resumed.push((after, work.turn.map(|t| t.1), work.requests.len()));
    }
    let elapsed = started.elapsed();
    let parsed = PARSED_LINES.with(std::cell::Cell::get) - parsed_before;
    eprintln!(
        "adoption reads: {SESSIONS} chats x {} records ({:.1} MB): parsed {parsed} lines in {} ms",
        log.records.len(),
        bytes as f64 / 1e6,
        elapsed.as_millis()
    );
    let open = (log.host_seq, Some(format!("t{TURNS}")), 1);
    assert!(resumed.iter().all(|r| *r == open), "{resumed:?}");
    assert!(parsed * 20 < lines, "parsed {parsed} of {lines} log lines");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

#[tokio::test]
async fn a_withdrawal_after_the_recovery_snapshot_is_not_lost() {
    let mut log = Log { records: Vec::new(), host_seq: 0 };
    log.push("mux", "host_started", json!({"incarnation": "inc"}), false);
    log.ask(7, false);
    let (hub, root) = hub_with(1, &log).await;
    let session = hub.resolve("chat0").unwrap();
    let work = hub.recovery_work(&session, "inc", log.host_seq);
    assert_eq!(work.requests.len(), 1);
    // The snapshot is complete, but the recovered handler has not run yet.
    hub.withdraw_permission(&session, Some("inc"), &json!(7));
    let key = super::super::permission_groups::AgentRequestKey::new(Some("inc"), &json!(7));
    assert!(
        session
            .permissions
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .cancelled_requests
            .contains(&key),
        "the cancellation vanished before recovery admitted it"
    );
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(root);
}

#[tokio::test]
async fn adoption_recovers_a_main_compaction_in_progress() {
    let mut log = hosted_log();
    log.update(json!({"sessionUpdate": "compaction", "state": "running"}));
    log.update_of("sub", json!({"sessionUpdate": "compaction", "state": "completed"}));
    let (hub, root) = hub_with(1, &log).await;
    let session = hub.resolve("chat0").unwrap();
    let work = hub.recovery_work(&session, "inc", log.host_seq);
    assert!(work.compacting, "main compaction was not recovered from the host log");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(root);
}

/// Everything `open_work` recovers, in a fixed order.
fn work_fields(w: &OpenWork) -> String {
    let permissions: std::collections::BTreeMap<_, _> = w.permissions.iter().collect();
    format!(
        "{:?} {:?} {} {:?} {} {} {:?} {:?} {:?} {:?} {:?} {} {:?} {:?} {} {} {:?} {:?} {:?} {:?} {:?} {:?}",
        w.turn.as_ref().map(|t| (t.0, &t.1, &t.2, &t.3, &t.4, t.5)),
        w.turn_line,
        w.turn_carried,
        w.carry_next,
        w.turn_at,
        w.heard_at,
        w.open_tools.iter().collect::<std::collections::BTreeSet<_>>(),
        w.prompt_request,
        w.prompt_response,
        w.steers,
        w.requests,
        w.last_host_seq,
        w.floor_cancelled,
        w.last_control,
        w.harness_grant,
        w.unsandboxed,
        w.doing,
        permissions,
        w.withdrawn.iter().collect::<std::collections::BTreeSet<_>>(),
        w.cancelled_permissions.iter().collect::<std::collections::BTreeSet<_>>(),
        w.withdrawn_asks.iter().collect::<std::collections::BTreeSet<_>>(),
        (&w.unwritten, w.receipts_unproven),
    )
}

/// A turn that carried into the next (`carried_turn.rs`): a restart before the next turn's start
/// still finds it named (`carriedTo`), and once it started, its steers sent before its prompt are
/// steers and its prompt is the hub's carried one.
#[tokio::test]
async fn adoption_finds_a_carried_turn_whose_prompt_had_not_gone_out() {
    let mut log = Log { records: Vec::new(), host_seq: 0 };
    log.push("mux", "host_started", json!({"incarnation": "inc"}), false);
    log.turn(1, 1);
    let carried = json!({"seq": 7, "promptIds": ["p-late"]});
    let answer = json!({"stopReason": "end_turn", "_meta": {"claude": {"carried": carried}}});
    log.push("in", "response", json!({"jsonrpc": "2.0", "id": 1, "result": answer}), true);
    let to = json!({"turnId": "t2", "promptId": "p-late", "prompt": "late", "client": "cli", "control": "local", "trustGate": true, "seq": 7, "promptIds": ["p-late"]});
    log.push(
        "mux",
        "turn_result",
        json!({"turnId": "t1", "status": "completed", "carriedTo": to}),
        false,
    );
    // A Web steer raised the carried turn before its start was logged.
    log.push("mux", "turn_control", json!({"turnId": "t2", "control": "web"}), false);
    let (hub, root) = hub_with(1, &log).await;
    let session = hub.resolve("chat0").unwrap();
    let work = hub.open_work(&session, "inc");
    assert!(work.turn.is_none());
    let (from, record) = work.carry_next.clone().expect("the carried turn is named");
    assert_eq!(from, "t1");
    let next = super::super::carried_turn::NextTurn::from_record(&record).unwrap();
    assert_eq!((next.next.turn_id.as_str(), next.next.prompt_id.as_str()), ("t2", "p-late"));
    assert_eq!(next.next.control, Control::Web, "raised before its start");
    assert!(next.continues.trust_gate, "its trust gate");
    assert_eq!((next.carried.seq, next.carried.prompt_ids.clone()), (7, vec!["p-late".to_owned()]));
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);

    let started = json!({"turnId": "t2", "promptId": "p-late", "prompt": "[coord] late", "promptLine": "coord: late", "client": "cli", "carried": {"fromTurnId": "t1", "promptIds": ["p-late"]}});
    log.push("mux", "turn_started", started, false);
    let steer = json!({"jsonrpc": "2.0", "id": 3, "method": "session/prompt", "params": {"sessionId": "own", "_meta": {"steer": true}}});
    log.push("out", "session/prompt", steer, true);
    let (hub, root) = hub_with(1, &log).await;
    let session = hub.resolve("chat0").unwrap();
    let work = hub.open_work(&session, "inc");
    assert_eq!(work.turn.as_ref().map(|t| t.1.as_str()), Some("t2"));
    assert_eq!(work.turn.as_ref().map(|t| t.5), Some(Control::Web), "raised before its start");
    assert!(work.turn_carried && work.carry_next.is_none());
    // The line the turn showed (`prompt_line.rs`), which its record keeps for a restart.
    assert_eq!(work.turn_line.as_deref(), Some("coord: late"));
    assert_eq!(work.prompt_request, None, "a steer is not a carried turn's prompt");
    assert_eq!(work.steers, vec![(json!(3), None)]);
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);

    let prompt = json!({"jsonrpc": "2.0", "id": 4, "method": "session/prompt", "params": {"sessionId": "own", "prompt": [], "_meta": {"carried": true}}});
    log.push("out", "session/prompt", prompt, true);
    let (hub, root) = hub_with(1, &log).await;
    let session = hub.resolve("chat0").unwrap();
    let work = hub.open_work(&session, "inc");
    assert_eq!(work.prompt_request, Some(json!(4)));
    assert_eq!(work.steers, vec![(json!(3), None)], "its steers stay steers");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A Web steer raised the turn the open turn carried into before the open turn's end was logged:
/// adoption knows the carried turn is a Web turn (`next_raised`).
#[tokio::test]
async fn adoption_knows_a_carried_turn_raised_before_its_turn_before_ended() {
    let mut log = Log { records: Vec::new(), host_seq: 0 };
    log.push("mux", "host_started", json!({"incarnation": "inc"}), false);
    log.turn(1, 1);
    log.push("mux", "turn_control", json!({"turnId": "t-next", "control": "web"}), false);
    let (hub, root) = hub_with(1, &log).await;
    let session = hub.resolve("chat0").unwrap();
    let work = hub.open_work(&session, "inc");
    assert_eq!(work.turn.as_ref().map(|t| t.1.as_str()), Some("t1"));
    assert!(work.next_raised, "the carried turn's raise was not kept");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A receipt note that can not be read (no number) leaves adoption nothing to rule out: it fails
/// closed (`OpenWork::receipts_unproven`), whatever the other notes say.
#[tokio::test]
async fn an_unreadable_receipt_note_fails_closed() {
    let mut log = hosted_log();
    let method = agent_host::WRITTEN_METHOD;
    let params = json!({"receipt": "42", "written": true});
    log.push("out", method, json!({"jsonrpc": "2.0", "method": method, "params": params}), true);
    let (hub, root) = hub_with(1, &log).await;
    let session = hub.resolve("chat0").unwrap();
    let work = hub.open_work(&session, "inc");
    assert!(work.receipts_unproven, "an unreadable receipt note was taken as proof");
    assert!(!hub.open_work(&session, "old").receipts_unproven, "another host's note counted");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(root);
}

/// Review round 2: a log that can not be read to its end (a segment the store refuses: here one
/// others may write), or that has no start of the adopted incarnation, proves no receipt.
#[cfg(unix)]
#[tokio::test]
async fn a_log_read_short_proves_no_receipt() {
    use std::os::unix::fs::PermissionsExt;
    let (hub, root) = hub_with(1, &hosted_log()).await;
    let session = hub.resolve("chat0").unwrap();
    assert!(!hub.open_work(&session, "inc").receipts_unproven, "a whole log proved nothing");
    assert!(hub.open_work(&session, "gone").receipts_unproven, "a host the log never started");
    let events = hub.store.session_dir("chat0").unwrap().join("events");
    for segment in std::fs::read_dir(events).unwrap() {
        let path = segment.unwrap().path();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o620)).unwrap();
    }
    let work = hub.open_work(&session, "inc");
    assert!(work.receipts_unproven, "a log the store could not read was taken as proof");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(root);
}

/// What `open_work` recovers from the heads is what a parse of every record recovers: for the
/// adopted incarnation and an older one, with the last turn open and with it closed.
#[tokio::test]
async fn open_work_from_heads_matches_a_parse_of_every_record() {
    let mut open = hosted_log();
    open.push(
        "mux",
        "permission_withdrawn",
        json!({"agentRequestId": 6_000, "incarnation": "inc"}),
        false,
    );
    let mut closed = hosted_log();
    let last_start = closed.records.iter().rposition(|r| r.kind == "turn_started").unwrap();
    closed.records.truncate(last_start);
    for log in [&open, &closed] {
        let (hub, root) = hub_with(1, log).await;
        let session = hub.resolve("chat0").unwrap();
        for incarnation in ["inc", "old", "gone"] {
            let all = hub.open_work_reading(&session, incarnation, |_, _, _| true);
            let heads = hub.open_work(&session, incarnation);
            assert_eq!(work_fields(&heads), work_fields(&all), "{incarnation}");
        }
        let work = hub.open_work(&session, "inc");
        if std::ptr::eq(log, &open) {
            let turn = work.turn.as_ref().map(|t| t.1.as_str());
            assert_eq!(turn, Some(format!("t{TURNS}").as_str()));
            assert_eq!(work.requests.len(), 1, "{:?}", work.requests);
            assert!(work.cancelled_permissions.contains("6000"));
            assert_eq!(work.permissions["6000"].2, Some(json!({"outcome": "cancelled"})));
            assert_eq!(work.steers.len(), 1);
            // The #26241 residual risk: the line with no receipt logged is the one held again.
            assert_eq!(work.unwritten, std::collections::BTreeSet::from([42]));
            assert!(work.harness_grant, "the answered ask chose allow always");
            assert!(work.doing.open_tools.contains("open"), "{:?}", work.doing);
            assert!(
                !work.doing.open_tools.contains("sub-call"),
                "a subagent's tool is not the turn's"
            );
        } else {
            assert!(work.turn.is_none());
        }
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&root);
    }
}

/// A Codex chat whose native root changed: its earlier root is a root, never one of its
/// subagents. A record that echoes the earlier root as legacy subagent activity makes no child
/// of it, so that root's tool in the open turn is still the turn's own (as the tap reads it).
#[tokio::test]
async fn open_work_never_reads_an_earlier_native_root_as_a_subagent() {
    let mut log = Log { records: Vec::new(), host_seq: 0 };
    log.push("mux", "host_started", json!({"incarnation": "inc"}), false);
    log.turn(1, 1);
    log.update_of("old-root", json!({"sessionUpdate": "tool_call", "toolCallId": "echo", "status": "in_progress", "_meta": {"codex": {"subagent": {"threadId": "old-root", "activity": "running"}}}}));
    log.update_of("old-root", json!({"sessionUpdate": "tool_call", "toolCallId": "root-call", "title": "Root", "status": "in_progress"}));
    let meta = json!({"agentSessionId": "own", "retiredAgentSessionIds": ["old-root"]});
    let (hub, root) = hub_with_meta(1, &log, meta).await;
    let session = hub.resolve("chat0").unwrap();
    let work = hub.open_work(&session, "inc");
    assert!(work.turn.is_some());
    assert!(
        work.doing.open_tools.contains("root-call"),
        "an earlier root's tool is the turn's: {:?}",
        work.doing
    );
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A line a crash cut short (`..."result":{"a":0,"hostSeq":999999}` with the record unclosed)
/// reads as a head whose `hostSeq` is its `msg`'s. The resume point and the recovered work are
/// still those of the whole records, before and after the daemon logs past it.
#[tokio::test]
async fn a_line_cut_short_never_moves_the_resume_point() {
    let mut log = hosted_log();
    let last_start = log.records.iter().rposition(|r| r.kind == "turn_started").unwrap();
    log.records.truncate(last_start);
    let (hub, root) = hub_with(1, &log).await;
    let session = hub.resolve("chat0").unwrap();
    let segment = std::fs::read_dir(hub.store.session_dir("chat0").unwrap().join("events"))
        .unwrap()
        .map(|e| e.unwrap().path())
        .max()
        .unwrap();
    let append = |line: String| {
        use std::io::Write;
        let mut file = std::fs::OpenOptions::new().append(true).open(&segment).unwrap();
        file.write_all(format!("{line}\n").as_bytes()).unwrap();
    };
    let whole = log.records.iter().filter_map(|r| r.host_seq).max().unwrap();
    let seq = log.records.len() + 1;
    append(format!(
        r#"{{"seq":{seq},"at":1,"dir":"in","kind":"response","msg":{{"id":7,"jsonrpc":"2.0","result":{{"a":0,"hostSeq":999999}}"#
    ));
    append(format!(
        r#"{{"seq":{seq},"at":1,"dir":"mux","kind":"permission_withdrawn","msg":{{"incarnation":"inc","hostSeq":999999}}"#
    ));
    for after in [whole, whole + 1] {
        assert_eq!(hub.last_host_seq(&session, "inc"), after);
        assert_eq!(hub.last_host_seq_parsed(&session, "inc"), after);
        let all = hub.open_work_reading(&session, "inc", |_, _, _| true);
        let heads = hub.open_work(&session, "inc");
        assert_eq!(heads.last_host_seq, after);
        assert_eq!(work_fields(&heads), work_fields(&all));
        if after > whole {
            break;
        }
        // The daemon logs on past the cut line.
        let next = seq + 1;
        append(format!(
            r#"{{"seq":{next},"at":2,"dir":"in","kind":"agent_message_chunk","msg":{{"jsonrpc":"2.0","method":"session/update","params":{{"sessionId":"own","update":{{"sessionUpdate":"agent_message_chunk"}}}}}},"hostSeq":{}}}"#,
            whole + 1,
        ));
    }
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// A controller's deferred withdrawal cannot stand for an entry of the next host, even if an
/// older record carried that host's sequence. Both adoption reads must retain the real cursor.
#[tokio::test]
async fn a_deferred_withdrawal_never_moves_either_adoption_cursor() {
    for incarnation in ["old", "inc"] {
        let mut log = Log { records: Vec::new(), host_seq: 0 };
        log.push("mux", "host_started", json!({"incarnation": "inc"}), false);
        log.ask(7, false);
        let real_cursor = if incarnation == "inc" { 900 } else { log.host_seq };
        log.push(
            "mux",
            "permission_withdrawn",
            json!({"agentRequestId": 7, "incarnation": incarnation}),
            false,
        );
        if let Some(marker) = log.records.last_mut() {
            marker.host_seq = Some(900);
        }
        // A crash may precede the raw copy; a stale copy may follow a replacement.
        if incarnation == "old" {
            log.push("in", method::CANCEL_REQUEST, json!({"params": {"requestId": 7}}), false);
        }
        let (hub, root) = hub_with(1, &log).await;
        let session = hub.resolve("chat0").unwrap();
        assert_eq!(hub.last_host_seq(&session, "inc"), real_cursor);
        assert_eq!(hub.last_host_seq_parsed(&session, "inc"), real_cursor);
        let all = hub.open_work_reading(&session, "inc", |_, _, _| true);
        let heads = hub.open_work(&session, "inc");
        assert_eq!(heads.last_host_seq, real_cursor);
        assert_eq!(work_fields(&heads), work_fields(&all));
        let expected = (incarnation == "inc").then(|| json!({"outcome": "cancelled"}));
        assert_eq!(heads.permissions["7"].2, expected);
        assert!(heads.withdrawn.is_empty());
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&root);
    }
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

/// The reads one adoption of host "inc" makes of `session`'s log (`hosts.rs` `adopt_held`), and
/// what they recovered.
fn adopt_reads(hub: &Arc<Hub>, session: &Arc<Session>) -> String {
    let env = hub.remote_host_env_current(session, "inc");
    let after = hub.last_host_seq(session, "inc");
    hub.seed_subagents(session, hub.subagents_from_log(session, "inc"));
    let work = hub.recovery_work(session, "inc", after);
    let running = session.subagents.lock().unwrap().running_count();
    format!("{env} {after} {running} {}", work_fields(&work))
}

/// The bytes a second adoption of the same host reads, after the host ran three more turns past
/// the first one, from a log of `turns` closed turns before it; and the log's size.
async fn second_adoption_reads(turns: u64) -> (u64, u64) {
    let log = hosted_log_of(turns, UPDATES);
    let (hub, root) = hub_with(1, &log).await;
    let session = hub.resolve("chat0").unwrap();
    adopt_reads(&hub, &session);
    // The host runs on: its open turn ends and three more run, under the seqs the daemon hands
    // out after its own records.
    let mut tail = Log { records: Vec::new(), host_seq: log.host_seq };
    tail.end_turn(turns);
    for turn in turns + 1..turns + 4 {
        tail.turn(turn, UPDATES);
        tail.end_turn(turn);
    }
    tail.turn(turns + 4, 2);
    let base = hub.settled_seq(&session);
    for (n, record) in tail.records.iter_mut().enumerate() {
        record.seq = base + 1 + n as u64;
        record.at = 1_000 + record.seq;
        hub.store.append("chat0", record).unwrap();
    }
    session.seq.store(base + tail.records.len() as u64, Ordering::SeqCst);
    let read_before = read_bytes();
    let second = adopt_reads(&hub, &session);
    let read = read_bytes() - read_before;
    // What it recovered is what a read of every record recovers.
    let all = hub.open_work_reading(&session, "inc", |_, _, _| true);
    let whole = hub.last_host_seq_parsed(&session, "inc");
    assert!(second.ends_with(&work_fields(&{
        let mut all = all;
        all.requests.retain(|(_, _, _, h)| h.is_none_or(|h| h <= whole));
        all
    })));
    assert!(second.starts_with(&format!("false {whole} ")), "{second}");
    let size: u64 = std::fs::read_dir(hub.store.session_dir("chat0").unwrap().join("events"))
        .unwrap()
        .map(|e| e.unwrap().metadata().unwrap().len())
        .sum();
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
    (read, size)
}

/// A daemon restart that adopts a host it adopted before reads what the host logged since, not
/// the chat's history: the second adoption of a chat whose log is 10x longer reads within 1.2x
/// the bytes. Every adoption read the whole log four times (a 4 GB chat: 16 GB per restart).
#[cfg(target_os = "linux")]
#[tokio::test]
async fn a_second_adoption_reads_what_followed_the_first_not_the_log() {
    let (short, short_size) = second_adoption_reads(5).await;
    let (long, long_size) = second_adoption_reads(50).await;
    eprintln!(
        "second adoption: log {:.1} MB read {:.2} MB; log {:.1} MB read {:.2} MB",
        short_size as f64 / 1e6,
        short as f64 / 1e6,
        long_size as f64 / 1e6,
        long as f64 / 1e6
    );
    assert!(long_size > 5 * short_size, "{short_size} {long_size}");
    assert!(long * 5 <= short * 6, "read {long} bytes of a long log, {short} of a short one");
}

/// `value` with every array sorted: a set's order is its hasher's.
fn canonical(mut value: Value) -> Value {
    fn sort(value: &mut Value) {
        match value {
            Value::Array(items) => {
                items.iter_mut().for_each(sort);
                items.sort_by_key(|v| v.to_string());
            }
            Value::Object(map) => map.values_mut().for_each(sort),
            _ => {}
        }
    }
    sort(&mut value);
    value
}

/// Everything the adoption reads of host `incarnation` recover, in a fixed order.
fn adoption_state(hub: &Arc<Hub>, session: &Arc<Session>, incarnation: &str) -> String {
    let work = hub.open_work(session, incarnation);
    format!(
        "{} {} {} {} {}",
        hub.remote_host_env_current(session, incarnation),
        hub.last_host_seq(session, incarnation),
        canonical(serde_json::to_value(hub.subagents_from_log(session, incarnation)).unwrap()),
        canonical(serde_json::to_value(&work).unwrap()),
        work_fields(&work),
    )
}

/// The logs the equivalence test folds: an open last turn (a steer, an unanswered ask, receipts,
/// a subagent's tool), a withdrawal, a closed last turn, a carried turn, a later host started
/// under the remote env policy with a compaction running.
fn checkpoint_logs() -> Vec<Log> {
    let open = hosted_log_of(3, 2);
    let mut withdrawn = hosted_log_of(3, 2);
    withdrawn.push(
        "mux",
        "permission_withdrawn",
        json!({"agentRequestId": 6_000, "incarnation": "inc"}),
        false,
    );
    let mut closed = hosted_log_of(3, 2);
    let last_start = closed.records.iter().rposition(|r| r.kind == "turn_started").unwrap();
    closed.records.truncate(last_start);
    let mut carried = Log { records: Vec::new(), host_seq: 0 };
    carried.push("mux", "host_started", json!({"incarnation": "inc"}), false);
    carried.turn(1, 1);
    let to = json!({"turnId": "t2", "promptId": "p-late", "prompt": "late", "client": "cli", "seq": 7, "promptIds": ["p-late"]});
    carried.push(
        "mux",
        "turn_result",
        json!({"turnId": "t1", "status": "completed", "carriedTo": to}),
        false,
    );
    carried.push("mux", "turn_control", json!({"turnId": "t2", "control": "web"}), false);
    let started = json!({"turnId": "t2", "promptId": "p-late", "prompt": "late", "client": "cli", "carried": {"fromTurnId": "t1", "promptIds": ["p-late"]}});
    carried.push("mux", "turn_started", started, false);
    let steer = json!({"jsonrpc": "2.0", "id": 3, "method": "session/prompt", "params": {"sessionId": "own", "_meta": {"steer": true, "promptId": "p-steer"}}});
    carried.push("out", "session/prompt", steer, true);
    let mut next = hosted_log_of(3, 2);
    next.end_turn(3);
    let policy = crate::agent::REMOTE_ENV_POLICY_ID;
    next.push(
        "mux",
        "host_started",
        json!({"incarnation": "next", "remoteEnvPolicy": policy}),
        false,
    );
    next.turn(4, 2);
    next.ask(9_100, false);
    next.update(json!({"sessionUpdate": "compaction", "state": "running"}));
    vec![open, withdrawn, closed, carried, next]
}

/// An adoption resumed from a checkpoint recovers what a fold of the whole log recovers: for
/// each log, a checkpoint saved by an adoption of each host incarnation when the log ended at
/// every record, then the rest of the log, against a fresh read of it all.
#[tokio::test]
async fn an_adoption_resumed_from_its_checkpoint_matches_a_whole_read() {
    let incarnations = ["inc", "old", "gone", "next"];
    for (n, log) in checkpoint_logs().iter().enumerate() {
        let (hub, root) = hub_with(1, log).await;
        let session = hub.resolve("chat0").unwrap();
        hub.catch_up(&session);
        let whole: Vec<String> =
            incarnations.iter().map(|i| adoption_state(&hub, &session, i)).collect();
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&root);
        let mut resumed = 0;
        for split in 1..log.records.len() {
            let head = Log { records: log.records[..split].to_vec(), host_seq: 0 };
            let (hub, root) = hub_with(1, &head).await;
            let session = hub.resolve("chat0").unwrap();
            // An adoption of each host when the log ended at `split`.
            let mut saved = Vec::new();
            let file = hub.store.session_dir("chat0").unwrap().join("adoption-checkpoint.json");
            for incarnation in incarnations {
                let _ = std::fs::remove_file(&file);
                hub.recovery_work(&session, incarnation, 0);
                saved.push(hub.store.adoption_checkpoint("chat0"));
            }
            for record in &log.records[split..] {
                hub.store.append("chat0", record).unwrap();
            }
            session.seq.store(log.records.len() as u64, Ordering::SeqCst);
            for ((incarnation, bytes), whole) in incarnations.iter().zip(saved).zip(&whole) {
                let _ = std::fs::remove_file(&file);
                if let Some(bytes) = bytes {
                    hub.store.save_adoption_checkpoint("chat0", &bytes).unwrap();
                    let inputs = hub.fold_inputs(&session);
                    assert!(
                        hub.adoption_checkpoint(&session, incarnation, &inputs).is_some(),
                        "log {n} split {split} {incarnation}: its checkpoint was not used"
                    );
                    resumed += 1;
                }
                let state = adoption_state(&hub, &session, incarnation);
                assert_eq!(&state, whole, "log {n} split {split} {incarnation}");
            }
            hub.shutdown_all().await;
            let _ = std::fs::remove_dir_all(&root);
        }
        assert!(resumed * 2 > log.records.len() * incarnations.len(), "log {n}: {resumed} resumed");
    }
}

/// A new hub must use the durable checkpoint, and changing the log must invalidate it even
/// when its final record keeps the same sequence, timestamp and kind.
#[tokio::test]
async fn adoption_checkpoint_reopens_and_rejects_rewritten_content() {
    let mut log = hosted_log_of(3, 2);
    log.end_turn(3);
    let (hub, root) = hub_with(1, &log).await;
    let session = hub.resolve("chat0").unwrap();
    hub.recovery_work(&session, "inc", u64::MAX);
    let expected = adoption_state(&hub, &session, "inc");
    hub.shutdown_all().await;
    drop(session);
    drop(hub);

    let mut cfg = Config::default();
    cfg.store.mode = StoreMode::Local;
    let hub = Hub::new_deferred(
        cfg.clone(),
        crate::store::open(&cfg.store, &root).unwrap(),
        crate::mailbox::Mailbox::memory(),
    );
    let session = hub.resolve("chat0").unwrap();
    hub.catch_up(&session);
    let inputs = hub.fold_inputs(&session);
    let point = hub.adoption_checkpoint(&session, "inc", &inputs).unwrap();
    assert_eq!(adoption_state(&hub, &session, "inc"), expected);

    // Earlier records can change while the final one is identical. The log's existing
    // rewrite stamp is the discriminator for this case.
    hub.store.bump_log_stamp("chat0", 2).unwrap();
    assert!(hub.adoption_checkpoint(&session, "inc", &inputs).is_none());
    hub.save_adoption_checkpoint(&session, point);
    assert!(hub.adoption_checkpoint(&session, "inc", &inputs).is_none());
    hub.recovery_work(&session, "inc", u64::MAX);
    let point = hub.adoption_checkpoint(&session, "inc", &inputs).unwrap();

    // An imported/replaced file can retain those three header fields. Alter only its body,
    // leaving the stamp alone, so this specifically exercises the full-record digest.
    hub.store.close_log("chat0");
    let events = hub.store.session_dir("chat0").unwrap().join("events");
    let mut replaced = false;
    for entry in std::fs::read_dir(events).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().and_then(|s| s.to_str()) != Some("ndjson") {
            continue;
        }
        let text = std::fs::read_to_string(&path).unwrap();
        let mut rewritten = String::new();
        let mut changed = false;
        for line in text.lines() {
            let mut record: EventRecord = serde_json::from_str(line).unwrap();
            if record.seq == point.seq {
                record.msg = json!({"turnId": "different", "status": "completed"});
                changed = true;
            }
            rewritten.push_str(&serde_json::to_string(&record).unwrap());
            rewritten.push('\n');
        }
        if changed {
            std::fs::write(path, rewritten).unwrap();
            replaced = true;
        }
    }
    assert!(replaced);
    assert!(hub.adoption_checkpoint(&session, "inc", &inputs).is_none());
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// The paired device that drove a Web turn is logged with it (`turn_started`, `turn_control`
/// `device`) and read back on adoption: the owner's phone keeps the chat's mode across a restart,
/// for the open turn and between turns (Leo, 2026-11-21: "i did not mean to pause you. it must
/// be a bug?").
#[tokio::test]
async fn adoption_reads_back_the_phone_that_drove_the_turn() {
    let mut log = Log { records: Vec::new(), host_seq: 0 };
    log.push("mux", "host_started", json!({"incarnation": "inc"}), false);
    let started = json!({"turnId": "t1", "promptId": "p1", "prompt": "go", "client": "phone", "control": "web", "device": "dev-phone"});
    log.push("mux", "turn_started", started, false);
    let (hub, root) = hub_with(1, &log).await;
    let session = hub.resolve("chat0").unwrap();
    let work = hub.open_work(&session, "inc");
    assert_eq!(work.turn_device.as_deref(), Some("dev-phone"), "the open turn's device");
    assert_eq!(work.last_device.as_deref(), Some("dev-phone"));
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);

    log.push("mux", "turn_result", json!({"turnId": "t1", "status": "completed"}), false);
    let (hub, root) = hub_with(1, &log).await;
    let session = hub.resolve("chat0").unwrap();
    let work = hub.open_work(&session, "inc");
    assert_eq!(work.turn_device, None, "no turn is open");
    assert_eq!(work.last_device.as_deref(), Some("dev-phone"), "between turns");
    assert_eq!(work.last_control, Some(Control::Web));
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);

    // A local turn, then a steer from another device: the floor follows the steer's device.
    log.push("mux", "turn_started", json!({"turnId": "t2", "promptId": "p2", "prompt": "go", "client": "cli", "control": "local"}), false);
    let (hub, root) = hub_with(1, &log).await;
    let session = hub.resolve("chat0").unwrap();
    let work = hub.open_work(&session, "inc");
    assert_eq!((work.turn_device.clone(), work.last_device.clone()), (None, None), "a local turn");
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);

    log.push(
        "mux",
        "turn_control",
        json!({"turnId": "t2", "control": "web", "device": "dev-ipad"}),
        false,
    );
    let (hub, root) = hub_with(1, &log).await;
    let session = hub.resolve("chat0").unwrap();
    let work = hub.open_work(&session, "inc");
    assert_eq!(work.turn_device.as_deref(), Some("dev-ipad"));
    assert_eq!(work.last_device.as_deref(), Some("dev-ipad"));
    hub.shutdown_all().await;
    let _ = std::fs::remove_dir_all(&root);
}

/// `last_host_seq_parsed` reads back from the log's end; it answers what the fold from the start
/// did (the largest `hostSeq` under the last `host_started` of the incarnation), for logs whose
/// hosts start, restart and hand over in every order.
#[tokio::test]
async fn the_parsed_host_seq_read_from_the_end_is_the_fold_from_the_start() {
    fn forward(records: &[EventRecord], incarnation: &str) -> u64 {
        let (mut last, mut current) = (0, false);
        for e in records {
            if e.dir == "mux" && e.kind == "host_started" {
                current = e.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation);
                if current {
                    last = 0;
                }
            } else if current
                && (e.kind != "permission_withdrawn"
                    || e.msg.get("incarnation").and_then(Value::as_str) == Some(incarnation))
                && let Some(h) = e.host_seq
            {
                last = last.max(h);
            }
        }
        last
    }
    // Each plan names the hosts started in order; each host logs `n` updates.
    let plans: &[&[(&str, u64)]] = &[
        &[],
        &[("inc", 3)],
        &[("old", 4)],
        &[("inc", 3), ("old", 5)],
        &[("old", 5), ("inc", 2)],
        &[("inc", 6), ("old", 2), ("inc", 1)],
        &[("inc", 2), ("inc", 4), ("old", 3)],
        &[("old", 1), ("inc", 0), ("old", 7)],
    ];
    for plan in plans {
        let mut log = Log { records: Vec::new(), host_seq: 0 };
        // Records before any host start count for none.
        log.update(json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "x"}}));
        for (incarnation, updates) in plan.iter() {
            log.push("mux", "host_started", json!({"incarnation": incarnation}), false);
            for _ in 0..*updates {
                log.update(json!({"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "x"}}));
            }
            // A withdrawal deferred from the other host carries a later `hostSeq`.
            let other = if *incarnation == "inc" { "old" } else { "inc" };
            log.push("mux", "permission_withdrawn", json!({"incarnation": other}), false);
            if let Some(marker) = log.records.last_mut() {
                marker.host_seq = Some(10_000);
            }
        }
        let (hub, root) = hub_with(1, &log).await;
        let session = hub.resolve("chat0").unwrap();
        for incarnation in ["inc", "old", "none"] {
            assert_eq!(
                hub.last_host_seq_parsed(&session, incarnation),
                forward(&log.records, incarnation),
                "plan {plan:?}, incarnation {incarnation}"
            );
        }
        hub.shutdown_all().await;
        let _ = std::fs::remove_dir_all(&root);
    }
}
