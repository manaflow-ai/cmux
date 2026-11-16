//! Capture a fixture harness through the real hosted reader and v1 tap, then replay the pure table.
//! No person's chat or harness credentials enter this fixture.
#[path = "../../tests/support/daemon_env.rs"]
mod daemon_env;

use super::*;
use crate::agent::{Direction, Tap};
use crate::agent_host::link::{self, HostLauncher};
use crate::agent_host::{self, SpawnSpec};
use acpmux_core::chat::record::{self, Context, Entry};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::path::Path;
use std::sync::{LazyLock, Mutex};
use tokio::sync::{mpsc, oneshot};
use tokio::time::{Duration, timeout};

const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in()
    .only_test("v2_record_capture_fixture_run")
    .keep(&["V2_RECORD_CAPTURE_BASE_SHA", "GITHUB_RUN_ID"]);
const LIMIT: usize = 256 * 1024;
const DEADLINE: Duration = Duration::from_secs(30);
// Only tests register an observer. This reads the tap's actual local before policy runs.
static TIMING: LazyLock<Mutex<HashMap<String, Arc<AtomicBool>>>> = LazyLock::new(Default::default);

pub(super) fn before(session: &str, awaiting: bool) {
    if let Some(value) = TIMING.lock().unwrap().get(session) {
        value.store(awaiting, Ordering::SeqCst);
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Snapshot {
    status: SessionStatus,
    hibernate: bool,
    loading: bool,
    awaiting_first_delta: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct CapturedEntry {
    harness: usize,
    direction: String,
    message: Value,
    host_seq: Option<u64>,
    context: Snapshot,
    /// All records, including caller effects, in the order v1 wrote them.
    records: Vec<crate::store::EventRecord>,
    /// The entry's own record; None means v1 kept this entry nowhere.
    table_record: Option<usize>,
}

#[derive(Debug, Serialize, Deserialize)]
struct Capture {
    format: String,
    base_sha: String,
    command: String,
    run_id: String,
    entries: Vec<CapturedEntry>,
}

const FIXTURE: &str = r#"
import json, sys

def send(value):
    print(json.dumps(value), flush=True)

def note(method, params):
    send({'jsonrpc':'2.0', 'method':method, 'params':params})

for line in sys.stdin:
    request = json.loads(line)
    method = request['method']
    if method == 'initialize':
        note('claude.system.init', {'type':'system','subtype':'init','model':'fixture','tools':['Read']})
        send({'jsonrpc':'2.0','id':request['id'],'result':{'protocolVersion':1}})
    elif method == 'session/prompt':
        note('claude.stream_event', {'event':{'type':'message_start'}})
        note('claude.stream_event', {'event':{'type':'content_block_delta','delta':{'text':'answer'}}})
        note('claude.stream_event', {'event':{'type':'content_block_delta','delta':{'text':'not retained'}}})
        note('claude.control_response', {'response':{'request_id':'ctx-fixture'}})
        note('claude.assistant', {'type':'assistant','message':{'id':'fixture-message','content':[{'type':'text','text':'answer'}]}})
        note('claude.result', {'type':'result','result':'answer','is_error':False})
        send({'jsonrpc':'2.0','id':request['id'],'result':{'stopReason':'end_turn'}})
    elif method == 'fixture/exit':
        sys.exit(request['params']['code'])
"#;

fn entry<'a>(direction: record::Direction, message: &'a Message) -> Entry<'a> {
    match message {
        Message::Notification { method, params } if method == crate::agent::HOST_EXIT => {
            Entry::Exit {
                code: params.as_ref().and_then(|p| p.get("code")).cloned().unwrap_or(Value::Null),
            }
        }
        Message::Notification { method, params } if method == crate::agent::HOST_STDERR => {
            Entry::Stderr {
                text: params.as_ref().and_then(|p| p.get("text")).cloned().unwrap_or(Value::Null),
            }
        }
        Message::Notification { method, .. } => {
            Entry::Notification { direction, method, value: message.to_value() }
        }
        Message::Request { method, .. } => {
            Entry::Request { direction, method, value: message.to_value() }
        }
        Message::Response { .. } => Entry::Response { direction, value: message.to_value() },
    }
}

fn replay(capture: &Capture) {
    let mut context = Context::default();
    let mut harness = None;
    for captured in &capture.entries {
        if harness != Some(captured.harness) {
            context.harness_started();
            harness = Some(captured.harness);
        }
        context.idle = captured.context.status == SessionStatus::Idle;
        context.closed = captured.context.status == SessionStatus::Closed;
        context.hibernate = captured.context.hibernate;
        context.loading = captured.context.loading;
        assert_eq!(
            context.awaiting_first_delta.load(Ordering::SeqCst),
            captured.context.awaiting_first_delta,
            "timing context before {}",
            captured.message
        );
        let message = Message::from_value(captured.message.clone()).unwrap();
        let direction =
            if captured.direction == "in" { record::Direction::In } else { record::Direction::Out };
        let prepared = record::record_of(entry(direction, &message), &mut context);
        let actual = captured.table_record.map(|index| &captured.records[index]);
        match (prepared, actual) {
            (None, None) => {}
            (Some(prepared), Some(actual)) => {
                assert_eq!(
                    serde_json::to_vec(&prepared.event(actual.seq, actual.at, actual.host_seq))
                        .unwrap(),
                    serde_json::to_vec(actual).unwrap(),
                    "entry {}",
                    captured.message
                );
                prepared.note_logged(&mut context);
            }
            _ => panic!("table retention differs for {}", captured.message),
        }
    }
}

fn assert_capture_coverage(entries: &[CapturedEntry]) {
    assert!(entries.iter().any(|e| e.message["method"] == "session/prompt"));
    assert!(entries.iter().any(|e| e.message["method"] == "claude.result"));
    assert!(entries.iter().any(|e| {
        e.message["method"] == "claude.stream_event"
            && e.message.pointer("/params/event/type").and_then(Value::as_str)
                == Some("content_block_delta")
            && e.context.awaiting_first_delta
            && e.table_record.is_some()
    }));
    assert!(
        entries
            .iter()
            .any(|e| { e.message["method"] == "claude.stream_event" && e.table_record.is_none() })
    );
    assert!(
        entries.iter().any(|e| {
            e.message["method"] == "claude.control_response" && e.table_record.is_none()
        })
    );
    let exits: Vec<_> =
        entries.iter().filter(|e| e.message["method"] == crate::agent::HOST_EXIT).collect();
    assert_eq!(exits.len(), 4);
    for (exit, (status, hibernate)) in exits.iter().zip([
        (SessionStatus::Ready, false),
        (SessionStatus::Running, false),
        (SessionStatus::Idle, false),
        (SessionStatus::Idle, true),
    ]) {
        assert_eq!(exit.context.status, status);
        assert_eq!(exit.context.hibernate, hibernate);
        assert!(exit.table_record.is_some());
    }
    let init: Vec<_> = entries
        .iter()
        .filter(|e| e.message["method"] == "claude.system.init")
        .map(|e| &e.records[e.table_record.unwrap()])
        .collect();
    assert_eq!(init.len(), 4);
    assert!(init[0].msg.get("tools").is_some());
    assert!(init[1..].iter().all(|record| record.msg.get("tools").is_none()));
}

/// Exceptional cleanup only, fenced by the live incarnation created by this test.
struct OwnedHost {
    record: agent_host::HostRecord,
    hosts: std::path::PathBuf,
}

impl Drop for OwnedHost {
    fn drop(&mut self) {
        if agent_host::liveness(&self.hosts, &self.record.session_id, &self.record.start_nonce)
            == agent_host::Liveness::Live
        {
            // SAFETY: this test spawned the host; the incarnation's live lock still identifies it.
            unsafe {
                libc::kill(self.record.host_pid as i32, libc::SIGTERM);
            }
        }
    }
}

async fn run_host(
    hub: &Arc<Hub>,
    session: &Arc<Session>,
    number: usize,
    exit_status: SessionStatus,
    hibernate: bool,
    turn: bool,
    captured: &Arc<Mutex<Vec<CapturedEntry>>>,
    timing: &Arc<AtomicBool>,
) {
    let scratch = tempfile::tempdir().unwrap();
    let dir = scratch.path();
    let script = dir.join("fixture.py");
    std::fs::write(&script, FIXTURE).unwrap();
    let hosts = dir.join("hosts");
    let id = format!("fixture-{number}");
    let spec = SpawnSpec {
        session_id: id.clone(),
        program: "python3".into(),
        args: vec![script.to_string_lossy().into_owned()],
        env: daemon_env::vars(dir, daemon_env::Agents::StandIn, &[]),
        cwd: dir.to_path_buf(),
        translator: None,
        codex_bridge: false,
        socket: agent_host::socket_path(&hosts, &id),
        hosts_dir: hosts,
        buffer_cap: agent_host::DEFAULT_BUFFER_CAP,
        router_owner_fifo: None,
        cwd_pin: None,
        orphan_exit: None,
        prompt_suggestions_managed: None,
        holder: None,
    };
    session.meta.lock().unwrap().status = SessionStatus::Ready;
    session.hibernated_at.store(0, Ordering::SeqCst);
    let original = hub.session_tap(session);
    let (done_tx, done_rx) = oneshot::channel();
    let done = Mutex::new(Some(done_tx));
    let (capture_hub, capture_session, captured, timing) =
        (hub.clone(), session.clone(), captured.clone(), timing.clone());
    let tap: Tap = Arc::new(move |direction, message, host_seq| {
        let mut sink = captured.lock().unwrap();
        let start = capture_hub.store.events(&capture_session.id, 0, usize::MAX).unwrap().len();
        let mut context = Snapshot {
            status: capture_session.status(),
            hibernate: capture_session.hibernated_at.load(Ordering::SeqCst) != 0,
            loading: capture_session.loading.load(Ordering::SeqCst),
            awaiting_first_delta: false,
        };
        let logged = original(direction, message, host_seq);
        context.awaiting_first_delta = timing.load(Ordering::SeqCst);
        let records =
            capture_hub.store.events(&capture_session.id, 0, usize::MAX).unwrap()[start..].to_vec();
        let indices: Vec<_> = records
            .iter()
            .enumerate()
            .filter(|(_, record)| {
                record.host_seq == host_seq && (host_seq.is_some() || record.dir == "out")
            })
            .map(|(index, _)| index)
            .collect();
        assert!(indices.len() <= 1, "one table record per entry: {message:?}");
        sink.push(CapturedEntry {
            harness: number,
            direction: if matches!(direction, Direction::In) { "in".into() } else { "out".into() },
            message: message.to_value(),
            host_seq,
            context,
            records,
            table_record: indices.first().copied(),
        });
        if matches!(message, Message::Notification { method, .. } if method == crate::agent::HOST_EXIT)
            && let Some(done) = done.lock().unwrap().take()
        {
            let _ = done.send(());
        }
        logged
    });
    let launcher = HostLauncher { exe: daemon_env::bin().into(), prefix: Vec::new() };
    let host = timeout(DEADLINE, link::spawn(&launcher, &spec))
        .await
        .expect("fixture host bootstrap deadline")
        .unwrap();
    let live_lock = std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .open(spec.hosts_dir.join(format!("{}.{}.live", host.session_id, host.start_nonce)))
        .unwrap();
    let owned_host = OwnedHost { record: host.clone(), hosts: spec.hosts_dir.clone() };
    let (inbound, mut receiver) = mpsc::channel(64);
    let drain = tokio::spawn(async move { while receiver.recv().await.is_some() {} });
    let attached = timeout(
        DEADLINE,
        crate::agent::ChildAgent::attach_hosted("fixture", host, 0, Vec::new(), inbound, tap),
    )
    .await
    .expect("fixture host attach deadline")
    .unwrap();
    let crate::agent::Attached::Ready(agent, ..) = attached else {
        panic!("fixture host refused attach")
    };
    let outcome = timeout(DEADLINE, async {
        agent
            .request("initialize", json!({"protocolVersion":1}))
            .await
            .map_err(|e| format!("initialize: {e:?}"))?;
        if turn {
            session.meta.lock().unwrap().status = SessionStatus::Running;
            agent
                .request(
                    "session/prompt",
                    json!({"sessionId":"fixture","prompt":[{"type":"text","text":"answer"}]}),
                )
                .await
                .map_err(|e| format!("prompt: {e:?}"))?;
        }
        session.meta.lock().unwrap().status = exit_status;
        session.hibernated_at.store(u64::from(hibernate), Ordering::SeqCst);
        agent
            .notify("fixture/exit", json!({"code":17}))
            .await
            .map_err(|e| format!("exit command: {e:?}"))?;
        done_rx.await.map_err(|e| format!("exit receipt: {e}"))?;
        Ok::<_, String>(())
    })
    .await;
    timeout(DEADLINE, agent.kill()).await.expect("fixture host cleanup deadline");
    drain.abort();
    let _ = drain.await;
    drop(owned_host);
    timeout(DEADLINE, async {
        use std::os::fd::AsRawFd;
        loop {
            // SAFETY: this test owns the descriptor. Nonblocking acquisition keeps the
            // deadline effective even if cleanup fails to stop the host.
            if unsafe { libc::flock(live_lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
                break;
            }
            let error = std::io::Error::last_os_error();
            assert_eq!(error.kind(), std::io::ErrorKind::WouldBlock, "live lock: {error}");
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("fixture host exit deadline");
    outcome.expect("fixture run deadline").expect("fixture protocol");
}

#[tokio::test]
#[ignore = "capture on cmux-ci with the same-head daemon binary; emits V2_RECORD_CAPTURE"]
async fn v2_record_capture_fixture_run() {
    assert!(
        std::env::var_os("ACPMUX_TEST_HERMETIC").is_some(),
        "run capture with the exact v2_record_capture_fixture_run filter for hermetic setup"
    );
    let base_sha = std::env::var("V2_RECORD_CAPTURE_BASE_SHA").expect("capture needs base SHA");
    let run_id = std::env::var("GITHUB_RUN_ID").expect("capture runs on cmux-ci");
    assert_eq!(base_sha.len(), 40);
    let mut config = Config::default();
    config.store.mode = crate::config::StoreMode::Memory;
    let store = crate::store::open(&config.store, Path::new("/unused")).unwrap();
    let hub = Hub::new(config, store);
    let meta: SessionMeta = serde_json::from_value(json!({
        "schema":crate::store::META_SCHEMA,"id":"v2-record-capture","name":"fixture",
        "harness":"claude","cwd":"/tmp","status":"ready","createdAt":1,"updatedAt":1
    }))
    .unwrap();
    hub.store.save(&meta).unwrap();
    let session = hub.make_session(meta);
    let timing = Arc::new(AtomicBool::new(false));
    TIMING.lock().unwrap().insert(session.id.clone(), timing.clone());
    let captured = Arc::new(Mutex::new(Vec::new()));
    for (number, (status, hibernate, turn)) in [
        (SessionStatus::Ready, false, true),
        (SessionStatus::Running, false, false),
        (SessionStatus::Idle, false, false),
        (SessionStatus::Idle, true, false),
    ]
    .into_iter()
    .enumerate()
    {
        run_host(&hub, &session, number, status, hibernate, turn, &captured, &timing).await;
    }
    TIMING.lock().unwrap().remove(&session.id);
    let entries = captured.lock().unwrap().clone();
    assert_capture_coverage(&entries);
    let capture = Capture { format:"v2-record-capture/v1-tap-1".into(), base_sha, run_id,
        command:"cargo build --locked -p acpmux --bin acpmux; CARGO_BIN_EXE_acpmux=<same-head binary> V2_RECORD_CAPTURE_BASE_SHA=<sha> cargo test --locked -p acpmux --lib v2_record_capture_fixture_run -- --ignored --nocapture".into(), entries };
    replay(&capture);
    let encoded = serde_json::to_string(&capture).unwrap();
    assert!(encoded.len() <= LIMIT, "capture exceeds 256 KiB");
    eprintln!("V2_RECORD_CAPTURE {encoded}");
}
