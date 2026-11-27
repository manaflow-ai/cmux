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
    let mut log = Log { records: Vec::new(), host_seq: 0 };
    log.push("mux", "host_started", json!({"incarnation": "old"}), false);
    log.turn(9_000, 3);
    log.end_turn(9_000);
    log.push("mux", "host_started", json!({"incarnation": "inc"}), false);
    for turn in 0..TURNS {
        log.turn(turn, UPDATES);
        if turn == 1 {
            log.ask(5_000, true);
            log.update(json!({"sessionUpdate": "tool_call", "toolCallId": "spawn", "status": "completed", "rawInput": {"prompt": "dig"}, "_meta": {"codex": {"collaboration": {"tool": "spawnAgent", "receiverThreadIds": ["sub"]}}}}));
        }
        if turn == 2 {
            log.push("in", "background_task_update", json!({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": "own", "update": {"sessionUpdate": "background_task_update", "toolCallId": "bg", "taskId": "bg", "state": "running", "command": "serve"}}}), true);
        }
        log.end_turn(turn);
    }
    log.turn(TURNS, 2);
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
