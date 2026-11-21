//! The recorded streams the Swift tests replay. A fixed script drives a hub; the daemon's bytes go
//! to one file and the C entry points' changes for them to another, beside the calls the client
//! made, so Swift hands the same bytes to the same calls and must get the same changes.
//!
//! Each `.jsonl` line is one of: `{"step": name}`; a call the client made before the step's
//! bytes (`{"call": "subscribe_mirror" | "want" | "unwant", "request": ...}`, `{"call": "connected" |
//! "disconnected"}`); `{"feed": [start, end]}`, the step's daemon bytes in the `.bytes` file;
//! `{"change": ...}`, one `acpmux_client_next_change` output, in order; `{"send": base64}`, one
//! `acpmux_client_take_send` output of the live run, in order. The sends are a record, not a
//! claim: credit follows when changes are taken, so the same bytes in other pieces may send
//! other frames; the changes are the same in every piece size. The fallback stream ends with `{"v1": {"request":
//! ..., "reply": [start, end]}}` lines: v1's requests on the same socket and the bytes answering
//! each, which the client never reads.
//!
//! A recorded stream holds what its replayer reads. The v1 replies are cut to what the app's v1
//! source reads (`cut_v1`): `initialize`'s reply to its capability, extension, feature and
//! operation lists, each list to its read entries, each list result to its read keys and each row
//! to its read fields. So a feature changes the recording only when the app reads what it adds. A
//! row the cut does not reach (a session anywhere but a result's `sessions`) fails the recording.
//!
//! The test fails when a committed file differs from the run; `ACPMUX_LIST_STREAM_BLESS=1`
//! rewrites them (or names a directory to write them to instead).

use super::*;
use base64::Engine as _;
use std::path::PathBuf;

const BLESS: &str = "ACPMUX_LIST_STREAM_BLESS";
/// How long the daemon stays quiet before a step is over.
const QUIET: Duration = Duration::from_millis(200);
/// Both files of one stream together stay under this.
const MAX_FIXTURE_BYTES: usize = 256 << 10;
/// The entries of `initialize`'s `_meta.acpmux` lists that the app's v1 source reads
/// (`AgentListFollow.follows`). The recorder cuts each list to these, in the daemon's order, so a
/// daemon feature that adds an entry changes no recorded byte. A later PR whose replay reads
/// another entry adds it here and records the stream again in its own CI.
const V1_INITIALIZE_ENTRIES: [(&str, &[&str]); 4] = [
    ("capabilities", &["session-list-follow-v1"]),
    ("extensions", &[]),
    ("features", &[]),
    ("operations", &[]),
];
/// The keys `initialize`'s reply keeps at each object on the way to those lists: the app's v1
/// source reads nothing else of it (`AgentTurnStateFeed.Message`, id 1). So `agentCapabilities`,
/// `agentInfo` and the keys beside the lists in `_meta.acpmux` (build, person challenge, trust gate
/// and the like) are cut. A later PR whose replay reads another key adds it here and records the
/// stream again in its own CI.
const V1_INITIALIZE_KEYS: [(&str, &[&str]); 3] = [
    ("/result", &["_meta"]),
    ("/result/_meta", &["acpmux"]),
    ("/result/_meta/acpmux", &["capabilities", "extensions", "features", "operations"]),
];
/// The keys of a `_acpmux/watch` or `_acpmux/sessions` result that the app's v1 source reads
/// (`AgentWatchPage`, `AgentWatchFollow`). The recorder cuts each result to these. A later PR whose
/// replay reads another key adds it here and records the stream again in its own CI.
const V1_LIST_RESULT_KEYS: &[&str] =
    &["follow", "gone", "listEpoch", "listSeq", "more", "nextCursor", "sessions"];
