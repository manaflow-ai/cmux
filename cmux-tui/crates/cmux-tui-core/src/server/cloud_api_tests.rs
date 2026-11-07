//! `cloud.<call>` frames end to end on a test mux: each call family against a fake Cloud API on
//! a local port, the reply shapes, the scrub of a refusal, and who may call.

use std::io::{Read as _, Write as _};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine as _;
use serde_json::{Value, json};

use super::*;
use crate::server::{BoundedOutbound, QueuedSink};

const VM: &str = "vm_abcdefghij0123456789";

/// One request the fake saw: its request line, its lowercased header lines and its body.
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
                    let head = String::from_utf8_lossy(&buffer[..end]).to_ascii_lowercase();
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

fn client(mux: &Mux, transport: ClientTransport) -> (u64, MessageWriter, Arc<BoundedOutbound>) {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    (mux.control_clients.register(transport, writer.clone()), writer, outbound)
}

/// The next reply on `outbound` (a call answers from its worker thread).
fn next_reply(outbound: &BoundedOutbound) -> Value {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if let Some(text) = outbound.try_pop() {
            return serde_json::from_str(&text).unwrap();
        }
        assert!(Instant::now() < deadline, "no reply");
        std::thread::sleep(Duration::from_millis(5));
    }
}

/// Sends `frame` as a local client and answers its reply.
fn call(mux: &Arc<Mux>, frame: Value) -> Value {
    let (client, writer, outbound) = client(mux, ClientTransport::Unix);
    assert_eq!(try_handle(mux, client, &frame.to_string(), &writer), Some(true));
    next_reply(&outbound)
}

fn frame(cmd: &str, origin: &str, auth: &str, args: Value) -> Value {
    json!({"id": 7, "cmd": cmd, "api": origin, "auth": auth, "access_token": "secret-access",
        "refresh_token": "secret-refresh", "team": "team_1", "app_version": "cmux-next",
        "args": args})
}

fn mux(name: &str) -> Arc<Mux> {
    Mux::new_for_test(name, crate::SurfaceOptions::default())
}

