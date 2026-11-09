//! `cmux cloud api` against a fake server on a local port: the routes, bodies and headers each
//! call sends, the answers it reads, and every refusal's reading. Ported from the app's
//! CloudAPIClient*, CloudErrorText, CloudGitHubApp, CloudHarnessLoginCopySwitch,
//! CloudHandoffTurnOpener and CloudResizeDisk Swift tests.

use std::io::{Read, Write as _};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};

use super::http::{base_url, vm_error};
use super::owner::{
    fork_children, github_app_state, handoff_turn, harness_login_copy, is_handoff_id,
};
use super::*;

const VM: &str = "vm_abcdefghij0123456789";
const HANDOFF: &str = "ho_0123456789abcdef0123";

/// One request the fake saw.
#[derive(Debug, Clone)]
struct Seen {
    line: String,
    headers: String,
    body: Vec<u8>,
}

impl Seen {
    fn json(&self) -> Value {
        serde_json::from_slice(&self.body).unwrap_or(Value::Null)
    }
    fn header(&self, name: &str) -> Option<String> {
        let prefix = format!("{}: ", name.to_ascii_lowercase());
        self.headers.lines().find_map(|l| l.strip_prefix(&prefix).map(|v| v.trim().to_owned()))
    }
    fn target(&self) -> String {
        self.line.split(' ').take(2).collect::<Vec<_>>().join(" ")
    }
}

/// `(status, body)`, or `None` to drop the connection without an answer.
type Reply = Option<(u16, String)>;

fn fake(
    handler: impl Fn(&Seen) -> Reply + Send + Sync + 'static,
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
                    let head = String::from_utf8_lossy(&buffer[..end]).to_string();
                    let length = head
                        .lines()
                        .find_map(|l| {
                            l.to_ascii_lowercase()
                                .strip_prefix("content-length: ")
                                .map(|v| v.trim().parse::<usize>().unwrap())
                        })
                        .unwrap_or(0);
                    if buffer.len() >= end + 4 + length || n == 0 {
                        break (head, buffer[end + 4..].to_vec());
                    }
                } else if n == 0 {
                    break (String::from_utf8_lossy(&buffer).to_string(), Vec::new());
                }
            };
            let (line, headers) =
                head.split_once("\r\n").map_or((head.clone(), String::new()), |(l, h)| {
                    let headers = h
                        .lines()
                        .map(|l| match l.split_once(':') {
                            Some((name, value)) => format!("{}:{value}", name.to_ascii_lowercase()),
                            None => l.to_owned(),
                        })
                        .collect::<Vec<_>>()
                        .join("\n");
                    (l.to_owned(), headers)
                });
            let request = Seen { line, headers, body };
            let reply = handler(&request);
            log.lock().unwrap().push(request);
            if let Some((status, reply)) = reply {
                let _ = stream.write_all(
                    format!("HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{reply}", reply.len())
                        .as_bytes(),
                );
            }
        }
    });
    (origin, seen)
}

fn request(origin: &str, auth: Auth, call: &str, args: Value) -> Request {
    Request {
        call: call.into(),
        api: origin.into(),
        auth,
        credential: "access".into(),
        refresh: Some("refresh".into()),
        team: Some("team-1".into()),
        app_version: Some("cmux-next".into()),
        local_only: false,
        args: args.as_object().cloned().unwrap_or_default(),
    }
}

fn go(request: &Request) -> Result<Value, Failure> {
    go_with(request, Vec::new())
}

fn go_with(request: &Request, tail: Vec<u8>) -> Result<Value, Failure> {
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    runtime.block_on(perform(request, Zeroizing::new(tail)))
}

fn ok(body: &str) -> Reply {
    Some((200, body.to_owned()))
}

// MARK: classic refusals (CloudAPIClientPlanRequiredTests, CloudErrorTextTests)

#[test]
fn a_free_accounts_refusal_is_the_pro_plan_refusal() {
    let body = br#"{"error":"vm_active_limit_exceeded","message":"Cloud VMs require a cmux Pro subscription.","limit":0,"upgradeRequired":true,"upgradeUrl":"https://cmux.com/pricing"}"#;
    assert_eq!(
        vm_error(402, body, None),
        Failure::PlanRequired {
            message: Some("Cloud VMs require a cmux Pro subscription.".into()),
            upgrade_url: Some("https://cmux.com/pricing".into()),
            plan: "pro".into(),
        }
    );
}

#[test]
fn a_pro_budget_that_names_max_is_a_max_plan_refusal() {
    let body = br#"{"error":"vm_compute_budget_reached","message":"This month's compute budget is used up.","upgradeRequired":true,"upgradePlanId":"max","upgradeUrl":"https://cmux.com/api/billing/checkout?plan=max"}"#;
    assert_eq!(
        vm_error(402, body, None),
        Failure::PlanRequired {
            message: Some("This month's compute budget is used up.".into()),
            upgrade_url: Some("https://cmux.com/api/billing/checkout?plan=max".into()),
            plan: "max".into(),
        }
    );
}

#[test]
fn a_credits_top_up_and_a_paid_plans_limit_stay_http_refusals() {
    let top_up = br#"{"error":"vm_create_credits_insufficient","message":"You are out of Cloud credits.","upgradeRequired":true,"upgradePlanId":"max"}"#;
    assert_eq!(
        vm_error(402, top_up, None),
        Failure::http(
            402,
            Some("vm_create_credits_insufficient".into()),
            Some("You are out of Cloud credits.".into())
        )
    );
    let limit = br#"{"error":"vm_active_limit_exceeded","message":"This plan allows 3 active Cloud VMs at a time.","limit":3}"#;
    assert_eq!(
        vm_error(402, limit, None),
        Failure::http(
            402,
            Some("vm_active_limit_exceeded".into()),
            Some("This plan allows 3 active Cloud VMs at a time.".into())
        )
    );
}

#[test]
fn an_upgrade_url_off_cmux_com_or_a_plan_not_sold_here_is_not_kept() {
    let elsewhere =
        br#"{"error":"x","upgradeRequired":true,"upgradeUrl":"https://evil.example/pricing"}"#;
    assert!(matches!(
        vm_error(402, elsewhere, None),
        Failure::PlanRequired { upgrade_url: None, .. }
    ));
    let plain_http =
        br#"{"error":"x","upgradeRequired":true,"upgradeUrl":"http://cmux.com/pricing"}"#;
    assert!(matches!(
        vm_error(402, plain_http, None),
        Failure::PlanRequired { upgrade_url: None, .. }
    ));
    // A browser reads `\` as `/`: this link is evil.example's, whatever follows the `@`.
    let backslash = br#"{"error":"x","upgradeRequired":true,"upgradeUrl":"https://evil.example\\@cmux.com/pricing"}"#;
    assert!(matches!(
        vm_error(402, backslash, None),
        Failure::PlanRequired { upgrade_url: None, .. }
    ));
    let team = br#"{"error":"x","upgradeRequired":true,"upgradePlanId":"team"}"#;
    assert!(matches!(vm_error(402, team, None), Failure::Http { .. }));
}