/// The fields of a v1 row (`_acpmux/watch`, `_acpmux/sessions`) that the app's v1 source decodes by
/// name (`AgentTurnStates`, `AgentChatDetail`, `AgentPeerRow`, `AgentActivityLane`,
/// `AgentTurnStateStore.startedBy`). The recorder cuts each row to these at its top level, so a
/// daemon feature that adds a row field changes no recorded byte; a kept field's value stays
/// whole. A later PR whose replay reads another field adds it here and records the stream again
/// in its own CI.
const V1_ROW_FIELDS: &[&str] = &[
    "agentSessionId",
    "commandsRunning",
    "createdAt",
    "createdMs",
    "cwd",
    "family",
    "harness",
    "indicator",
    "lane",
    "lastMessage",
    "lastPrompt",
    "model",
    "name",
    "peer",
    "preview",
    "pullRequests",
    "sessionId",
    "shortName",
    "spawnedBy",
    "stale",
    "startedBy",
    "subagentNames",
    "subagentsRunning",
    "tags",
    "title",
    "titleSource",
    "turn",
    "unread",
    "updatedAt",
    "updatedMs",
    "usageStats",
    "usageWarnings",
    "workspaceId",
    "workspace_id",
];

fn fixtures_dir() -> PathBuf {
    std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../Packages/macOS/CmuxNext/Tests/Fixtures/AgentListStream")
}

/// One step of a run: the calls before it, its daemon bytes, and what the client gave and sent.
struct Step {
    name: &'static str,
    calls: Vec<Value>,
    range: (usize, usize),
    changes: Vec<Value>,
    sends: Vec<Vec<u8>>,
}

fn apply(ffi: &mut Ffi, call: &Value) {
    match call["call"].as_str() {
        Some("subscribe_mirror") => {
            let sid: Value = serde_json::from_str(&ffi.subscribe_mirror(&call["request"])).unwrap();
            assert_eq!(sid, json!({"sid": SID}));
        }
        Some("want") => ffi.want(&call["request"]),
        Some("unwant") => ffi.unwant(&call["request"]),
        Some("connected") => ffi.connected(),
        Some("disconnected") => ffi.disconnected(),
        other => panic!("no such call: {other:?}"),
    }
}

/// A live run, step by step.
struct Recorder {
    run: Run,
    calls: Vec<Value>,
    steps: Vec<Step>,
}

impl Recorder {
    fn new() -> Self {
        Self { run: Run::new(), calls: Vec::new(), steps: Vec::new() }
    }

    fn call(&mut self, call: Value) {
        apply(&mut self.run.ffi, &call);
        self.calls.push(call);
    }

    async fn step(&mut self, name: &'static str, done: impl Fn(&[Value]) -> bool) -> &Step {
        let start = self.run.bytes.len();
        let sent = self.run.sent.len();
        let changes = self.run.step(QUIET, done).await;
        self.steps.push(Step {
            name,
            calls: std::mem::take(&mut self.calls),
            range: (start, self.run.bytes.len()),
            changes,
            sends: self.run.sent[sent..].to_vec(),
        });
        self.steps.last().unwrap()
    }
}

/// The same calls and bytes through a new handle, the bytes in pieces of at most `chunk`.
fn replay(bytes: &[u8], steps: &[Step], chunk: usize) {
    let mut ffi = Ffi::new();
    for step in steps {
        for call in &step.calls {
            apply(&mut ffi, call);
        }
        let mut changes = ffi.changes();
        changes.extend(ffi.feed(&bytes[step.range.0..step.range.1], chunk));
        assert_eq!(changes, step.changes, "step {} in pieces of {chunk} bytes", step.name);
        // Drained as a transport drains them; their frames depend on the piece size (above).
        ffi.sends();
    }
}

fn jsonl(steps: &[Step], tail: &[Value]) -> Vec<u8> {
    let mut lines = Vec::new();
    for step in steps {
        lines.push(json!({"step": step.name}));
        lines.extend(step.calls.iter().cloned());
        lines.push(json!({"feed": [step.range.0, step.range.1]}));
        lines.extend(step.changes.iter().map(|change| json!({"change": change})));
        let base64 = base64::engine::general_purpose::STANDARD;
        lines.extend(step.sends.iter().map(|send| json!({"send": base64.encode(send)})));
    }
    lines.extend(tail.iter().cloned());
    let mut out = Vec::new();
    for line in lines {
        out.extend(serde_json::to_vec(&line).unwrap());
        out.push(b'\n');
    }
    out
}

