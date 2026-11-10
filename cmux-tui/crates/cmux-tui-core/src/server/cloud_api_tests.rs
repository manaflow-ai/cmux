//! The `cloud.*` Cloud API operations end to end: a test daemon on a real socket, the SDK's raw
//! client (`cmux::raw::Client::request_raw`), and each call family against a fake Cloud API on a
//! local port. Covers the result shapes, the scrub of a refusal and refused fields.

use std::io::{Read as _, Write as _};
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use base64::Engine as _;
use serde_json::{Map, Value, json};

use super::*;

const VM: &str = "vm_abcdefghij0123456789";

/// One request the fake saw: its request line, its header lines (names lowercased, values as
/// sent) and its body.
#[derive(Debug, Clone)]
struct Seen {
    line: String,
    headers: String,
    body: Vec<u8>,
}

impl Seen {
    fn header(&self, name: &str) -> Option<String> {
        let prefix = format!("{name}: ");
        self.headers.lines().find_map(|l| l.strip_prefix(&prefix).map(|v| v.trim().to_owned()))
    }
}

/// A Cloud API that answers every request with `reply(seen)` (status, body).
fn fake(
    reply: impl Fn(&Seen) -> (u16, String) + Send + Sync + 'static,
) -> (String, Arc<Mutex<Vec<Seen>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&seen);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buffer = Vec::new();
            let mut chunk = [0_u8; 65536];
            let (head, body) = loop {
                let n = stream.read(&mut chunk).unwrap_or(0);
                buffer.extend_from_slice(&chunk[..n]);
                if let Some(end) = buffer.windows(4).position(|w| w == b"\r\n\r\n") {
                    let head = lowercase_names(&String::from_utf8_lossy(&buffer[..end]));
                    let length = head
                        .lines()
                        .find_map(|l| l.strip_prefix("content-length: "))
                        .and_then(|v| v.trim().parse::<usize>().ok())
                        .unwrap_or(0);
                    if buffer.len() >= end + 4 + length || n == 0 {
                        let line = String::from_utf8_lossy(&buffer[..end])
                            .lines()
                            .next()
                            .unwrap_or_default()
                            .to_owned();
                        break ((line, head), buffer[end + 4..].to_vec());
                    }
                } else if n == 0 {
                    break ((String::new(), String::new()), Vec::new());
                }
            };
            let seen = Seen { line: head.0, headers: head.1, body };
            let (status, text) = reply(&seen);
            log.lock().unwrap().push(seen);
            let _ = stream.write_all(
                format!(
                    "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{text}",
                    text.len()
                )
                .as_bytes(),
            );
        }
    });
    (origin, seen)
}

