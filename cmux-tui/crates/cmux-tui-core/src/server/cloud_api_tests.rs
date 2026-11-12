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
    use std::time::{Duration, Instant};

    // Each admitted call keeps its slot here, named by who called, until "its server answers";
    // a refused one is noted with the limit.
    type Held = Arc<Mutex<VecDeque<(usize, Slot)>>>;
    type Refused = Arc<Mutex<Vec<(usize, usize)>>>;
    fn hold(held: &Held, refused: &Refused, caller: usize) -> Job {
        let (held, refused) = (Arc::clone(held), Arc::clone(refused));
        Box::new(move |slot| match slot {
            Ok(slot) => held.lock().unwrap().push_back((caller, slot)),
            Err(limit) => refused.lock().unwrap().push((caller, limit)),
        })
    }
    fn holders(held: &Held) -> Vec<usize> {
        held.lock().unwrap().iter().map(|(caller, _)| *caller).collect()
    }
    // Synthetic times an hour out: the line's own timer never reaches them, so only `expire`
    // (given each time here) and a freed slot move the line. No test waits on a clock.
    let t0 = Instant::now() + Duration::from_secs(3600);
    let far = t0 + Duration::from_secs(3600);
    let slots: &'static Slots = Box::leak(Box::new(Slots::new()));
    let (held, refused): (Held, Refused) = (Arc::default(), Arc::default());

    // 16 hand-off followers hold every long-poll slot; a 17th caller (a new Run's wait) lines up.
    for follower in 0..MAX_LONG_POLLS {
        slots.admit(true, far, hold(&held, &refused, follower));
    }
    let newcomer = 1000;
    slots.admit(true, far, hold(&held, &refused, newcomer));
    assert!(!holders(&held).contains(&newcomer), "the 17th waits, with no slot");

    // Interactive calls still have their 16 while the long polls are full and one waits.
    let interactive: Held = Arc::default();
    for call in 0..MAX_WORKERS - MAX_LONG_POLLS {
        slots.admit(false, far, hold(&interactive, &refused, call));
    }
    slots.admit(false, far, hold(&interactive, &refused, 99));
    assert_eq!(refused.lock().unwrap().pop(), Some((99, MAX_WORKERS)), "the daemon's limit holds");
    let given: Vec<_> = interactive.lock().unwrap().drain(..).collect();
    drop(given);

    // Every follower's wait answers and it rearms at once, round after round: the slot the first
    // one gives back goes to the 17th, and the rearming followers line up behind it.
    let mut served = false;
    for _ in 0..3 * MAX_LONG_POLLS {
        let (follower, slot) = held.lock().unwrap().pop_front().unwrap();
        drop(slot);
        if follower == newcomer {
            served = true;
            break;
        }
        slots.admit(true, far, hold(&held, &refused, follower));
    }
    assert!(served, "the 17th got the first slot given back, not a rearming follower");
    assert_eq!(holders(&held).len(), MAX_LONG_POLLS, "the followers hold the cap again");
    assert!(refused.lock().unwrap().is_empty());

    // Many batches (review at d99396ad): 3 lines' worth wait behind the 16 and slots free a batch
    // at a time, 25 s apart (at 20, 45 and 70 s). Caller c is in time for its batch (start_by
    // 25 s × (c / 16 + 1)) unless it is odd and past the first batch (10 s less: too late for
    // the slot it would get). Each waiting call starts by its start_by or is answered busy at it
    // (never later), first come first served.
    for round in 0..4_u64 {
        let base = t0 + Duration::from_secs(1000 * round);
        let callers = 3 * MAX_LONG_POLLS;
        let start_by = |c: usize| {
            let batch = u64::try_from(c / MAX_LONG_POLLS).unwrap();
            let late = if c % 2 == 1 && batch > 0 { 10 } else { 0 };
            base + Duration::from_secs(25 * (batch + 1) - late)
        };
        for c in 0..callers {
            slots.admit(true, start_by(c), hold(&held, &refused, 2000 + c));
        }
        let (mut started, mut busy) = (Vec::new(), 0);
        for batch in 1..=3_u64 {
            let now = base + Duration::from_secs(25 * batch - 5);
            busy += slots.expire(now);
            for (caller, limit) in refused.lock().unwrap().drain(..) {
                assert_eq!(limit, MAX_LONG_POLLS);
                assert!(start_by(caller - 2000) <= now, "busy only at its start_by: {caller}");
            }
            // The batch in flight answers: its 16 slots go to the line, oldest first.
            let answered: Vec<_> = held.lock().unwrap().drain(..).collect();
            drop(answered);
            let batch_started = holders(&held);
            for caller in &batch_started {
                assert!(start_by(caller - 2000) > now, "started in time: {caller}");
            }
            started.extend(batch_started);
        }
        assert_eq!((started.len(), busy), (36, 12), "round {round}");
        let mut sorted = started.clone();
        sorted.sort_unstable();
        assert_eq!(started, sorted, "first come, first served");
        let given: Vec<_> = held.lock().unwrap().drain(..).collect();
        drop(given);
        for follower in 0..MAX_LONG_POLLS {
            slots.admit(true, far, hold(&held, &refused, follower));
        }
    }

    // The edges of start_by: a call whose start_by is now is busy, one a nanosecond later waits.
    let edge = t0 + Duration::from_secs(9000);
    slots.admit(true, edge, hold(&held, &refused, 3000));
    assert_eq!(slots.expire(edge - Duration::from_nanos(1)), 0, "still in time");
    assert_eq!(slots.expire(edge), 1, "out of time exactly at its start_by");
    assert_eq!(refused.lock().unwrap().pop(), Some((3000, MAX_LONG_POLLS)));
    // One already past its start_by when it arrives is busy at once, never queued.
    slots.admit(true, Instant::now(), hold(&held, &refused, 3001));
    assert_eq!(refused.lock().unwrap().pop(), Some((3001, MAX_LONG_POLLS)));

    // A line past its own limit is busy, and the job of a refused call never holds a slot.
    let waiting: Held = Arc::default();
    for caller in 0..MAX_QUEUED_LONG_POLLS {
        slots.admit(true, far, hold(&waiting, &refused, caller));
    }
    slots.admit(true, far, hold(&waiting, &refused, 4000));
    assert_eq!(refused.lock().unwrap().pop(), Some((4000, MAX_QUEUED_LONG_POLLS)));
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