#[test]
fn the_action_and_trace_id_follow_the_message() {
    let body = br#"{"error":"vm_busy","message":"It failed.","action":"Run `cmux vm ls`.","traceId":"t-1"}"#;
    assert_eq!(
        vm_error(409, body, None),
        Failure::Http {
            status: 409,
            code: Some("vm_busy".into()),
            message: Some("It failed.".into()),
            action: Some("Run `cmux vm ls`.".into()),
            trace_id: Some("t-1".into()),
        }
    );
    // A blank action is none; the ui block's message and trace id win or fill in.
    let blank = br#"{"error":"busy","message":"Resize in progress.","action":"  "}"#;
    assert!(matches!(vm_error(409, blank, None), Failure::Http { action: None, .. }));
    let ui = br#"{"error":"internal","ui":{"message":"Try again.","traceId":"t-9"}}"#;
    assert!(matches!(vm_error(500, ui, None),
        Failure::Http { message: Some(m), trace_id: Some(t), .. } if m == "Try again." && t == "t-9"));
    assert_eq!(vm_error(502, b"<html>", None), Failure::http(502, None, None));
}

#[test]
fn a_worker_refusal_names_its_nested_code_and_the_header_code_wins() {
    let body =
        br#"{"ok":false,"error":{"code":"machine.not_running","message":"Start it first."}}"#;
    assert_eq!(
        vm_error(409, body, None),
        Failure::http(409, Some("machine.not_running".into()), Some("Start it first.".into()))
    );
    assert!(matches!(vm_error(409, body, Some("vm_not_running")),
        Failure::Http { code: Some(c), .. } if c == "vm_not_running"));
}

// MARK: classic routes

#[test]
fn classic_calls_send_the_stack_session_and_the_team() {
    let (origin, seen) = fake(|_| ok(r#"{"domains":[{"id":"dom-1"}]}"#));
    let answer = go(&request(&origin, Auth::Stack, "vm.domains", json!({}))).unwrap();
    assert_eq!(answer, json!([{ "id": "dom-1" }]));
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), "GET /api/vm/domains");
    assert_eq!(seen[0].header("authorization").as_deref(), Some("Bearer access"));
    assert_eq!(seen[0].header("x-stack-refresh-token").as_deref(), Some("refresh"));
    assert_eq!(seen[0].header("x-cmux-team-id").as_deref(), Some("team-1"));
    assert_eq!(seen[0].header("x-cmux-client").as_deref(), Some("cmux-mac"));
    assert_eq!(seen[0].header("x-cmux-app-version").as_deref(), Some("cmux-next"));
}

// MARK: the team's network (cmux-platform)

const MESH: &str = "mesh_0123456789abcdefghjkmnpqrs";
const TARGET: &str = r#"{"team":"team_1","tenant":"t1","project":"p1","origin":"https://vm.invalid","mesh":"mesh_0123456789abcdefghjkmnpqrs","ipv4_cidr":"10.128.16.0/20"}"#;
const NO_MESH: &str = r#"{"code":"selector.not_found","message":"no available network mesh"}"#;
const NOT_INSTALL: &str = r#"{"code":"auth.forbidden","message":"an install is required"}"#;

fn networks(origin: &str, auth: Auth) -> Result<Value, Failure> {
    go(&request(origin, auth, "vm.networks", json!({})))
}

#[test]
fn the_network_list_is_the_platforms_network_target_as_the_install() {
    let (origin, seen) = fake(|_| ok(TARGET));
    let network = json!({ "id": MESH, "cidr": "10.128.16.0/20", "cidrV6": null, "scope": "team" });
    assert_eq!(networks(&origin, Auth::Worker).unwrap(), json!([network]));
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].target(), "GET /v1/host/network/target");
    assert_eq!(seen[0].header("authorization").as_deref(), Some("Bearer access"));
    assert_eq!(seen[0].header("x-cmux-team").as_deref(), Some("team-1"));
    assert_eq!(seen[0].header("x-stack-refresh-token"), None);
}

#[test]
fn a_team_with_no_mesh_yet_has_no_network_and_a_refusal_is_read() {
    let (origin, _seen) = fake(|_| Some((404, NO_MESH.into())));
    assert_eq!(networks(&origin, Auth::Worker).unwrap(), json!([]));
    let (origin, _seen) = fake(|_| Some((403, NOT_INSTALL.into())));
    let failure = networks(&origin, Auth::Worker).unwrap_err();
    assert!(matches!(failure, Failure::Http { status: 403, .. }), "{failure:?}");
}