#[test]
fn only_cloud_calls_of_the_library_are_this_modules() {
    assert_eq!(call_of(r#"{"cmd":"cloud.vm.resize"}"#).map(|c| c.0), Some("vm.resize"));
    assert_eq!(call_of(r#"{"cmd":"cloud.machine.io"}"#).map(|c| c.0), Some("machine.io"));
    for line in [
        r#"{"cmd":"cloud.repo.add"}"#,
        r#"{"cmd":"cloud.vm.nope"}"#,
        r#"{"cmd":"cloud.machine.link_token"}"#,
        r#"{"cmd":"vm.resize"}"#,
        r#"{"cmd":"cloud.vm.resize","protocol":"cmux.protocol/2"}"#,
        r#"{"cmd":"ping","note":"cloud.vm.resize"}"#,
        "not json \"cloud.",
    ] {
        assert!(call_of(line).is_none(), "{line}");
    }
    for name in CALLS {
        assert!(call_of(&json!({ "cmd": format!("cloud.{name}") }).to_string()).is_some());
    }
}

#[test]
fn a_classic_call_sends_the_stack_session_and_answers_its_body() {
    let (origin, seen) = fake(|_| (200, r#"{"domains":[{"id":"d1"}]}"#.into()));
    let mux = mux("cloud-api-vm");
    let reply = call(&mux, frame("cloud.vm.domains", &origin, "stack", json!({})));
    assert_eq!(reply, json!({"id": 7, "ok": true, "data": [{"id": "d1"}]}));
    let seen = seen.lock().unwrap();
    assert!(seen[0].line.starts_with("GET /api/vm/domains "));
    assert_eq!(seen[0].header("authorization").as_deref(), Some("Bearer secret-access"));
    assert_eq!(seen[0].header("x-stack-refresh-token").as_deref(), Some("secret-refresh"));
    assert_eq!(seen[0].header("x-cmux-team-id").as_deref(), Some("team_1"));
}

#[test]
fn a_run_wait_is_capped_at_the_servers_bound() {
    let (origin, seen) =
        fake(|_| (200, r#"{"run":{"id":"r1","state":"running"},"receipt":null}"#.into()));
    let mux = mux("cloud-api-runs");
    let reply =
        call(&mux, frame("cloud.runs.wait", &origin, "stack", json!({"id": "r1", "timeoutMs": 1})));
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["data"]["run"]["id"], "r1");
    assert!(seen.lock().unwrap()[0].line.starts_with("GET /api/runs/r1/wait?timeoutMs=1 "));
}

#[test]
fn an_owner_call_sends_only_authorization_and_the_team() {
    let (origin, seen) = fake(|_| (200, r#"{"handoffs":[{"id":"h"}],"nextCursor":null}"#.into()));
    let mux = mux("cloud-api-owner");
    let reply = call(&mux, frame("cloud.owner.handoffs", &origin, "owner", json!({})));
    assert_eq!(reply["data"], json!([{"id": "h"}]));
    let seen = seen.lock().unwrap();
    assert!(seen[0].line.starts_with("GET /v1/handoffs?limit=100 "));
    assert_eq!(seen[0].header("x-cmux-team").as_deref(), Some("team_1"));
    assert_eq!(seen[0].header("x-stack-refresh-token"), None);
}

#[test]
fn a_keyed_start_sends_the_decoded_key_as_the_body_only() {
    let (origin, seen) =
        fake(|_| (200, r#"{"ok":true,"value":{"personInstance":"run-2"}}"#.into()));
    let mux = mux("cloud-api-keyed");
    let key = b"person-key-line\n";
    let mut request = frame(
        "cloud.owner.acpmux_keyed_start",
        &origin,
        "owner",
        json!({"machine": VM, "key_length": key.len()}),
    );
    request["key_base64"] = json!(base64::engine::general_purpose::STANDARD.encode(key));
    let reply = call(&mux, request);
    assert_eq!(reply["data"], json!({"personInstance": "run-2"}));
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].body, key);
    assert!(!seen[0].line.contains("person-key"));
}

#[test]
fn a_preview_refresh_goes_through_the_platform_client() {
    let catalog = r#"{"machine":"vm_abc","listening":[3000],"previews":[],"unavailable":[]}"#;
    let (origin, seen) = fake(move |_| (200, catalog.into()));
    let mux = mux("cloud-api-previews");
    let reply = call(
        &mux,
        frame("cloud.previews.refresh", &origin, "worker", json!({"machine": "vm_abc"})),
    );
    assert_eq!(reply["data"]["listening"], json!([3000]));
    assert!(
        seen.lock().unwrap()[0]
            .line
            .starts_with("POST /v1/cloud/machines/vm_abc/previews/refresh ")
    );
}

#[test]
fn a_machine_exec_runs_on_its_route() {
    let (origin, seen) = fake(|_| (200, r#"{"exitCode":0,"stdout":"ok","stderr":""}"#.into()));
    let mux = mux("cloud-api-machine");
    let reply = call(
        &mux,
        frame(
            "cloud.machine.io",
            &origin,
            "stack",
            json!({"op": "exec", "machine": "m1", "command": "true", "timeout_ms": 1000}),
        ),
    );
    assert_eq!(reply["data"]["stdout"], "ok");
    assert!(seen.lock().unwrap()[0].line.starts_with("POST /api/vm/m1/exec "));
}

#[test]
fn a_refusal_names_its_kind_and_never_carries_a_credential_back() {
    let (origin, _seen) = fake(|_| {
        (409, r#"{"error":"vm_busy","message":"echo secret-access and secret-refresh"}"#.into())
    });
    let mux = mux("cloud-api-refusal");
    let reply = call(&mux, frame("cloud.vm.networks", &origin, "stack", json!({})));
    assert_eq!(reply["ok"], false);
    assert_eq!(reply["id"], 7);
    assert_eq!(reply["error_code"], "cloud.http");
    assert_eq!(reply["failure"]["kind"], "http");
    assert_eq!(reply["failure"]["status"], 409);
    assert_eq!(reply["failure"]["code"], "vm_busy");
    let text = reply.to_string();
    assert!(!text.contains("secret-access") && !text.contains("secret-refresh"), "{text}");
    assert!(text.contains("[redacted]"));
}

#[test]
fn a_frame_that_is_not_a_call_runs_nothing_and_echoes_nothing() {
    let mux = mux("cloud-api-invalid");
    let (client, writer, outbound) = client(&mux, ClientTransport::Unix);
    let line = json!({"id": 1, "cmd": "cloud.vm.domains", "access_token": "secret-access",
        "extra": 1})
    .to_string();
    assert_eq!(try_handle(&mux, client, &line, &writer), Some(true));
    let reply = next_reply(&outbound);
    assert_eq!(reply["error_code"], "invalid_request");
    assert!(!reply.to_string().contains("secret-access"));
    let bad_key = json!({"id": 2, "cmd": "cloud.owner.acpmux_keyed_start", "api": "https://x",
        "auth": "owner", "access_token": "a", "key_base64": "%%%"})
    .to_string();
    assert_eq!(try_handle(&mux, client, &bad_key, &writer), Some(true));
    assert_eq!(next_reply(&outbound)["error_code"], "invalid_request");
}

#[test]
fn only_a_local_socket_client_may_call() {
    let (origin, seen) = fake(|_| (200, "{}".into()));
    let mux = mux("cloud-api-transport");
    for transport in [ClientTransport::Remote, ClientTransport::WebSocket] {
        let (client, writer, outbound) = client(&mux, transport);
        let line = frame("cloud.vm.domains", &origin, "stack", json!({})).to_string();
        assert_eq!(try_handle(&mux, client, &line, &writer), Some(true));
        assert_eq!(next_reply(&outbound)["error_code"], "remote_denied");
    }
    let (client, writer, outbound) = client(&mux, ClientTransport::Unix);
    let mut forged = frame("cloud.vm.domains", &origin, "stack", json!({}));
    forged["credential"] = json!("forged");
    assert_eq!(try_handle(&mux, client, &forged.to_string(), &writer), Some(true));
    assert_eq!(next_reply(&outbound)["error_code"], "remote_denied");
    assert!(seen.lock().unwrap().is_empty());
}
