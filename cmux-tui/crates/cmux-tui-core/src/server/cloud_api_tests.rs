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
fn a_run_is_the_daemons_own_and_sends_nothing_to_the_api() {
    let (origin, seen) = fake(|_| (200, r#"{"run":{"id":"r1"},"receipt":null}"#.into()));
    let daemon = Daemon::start("runs");
    let (code, _, details) = daemon
        .send(
            "cloud.runs.wait",
            params(&origin, "owner", json!({"id": "run_nope", "timeoutMs": 1})),
            None,
        )
        .unwrap_err();
    assert_eq!(code, "operation.failed");
    let failure = &details["extra"]["failure"];
    assert_eq!(failure["status"], 404);
    assert_eq!(failure["code"], "run_not_found");
    let (_, _, details) = daemon
        .send(
            "cloud.runs.create",
            params(&origin, "owner", json!({"task": "hi", "idempotencyKey": "k", "image": "img"})),
            Some("run-1"),
        )
        .unwrap_err();
    assert_eq!(details["extra"]["failure"]["code"], "run_image_invalid");
    assert!(seen.lock().unwrap().is_empty(), "no Run call goes over HTTP");
}

/// Codex's review of #39022 at e59d43c8 (F1): a Run the app followed from before the daemon ran
/// Runs is classic Cloud's. Its wait and cancel drain there with the app's Stack session, in the
/// Run's team, so an upgrade never drops its result; a Run the daemon knows never goes there.
#[test]
fn a_run_from_before_the_upgrade_drains_on_classic_cloud() {
    let (origin, seen) = fake(|seen| {
        if seen.line.starts_with("GET") {
            let done =
                r#"{"run":{"id":"r-old","status":"succeeded"},"receipt":{"status":"succeeded"}}"#;
            (200, done.into())
        } else {
            (200, r#"{"run":{"id":"r-old","status":"cancelled"}}"#.into())
        }
    });
    let daemon = Daemon::start("classic-drain");
    let classic = |args: Value| {
        let mut args = args;
        args["classicApi"] = json!(origin);
        args["classicTeam"] = json!("team_stack");
        params("https://owner.invalid", "owner", args)
    };
    let waited = daemon
        .send("cloud.runs.wait", classic(json!({"id": "r-old", "timeoutMs": 1})), None)
        .unwrap();
    assert_eq!(waited["receipt"]["status"], "succeeded", "{waited}");
    let cancelled = daemon
        .send("cloud.runs.cancel", classic(json!({"id": "r-old"})), Some("drain-cancel"))
        .unwrap();
    assert_eq!(cancelled["value"]["run"]["status"], "cancelled", "{cancelled}");
    {
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 2);
        assert!(
            seen[0].line.starts_with("GET /api/runs/r-old/wait?timeoutMs=1 "),
            "{}",
            seen[0].line
        );
        assert!(seen[1].line.starts_with("POST /api/runs/r-old/cancel "), "{}", seen[1].line);
        for request in seen.iter() {
            assert_eq!(request.header("authorization").as_deref(), Some("Bearer secret-access"));
            assert_eq!(request.header("x-stack-refresh-token").as_deref(), Some("secret-refresh"));
            assert_eq!(request.header("x-cmux-team-id").as_deref(), Some("team_stack"));
        }
    }
    // With no classic session (not the app's), a Run the daemon never made is just not found,
    // and nothing is sent.
    let (_, _, details) = daemon
        .send(
            "cloud.runs.wait",
            params(&origin, "owner", json!({"id": "r-x", "timeoutMs": 1})),
            None,
        )
        .unwrap_err();
    assert_eq!(details["extra"]["failure"]["code"], "run_not_found");
    assert_eq!(seen.lock().unwrap().len(), 2);
}

/// #39022 review at 946e940e, F1: an incognito send's Run was a daemon Run, an ordinary Cloud chat
/// the app opens and keeps, so its prompt and reply showed outside the incognito window. Classic
/// Cloud runs it with no chat in the app; without the app's classic session it is refused, never
/// started as a daemon Run.
#[test]
fn an_incognito_run_goes_to_classic_cloud_never_to_a_chat() {
    let (origin, seen) =
        fake(|_| (200, r#"{"id":"r-private","status":"queued","environment":"sandboxed"}"#.into()));
    let daemon = Daemon::start("incognito-create");
    let create = json!({"task": "private", "agent": "codex", "timeoutMs": 30_000,
        "idempotencyKey": "k-private", "incognito": true,
        "expectedAccount": {"user_id": "u1", "team_id": "team_1"}});
    let mut classic = create.clone();
    classic["classicApi"] = json!(origin);
    classic["classicTeam"] = json!("team_stack");
    let created = daemon
        .send("cloud.runs.create", params("https://owner.invalid", "owner", classic), Some("c-1"))
        .unwrap();
    assert_eq!(created["value"]["id"], "r-private", "{created}");
    {
        let seen = seen.lock().unwrap();
        assert_eq!(seen.len(), 1);
        assert!(seen[0].line.starts_with("POST /api/runs "), "{}", seen[0].line);
        assert_eq!(seen[0].header("idempotency-key").as_deref(), Some("k-private"));
        assert_eq!(seen[0].header("x-stack-refresh-token").as_deref(), Some("secret-refresh"));
        assert_eq!(seen[0].header("x-cmux-team-id").as_deref(), Some("team_stack"));
        let body: Value = serde_json::from_slice(&seen[0].body).unwrap();
        assert_eq!(
            body,
            json!({"environment": "sandboxed", "task": "private", "agent": "codex",
                "timeoutMs": 30_000})
        );
    }
    // Without the app's classic session: refused, nothing sent, and no daemon Run started.
    let (_, _, details) = daemon
        .send("cloud.runs.create", params(&origin, "owner", create), Some("c-2"))
        .unwrap_err();
    assert_eq!(details["extra"]["failure"]["code"], "run_incognito_unavailable", "{details}");
    assert_eq!(seen.lock().unwrap().len(), 1);
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
fn a_keyed_start_sends_the_decoded_key_as_the_body_only() {
    let (origin, seen) =
        fake(|_| (200, r#"{"ok":true,"value":{"personInstance":"run-2"}}"#.into()));
    let daemon = Daemon::start("keyed");
    let key = b"person-key-line\n";
    let mut request = params(&origin, "owner", json!({"machine": VM, "key_length": key.len()}));
    request["key_base64"] = json!(base64::engine::general_purpose::STANDARD.encode(key));
    let result = daemon.send("cloud.owner.acpmux_keyed_start", request, Some("keyed-1")).unwrap();
    assert_eq!(result["value"], json!({"personInstance": "run-2"}));
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].body, key);
    assert!(!seen[0].line.contains("person-key"));
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
        let body =
            r#"{"error":{"code":"vm_busy","message":"echo secret-access and secret-refresh"}}"#;
        (409, body.into())
    });
    let daemon = Daemon::start("refusal");
    let (code, message, details) =
        daemon.send("cloud.owner.handoffs", params(&origin, "owner", json!({})), None).unwrap_err();
    assert_eq!(code, "operation.failed");
    assert_eq!(details["operation"], "cloud.owner.handoffs");
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
    let (code, message, details) = daemon.send("cloud.owner.handoffs", unknown, None).unwrap_err();
    assert_eq!(code, "validation.invalid");
    assert!(!format!("{message} {details}").contains("secret-access"));

    let mut no_token = params(&origin, "stack", json!({}));
    no_token["access_token"] = json!("   ");
    let (code, _, _) = daemon.send("cloud.owner.handoffs", no_token, None).unwrap_err();
    assert_eq!(code, "validation.invalid");

    let mut bad_key = params(&origin, "owner", json!({}));
    bad_key["key_base64"] = json!("%%%%");
    let (code, message, details) =
        daemon.send("cloud.owner.acpmux_keyed_start", bad_key, Some("bad-key")).unwrap_err();
    assert_eq!(code, "validation.invalid");
    assert!(!format!("{message} {details}").contains("%%%%"));

    let open = params(&origin, "owner", json!({"session": "s-1", "machine": VM}));
    let (code, _, _) = daemon.send("cloud.owner.handoff_open", open, None).unwrap_err();
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
            (200, r#"{"handoffs":[{"id":"h"}],"nextCursor":null}"#.into())
        } else {
            (409, r#"{"error":{"code":"vm_busy","message":"echo secret-access"}}"#.into())
        }
    });
    let daemon = Daemon::start("records");
    let handoffs = params(&origin, "owner", json!({}));
    assert!(daemon.send("cloud.owner.handoffs", handoffs, None).is_ok());
    let open = params(&origin, "owner", json!({"session": "s-1", "machine": VM}));
    assert!(daemon.send("cloud.owner.handoff_open", open, Some("records-1")).is_err());
    let mut keyed = params(&origin, "owner", json!({"machine": VM, "key_length": 10}));
    keyed["key_base64"] = json!(base64::engine::general_purpose::STANDARD.encode(b"secret-key"));
    let _ = daemon.send("cloud.owner.acpmux_keyed_start", keyed, Some("records-2"));
    assert_eq!(seen.lock().unwrap().len(), 3, "every call reached the API");
    let written = files(&daemon.state);
    assert!(!written.is_empty(), "the daemon keeps durable state");
    for (path, bytes) in written {
        let text = String::from_utf8_lossy(&bytes);
        for secret in ["secret-access", "secret-refresh", "secret-key", "c2VjcmV0LWtleQ"] {
            assert!(!text.contains(secret), "{} holds {secret}", path.display());
        }
    }
}