#[test]
fn the_network_list_never_goes_to_classic() {
    let (origin, seen) = fake(|_| ok(r#"{"networks":[{"id":"net-1"}]}"#));
    let failure = networks(&origin, Auth::Stack).unwrap_err();
    assert!(matches!(failure, Failure::Transport(_)), "{failure:?}");
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn provision_and_the_api_key_routes_address_the_publication_and_key() {
    let (origin, seen) = fake(|s| {
        if s.line.starts_with("POST") {
            ok(r#"{"url":"https://hello--owner--3000.cmux.sh","token":"cmux_api_secret"}"#)
        } else if s.line.starts_with("GET") {
            ok(r#"{"apiKeys":[{"id":"key-1"}]}"#)
        } else {
            ok(r#"{"apiKey":{"id":"key-1","revokedAt":"2026-10-26T12:05:00.000Z"}}"#)
        }
    });
    let args = json!({ "vmId": "vm-1", "port": 3000, "keyName": "agent" });
    let provisioned = go(&request(&origin, Auth::Stack, "vm.provision_api", args)).unwrap();
    assert_eq!(provisioned["token"], "cmux_api_secret");
    let keys = go(&request(
        &origin,
        Auth::Stack,
        "vm.publication_api_keys",
        json!({ "publication": "hello--owner--3000.cmux.sh" }),
    ))
    .unwrap();
    assert_eq!(keys, json!([{ "id": "key-1" }]));
    let revoked = go(&request(
        &origin,
        Auth::Stack,
        "vm.revoke_publication_api_key",
        json!({ "publication": "pub/1", "keyId": "key-1" }),
    ))
    .unwrap();
    assert_eq!(revoked["revokedAt"], "2026-10-26T12:05:00.000Z");
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), "POST /api/vm/apis");
    assert_eq!(seen[0].json(), json!({ "vmId": "vm-1", "port": 3000, "name": "agent" }));
    assert_eq!(seen[1].target(), "GET /api/vm/publications/hello--owner--3000.cmux.sh/api-keys");
    // A publication name never adds a path part.
    assert_eq!(seen[2].target(), "DELETE /api/vm/publications/pub%2F1/api-keys/key-1");
}

#[test]
fn firewall_and_tunnel_queries_are_encoded_and_the_purpose_defaults_to_browser() {
    let (origin, seen) = fake(|_| ok(r#"{"rules":[]}"#));
    go(&request(&origin, Auth::Stack, "vm.firewall_list", json!({ "vmId": "vm 1&x=y" }))).unwrap();
    go(&request(
        &origin,
        Auth::Stack,
        "vm.tunnel_attach",
        json!({ "deviceFingerprint": "fp", "networkId": "net-1" }),
    ))
    .unwrap();
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), "GET /api/vm/firewall?vmId=vm+1%26x%3Dy");
    assert_eq!(seen[1].target(), "POST /api/vm/tunnel/network/attach");
    assert_eq!(
        seen[1].json(),
        json!({ "deviceFingerprint": "fp", "networkId": "net-1", "tunnelPurpose": "browser" })
    );
}

#[test]
fn an_scp_endpoint_is_used_only_when_it_is_safe() {
    let good = json!({ "host": "h", "port": 22, "username": "cmux", "hostPublicKey": "ssh-ed25519 AAA", "expiresAtUnix": 2000 });
    assert!(classic::safe_scp_endpoint(&good, 1000));
    let snake = json!({ "port": 22, "username": "cmux", "host_public_key": "ssh-ed25519 AAA", "expires_at_unix": 2000 });
    assert!(classic::safe_scp_endpoint(&snake, 1000));
    assert!(!classic::safe_scp_endpoint(&good, 2000));
    for (field, bad) in [
        ("port", json!(2222)),
        ("username", json!("root")),
        ("hostPublicKey", json!("ssh-rsa AAA")),
    ] {
        let mut endpoint = good.clone();
        endpoint[field] = bad;
        assert!(!classic::safe_scp_endpoint(&endpoint, 1000), "{field}");
    }
}

// MARK: Runs (CloudAPIClientRunTests)

#[test]
fn a_create_sends_the_key_and_a_wait_is_capped_at_the_server_bound() {
    let (origin, seen) = fake(|s| {
        if s.line.contains("/wait") {
            ok(
                r#"{"run":{"id":"run-1","status":"succeeded"},"receipt":{"schema":"cmux.run.receipt/v1"}}"#,
            )
        } else {
            Some((202, r#"{"id":"run-1","status":"queued"}"#.into()))
        }
    });
    let created = go(&request(
        &origin,
        Auth::Stack,
        "runs.create",
        json!({ "task": "hi", "agent": "claude", "idempotencyKey": "key-1" }),
    ))
    .unwrap();
    assert_eq!(created["id"], "run-1");
    let waited = go(&request(
        &origin,
        Auth::Stack,
        "runs.wait",
        json!({ "id": "run-1", "timeoutMs": 60000 }),
    ))
    .unwrap();
    assert_eq!(waited["receipt"]["schema"], "cmux.run.receipt/v1");
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), "POST /api/runs");
    assert_eq!(seen[0].header("idempotency-key").as_deref(), Some("key-1"));
    assert_eq!(
        seen[0].json(),
        json!({ "environment": "sandboxed", "task": "hi", "agent": "claude" })
    );
    assert_eq!(seen[1].target(), "GET /api/runs/run-1/wait?timeoutMs=10000");
}

/// A Run API that answers `running` `finish_after` times, then the receipt; drops `drop` creates.
fn sandbox_api(
    finish_after: usize,
    drop: usize,
    malformed: bool,
) -> (String, Arc<Mutex<Vec<Seen>>>) {
    let waits = Arc::new(Mutex::new(0_usize));
    let drops = Arc::new(Mutex::new(drop));
    fake(move |s| {
        if s.target() == "POST /api/runs" {
            let mut drops = drops.lock().unwrap();
            if *drops > 0 {
                *drops -= 1;
                return None;
            }
            return ok(r#"{"id":"run-9","status":"queued"}"#);
        }
        let mut waits = waits.lock().unwrap();
        *waits += 1;
        if malformed {
            ok(r#"{"error":"internal"}"#)
        } else if *waits > finish_after {
            ok(
                r#"{"run":{"id":"run-9","status":"succeeded"},"receipt":{"status":"succeeded","reply":"done"}}"#,
            )
        } else {
            ok(r#"{"run":{"id":"run-9","status":"running"},"receipt":null}"#)
        }
    })
}

fn creates(seen: &Arc<Mutex<Vec<Seen>>>) -> Vec<Option<String>> {
    seen.lock()
        .unwrap()
        .iter()
        .filter(|s| s.target() == "POST /api/runs")
        .map(|s| s.header("idempotency-key"))
        .collect()
}

fn waits(seen: &Arc<Mutex<Vec<Seen>>>) -> usize {
    seen.lock().unwrap().iter().filter(|s| s.line.contains("/wait")).count()
}

#[test]
fn run_sandbox_waits_until_the_receipt_then_answers_the_snapshot() {
    let (origin, seen) = sandbox_api(2, 0, false);
    let snapshot = go(&request(
        &origin,
        Auth::Stack,
        "runs.sandbox",
        json!({ "task": "hi", "timeoutMs": 60000, "idempotencyKey": "k" }),
    ))
    .unwrap();
    assert_eq!(snapshot["receipt"]["reply"], "done");
    assert_eq!(waits(&seen), 3);
}

#[test]
fn a_create_whose_answer_was_lost_is_sent_once_more_under_the_same_key() {
    let (origin, seen) = sandbox_api(0, 1, false);
    let snapshot = go(&request(
        &origin,
        Auth::Stack,
        "runs.sandbox",
        json!({ "task": "hi", "timeoutMs": 60000, "idempotencyKey": "send-1" }),
    ))
    .unwrap();
    assert_eq!(snapshot["receipt"]["reply"], "done");
    assert_eq!(creates(&seen), vec![Some("send-1".into()), Some("send-1".into())]);
    // One process, one credential: the retry goes with the first create's.
    let tokens: Vec<_> = seen.lock().unwrap().iter().map(|s| s.header("authorization")).collect();
    assert!(tokens.iter().all(|t| t.as_deref() == Some("Bearer access")));
}

#[test]
fn a_retry_that_fails_after_an_uncertain_create_stays_uncertain() {
    let (origin, seen) = sandbox_api(0, 2, false);
    let failure = go(&request(
        &origin,
        Auth::Stack,
        "runs.start",
        json!({ "task": "hi", "timeoutMs": 60000, "idempotencyKey": "send-2" }),
    ))
    .unwrap_err();
    assert_eq!(failure, Failure::TimedOut("/api/runs".into()));
    assert_eq!(creates(&seen), vec![Some("send-2".into()), Some("send-2".into())]);
}

#[test]
fn a_refused_create_is_not_sent_again() {
    let (origin, seen) = fake(|_| Some((403, r#"{"error":"run_sandbox_unavailable"}"#.into())));
    let failure = go(&request(
        &origin,
        Auth::Stack,
        "runs.start",
        json!({ "task": "hi", "idempotencyKey": "k" }),
    ))
    .unwrap_err();
    assert_eq!(failure, Failure::http(403, Some("run_sandbox_unavailable".into()), None));
    assert_eq!(creates(&seen).len(), 1);
}

#[test]
fn a_wait_answer_that_is_no_snapshot_ends_at_once() {
    let (origin, seen) = sandbox_api(usize::MAX, 0, true);
    let failure = go(&request(
        &origin,
        Auth::Stack,
        "runs.sandbox",
        json!({ "task": "hi", "timeoutMs": 60000, "idempotencyKey": "k" }),
    ))
    .unwrap_err();
    assert_eq!(failure, Failure::TimedOut("/api/runs/run-9".into()));
    assert_eq!(waits(&seen), 1);
}

#[test]
fn run_sandbox_stops_at_the_deadline() {
    let (origin, seen) = sandbox_api(usize::MAX, 0, false);
    let failure = go(&request(&origin, Auth::Stack, "runs.sandbox",
        json!({ "task": "hi", "timeoutMs": 300, "teardownMs": 0, "callsMarginMs": 60000, "idempotencyKey": "k" }))).unwrap_err();
    assert_eq!(failure, Failure::TimedOut("/api/runs/run-9".into()));
    assert!(waits(&seen) >= 1);
}

#[test]
fn a_server_that_never_answers_still_ends_at_the_bound() {
    let (origin, _seen) = fake(|_| {
        std::thread::sleep(Duration::from_secs(3));
        None
    });
    let started = std::time::Instant::now();
    let failure = go(&request(&origin, Auth::Stack, "runs.sandbox",
        json!({ "task": "hi", "timeoutMs": 50, "teardownMs": 0, "callsMarginMs": 50, "idempotencyKey": "k" }))).unwrap_err();
    assert_eq!(failure, Failure::TimedOut("/api/runs".into()));
    assert!(started.elapsed() < Duration::from_secs(2));
}

// MARK: owner routes

#[test]
fn owner_calls_send_only_authorization_and_the_cmux_team() {
    let (origin, seen) = fake(|_| ok(r#"{"ok":true,"value":{"instance":"i-1","proof":"p-1"}}"#));
    let answer = go(&request(
        &origin,
        Auth::Owner,
        "owner.acpmux_person_holds",
        json!({ "machine": VM, "nonce": "n-1" }),
    ))
    .unwrap();
    assert_eq!(answer, json!({ "instance": "i-1", "proof": "p-1" }));
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), format!("POST /v1/cloud/machines/{VM}/acpmux/person-holds"));
    assert_eq!(seen[0].json(), json!({ "nonce": "n-1" }));
    assert_eq!(seen[0].header("x-cmux-team").as_deref(), Some("team-1"));
    for absent in [
        "x-stack-refresh-token",
        "x-cmux-team-id",
        "x-cmux-client",
        "x-cmux-app-version",
        "idempotency-key",
    ] {
        assert_eq!(seen[0].header(absent), None, "{absent}");
    }
}

#[test]
fn a_keyed_start_sends_the_key_bytes_as_the_body_only() {
    let (origin, seen) = fake(|_| ok(r#"{"ok":true,"value":{"personInstance":"run-2"}}"#));
    let key = b"person-key-line\n".to_vec();
    let mut input = serde_json::to_vec(&json!({
        "call": "owner.acpmux_keyed_start", "api": origin, "auth": "owner", "credential": "access",
        "team": "team_x", "args": { "machine": VM, "key_length": key.len() },
    }))
    .unwrap();
    input.push(b'\n');
    input.extend_from_slice(&key);
    let (parsed, tail) = parse(&input).unwrap();
    assert_eq!(tail.as_slice(), key.as_slice());
    let answer = go_with(&parsed, tail.to_vec()).unwrap();
    assert_eq!(answer, json!({ "personInstance": "run-2" }));
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), format!("POST /v1/cloud/machines/{VM}/acpmux/keyed-start"));
    assert_eq!(seen[0].body, key);
    assert_eq!(seen[0].header("content-type").as_deref(), Some("application/octet-stream"));
    assert!(!seen[0].line.contains("person-key"));
}

#[test]
fn a_keyed_start_with_a_short_key_or_another_machine_id_sends_nothing() {
    let (origin, seen) = fake(|_| ok("{}"));
    let short = request(
        &origin,
        Auth::Owner,
        "owner.acpmux_keyed_start",
        json!({ "machine": VM, "key_length": 10 }),
    );
    assert!(matches!(go_with(&short, b"abc".to_vec()), Err(Failure::Transport(_))));
    for machine in ["vm_short", "../x", "vm_ABCDEFGHIJ0123456789"] {
        let other = request(
            &origin,
            Auth::Owner,
            "owner.acpmux_keyed_start",
            json!({ "machine": machine, "key_length": 3 }),
        );
        assert_eq!(
            go_with(&other, b"abc".to_vec()),
            Err(Failure::Transport("not a Cloud machine id".into()))
        );
    }
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn an_owner_refusal_reads_its_code_and_message() {
    let (origin, _seen) = fake(|_| {
        Some((
            409,
            r#"{"ok":false,"error":{"code":"cloud.acpmux.unsupported","message":"too old"}}"#
                .into(),
        ))
    });
    let failure = go(&request(
        &origin,
        Auth::Owner,
        "owner.acpmux_person_holds",
        json!({ "machine": VM, "nonce": "n" }),
    ))
    .unwrap_err();
    assert_eq!(
        failure,
        Failure::http(409, Some("cloud.acpmux.unsupported".into()), Some("too old".into()))
    );
    // A 2xx without `ok: true` is no answer either.
    let (origin, _seen) = fake(|_| ok(r#"{"value":{"instance":"i","proof":"p"}}"#));
    let failure = go(&request(
        &origin,
        Auth::Owner,
        "owner.acpmux_person_holds",
        json!({ "machine": VM, "nonce": "n" }),
    ))
    .unwrap_err();
    assert_eq!(failure, Failure::http(200, None, None));
}

#[test]
fn a_fork_runs_children_read_from_a_list_an_object_or_one_child() {
    let child = json!({ "id": "c-1", "harness": "claude", "state": "starting", "machineId": null });
    let want = json!([{ "id": "c-1", "harness": "claude", "state": "starting", "machineId": null, "error": null }]);
    assert_eq!(fork_children(json!([child])), Some(want.clone()));
    assert_eq!(fork_children(json!({ "children": [child] })), Some(want.clone()));
    assert_eq!(fork_children(child), Some(want));
    assert_eq!(fork_children(json!({ "id": "c-1" })), None);
    assert_eq!(fork_children(json!("x")), None);
}

#[test]
fn a_fork_run_refuses_a_workspace_that_is_no_id() {
    let (origin, seen) = fake(|_| ok("{}"));
    let args = json!({ "workspace": "ws/../x", "clientKey": "k", "sourceMachine": VM, "session": "s", "harnesses": ["claude"] });
    assert_eq!(
        go(&request(&origin, Auth::Owner, "owner.fork_run", args)),
        Err(Failure::Transport("not a workspace id".into()))
    );
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn a_handoff_wait_is_capped_and_its_body_answered_as_sent() {
    let (origin, seen) =
        fake(|_| ok(r#"{"handoff":{"id":"ho_0123456789abcdef0123","version":3}}"#));
    let answer = go(&request(
        &origin,
        Auth::Owner,
        "owner.handoff_wait",
        json!({ "id": HANDOFF, "after": -4, "timeoutMs": 90000 }),
    ))
    .unwrap();
    assert_eq!(answer["handoff"]["version"], 3);
    assert_eq!(
        seen.lock().unwrap()[0].target(),
        format!("GET /v1/handoffs/{HANDOFF}/wait?after=0&timeoutMs=25000")
    );
    let bad = go(&request(&origin, Auth::Owner, "owner.handoff_wait", json!({ "id": "ho_x" })));
    assert_eq!(bad, Err(Failure::Transport("not a hand-off id".into())));
}

#[test]
fn the_handoffs_list_reads_page_after_page() {
    let (origin, seen) = fake(|s| {
        if s.line.contains("cursor=") {
            ok(r#"{"handoffs":[{"id":"b"}],"nextCursor":null}"#)
        } else {
            ok(r#"{"handoffs":[{"id":"a"}],"nextCursor":"next_1"}"#)
        }
    });
    let answer = go(&request(&origin, Auth::Owner, "owner.handoffs", json!({}))).unwrap();
    assert_eq!(answer, json!([{ "id": "a" }, { "id": "b" }]));
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), "GET /v1/handoffs?limit=100");
    assert_eq!(seen[1].target(), "GET /v1/handoffs?limit=100&cursor=next_1");
}

#[test]
fn a_handoffs_cursor_that_is_no_cursor_is_never_sent() {
    let (origin, seen) = fake(|_| ok(r#"{"handoffs":[],"nextCursor":"a&b"}"#));
    let failure = go(&request(&origin, Auth::Owner, "owner.handoffs", json!({}))).unwrap_err();
    assert_eq!(failure, Failure::Transport("not a list cursor".into()));
    assert_eq!(seen.lock().unwrap().len(), 1);
}

#[test]
fn the_stores_handoff_is_read_and_its_machine_token_is_not() {
    let handoff = json!({ "id": HANDOFF, "sessionId": "s-1", "machine": VM, "turn": 2, "state": "open",
                          "status": "done", "machineToken": "cmm_secret" });
    let turn = handoff_turn(&handoff).unwrap();
    assert_eq!(
        turn,
        json!({ "id": HANDOFF, "sessionId": "s-1", "machine": VM, "turn": 2, "state": "open", "status": "done" })
    );
    assert!(!turn.to_string().contains("cmm_secret"));
    for (field, bad) in [
        ("id", json!("ho_1")),
        ("turn", json!(0)),
        ("state", json!("gone")),
        ("status", json!("weird")),
    ] {
        let mut other = handoff.clone();
        other[field] = bad;
        assert_eq!(handoff_turn(&other), None, "{field}");
    }
}

#[test]
fn a_refusal_that_carries_the_handoff_answers_it_with_its_code() {
    let body = json!({ "error": { "code": "handoff.turn_running", "message": "busy" },
                       "handoff": { "id": HANDOFF, "sessionId": "s-1", "machine": VM, "turn": 3, "state": "open", "status": "running" } });
    let (origin, seen) = fake(move |_| Some((409, body.to_string())));
    let answer = go(&request(
        &origin,
        Auth::Owner,
        "owner.handoff_begin_turn",
        json!({ "id": HANDOFF, "after": 2 }),
    ))
    .unwrap();
    assert_eq!(answer["turn"], 3);
    assert_eq!(answer["refusal"], "handoff.turn_running");
    assert_eq!(seen.lock().unwrap()[0].json(), json!({ "after": 2 }));
    // Another refusal, even with a hand-off, is the route's error.
    let other = json!({ "error": { "code": "auth.unauthenticated", "message": "sign in" },
                        "handoff": { "id": HANDOFF, "sessionId": "s", "machine": VM, "turn": 1, "state": "open", "status": "done" } });
    let (origin, _seen) = fake(move |_| Some((401, other.to_string())));
    let failure = go(&request(
        &origin,
        Auth::Owner,
        "owner.handoff_begin_turn",
        json!({ "id": HANDOFF, "after": 0 }),
    ))
    .unwrap_err();
    assert_eq!(
        failure,
        Failure::http(401, Some("auth.unauthenticated".into()), Some("sign in".into()))
    );
}

#[test]
fn a_handoff_opens_only_for_a_session_and_machine_id() {
    let (origin, seen) = fake(|_| ok("{}"));
    let bad_session = request(
        &origin,
        Auth::Owner,
        "owner.handoff_open",
        json!({ "session": "a b", "machine": VM }),
    );
    assert_eq!(go(&bad_session), Err(Failure::Transport("not a session id".into())));
    let bad_machine = request(
        &origin,
        Auth::Owner,
        "owner.handoff_open",
        json!({ "session": "s-1", "machine": "a/b" }),
    );
    assert_eq!(go(&bad_machine), Err(Failure::Transport("not a Cloud machine id".into())));
    assert!(seen.lock().unwrap().is_empty());
}

#[test]
fn the_harness_login_copy_switch_decodes_plain_or_wrapped_and_caps_its_ttl() {
    assert_eq!(
        harness_login_copy(&json!({ "enabled": true, "ttlSeconds": 120 })).unwrap(),
        json!({ "enabled": true, "ttlSeconds": 120 })
    );
    assert_eq!(
        harness_login_copy(&json!({ "ok": true, "value": { "enabled": false, "ttlSeconds": 60 } }))
            .unwrap(),
        json!({ "enabled": false, "ttlSeconds": 60 })
    );
    // A ttl longer than five minutes is cut to five: the switch always takes effect within that.
    assert_eq!(
        harness_login_copy(&json!({ "enabled": true, "ttlSeconds": 86400 })).unwrap()["ttlSeconds"],
        300
    );
    assert!(harness_login_copy(&json!({ "enabled": "yes" })).is_err());
}

#[test]
fn the_github_app_status_says_why() {
    let state = |status: u16, text: &str| github_app_state(status, text.as_bytes());
    assert_eq!(
        state(
            200,
            r#"{"configured":true,"app_slug":"cmux","connection":{"status":"active","account_login":"acme"}}"#
        ),
        "ready"
    );
    for (status, text, want) in [
        (200, r#"{"configured":true,"app_slug":"cmux","connection":null}"#, "not_connected"),
        (
            200,
            r#"{"configured":true,"app_slug":"cmux","allowed":false,"connection":{"status":"active"}}"#,
            "unknown",
        ),
        (
            200,
            r#"{"configured":true,"app_slug":"cmux","allowed":true,"connection":{"status":"active"}}"#,
            "ready",
        ),
        (
            200,
            r#"{"configured":true,"app_slug":"cmux","connection":{"status":"needs_reauth"}}"#,
            "not_connected",
        ),
        (200, r#"{"configured":false,"app_slug":null,"connection":null}"#, "not_configured"),
        (
            404,
            r#"{"error":{"code":"integration.not_found","message":"no GitHub connection"}}"#,
            "not_connected",
        ),
        (
            503,
            r#"{"error":{"code":"integration.unavailable","message":"GitHub App is not configured"}}"#,
            "unknown",
        ),
        (401, r#"{"error":{"code":"auth.unauthenticated","message":"sign in"}}"#, "unknown"),
        (200, r#"{"connection":{"status":"active"}}"#, "unknown"),
        (200, r#"{"configured":true,"app_slug":"","connection":{"status":"active"}}"#, "unknown"),
        (200, r#"{"configured":true,"connection":{"status":"active"}}"#, "unknown"),
        (
            200,
            r#"{"configured":true,"app_slug":" \n","connection":{"status":"active"}}"#,
            "unknown",
        ),
        (200, "not json", "unknown"),
        (502, "", "unknown"),
    ] {
        assert_eq!(state(status, text), want, "{text}");
    }
}

#[test]
fn only_a_team_id_reaches_the_github_status_url_and_no_team_header_is_sent() {
    let (origin, seen) = fake(|_| ok(r#"{"configured":false}"#));
    let answer =
        go(&request(&origin, Auth::Owner, "owner.github_app", json!({ "team": "team_01HZX9" })))
            .unwrap();
    assert_eq!(answer, json!({ "state": "not_configured" }));
    for other in
        ["", "team_", "01HZX9", "team_a&b=c", "team_a/../x", "team_a b", "TEAM_a", "team_a\n"]
    {
        let answer =
            go(&request(&origin, Auth::Owner, "owner.github_app", json!({ "team": other })))
                .unwrap();
        assert_eq!(answer, json!({ "state": "unknown" }), "{other:?}");
    }
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 1);
    assert_eq!(seen[0].target(), "GET /v1/integrations/github/status?team=team_01HZX9");
    assert_eq!(seen[0].header("x-cmux-team"), None);
}

// MARK: transport

#[test]
fn a_base_url_is_https_or_loopback_http_with_no_user_query_or_fragment() {
    assert!(base_url("https://cmux.com").is_ok());
    assert!(base_url("https://cmux.com/prefix/").is_ok());
    assert!(base_url("http://127.0.0.1:9").is_ok());
    assert!(base_url("http://localhost:3000").is_ok());
    for bad in [
        "http://cmux.com",
        "https://u:p@cmux.com",
        "https://cmux.com?x=1",
        "ftp://cmux.com",
        "cmux.com",
    ] {
        assert!(base_url(bad).is_err(), "{bad}");
    }
}

#[test]
fn a_base_path_is_kept() {
    let (origin, seen) = fake(|_| ok(r#"{"domains":[]}"#));
    go(&request(&format!("{origin}/prefix/"), Auth::Stack, "vm.domains", json!({}))).unwrap();
    assert_eq!(seen.lock().unwrap()[0].target(), "GET /prefix/api/vm/domains");
}

#[test]
fn a_local_backend_that_is_not_running_is_no_backend() {
    let port = TcpListener::bind("127.0.0.1:0").unwrap().local_addr().unwrap().port();
    let mut call =
        request(&format!("http://127.0.0.1:{port}"), Auth::Stack, "vm.domains", json!({}));
    call.local_only = true;
    assert_eq!(go(&call), Err(Failure::NoBackend));
    call.local_only = false;
    assert!(matches!(go(&call), Err(Failure::Transport(_))));
}

#[test]
fn a_refusal_never_carries_a_credential_back() {
    let mut call = request("https://x.invalid", Auth::Stack, "vm.domains", json!({}));
    call.credential = "secret-access".into();
    call.refresh = Some("secret-refresh".into());
    let line = scrub(
        answer_line(&Err(Failure::Transport("echo secret-access secret-refresh".into()))),
        &call,
    );
    assert!(!line.contains("secret-access") && !line.contains("secret-refresh"), "{line}");
}

#[test]
fn the_answer_line_is_the_apps_error_cases() {
    let line: Value = serde_json::from_str(&answer_line(&Ok(json!([1])))).unwrap();
    assert_eq!(line, json!({ "ok": true, "body": [1] }));
    let line: Value =
        serde_json::from_str(&answer_line(&Err(Failure::TimedOut("/api/runs".into())))).unwrap();
    assert_eq!(line, json!({ "ok": false, "error": { "kind": "timed_out", "path": "/api/runs" } }));
    let line: Value =
        serde_json::from_str(&answer_line(&Err(Failure::http(409, Some("c".into()), None))))
            .unwrap();
    assert_eq!(
        line["error"],
        json!({ "kind": "http", "status": 409, "code": "c", "message": null, "action": null, "trace_id": null })
    );
}

#[test]
fn an_unknown_call_or_a_request_that_is_not_one_runs_nothing() {
    assert!(parse(b"{}").is_err());
    assert!(
        parse(br#"{"call":"vm.domains","api":"x","auth":"stack","credential":"c","extra":1}"#)
            .is_err()
    );
    let (origin, seen) = fake(|_| ok("{}"));
    assert!(matches!(
        go(&request(&origin, Auth::Stack, "vm.nothing", json!({}))),
        Err(Failure::Transport(_))
    ));
    assert!(seen.lock().unwrap().is_empty());
}

// MARK: machine routes (CloudWorkerMachineFilesTests, CloudMachineIOTests)

#[test]
fn a_classic_machine_execs_and_writes_on_its_api_vm_routes() {
    let (origin, seen) = fake(|s| {
        if s.line.contains("/exec") {
            ok(r#"{"exitCode":0,"stdout":"ok","stderr":""}"#)
        } else {
            ok("{}")
        }
    });
    let exec = go(&request(
        &origin,
        Auth::Stack,
        "machine.io",
        json!({ "op": "exec", "machine": "m1", "command": "true", "timeout_ms": 8000 }),
    ))
    .unwrap();
    assert_eq!(exec["stdout"], "ok");
    go(&request(&origin, Auth::Stack, "machine.io",
        json!({ "op": "write", "machine": "m1", "path": "/a b", "data_base64": "aGk=", "mode": 384 }))).unwrap();
    go(&request(
        &origin,
        Auth::Stack,
        "machine.io",
        json!({ "op": "stat", "machine": "m1", "path": "/a b" }),
    ))
    .unwrap();
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), "POST /api/vm/m1/exec");
    assert_eq!(seen[0].json(), json!({ "command": "true", "timeoutMs": 8000 }));
    assert_eq!(seen[0].header("x-stack-refresh-token").as_deref(), Some("refresh"));
    assert_eq!(seen[1].target(), "POST /api/vm/m1/fs/write");
    assert_eq!(seen[1].json(), json!({ "path": "/a b", "dataBase64": "aGk=", "mode": 384 }));
    assert_eq!(seen[2].target(), "GET /api/vm/m1/fs/stat?path=%2Fa+b");
}

#[test]
fn a_worker_machines_proxied_call_sends_the_persons_session_and_cmux_team() {
    // Not a Worker machine id, so machine-io takes the cmux API's own route (no client session).
    let (origin, seen) = fake(|_| ok(r#"{"exitCode":0,"stdout":"ok","stderr":""}"#));
    let mut call = request(
        &origin,
        Auth::Worker,
        "machine.io",
        json!({ "op": "exec", "machine": "m1", "command": "true", "timeout_ms": 8000 }),
    );
    call.team = Some("team_cmux".into());
    call.credential = "session-access".into();
    let exec = go(&call).unwrap();
    assert_eq!(exec["stdout"], "ok");
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), "POST /v1/cloud/machines/m1/exec");
    assert_eq!(seen[0].header("authorization").as_deref(), Some("Bearer session-access"));
    assert_eq!(seen[0].header("x-cmux-team").as_deref(), Some("team_cmux"));
    assert_eq!(
        seen[0].header("x-stack-refresh-token"),
        None,
        "the Stack refresh token never goes to the Worker"
    );
}

#[test]
fn a_machine_io_answer_reads_as_its_routes() {
    let path = "/v1/cloud/machines/vm_x/fs/stat";
    let ok_line =
        json!({ "route": "direct", "status": 200, "code": null, "body": { "kind": "file" } });
    assert_eq!(machine::read(&ok_line, path).unwrap(), json!({ "kind": "file" }));
    let refused = json!({ "route": "proxy", "status": 404, "code": "vm_file_not_found",
                          "body": { "ok": false, "error": { "code": "vm_file_not_found", "message": "no such file: /a" } } });
    assert_eq!(
        machine::read(&refused, path).unwrap_err(),
        Failure::http(404, Some("vm_file_not_found".into()), Some("no such file: /a".into()))
    );
    let late = json!({ "route": "proxy", "status": 0, "code": "timed_out", "body": null });
    assert_eq!(machine::read(&late, path).unwrap_err(), Failure::TimedOut(path.into()));
    let gone = json!({ "route": "proxy", "status": 0, "code": "transport", "body": null });
    assert_eq!(machine::read(&gone, path).unwrap_err(), Failure::Transport("transport".into()));
}

#[test]
fn a_worker_machine_call_needs_a_bare_secure_origin() {
    let call = request(
        "http://cmux.example",
        Auth::Worker,
        "machine.io",
        json!({ "op": "stat", "machine": VM, "path": "/a" }),
    );
    assert!(matches!(go(&call), Err(Failure::Transport(_))));
}

// MARK: previews (CloudPreviewShareLinkTests, CloudLivePreviewTests)

const LINK: &str = r#"{"link":{"linkId":"link_123","creator":"user_1","team":"team_1","machine":"vm_abc","port":3000,"hostname":"preview.example","ruleId":"rule_1","createdAt":1700000000000,"expiresAt":1700086400000,"maxUses":null,"redemptions":0,"revokedAt":null},"url":"https://preview.example/?cmux_share=secret"}"#;

#[test]
fn a_preview_link_is_created_and_revoked_on_the_platform_with_the_persons_session_and_team() {
    let (origin, seen) =
        fake(|s| if s.line.starts_with("POST") { ok(LINK) } else { ok(r#"{"revoked":true}"#) });
    let mut call = request(
        &origin,
        Auth::Worker,
        "previews.create_link",
        json!({ "machine": "vm_abc", "port": 3000 }),
    );
    call.team = Some("team_1".into());
    let created = go(&call).unwrap();
    assert_eq!(created["link"]["linkId"], "link_123");
    assert_eq!(created["url"], "https://preview.example/?cmux_share=secret");
    call.call = "previews.revoke_link".into();
    call.args = json!({ "machine": "vm_abc", "port": 3000, "linkId": "link_123" })
        .as_object()
        .cloned()
        .unwrap();
    assert_eq!(go(&call).unwrap(), json!({ "revoked": true }));
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].target(), "POST /v1/cloud/machines/vm_abc/previews/3000/links");
    assert_eq!(seen[0].json(), json!({}));
    assert_eq!(seen[0].header("authorization").as_deref(), Some("Bearer access"));
    assert_eq!(seen[0].header("x-cmux-team").as_deref(), Some("team_1"));
    assert_eq!(seen[1].target(), "DELETE /v1/cloud/machines/vm_abc/previews/3000/links/link_123");
}

#[test]
fn a_preview_refresh_answers_the_catalog_and_a_refusal_its_code() {
    let catalog = r#"{"machine":"vm_abc","listening":[3000],"previews":[{"port":3000,"origin":"https://p.example","url":"https://p.example/?t=1","expiresAt":1}],"unavailable":[]}"#;
    let (origin, seen) = fake(move |_| ok(catalog));
    let answer =
        go(&request(&origin, Auth::Worker, "previews.refresh", json!({ "machine": "vm_abc" })))
            .unwrap();
    assert_eq!(answer["listening"], json!([3000]));
    assert_eq!(seen.lock().unwrap()[0].target(), "POST /v1/cloud/machines/vm_abc/previews/refresh");
    let (origin, _seen) = fake(|_| {
        Some((404, r#"{"_tag":"NotFound","code":"machine.not_found","message":"gone"}"#.into()))
    });
    let failure =
        go(&request(&origin, Auth::Worker, "previews.refresh", json!({ "machine": "vm_abc" })))
            .unwrap_err();
    assert_eq!(failure, Failure::http(404, Some("machine.not_found".into()), Some("gone".into())));
}

#[test]
fn only_store_handoff_ids_reach_the_path() {
    assert!(is_handoff_id("ho_0123456789abcdef0123"));
    assert!(!is_handoff_id("ho_../../v1/cloud"));
    assert!(!is_handoff_id("ho_0123456789ABCDEF0123"));
}

#[test]
fn every_listed_call_is_one_perform_answers() {
    for call in CALLS {
        for auth in [Auth::Stack, Auth::Owner, Auth::Worker] {
            let result = go(&request("http://127.0.0.1:1", auth, call, json!({})));
            if let Err(Failure::Transport(message)) = &result {
                assert!(!message.starts_with("no cloud api call"), "{call}: {message}");
            }
        }
    }
    let unknown = go(&request("http://127.0.0.1:1", Auth::Stack, "vm.nope", json!({})));
    assert!(matches!(unknown, Err(Failure::Transport(m)) if m.starts_with("no cloud api call")));
}

#[test]
fn a_sandboxed_runs_longest_wait_is_its_whole_bound() {
    let sandbox =
        request("https://cmux.com", Auth::Stack, "runs.sandbox", json!({ "timeoutMs": 1_000_000 }));
    assert_eq!(longest(&sandbox), Duration::from_millis(1_000_000 + 180_000 + 60_000));
    let domains = request("https://cmux.com", Auth::Stack, "vm.domains", json!({}));
    assert_eq!(longest(&domains), Duration::from_secs(960));
}

#[test]
fn a_failure_reads_as_one_line_and_names_its_kind() {
    let failure = Failure::http(409, Some("vm_busy".into()), Some("busy".into()));
    assert_eq!(failure.kind(), "http");
    assert_eq!(failure.to_string(), "the Cloud API refused the call: 409 vm_busy: busy");
    assert_eq!(Failure::NoBackend.kind(), failure_kind(&Failure::NoBackend));
}

fn failure_kind(failure: &Failure) -> String {
    failure.json()["kind"].as_str().unwrap_or_default().to_owned()
}

// MARK: review findings (#37350)

#[test]
fn a_keyed_start_refusal_that_echoes_the_key_carries_no_service_text() {
    let (origin, _seen) = fake(|seen| {
        let echoed = String::from_utf8_lossy(&seen.body).trim().to_owned();
        Some((
            409,
            json!({ "ok": false, "error": { "code": echoed, "message": echoed } }).to_string(),
        ))
    });
    let key = b"person-key-line\n".to_vec();
    let call = request(
        &origin,
        Auth::Owner,
        "owner.acpmux_keyed_start",
        json!({ "machine": VM, "key_length": key.len() }),
    );
    let failure = go_with(&call, key).unwrap_err();
    assert_eq!(failure, Failure::http(409, None, None));
    let text = format!("{} {}", failure, failure.json());
    assert!(!text.contains("person-key"), "{text}");
}

#[test]
fn an_answer_over_the_limit_is_refused_while_it_is_read() {
    let big = format!(r#"{{"domains":"{}"}}"#, "x".repeat(MAX_ANSWER_BYTES));
    let (origin, _seen) = fake(move |_| ok(&big));
    let failure = go(&request(&origin, Auth::Stack, "vm.domains", json!({}))).unwrap_err();
    assert!(
        matches!(&failure, Failure::Transport(message) if message.contains("larger than")),
        "{failure:?}"
    );
}

#[test]
fn a_success_is_never_scrubbed_whatever_its_field_order() {
    let call = request("https://cmux.com", Auth::Stack, "vm.domains", json!({}));
    let line = answer_line(&Ok(json!({ "note": "access" })));
    assert_eq!(scrub(line.clone(), &call), line);
    let refusal = answer_line(&Err(Failure::Transport("echo access".into())));
    assert!(!scrub(refusal, &call).contains("echo access"));
}

/// An origin on a loopback port nothing listens on.
fn closed_origin() -> String {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    drop(listener);
    origin
}

#[test]
fn a_local_stack_that_is_not_running_is_no_backend_for_previews() {
    let mut call =
        request(&closed_origin(), Auth::Worker, "previews.refresh", json!({ "machine": "vm_abc" }));
    call.local_only = true;
    assert_eq!(go(&call), Err(Failure::NoBackend));
    call.local_only = false;
    assert!(matches!(go(&call), Err(Failure::Transport(_))));
}

#[test]
fn a_local_stack_that_is_not_running_is_no_backend_for_a_worker_machine_io() {
    let args = json!({ "op": "exec", "machine": VM, "command": "true", "route": "proxy" });
    let mut call = request(&closed_origin(), Auth::Worker, "machine.io", args);
    call.local_only = true;
    assert_eq!(go(&call), Err(Failure::NoBackend));
    call.local_only = false;
    assert!(matches!(go(&call), Err(Failure::Transport(_))));
}

// MARK: review follow-ups (#37350)

#[test]
fn a_preview_call_ends_at_its_own_30_second_deadline() {
    assert_eq!(previews::PREVIEW_TIMEOUT, Duration::from_secs(30));
    // A server that takes each request and never answers.
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    std::thread::spawn(move || {
        let mut held = Vec::new();
        for stream in listener.incoming().flatten() {
            held.push(stream);
        }
    });
    for (call, args) in [
        ("previews.refresh", json!({ "machine": "vm_abc" })),
        ("previews.create_link", json!({ "machine": "vm_abc", "port": 3000 })),
        ("previews.revoke_link", json!({ "machine": "vm_abc", "port": 3000, "linkId": "l1" })),
    ] {
        // Paused time: the runtime moves its clock to the next deadline while it waits.
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .start_paused(true)
            .build()
            .unwrap();
        let call = request(&origin, Auth::Worker, call, args);
        let (failure, waited) = runtime.block_on(async {
            let started = tokio::time::Instant::now();
            let failure = perform(&call, Zeroizing::new(Vec::new())).await.unwrap_err();
            (failure, started.elapsed())
        });
        assert!(matches!(failure, Failure::TimedOut(_)), "{}: {failure:?}", call.call);
        assert!(
            waited >= Duration::from_secs(30) && waited < Duration::from_secs(60),
            "{}: {waited:?}",
            call.call
        );
    }
}

#[test]
fn owner_handoffs_reads_at_most_50_pages() {
    let (origin, seen) = fake(|_| ok(r#"{"handoffs":[{"id":"h"}],"nextCursor":"next"}"#));
    let answer =
        go(&request(&origin, Auth::Owner, "owner.handoffs", json!({ "pages": 100_000 }))).unwrap();
    assert_eq!(answer.as_array().map(Vec::len), Some(50));
    assert_eq!(seen.lock().unwrap().len(), 50);
}

#[test]
fn owner_handoffs_stops_at_the_answer_limit() {
    let page = format!(
        r#"{{"handoffs":[{{"id":"h","note":"{}"}}],"nextCursor":"next"}}"#,
        "x".repeat(MAX_ANSWER_BYTES / 3)
    );
    let (origin, seen) = fake(move |_| ok(&page));
    let failure = go(&request(&origin, Auth::Owner, "owner.handoffs", json!({}))).unwrap_err();
    assert!(
        matches!(&failure, Failure::Transport(message) if message.contains("larger than")),
        "{failure:?}"
    );
    assert_eq!(seen.lock().unwrap().len(), 3, "refused at the page that passed the limit");
}

#[test]
fn a_run_start_that_is_not_one_is_refused_as_it_is_and_sends_nothing() {
    let (origin, seen) = fake(|_| ok(r#"{"id":"run_1"}"#));
    for args in [json!({ "idempotencyKey": "k" }), json!({ "task": "hi" })] {
        let failure = go(&request(&origin, Auth::Stack, "runs.start", args)).unwrap_err();
        assert!(
            matches!(&failure, Failure::Transport(message) if message.starts_with("the call needs")),
            "{failure:?}"
        );
    }
    assert!(seen.lock().unwrap().is_empty());
}

// MARK: review follow-ups (#37526)

#[test]
fn a_preview_refusal_is_read_within_the_calls_one_deadline() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .start_paused(true)
        .build()
        .unwrap();
    runtime.block_on(async {
        let started = tokio::time::Instant::now();
        let deadline = started + previews::PREVIEW_TIMEOUT;
        // The answer takes 25 s, then its refusal's body 20 s more: 30 s in all, not 45.
        let sent = async {
            tokio::time::sleep(Duration::from_secs(25)).await;
            Err::<Value, ()>(())
        };
        let failure = previews::within(deadline, "/p".into(), sent, |()| async {
            tokio::time::sleep(Duration::from_secs(20)).await;
            Failure::http(500, None, None)
        })
        .await
        .unwrap_err();
        assert_eq!(failure, Failure::TimedOut("/p".into()));
        assert_eq!(started.elapsed(), Duration::from_secs(30));

        // A refusal read in time is the refusal.
        let started = tokio::time::Instant::now();
        let deadline = started + previews::PREVIEW_TIMEOUT;
        let sent = async {
            tokio::time::sleep(Duration::from_secs(25)).await;
            Err::<Value, ()>(())
        };
        let failure = previews::within(deadline, "/p".into(), sent, |()| async {
            tokio::time::sleep(Duration::from_secs(4)).await;
            Failure::http(500, None, None)
        })
        .await
        .unwrap_err();
        assert_eq!(failure, Failure::http(500, None, None));
    });
}