/// Fails when the committed file differs from this run's; under the bless variable, writes it.
fn check_or_bless(name: &str, actual: &[u8]) {
    if let Some(dir) = std::env::var_os(BLESS) {
        let dir = if dir == "1" { fixtures_dir() } else { PathBuf::from(dir) };
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(dir.join(name), actual).unwrap();
        return;
    }
    let path = fixtures_dir().join(name);
    let committed = std::fs::read(&path).unwrap_or_else(|error| {
        panic!("{}: {error}; record it with {BLESS}=1", path.display());
    });
    if committed != actual {
        let at = committed
            .iter()
            .zip(actual)
            .position(|(a, b)| a != b)
            .unwrap_or(committed.len().min(actual.len()));
        let around = |bytes: &[u8]| {
            let start = at.saturating_sub(80);
            String::from_utf8_lossy(&bytes[start..bytes.len().min(at + 80)]).into_owned()
        };
        panic!(
            "{name} differs from this run at byte {at} (committed {} bytes, recorded {}): \
             committed {:?}, recorded {:?}. If the change is meant, rerun with {BLESS}=1",
            committed.len(),
            actual.len(),
            around(&committed),
            around(actual),
        );
    }
}

fn live_rows() -> Vec<(String, &'static str, Value)> {
    let mut live: Vec<_> = (0..17).map(|n| (format!("chat-{n:02}"), "idle", json!({}))).collect();
    live.push(("parent".into(), "idle", json!({})));
    // Spawned by `parent` late in the script (see there).
    live.push(("child".into(), "running", json!({})));
    live
}

fn fixture() -> Fixture {
    let live = live_rows();
    let live: Vec<(&str, &str, Value)> =
        live.iter().map(|(id, status, tags)| (id.as_str(), *status, tags.clone())).collect();
    Fixture::new(&live, 8, 8, false)
}

fn has_kind(changes: &[Value], wanted: &str) -> bool {
    changes.iter().any(|change| kind(change) == Some(wanted))
}