/// A wait that starts late is held only as long as still answers by its caller's deadline, and
/// one that cannot be held a second is past its start_by; edges included.
#[cfg(unix)]
#[test]
fn a_late_wait_is_held_shorter_and_answers_by_its_deadline() {
    use super::calls::{fit_poll, start_by};
    use std::time::{Duration, Instant};
    let call = |name: &str, held: Option<i64>| cmux_cloud_api::Request {
        call: name.to_owned(),
        api: "https://api.example".into(),
        auth: cmux_cloud_api::Auth::Owner,
        credential: "t".into(),
        refresh: None,
        team: None,
        app_version: None,
        local_only: false,
        args: held
            .map(|ms| json!({ "timeoutMs": ms }))
            .and_then(|v| v.as_object().cloned())
            .unwrap_or_default(),
    };
    let by = Instant::now() + Duration::from_secs(3600);
    for name in ["runs.wait", "owner.handoff_wait"] {
        // Start by: 15 s of answer margin and the 1 s hold before the deadline.
        assert_eq!(start_by(&call(name, Some(10_000)), by), by - Duration::from_secs(16));
        // (time left when it starts, asked, held)
        for (left, asked, held) in [
            (Duration::from_secs(50), Some(10_000), 10_000),
            (Duration::from_secs(20), Some(10_000), 5_000),
            (Duration::from_secs(16), Some(25_000), 1_000),
            (Duration::from_millis(16_001), Some(25_000), 1_001),
            (Duration::from_secs(30), None, 15_000),
        ] {
            let mut late = call(name, asked);
            fit_poll(&mut late, by, by - left);
            assert_eq!(late.args["timeoutMs"], json!(held), "{name} {left:?}");
        }
    }
    // A sandboxed Run keeps its whole own time; any other call is never shortened.
    let sandbox = call("runs.sandbox", None);
    assert_eq!(start_by(&sandbox, by), by - cmux_cloud_api::own(&sandbox));
    let mut other = call("runs.cancel", Some(10_000));
    fit_poll(&mut other, by, by - Duration::from_secs(1));
    assert_eq!(other.args["timeoutMs"], json!(10_000));
}