/// `head` with each header name lowercased and every value kept as sent.
fn lowercase_names(head: &str) -> String {
    head.lines()
        .map(|line| match line.split_once(':') {
            Some((name, value)) => format!("{}:{value}", name.to_ascii_lowercase()),
            None => line.to_owned(),
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// A test daemon serving its own socket; the socket is removed on drop.
struct Daemon {
    socket: PathBuf,
    /// The daemon's durable state (registry, journal, request records).
    state: PathBuf,
}

impl Daemon {
    fn start(name: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let session = format!(
            "cloud-api-{name}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        );
        let state = std::env::temp_dir().join(format!("{session}-state"));
        let mux = Mux::open_persistent(&session, crate::SurfaceOptions::default(), &state).unwrap();
        let socket = crate::server::serve(mux, None).unwrap();
        Self { socket, state }
    }

    fn client(&self) -> cmux::raw::Client {
        let config = cmux::raw::ClientConfig::from_socket_path(&self.socket)
            .with_timeout(Duration::from_secs(30));
        cmux::raw::Client::connect(config).unwrap()
    }

    /// One `cmux.protocol/2` request for `operation`: the response's `result`, or the protocol
    /// error's code, message and details.
    fn send(
        &self,
        operation: &str,
        mut params: Value,
        key: Option<&str>,
    ) -> Result<Value, (String, String, Value)> {
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let mut request = Map::new();
        request.insert("protocol".into(), json!("cmux.protocol/2"));
        request.insert("type".into(), json!("request"));
        request.insert("id".into(), json!("cloud-api-test"));
        request.insert("operation".into(), json!(operation));
        request.insert("params".into(), params);
        if let Some(key) = key {
            request.insert("idempotency_key".into(), json!(key));
        }
        match self.client().request_raw(request) {
            Ok(response) => Ok(response["result"].clone()),
            Err(cmux::raw::Error::Protocol { code, message, details, .. }) => {
                Err((code, message, details))
            }
            Err(other) => panic!("{operation}: {other}"),
        }
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        crate::server::cleanup(&self.socket);
        let _ = std::fs::remove_dir_all(&self.state);
    }
}

fn params(origin: &str, auth: &str, args: Value) -> Value {
    json!({"api": origin, "auth": auth, "access_token": "secret-access",
        "refresh_token": "secret-refresh", "team": "team_1", "app_version": "cmux-next",
        "args": args})
}

#[test]
fn every_call_of_the_library_is_one_of_this_modules_operations() {
    for name in cmux_cloud_api::CALLS {
        let wire = format!("cloud.{name}");
        let operation: ResourceOperation = serde_json::from_value(json!(wire))
            .unwrap_or_else(|_| panic!("{wire} is no operation"));
        assert!(handles(operation), "{wire}");
        assert_eq!(operation.wire_name(), wire);
    }
    let catalog: Value =
        serde_json::from_str(include_str!("../../../../spec/resource-operations-v2.json")).unwrap();
    let ours = catalog["operations"]
        .as_object()
        .unwrap()
        .keys()
        .filter_map(|name| serde_json::from_value::<ResourceOperation>(json!(name)).ok())
        .filter(|operation| handles(*operation))
        .count();
    assert_eq!(ours, cmux_cloud_api::CALLS.len());
}

#[test]
fn a_classic_read_sends_the_stack_session_and_answers_its_body() {
    let (origin, seen) =
        fake(|_| (200, r#"{"run":{"id":"r1","state":"running"},"receipt":null}"#.into()));
    let daemon = Daemon::start("vm");
    let args = json!({"id": "r1", "timeoutMs": 1});
    let result = daemon.send("cloud.runs.wait", params(&origin, "stack", args), None);
    assert_eq!(result, Ok(json!({"run": {"id": "r1", "state": "running"}, "receipt": null})));
    let seen = seen.lock().unwrap();
    assert!(seen[0].line.starts_with("GET /api/runs/r1/wait?timeoutMs=1 "));
    assert_eq!(seen[0].header("authorization").as_deref(), Some("Bearer secret-access"));
    assert_eq!(seen[0].header("x-stack-refresh-token").as_deref(), Some("secret-refresh"));
    assert_eq!(seen[0].header("x-cmux-team-id").as_deref(), Some("team_1"));
}

#[test]
fn a_classic_mutation_answers_a_mutation_result_that_is_never_replayed() {
    let (origin, seen) = fake(|_| (200, r#"{"id":"r1","state":"cancelled"}"#.into()));
    let daemon = Daemon::start("vm-mutation");
    let result = daemon
        .send("cloud.runs.cancel", params(&origin, "stack", json!({"id": "r1"})), Some("cancel-1"))
        .unwrap();
    assert_eq!(result["replayed"], false);
    assert_eq!(result["revision"], "0");
    assert_eq!(result["value"], json!({"id": "r1", "state": "cancelled"}));
    assert!(seen.lock().unwrap()[0].line.starts_with("POST /api/runs/r1/cancel "));
}

#[test]
fn a_classic_vm_call_is_refused_at_once_and_sends_nothing() {
    let (origin, seen) = fake(|_| (200, "{}".into()));
    let daemon = Daemon::start("vm-gone");
    let (code, _, details) = daemon
        .send("cloud.vm.firewall_list", params(&origin, "stack", json!({})), None)
        .unwrap_err();
    assert_eq!(code, "operation.failed");
    assert_eq!(details["extra"]["failure"]["status"], 501);
    assert_eq!(details["extra"]["failure"]["code"], "cloud.not_available");
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn a_run_wait_is_capped_at_the_servers_bound() {
    let (origin, seen) =
        fake(|_| (200, r#"{"run":{"id":"r1","state":"running"},"receipt":null}"#.into()));
    let daemon = Daemon::start("runs");
    let result = daemon
        .send(
            "cloud.runs.wait",
            params(&origin, "stack", json!({"id": "r1", "timeoutMs": 1})),
            None,
        )
        .unwrap();
    assert_eq!(result["run"]["id"], "r1");
    assert!(seen.lock().unwrap()[0].line.starts_with("GET /api/runs/r1/wait?timeoutMs=1 "));
}

#[test]
fn an_owner_read_sends_only_authorization_and_the_team() {
    let (origin, seen) = fake(|_| (200, r#"{"handoffs":[{"id":"h"}],"nextCursor":null}"#.into()));
    let daemon = Daemon::start("owner");
    let result = daemon.send("cloud.owner.handoffs", params(&origin, "owner", json!({})), None);
    assert_eq!(result, Ok(json!([{"id": "h"}])));
    let seen = seen.lock().unwrap();
    assert!(seen[0].line.starts_with("GET /v1/handoffs?limit=100 "));
    assert_eq!(seen[0].header("x-cmux-team").as_deref(), Some("team_1"));
    assert_eq!(seen[0].header("x-stack-refresh-token"), None);
}

#[test]
fn a_person_key_never_goes_through_the_daemon() {
    let (origin, seen) =
        fake(|_| (200, r#"{"ok":true,"value":{"personInstance":"run-2"}}"#.into()));
    let daemon = Daemon::start("keyed");
    let key = b"person-key-line\n";
    let mut request = params(&origin, "owner", json!({"machine": VM, "key_length": key.len()}));
    request["key_base64"] = json!(base64::engine::general_purpose::STANDARD.encode(key));
    let (code, message, details) =
        daemon.send("cloud.owner.acpmux_keyed_start", request, Some("keyed-1")).unwrap_err();
    assert_eq!(code, "validation.invalid");
    assert!(!format!("{message} {details}").contains("person-key"));
    // Without a key the keyed start has nothing to send: refused before any request too.
    let bare = params(&origin, "owner", json!({"machine": VM, "key_length": key.len()}));
    assert!(daemon.send("cloud.owner.acpmux_keyed_start", bare, Some("keyed-2")).is_err());
    assert!(seen.lock().unwrap().is_empty(), "the app streams the key itself");
}

#[test]
fn a_preview_refresh_goes_through_the_platform_client() {
    let catalog = r#"{"machine":"vm_abc","listening":[3000],"previews":[],"unavailable":[]}"#;
    let (origin, seen) = fake(move |_| (200, catalog.into()));
    let daemon = Daemon::start("previews");
    let result = daemon
        .send(
            "cloud.previews.refresh",
            params(&origin, "worker", json!({"machine": "vm_abc"})),
            Some("refresh-1"),
        )
        .unwrap();
    assert_eq!(result["value"]["listening"], json!([3000]));
    assert!(
        seen.lock().unwrap()[0]
            .line
            .starts_with("POST /v1/cloud/machines/vm_abc/previews/refresh ")
    );
}

#[test]
fn a_classic_machine_exec_is_refused_before_any_request() {
    let (origin, seen) = fake(|_| (200, r#"{"exitCode":0,"stdout":"ok","stderr":""}"#.into()));
    let daemon = Daemon::start("machine");
    let (code, _, details) = daemon
        .send(
            "cloud.machine.io",
            params(
                &origin,
                "stack",
                json!({"op": "exec", "machine": "m1", "command": "true", "timeout_ms": 1000}),
            ),
            Some("exec-1"),
        )
        .unwrap_err();
    assert_eq!(code, "operation.failed");
    assert_eq!(details["extra"]["failure"]["status"], 501);
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn a_refusal_names_its_kind_and_never_carries_a_credential_back() {
    let (origin, _seen) = fake(|_| {
        (409, r#"{"error":"vm_busy","message":"echo secret-access and secret-refresh"}"#.into())
    });
    let daemon = Daemon::start("refusal");
    let args = json!({"id": "r1", "timeoutMs": 1});
    let (code, message, details) =
        daemon.send("cloud.runs.wait", params(&origin, "stack", args), None).unwrap_err();
    assert_eq!(code, "operation.failed");
    assert_eq!(details["operation"], "cloud.runs.wait");
    assert_eq!(details["reason"], "http");
    let failure = &details["extra"]["failure"];
    assert_eq!(failure["kind"], "http");
    assert_eq!(failure["status"], 409);
    assert_eq!(failure["code"], "vm_busy");
    let text = format!("{message} {details}");
    assert!(!text.contains("secret-access") && !text.contains("secret-refresh"), "{text}");
    assert!(text.contains("[redacted]"), "{text}");
}

#[test]
fn a_request_that_is_not_a_call_runs_nothing_and_echoes_nothing() {
    let (origin, seen) = fake(|_| (200, "{}".into()));
    let daemon = Daemon::start("invalid");
    let mut unknown = params(&origin, "stack", json!({}));
    unknown["extra_field"] = json!("secret-extra");
    let (code, message, details) = daemon.send("cloud.runs.wait", unknown, None).unwrap_err();
    assert_eq!(code, "validation.invalid");
    assert!(!format!("{message} {details}").contains("secret-access"));

    let mut no_token = params(&origin, "stack", json!({}));
    no_token["access_token"] = json!("   ");
    let (code, _, _) = daemon.send("cloud.runs.wait", no_token, None).unwrap_err();
    assert_eq!(code, "validation.invalid");

    let mut bad_key = params(&origin, "owner", json!({}));
    bad_key["key_base64"] = json!("%%%%");
    let (code, message, details) =
        daemon.send("cloud.owner.acpmux_keyed_start", bad_key, Some("bad-key")).unwrap_err();
    assert_eq!(code, "validation.invalid");
    assert!(!format!("{message} {details}").contains("%%%%"));

    let (code, _, _) =
        daemon.send("cloud.runs.cancel", params(&origin, "stack", json!({})), None).unwrap_err();
    assert_eq!(code, "validation.invalid", "a mutation needs its idempotency key");
    assert!(seen.lock().unwrap().is_empty());
}

/// Every file under `root`, read whole.
fn files(root: &std::path::Path) -> Vec<(PathBuf, Vec<u8>)> {
    let mut found = Vec::new();
    let mut dirs = vec![root.to_path_buf()];
    while let Some(dir) = dirs.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                dirs.push(path);
            } else if let Ok(bytes) = std::fs::read(&path) {
                found.push((path, bytes));
            }
        }
    }
    found
}

#[test]
fn no_record_or_log_of_the_daemon_holds_a_credential() {
    let (origin, seen) = fake(|seen| {
        if seen.line.starts_with("GET") {
            (200, r#"{"run":{"id":"r1","state":"running"},"receipt":null}"#.into())
        } else {
            (409, r#"{"error":"vm_busy","message":"echo secret-access"}"#.into())
        }
    });
    let daemon = Daemon::start("records");
    let wait = params(&origin, "stack", json!({"id": "r1", "timeoutMs": 1}));
    assert!(daemon.send("cloud.runs.wait", wait, None).is_ok());
    let cancel = params(&origin, "stack", json!({"id": "r1"}));
    assert!(daemon.send("cloud.runs.cancel", cancel, Some("records-1")).is_err());
    let mut keyed = params(&origin, "owner", json!({"machine": VM, "key_length": 10}));
    keyed["key_base64"] = json!(base64::engine::general_purpose::STANDARD.encode(b"secret-key"));
    let _ = daemon.send("cloud.owner.acpmux_keyed_start", keyed, Some("records-2"));
    assert_eq!(
        seen.lock().unwrap().len(),
        2,
        "every call but the refused keyed start reached the API"
    );
    let written = files(&daemon.state);
    assert!(!written.is_empty(), "the daemon keeps durable state");
    for (path, bytes) in written {
        let text = String::from_utf8_lossy(&bytes);
        for secret in ["secret-access", "secret-refresh", "secret-key", "c2VjcmV0LWtleQ"] {
            assert!(!text.contains(secret), "{} holds {secret}", path.display());
        }
    }
}

/// The person key the log check sends, and its base64 as the request carries it.
const LOG_CHECK_KEY: &str = "person-key-for-the-log-check";

/// The log check's child (it returns at once unless the check started it): keyed starts handed a
/// person key (refused: no key goes through the daemon) to APIs that would echo it, and then the
/// daemon's store.
#[test]
fn keyed_start_for_the_log_check() {
    if std::env::var_os("CMUX_CLOUD_API_LOG_CHECK_CHILD").is_none() {
        return;
    }
    let encoded = base64::engine::general_purpose::STANDARD.encode(LOG_CHECK_KEY);
    let echo = |seen: &Seen| String::from_utf8_lossy(&seen.body).to_string();
    let (refusing, _) = fake(move |seen| {
        (409, json!({"error": "vm_busy", "message": format!("echo {}", echo(seen))}).to_string())
    });
    let (garbled, _) =
        fake(move |seen| (200, json!({"ok": true, "value": {"echo": echo(seen)}}).to_string()));
    let daemon = Daemon::start("key-log");
    for (n, origin) in [refusing, garbled].iter().enumerate() {
        let mut keyed =
            params(origin, "owner", json!({"machine": VM, "key_length": LOG_CHECK_KEY.len()}));
        keyed["key_base64"] = json!(encoded);
        let (_, message, details) = daemon
            .send("cloud.owner.acpmux_keyed_start", keyed, Some(&format!("key-log-{n}")))
            .unwrap_err();
        let text = format!("{message} {details}");
        assert!(!text.contains(LOG_CHECK_KEY) && !text.contains(&encoded), "refusal: {text}");
    }
    for (path, bytes) in files(&daemon.state) {
        let text = String::from_utf8_lossy(&bytes);
        assert!(!text.contains(LOG_CHECK_KEY) && !text.contains(&encoded), "{}", path.display());
    }
    println!("log check: both keyed starts ran");
}

/// A person key handed to the daemon is in no line it logs (its stdout and stderr, every level),
/// no file of its store and no refusal. The calls run in a child process of this test binary, so the check
/// reads everything the daemon's threads print.
#[test]
fn the_person_key_is_in_no_log_line_store_or_refusal_of_the_daemon() {
    let module = module_path!().split_once("::").map_or("", |(_, rest)| rest);
    let child = format!("{module}::keyed_start_for_the_log_check");
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([child.as_str(), "--exact", "--nocapture", "--test-threads=1"])
        .env("CMUX_CLOUD_API_LOG_CHECK_CHILD", "1")
        .env("RUST_LOG", "trace")
        .env("RUST_BACKTRACE", "1")
        .output()
        .unwrap();
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(output.status.success(), "the child failed:\n{text}");
    assert!(text.contains("log check: both keyed starts ran"), "the child ran nothing:\n{text}");
    let encoded = base64::engine::general_purpose::STANDARD.encode(LOG_CHECK_KEY);
    assert!(
        !text.contains(LOG_CHECK_KEY) && !text.contains(&encoded),
        "the daemon logged the key:\n{text}"
    );
}

/// Long polls (a hand-off follower holds one per open hand-off) take at most their own cap of the
/// daemon's slots: with that cap full, one more long poll is `busy`, and every interactive call
/// (exec, files, previews, cancel, turns) still gets a slot, up to the daemon's limit.
#[test]
fn long_polls_at_their_cap_leave_interactive_calls_their_slots() {
    use super::calls::{
        Job, MAX_LONG_POLLS, MAX_QUEUED_LONG_POLLS, MAX_WORKERS, Slot, Slots, long_poll,
    };
    use std::collections::VecDeque;
    use std::sync::{Arc, Mutex};

    // Each admitted call keeps its slot here, named by who called, until "its server answers".
    type Held = Arc<Mutex<VecDeque<(usize, Slot)>>>;
    fn hold(held: &Held, caller: usize) -> Job {
        let held = Arc::clone(held);
        Box::new(move |slot| held.lock().unwrap().push_back((caller, slot)))
    }
    fn holders(held: &Held) -> Vec<usize> {
        held.lock().unwrap().iter().map(|(caller, _)| *caller).collect()
    }
    let slots: &'static Slots = Box::leak(Box::new(Slots::new()));
    let held: Held = Arc::default();

    // 16 hand-off followers hold every long-poll slot; a 17th caller (a new Run's wait) lines up.
    for follower in 0..MAX_LONG_POLLS {
        slots.admit(true, hold(&held, follower)).unwrap();
    }
    let newcomer = 1000;
    slots.admit(true, hold(&held, newcomer)).unwrap();
    assert!(!holders(&held).contains(&newcomer), "the 17th waits, with no slot");

    // Interactive calls still have their 16 while the long polls are full and one waits.
    let interactive: Held = Arc::default();
    for call in 0..MAX_WORKERS - MAX_LONG_POLLS {
        slots.admit(false, hold(&interactive, call)).unwrap();
    }
    assert_eq!(
        slots.admit(false, Box::new(|_| {})).err(),
        Some(MAX_WORKERS),
        "the daemon's limit holds"
    );
    drop(interactive.lock().unwrap().drain(..).collect::<Vec<_>>());

    // Every follower's wait answers and it rearms at once, round after round: the slot the first
    // one gives back goes to the 17th, and the rearming followers line up behind it.
    let mut served = false;
    for _ in 0..3 * MAX_LONG_POLLS {
        let (follower, slot) = held.lock().unwrap().pop_front().unwrap();
        if follower == newcomer {
            served = true;
            drop(slot);
            break;
        }
        drop(slot);
        slots.admit(true, hold(&held, follower)).unwrap();
    }
    assert!(served, "the 17th got the first slot given back, not a rearming follower");
    assert!(!holders(&held).contains(&newcomer), "the 17th answered and left");
    assert_eq!(holders(&held).len(), MAX_LONG_POLLS, "the followers hold the cap again");

    // A line past its own limit is busy, and the job of a refused call never runs.
    let waiting: Held = Arc::default();
    for caller in 0..MAX_QUEUED_LONG_POLLS {
        slots.admit(true, hold(&waiting, caller)).unwrap();
    }
    assert_eq!(
        slots.admit(true, Box::new(|_| panic!("refused"))).err(),
        Some(MAX_QUEUED_LONG_POLLS)
    );
    // Slots given back go to the line in order.
    let given: Vec<_> = held.lock().unwrap().drain(..).collect();
    drop(given);
    assert_eq!(holders(&waiting), (0..MAX_LONG_POLLS).collect::<Vec<_>>());
    for operation in [
        ResourceOperation::CloudOwnerHandoffWait,
        ResourceOperation::CloudRunsWait,
        ResourceOperation::CloudRunsSandbox,
    ] {
        assert!(long_poll(operation), "{operation:?}");
    }
    for operation in [
        ResourceOperation::CloudMachineIo,
        ResourceOperation::CloudRunsCancel,
        ResourceOperation::CloudOwnerHandoffBeginTurn,
        ResourceOperation::CloudPreviewsCreateLink,
        ResourceOperation::CloudOwnerHandoffs,
    ] {
        assert!(!long_poll(operation), "{operation:?}");
    }
}
