//! `cmux cloud api` end to end: the CLI's `cmux.protocol/2` request (`call_as`) through a real
//! daemon socket to a fake Cloud API on a local port, one call of each family, and the answer
//! read back.

use std::io::{Read as _, Write as _};
use std::net::TcpListener;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock};

use cmux_cloud_api::Auth;
use cmux_tui_core::{Mux, SurfaceOptions};
use serde_json::{Map, json};

use super::*;

const VM: &str = "vm_abcdefghij0123456789";

/// One request the fake saw: its request line, its head (names lowercased) and its body.
#[derive(Debug, Clone)]
struct Seen {
    line: String,
    head: String,
    body: Vec<u8>,
}

impl Seen {
    fn header(&self, name: &str) -> Option<String> {
        let prefix = format!("{name}: ");
        self.head.lines().find_map(|l| l.strip_prefix(&prefix).map(|v| v.trim().to_owned()))
    }
}

type Log = Arc<Mutex<Vec<Seen>>>;

/// A Cloud API that answers `reply(seen)` (status, body) to every request.
fn fake(reply: impl Fn(&Seen) -> (u16, String) + Send + Sync + 'static) -> (String, Log) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let seen: Log = Arc::default();
    let log = Arc::clone(&seen);
    std::thread::spawn(move || {
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { continue };
            let mut buffer = Vec::new();
            let mut chunk = [0_u8; 65536];
            let seen = loop {
                let n = stream.read(&mut chunk).unwrap_or(0);
                buffer.extend_from_slice(&chunk[..n]);
                let Some(end) = buffer.windows(4).position(|w| w == b"\r\n\r\n") else {
                    if n == 0 {
                        break None;
                    }
                    continue;
                };
                let raw = String::from_utf8_lossy(&buffer[..end]).to_string();
                // Names lowercased, values as sent.
                let head = raw
                    .lines()
                    .map(|line| match line.split_once(':') {
                        Some((name, value)) => format!("{}:{value}", name.to_ascii_lowercase()),
                        None => line.to_owned(),
                    })
                    .collect::<Vec<_>>()
                    .join("\n");
                let length = head
                    .lines()
                    .find_map(|l| l.strip_prefix("content-length: "))
                    .and_then(|v| v.trim().parse::<usize>().ok())
                    .unwrap_or(0);
                if buffer.len() >= end + 4 + length || n == 0 {
                    let line = raw.lines().next().unwrap_or_default().to_owned();
                    break Some(Seen { line, head, body: buffer[end + 4..].to_vec() });
                }
            };
            let Some(seen) = seen else { continue };
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

/// One daemon for the module's tests, on its own socket.
fn daemon() -> &'static PathBuf {
    static SOCKET: OnceLock<PathBuf> = OnceLock::new();
    SOCKET.get_or_init(|| {
        let mux = Mux::new(
            format!("cloud-api-cli-test-{}", std::process::id()),
            SurfaceOptions { command: Some(vec!["/bin/cat".to_string()]), ..Default::default() },
        );
        cmux_tui_core::server::serve(mux, None).unwrap()
    })
}

fn request(origin: &str, auth: Auth, call: &str, args: Value) -> Request {
    Request {
        call: call.into(),
        api: origin.into(),
        auth,
        credential: "secret-access".into(),
        refresh: Some("secret-refresh".into()),
        team: Some("team_1".into()),
        app_version: Some("cmux-next".into()),
        local_only: false,
        args: args.as_object().cloned().unwrap_or_else(Map::new),
    }
}

fn go(request: &Request, key: &[u8]) -> Result<Value, Failure> {
    call_socket(daemon(), false, None, request, key)
}

#[test]
fn a_classic_call_reaches_the_api_through_the_daemon() {
    let (origin, seen) =
        fake(|_| (200, r#"{"run":{"id":"r1","state":"running"},"receipt":null}"#.into()));
    let args = json!({"id": "r1", "timeoutMs": 1});
    let answer = go(&request(&origin, Auth::Stack, "runs.wait", args), &[]);
    assert_eq!(answer.unwrap()["run"]["id"], "r1");
    let seen = seen.lock().unwrap();
    assert!(seen[0].line.starts_with("GET /api/runs/r1/wait?timeoutMs=1 "));
    assert_eq!(seen[0].header("authorization").as_deref(), Some("Bearer secret-access"));
    assert_eq!(seen[0].header("x-stack-refresh-token").as_deref(), Some("secret-refresh"));
    assert_eq!(seen[0].header("x-cmux-team-id").as_deref(), Some("team_1"));
}

#[test]
fn a_run_create_sends_its_key_through_the_daemon() {
    let (origin, seen) = fake(|_| (200, r#"{"id":"run_1","state":"queued"}"#.into()));
    let args = json!({"task": "echo hi", "idempotencyKey": "k-1"});
    let answer = go(&request(&origin, Auth::Stack, "runs.start", args), &[]).unwrap();
    assert_eq!(answer["id"], "run_1");
    let seen = seen.lock().unwrap();
    assert!(seen[0].line.starts_with("POST /api/runs "));
    assert_eq!(seen[0].header("idempotency-key").as_deref(), Some("k-1"));
}

#[test]
fn a_keyed_start_carries_the_key_bytes_to_the_request_body_only() {
    let (origin, seen) =
        fake(|_| (200, r#"{"ok":true,"value":{"personInstance":"run-2"}}"#.into()));
    let key = b"person-key-line\n";
    let args = json!({"machine": VM, "key_length": key.len()});
    let call = request(&origin, Auth::Owner, "owner.acpmux_keyed_start", args);
    assert_eq!(go(&call, key).unwrap(), json!({"personInstance": "run-2"}));
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].body, key);
    assert_eq!(seen[0].header("x-cmux-team").as_deref(), Some("team_1"));
    assert_eq!(seen[0].header("x-stack-refresh-token"), None);
    assert!(!seen[0].head.contains("person-key"));
}

#[test]
fn a_preview_link_is_created_on_the_platform_through_the_daemon() {
    let link = r#"{"link":{"linkId":"link_123","creator":"user_1","team":"team_1","machine":"vm_abc","port":3000,"hostname":"preview.example","ruleId":"rule_1","createdAt":1700000000000,"expiresAt":1700086400000,"maxUses":null,"redemptions":0,"revokedAt":null},"url":"https://preview.example/?cmux_share=s"}"#;
    let (origin, seen) = fake(move |_| (200, link.into()));
    let args = json!({"machine": "vm_abc", "port": 3000});
    let answer = go(&request(&origin, Auth::Worker, "previews.create_link", args), &[]).unwrap();
    assert_eq!(answer["link"]["linkId"], "link_123");
    let seen = seen.lock().unwrap();
    assert!(seen[0].line.starts_with("POST /v1/cloud/machines/vm_abc/previews/3000/links "));
    assert_eq!(seen[0].header("x-cmux-team").as_deref(), Some("team_1"));
}

#[test]
fn a_classic_machine_exec_is_refused_through_the_daemon() {
    let (origin, seen) = fake(|_| (200, r#"{"exitCode":0,"stdout":"ok","stderr":""}"#.into()));
    let args = json!({"op": "exec", "machine": "m1", "command": "true", "timeout_ms": 1000});
    let failure = go(&request(&origin, Auth::Stack, "machine.io", args), &[]).unwrap_err();
    assert!(matches!(failure, Failure::Http { status: 501, .. }), "{failure:?}");
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn a_refusal_comes_back_as_the_same_failure_with_no_credential() {
    let (origin, _seen) = fake(|_| {
        (
            402,
            r#"{"error":"vm_active_limit_exceeded","message":"echo secret-access","upgradeRequired":true,"upgradeUrl":"https://cmux.com/pricing"}"#
                .into(),
        )
    });
    let args = json!({"id": "r1", "timeoutMs": 1});
    let failure = go(&request(&origin, Auth::Stack, "runs.wait", args), &[]).unwrap_err();
    assert_eq!(
        failure,
        Failure::PlanRequired {
            message: Some("echo [redacted]".into()),
            upgrade_url: Some("https://cmux.com/pricing".into()),
            plan: "pro".into(),
        }
    );
}

#[test]
fn a_daemon_that_is_not_running_is_a_transport_failure() {
    let missing = std::env::temp_dir().join(format!("cloud-api-none-{}.sock", std::process::id()));
    let call = request("https://cmux.com", Auth::Stack, "runs.wait", json!({"id": "r1"}));
    assert!(matches!(call_socket(&missing, false, None, &call, &[]), Err(Failure::Transport(_))));
}

#[test]
fn the_params_carry_the_route_the_fields_and_the_key_as_base64() {
    let call = request("https://cmux.com", Auth::Owner, "owner.acpmux_keyed_start", json!({}));
    let params = Value::Object(params(&call, b"k\n", Some("work")));
    assert_eq!(params["machine"], "current");
    assert_eq!(params["session"], "work");
    assert_eq!(params["access_token"], "secret-access");
    assert_eq!(params["refresh_token"], "secret-refresh");
    assert_eq!(params["auth"], "owner");
    assert_eq!(params["args"], json!({}));
    assert_eq!(params["key_base64"], "awo=");
    let plain = super::params(&call, &[], None);
    assert!(plain.get("key_base64").is_none());
    assert_eq!(plain["session"], "current");
}

#[test]
fn a_resource_error_reads_back_every_failure_kind() {
    for failure in [
        Failure::TimedOut("/api/runs".into()),
        Failure::Transport("t".into()),
        Failure::NoBackend,
        Failure::Http {
            status: 409,
            code: Some("c".into()),
            message: Some("m".into()),
            action: Some("a".into()),
            trace_id: Some("t".into()),
            retryable: Some(true),
            retry_after_s: Some(5),
        },
        Failure::PlanRequired { message: None, upgrade_url: None, plan: "max".into() },
        Failure::Decoding("d".into()),
    ] {
        let error = json!({"code": "operation.failed", "message": "x", "retryable": false,
            "details": {"operation": "cloud.vm.domains", "reason": failure.kind(),
                "extra": {"failure": failure.json()}}});
        assert_eq!(from_error(&error), failure);
    }
    let invalid = json!({"code": "validation.invalid", "message": "auth is stack, owner or worker",
        "retryable": false, "details": {}});
    assert_eq!(from_error(&invalid), Failure::Transport("auth is stack, owner or worker".into()));
}