fn any_names(changes: &[Value], chat_id: &str) -> bool {
    changes.iter().any(|change| names(change, chat_id))
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_sidebar_mirror_stream_is_recorded() {
    let mut fx = fixture();
    // 19 local rows and one of another machine's: the window holds 20.
    fx.add_peer_row("peer-a", "peer-chat");
    // A live chat open in a tab, wanted so its row stays through its close.
    //
    // At most one key is wanted when a walk finishes: the client re-queues its wanted keys from
    // a hash map then (`finish_mirror_walk`), so two or more are read in an order that changes
    // from run to run, and the recording would too. The 8 closed keys are the gate's.
    let tab = vec![key(&fx.summary("chat-05"))];

    let mut rec = Recorder::new();
    rec.call(json!({"call": "subscribe_mirror", "request": mirror_request()}));
    rec.call(json!({"call": "connected"}));
    rec.run.connect(fx.v2.clone(), "fixture-daemon");
    let step = rec.step("connect", connected_whole(&[])).await;
    let window = step.changes.iter().find(|change| change.get("rows").is_some()).unwrap();
    assert_eq!(window["rows"].as_array().unwrap().len(), 20, "the first window");

    rec.call(json!({"call": "want", "request": want_request(&tab)}));
    rec.step("want", |changes| any_names(changes, "chat-05")).await;

    fx.edit("chat-03", |meta| meta.title = Some("chat-03: renamed".into()));
    rec.step("summary", |changes| any_names(changes, "chat-03")).await;

    fx.edit("chat-05", |meta| meta.status = crate::store::SessionStatus::Closed);
    rec.step("wanted-closed", |changes| any_names(changes, "chat-05")).await;

    rec.call(json!({"call": "disconnected"}));
    rec.run.drop_socket().await;
    fx.edit("chat-07", |meta| meta.title = Some("chat-07: renamed while away".into()));
    rec.call(json!({"call": "connected"}));
    rec.run.connect(fx.v2.clone(), "fixture-daemon");
    let step = rec.step("resume", |changes| has_kind(changes, "resumeEnd")).await;
    assert!(any_names(&step.changes, "chat-07"), "the resume brings what was missed");

    rec.call(json!({"call": "disconnected"}));
    rec.run.drop_socket().await;
    // The other machine's row is not in the restarted daemon's list.
    fx.restart();
    rec.call(json!({"call": "connected"}));
    rec.run.connect(fx.v2.clone(), "fixture-daemon-restarted");
    let step = rec
        .step("restart", |changes| {
            has_kind(changes, "whole")
                && any_names(changes, "chat-05")
                && changes
                    .iter()
                    .any(|change| kind(change) == Some("gone") && change["why"] == "missed")
        })
        .await;
    let gone = step.changes.iter().find(|change| kind(change) == Some("gone")).unwrap();
    assert_eq!(gone["chatId"], "peer-chat", "a peer's dropped row arrives as gone missed");
    assert!(any_names(&step.changes, "chat-05"), "the tab's closed chat is read again");

    // The tab closes, so the parent below is the only key the mirror reads. The child gets its
    // parent only now: the mirror wants the parent of each child it holds, and a parent wanted
    // beside the tab's key at a walk would be read in either order.
    rec.call(json!({"call": "unwant", "request": want_request(&tab)}));
    let spawned = crate::store::Tag { value: "parent".into(), expires_at: None };
    fx.edit("child", |meta| {
        meta.tags.insert(crate::hub::views::SPAWNED_BY_TAG.into(), spawned);
    });
    let listed = |change: &Value| {
        names(change, "child") && rows(change).iter().any(|row| row.get("spawnedBy").is_some())
    };
    rec.step("child-spawned", |changes| changes.iter().any(listed)).await;

    let archived = crate::store::Tag { value: "1".into(), expires_at: None };
    fx.edit("parent", |meta| {
        meta.tags.insert("archived".into(), archived);
    });
    // The parent leaves the live view; the mirror holds it only for its child, and such a parent
    // is not handed to the caller (the design doc, "The list's clients" 2). What the sidebar
    // gets is its child again, now with no `spawnedBy`.
    let unlisted = |change: &Value| {
        names(change, "child") && rows(change).iter().all(|row| row.get("spawnedBy").is_none())
    };
    rec.step("parent-archived", |changes| changes.iter().any(unlisted)).await;
    // The tee's fan-out to the child, as after a parent's mark.
    fx.publish("child");
    rec.step("child-after-parent", |_| true).await;
    rec.run.drop_socket().await;

    let bytes = rec.run.bytes.clone();
    for chunk in [usize::MAX, 7, 1] {
        replay(&bytes, &rec.steps, chunk);
    }
    let lines = jsonl(&rec.steps, &[]);
    assert!(bytes.len() + lines.len() < MAX_FIXTURE_BYTES, "{} + {}", bytes.len(), lines.len());
    check_or_bless("mirror.bytes", &bytes);
    check_or_bless("mirror.jsonl", &lines);
}

/// The values in v1's replies that differ from run to run or commit to commit, wherever they
/// sit: each person challenge's connection id and nonce, the daemon's build (its commit and
/// date), and each session receipt's generation.
#[derive(Default)]
struct PerRun {
    challenge: std::collections::BTreeMap<String, &'static str>,
    generations: std::collections::BTreeSet<u64>,
}

impl PerRun {
    fn collect(&mut self, value: &Value) {
        match value {
            Value::Object(map) => {
                if let Some(challenge) = map.get("personChallenge") {
                    for field in ["connection", "nonce"] {
                        if let Some(text) = challenge.get(field).and_then(Value::as_str) {
                            self.challenge.insert(text.to_owned(), field);
                        }
                    }
                }
                let build = map.get("acpmux").and_then(|meta| meta.get("build"));
                if let Some(text) = build.and_then(Value::as_str) {
                    self.challenge.insert(text.to_owned(), "build");
                }
                if let Some(generation) = map
                    .get("sessionReceipt")
                    .and_then(|receipt| receipt.get("generation"))
                    .and_then(Value::as_u64)
                {
                    self.generations.insert(generation);
                }
                map.values().for_each(|value| self.collect(value));
            }
            Value::Array(items) => items.iter().for_each(|value| self.collect(value)),
            _ => {}
        }
    }
}

/// Cuts each line of one v1 reply to what the app's v1 source reads: `initialize`'s lists to
/// `V1_INITIALIZE_ENTRIES` and each row to `V1_ROW_FIELDS`. Every other byte stays the
/// daemon's (asserted: a line read and written back is the line).
fn cut_v1(method: &str, reply: &str) -> String {
    let mut out = String::with_capacity(reply.len());
    for line in reply.split_inclusive('\n') {
        let (text, end) = line.strip_suffix('\n').map_or((line, ""), |text| (text, "\n"));
        let Ok(mut value) = serde_json::from_str::<Value>(text) else {
            out.push_str(line);
            continue;
        };
        assert_eq!(serde_json::to_string(&value).unwrap(), text, "a v1 line written back differs");
        let keep = |value: &mut Value, at: &str, kept: &[&str]| {
            if let Some(object) = value.pointer_mut(at).and_then(Value::as_object_mut) {
                object.retain(|key, _| kept.contains(&key.as_str()));
            }
        };
        if method == "initialize" {
            for (at, kept) in V1_INITIALIZE_KEYS {
                keep(&mut value, at, kept);
            }
        } else {
            keep(&mut value, "/result", V1_LIST_RESULT_KEYS);
        }
        if let Some(meta) = value.pointer_mut("/result/_meta/acpmux").and_then(Value::as_object_mut)
        {
            for (list, kept) in V1_INITIALIZE_ENTRIES {
                if let Some(Value::Array(entries)) = meta.get_mut(list) {
                    entries
                        .retain(|entry| entry.as_str().is_some_and(|entry| kept.contains(&entry)));
                }
            }
        }
        if let Some(Value::Array(rows)) = value.pointer_mut("/result/sessions") {
            for row in rows.iter_mut().filter_map(Value::as_object_mut) {
                row.retain(|field, _| V1_ROW_FIELDS.contains(&field.as_str()));
            }
        }
        assert_no_uncut_row(&value, "");
        out.push_str(&serde_json::to_string(&value).unwrap());
        out.push_str(end);
    }
    out
}

/// Fails on a session the cut does not reach: an object holding `sessionId` anywhere but as a row
/// of a result's `sessions` (a `session_changed` push, a `gone` entry, a row nested elsewhere).
/// Recorded whole, it would bring back what `cut_v1` keeps out; the PR that records one cuts it.
fn assert_no_uncut_row(value: &Value, at: &str) {
    match value {
        Value::Object(object) => {
            assert!(
                !object.contains_key("sessionId"),
                "a session at {at:?} that cut_v1 does not cut; cut it to V1_ROW_FIELDS first"
            );
            for (key, value) in object {
                assert_no_uncut_row(value, &format!("{at}/{key}"));
            }
        }
        Value::Array(items) if at != "/result/sessions" => {
            for (n, value) in items.iter().enumerate() {
                assert_no_uncut_row(value, &format!("{at}/{n}"));
            }
        }
        _ => {}
    }
}

/// Reads from `socket` until a line answers `id`, then until it is quiet; returns the bytes.
async fn v1_reply(socket: &mut tokio::net::UnixStream, id: Option<u64>) -> Vec<u8> {
    let mut bytes = Vec::new();
    let mut buf = vec![0_u8; 64 << 10];
    let answered = |bytes: &[u8]| {
        bytes.split(|b| *b == b'\n').any(|line| {
            serde_json::from_slice::<Value>(line).is_ok_and(|value| {
                id.is_none_or(|id| value.get("id") == Some(&json!(id)))
                    && (value.get("result").is_some() || value.get("error").is_some())
            })
        })
    };
    let deadline = Instant::now() + STEP_WAIT;
    loop {
        let done = answered(&bytes);
        let wait = if done { QUIET } else { deadline.saturating_duration_since(Instant::now()) };
        match tokio::time::timeout(wait, socket.read(&mut buf)).await {
            Ok(Ok(0)) | Err(_) => {
                assert!(done, "no reply to {id:?}: {}", String::from_utf8_lossy(&bytes));
                return bytes;
            }
            Ok(Ok(n)) => bytes.extend_from_slice(&buf[..n]),
            Ok(Err(error)) => panic!("socket read failed: {error}"),
        }
    }
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn the_method_not_found_stream_is_recorded() {
    let fx = fixture();
    let (mut socket, server) = tokio::net::UnixStream::pair().unwrap();
    // A daemon with no v2 list: the upgrade is a v1 request it does not know.
    let task = tokio::spawn(super::super::serve_stream(
        fx.v1.clone(),
        server,
        None,
        false,
        crate::sender_harness::SocketPeer::Unknown,
        None,
    ));
    let mut ffi = Ffi::new();
    let calls = vec![
        json!({"call": "subscribe_mirror", "request": mirror_request()}),
        json!({"call": "want", "request": want_request(&fx.wanted)}),
        json!({"call": "connected"}),
    ];
    for call in &calls {
        apply(&mut ffi, call);
    }
    let mut changes = ffi.changes();
    let sends = ffi.sends();
    for send in &sends {
        socket.write_all(send).await.unwrap();
    }
    let reply = v1_reply(&mut socket, None).await;
    changes.extend(ffi.feed(&reply, reply.len()));
    assert!(
        matches!(changes.as_slice(), [change] if kind(change) == Some("fallback")),
        "one fallback change: {changes:?}"
    );
    assert_eq!(ffi.received(b"{\"jsonrpc\":\"2.0\",\"id\":9}\n"), 0, "later bytes are v1's");
    let steps = vec![Step { name: "upgrade", calls, range: (0, reply.len()), changes, sends }];
    let mut bytes = reply;

    // v1's feed on the same socket, as the app's v1 source sends it after the fallback.
    let (_, epoch) = fx.v1.list_cursor();
    let (run_id, epoch) = (fx.v1.run_id(), epoch.to_owned());
    let mut tail = Vec::new();
    let requests = [
        (
            1_u64,
            "initialize",
            json!({
                "protocolVersion": 1,
                "clientInfo": {"name": "cmux-next-turn-states", "version": "1"},
                "clientCapabilities": {},
            }),
        ),
        (2, "_acpmux/watch", json!({"enabled": true})),
        (3, "_acpmux/sessions", json!({"usage": true})),
    ];
    for (id, method, params) in requests {
        let request = crate::rpc::Message::request(id, method, params);
        let line = request.to_line();
        socket.write_all(line.as_bytes()).await.unwrap();
        // This run's id and list epoch are the only bytes that differ from run to run.
        // What a daemon feature adds and the app's v1 source does not read is cut (`cut_v1`).
        let reply =
            cut_v1(method, &String::from_utf8(v1_reply(&mut socket, Some(id)).await).unwrap());
        let mut reply = reply.replace(&run_id, "fixture-run").replace(&epoch, "fixture-epoch");
        // So are the connection's id and nonce in `initialize`'s person challenge, and the
        // process's start in each row's session receipt.
        let mut found = PerRun::default();
        for line in reply.lines() {
            if let Ok(value) = serde_json::from_str::<Value>(line) {
                found.collect(&value);
            }
        }
        for (text, field) in found.challenge {
            reply = reply.replace(&text, &format!("fixture-{field}"));
        }
        for generation in found.generations {
            reply = reply.replace(&format!("\"generation\":{generation}"), "\"generation\":1");
        }
        let start = bytes.len();
        bytes.extend_from_slice(reply.as_bytes());
        let request: Value = serde_json::from_str(&line).unwrap();
        tail.push(json!({"v1": {"request": request, "reply": [start, bytes.len()]}}));
    }
    drop(socket);
    tokio::time::timeout(STEP_WAIT, task).await.unwrap().unwrap();

    for chunk in [usize::MAX, 7, 1] {
        replay(&bytes, &steps, chunk);
    }
    let lines = jsonl(&steps, &tail);
    assert!(bytes.len() + lines.len() < MAX_FIXTURE_BYTES, "{} + {}", bytes.len(), lines.len());
    check_or_bless("fallback.bytes", &bytes);
    check_or_bless("fallback.jsonl", &lines);
}

/// The detector for a recorded v1 answer that goes red whenever a daemon feature lands: an entry
/// added to each of `initialize`'s four lists, a key added beside them in `_meta.acpmux`, in
/// `agentCapabilities` and at the top of each result, and a field added to every row change no
/// byte the recorder keeps. A kept value does, which is what the recording is about.
#[test]
fn a_daemon_feature_changes_no_recorded_v1_byte() {
    let initialize = |extra: bool| {
        let mut acpmux = json!({
            "build": "fixture-build",
            "version": "1.0.0",
            "trustGate": true,
            "capabilities": ["acpmux-v1", "session-list-follow-v1", "read-through-v1"],
            "extensions": ["_acpmux/v2", "_acpmux/sessions"],
            "features": ["promptAccepted", "turnIds"],
            "operations": ["_acpmux/handoff_get"],
        });
        let mut result = json!({
            "_meta": {"acpmux": {}},
            "agentCapabilities": {"loadSession": true},
            "agentInfo": {"name": "acpmux"},
            "protocolVersion": 1,
        });
        if extra {
            for (list, _) in V1_INITIALIZE_ENTRIES {
                acpmux[list].as_array_mut().unwrap().insert(1, json!("a-feature-of-tomorrow-v1"));
            }
            acpmux["aKeyOfTomorrow"] = json!({"nested": true});
            result["agentCapabilities"]["aCapabilityOfTomorrow"] = json!({});
            result["_meta"]["aMetaOfTomorrow"] = json!(1);
            result["aResultKeyOfTomorrow"] = json!([1]);
        }
        result["_meta"]["acpmux"] = acpmux;
        format!("{}\n", json!({"id": 1, "jsonrpc": "2.0", "result": result}))
    };
    let sessions = |extra: bool, title: &str, seq: u64| {
        let rows: Vec<Value> = ["chat-00", "chat-01"]
            .iter()
            .map(|id| {
                let mut row = json!({
                    "sessionId": id, "indicator": "working", "title": title,
                    "lane": {"state": "working", "since": 1}, "eventCount": 3, "hostBuild": "fixture-build",
                });
                if extra {
                    row["aFieldOfTomorrow"] = json!({"nested": [1, 2]});
                }
                row
            })
            .collect();
        let mut result = json!({"listEpoch": "fixture-epoch", "listSeq": seq, "sessions": rows});
        if extra {
            result["aResultKeyOfTomorrow"] = json!({"total": 2});
        }
        format!("{}\n", json!({"id": 3, "jsonrpc": "2.0", "result": result}))
    };

    let cut = cut_v1("initialize", &initialize(false));
    assert_eq!(
        cut,
        cut_v1("initialize", &initialize(true)),
        "an added key changed a recorded byte"
    );
    let kept: Value = serde_json::from_str(&cut).unwrap();
    assert_eq!(
        kept["result"],
        json!({"_meta": {"acpmux": {
            "capabilities": ["session-list-follow-v1"], "extensions": [], "features": [], "operations": [],
        }}}),
        "initialize keeps only what the app reads"
    );

    let method = "_acpmux/sessions";
    let cut = cut_v1(method, &sessions(false, "a", 27));
    assert_eq!(
        cut,
        cut_v1(method, &sessions(true, "a", 27)),
        "an added field changed a recorded byte"
    );
    assert_ne!(
        cut,
        cut_v1(method, &sessions(false, "b", 27)),
        "a kept row field's value is recorded"
    );
    assert_ne!(
        cut,
        cut_v1(method, &sessions(false, "a", 28)),
        "a kept result key's value is recorded"
    );
    let kept: Value = serde_json::from_str(&cut).unwrap();
    assert_eq!(kept["result"]["listEpoch"], json!("fixture-epoch"), "the result's read keys stay");
    assert_eq!(kept["result"]["sessions"][0].get("eventCount"), None, "an unread field is cut");
    assert_eq!(kept["result"]["sessions"][0]["lane"], json!({"state": "working", "since": 1}));
    assert_eq!(cut_v1(method, "not json\n"), "not json\n");
}

/// A session the cut does not reach fails the recording rather than bringing the class back: here
/// a `session_changed` push recorded on the watch, whose row `cut_v1` does not cut.
#[test]
#[should_panic(expected = "a session at \"/params\" that cut_v1 does not cut")]
fn a_session_the_cut_does_not_reach_fails_the_recording() {
    let push = json!({
        "jsonrpc": "2.0",
        "method": "_acpmux/session_changed",
        "params": {"sessionId": "chat-00", "session": {"sessionId": "chat-00", "eventCount": 3}},
    });
    cut_v1("_acpmux/watch", &format!("{push}\n"));
}
