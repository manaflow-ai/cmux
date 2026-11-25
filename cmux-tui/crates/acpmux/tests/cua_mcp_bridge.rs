//! `acpmux cua-mcp` (the Computer Use helper v2 bridge, `cua_v2.rs`) as a
//! real process: it reads `endpoint.json` from `CMUX_NEXT_CUA_V2_DIR`,
//! connects to the helper socket named there, and sends the per-launch
//! secret first. A stand-in helper (a Unix listener in this test process)
//! records what reaches it.
//!
//! The bridge must not trust an `endpoint.json` that another user could have
//! written or read (fleet Macs run several slot users on one Mac): with a
//! group- or world-accessible file it refuses before it connects, so no
//! secret reaches any socket. A private file of this user connects, the
//! peer uid (this test's own) passes, and the secret is sent.
//! The other-user socket case needs a second account (bead cx-8coo).
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process starts no agent.
const HERMETIC: daemon_env::Process = daemon_env::Process::deny()
    .with_env(&[("CMUX_CUA_ALLOWED_TARGET_BUNDLE_IDS", "com.apple.Terminal")]);

use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const SECRET: &str = "00112233445566778899aabbccddeeff";

struct Dir(PathBuf);

impl Dir {
    fn new(tag: &str) -> Dir {
        let nanos = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().subsec_nanos();
        let path = PathBuf::from("/tmp").join(format!("acpx-{tag}-{}-{nanos}", std::process::id()));
        std::fs::create_dir(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        Dir(path)
    }
}

impl Drop for Dir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// Writes endpoint.json with `mode` and starts a stand-in helper on `h.sock`
/// that records the first line it gets and answers the MCP bridge.
fn stand_in(dir: &Path, mode: u32) -> std::sync::mpsc::Receiver<String> {
    let socket = dir.join("h.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let endpoint = dir.join("endpoint.json");
    std::fs::write(
        &endpoint,
        json!({"protocol": 1, "socket": socket, "secret": SECRET}).to_string(),
    )
    .unwrap();
    std::fs::set_permissions(&endpoint, std::fs::Permissions::from_mode(mode)).unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let consent_home = dir.to_owned();
    std::thread::spawn(move || {
        let Ok((stream, _)) = listener.accept() else { return };
        let mut writer = stream.try_clone().unwrap();
        let mut lines = BufReader::new(stream).lines();
        let Some(Ok(first)) = lines.next() else { return };
        let _ = tx.send(first);
        writeln!(writer, "{}", json!({"ok": true, "protocol": 1})).unwrap();
        while let Some(Ok(line)) = lines.next() {
            let request: Value = serde_json::from_str(&line).unwrap();
            if request["method"] == "machine/consent" {
                let required = consent_home.join("machine-credential.json").exists()
                    || consent_home.join("consent.json").exists();
                let consent = std::fs::read(consent_home.join("consent.json"))
                    .ok()
                    .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
                    .unwrap_or(json!({"screen":"none", "control":"none"}));
                writeln!(
                    writer,
                    "{}",
                    json!({"id":request["id"], "ok":true,
                    "result":{"consentRequired":required,"consent":consent}})
                )
                .unwrap();
                continue;
            }
            if request["method"] == "tools/list" {
                let inventory = std::fs::read(consent_home.join("inventory.json"))
                    .ok()
                    .and_then(|bytes| serde_json::from_slice::<Value>(&bytes).ok())
                    .unwrap_or(json!([
                        {"name":"stand_in_tool", "inputSchema":{"type":"object"}},
                        {"name":"screenshot", "annotations":{"readOnlyHint":true}},
                        {"name":"driver_observation", "annotations":{"readOnlyHint":true}},
                        {"name":"click", "annotations":{"readOnlyHint":false}}
                    ]));
                writeln!(writer, "{}", json!({"id":request["id"],"ok":true,"result":inventory}))
                    .unwrap();
                continue;
            }
            let _ = tx.send(line);
            let reply = json!({"id": request["id"], "ok": true,
                "result": [{"name": "stand_in_tool", "inputSchema": {"type": "object"}}]});
            writeln!(writer, "{reply}").unwrap();
        }
    });
    rx
}

/// Runs `acpmux cua-mcp` for one `tools/list` and returns its reply.
fn tools_list(dir: &Path) -> Value {
    let mut child = daemon_env::acpmux(dir)
        .arg("cua-mcp")
        .env("CMUX_NEXT_CUA_V2_DIR", dir)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    writeln!(stdin, "{}", json!({"jsonrpc": "2.0", "id": 1, "method": "tools/list"})).unwrap();
    drop(stdin);
    let out = child.wait_with_output().unwrap();
    let text = String::from_utf8(out.stdout).unwrap();
    serde_json::from_str(text.lines().next().expect("a reply line")).unwrap()
}

#[test]
fn an_endpoint_file_other_users_can_read_is_refused_before_any_secret_is_sent() {
    let dir = Dir::new("open");
    let received = stand_in(&dir.0, 0o644);
    let reply = tools_list(&dir.0);
    let message = reply["error"]["message"].as_str().unwrap_or_default();
    assert!(message.contains("not private to this user"), "reply: {reply}");
    assert!(
        received.recv_timeout(Duration::from_millis(500)).is_err(),
        "the bridge connected and sent a line to the socket"
    );
}

#[test]
fn a_private_endpoint_file_of_this_user_reaches_the_helper_with_the_secret() {
    let dir = Dir::new("private");
    let received = stand_in(&dir.0, 0o600);
    let reply = tools_list(&dir.0);
    assert_eq!(reply["result"]["tools"][0]["name"], "stand_in_tool", "reply: {reply}");
    let first: Value =
        serde_json::from_str(&received.recv_timeout(Duration::from_secs(5)).unwrap()).unwrap();
    assert_eq!(first, json!({"secret": SECRET}));
}

fn machine_state(dir: &Path, screen: &str, control: &str) {
    for (name, body) in [
        (
            "machine-credential.json",
            json!({"credential":"cmm_test", "machine_id":"test", "team_id":"team", "name":"test", "hub_origin":"https://example.com", "last_heartbeat":null,"revoked":false,"wgPublicKey":"key"}),
        ),
        ("consent.json", json!({"screen":screen,"control":control})),
    ] {
        let path = dir.join(name);
        std::fs::write(&path, body.to_string()).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600)).unwrap();
    }
}

/// The connection predates join and remains open through grants and revocation.
/// A control grant must never implicitly grant screen capture, including a
/// screenshot returned after a click or a future unknown operation.
#[test]
fn an_open_bridge_rechecks_independent_screen_consent_on_every_call() {
    let dir = Dir::new("consent");
    let _received = stand_in(&dir.0, 0o600);
    let mut child = daemon_env::acpmux(&dir.0)
        .arg("cua-mcp")
        .env("CMUX_NEXT_CUA_V2_DIR", &dir.0)
        .env("ACPMUX_HOME", dir.0.join("empty-agent-controlled-home"))
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut input = child.stdin.take().unwrap();
    let mut output = BufReader::new(child.stdout.take().unwrap());
    let mut id = 0;
    let mut call = |name: &str| {
        id += 1;
        writeln!(input, "{}", json!({"jsonrpc":"2.0","id":id,"method":"tools/call","params":{"name":name,"arguments":{}}})).unwrap();
        input.flush().unwrap();
        let mut line = String::new();
        output.read_line(&mut line).unwrap();
        serde_json::from_str::<Value>(&line).unwrap()
    };
    assert_ne!(call("screenshot")["result"]["isError"], true);
    machine_state(&dir.0, "none", "granted");
    for name in ["screenshot", "get_desktop_state", "click", "future_capture_action"] {
        let result = call(name);
        assert_eq!(result["result"]["isError"], true, "{name}: {result}");
        assert!(result.to_string().contains("consent_required"));
    }
    machine_state(&dir.0, "granted", "none");
    assert_ne!(call("screenshot")["result"]["isError"], true);
    assert_ne!(call("driver_observation")["result"]["isError"], true);
    assert_eq!(call("click")["result"]["isError"], true);
    // Inventory, not a familiar tool name, determines whether this is read-only.
    std::fs::write(
        dir.0.join("inventory.json"),
        json!({"tools":[{"name":"screenshot","annotations":{"readOnlyHint":false}}]}).to_string(),
    )
    .unwrap();
    assert_eq!(call("screenshot")["result"]["isError"], true);
    assert_eq!(call("unlisted_tool")["result"]["isError"], true);
    machine_state(&dir.0, "granted", "granted");
    assert_ne!(call("click")["result"]["isError"], true);
    machine_state(&dir.0, "none", "granted");
    assert_eq!(call("click")["result"]["isError"], true);
    drop(input);
    assert!(child.wait().unwrap().success());
}

#[test]
fn target_scope_cannot_come_from_bridge_env_or_model_arguments() {
    for scope in [Some("com.cmuxterm.app.debug.guard-test,com.apple.Terminal"), None] {
        let dir = Dir::new("target-scope");
        let received = stand_in(&dir.0, 0o600);
        let mut command = daemon_env::acpmux(&dir.0);
        command
            .arg("cua-mcp")
            .env("CMUX_NEXT_CUA_V2_DIR", &dir.0)
            .env_remove("CMUX_CUA_ALLOWED_TARGET_BUNDLE_IDS")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        if let Some(scope) = scope {
            command.env("CMUX_CUA_ALLOWED_TARGET_BUNDLE_IDS", scope);
        }
        let mut child = command.spawn().unwrap();
        let mut stdin = child.stdin.take().unwrap();
        let arguments = json!({"pid": 42,
            "allowed_target_bundle_ids": "com.cmuxterm.app",
            "_cua_allowed_target_bundle_ids": ["com.cmuxterm.app"]});
        writeln!(
            stdin,
            "{}",
            json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "click", "arguments": arguments,
                "allowed_target_bundle_ids": "com.cmuxterm.app"}})
        )
        .unwrap();
        drop(stdin);
        let output = child.wait_with_output().unwrap();
        assert!(output.status.success());
        let _hello = received.recv_timeout(Duration::from_secs(5)).unwrap();
        let request: Value =
            serde_json::from_str(&received.recv_timeout(Duration::from_secs(5)).unwrap()).unwrap();
        assert!(request.get("allowed_target_bundle_ids").is_none(), "request: {request}");
        assert_eq!(request["arguments"], arguments);
    }
}

#[tokio::test]
async fn in_memory_target_scope_cannot_come_from_the_bridge_or_arguments() {
    use acpmux::cua_v2::Helper;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

    assert_eq!(std::env::var("CMUX_CUA_ALLOWED_TARGET_BUNDLE_IDS").unwrap(), "com.apple.Terminal");
    let (client, server) = tokio::io::duplex(4096);
    let peer = tokio::spawn(async move {
        let mut server = tokio::io::BufReader::new(server);
        let mut line = String::new();
        server.read_line(&mut line).await.unwrap();
        let hello: Value = serde_json::from_str(&line).unwrap();
        assert_eq!(hello, json!({"secret": SECRET}));
        server.get_mut().write_all(b"{\"ok\":true,\"protocol\":1}\n").await.unwrap();
        line.clear();
        server.read_line(&mut line).await.unwrap();
        let mut request: Value = serde_json::from_str(&line).unwrap();
        if request["method"] == "machine/consent" {
            let reply = json!({"id":request["id"],"ok":true,"result":{"consentRequired":false,"consent":{"screen":"none","control":"none"}}});
            server.get_mut().write_all(format!("{reply}\n").as_bytes()).await.unwrap();
            line.clear();
            server.read_line(&mut line).await.unwrap();
            request = serde_json::from_str(&line).unwrap();
        }
        let reply = json!({"id": request["id"], "ok": true, "result": {"accepted": true}});
        server.get_mut().write_all(format!("{reply}\n").as_bytes()).await.unwrap();
        request
    });
    let mut helper = Helper::admit(client, SECRET).await.unwrap();
    let arguments = json!({"pid": 42, "allowed_target_bundle_ids": "com.apple.Terminal",
        "_cua_allowed_target_bundle_ids": ["com.apple.Terminal"]});
    let result = helper.request("tools/call", Some("click"), arguments.clone()).await.unwrap();
    assert_eq!(result, json!({"accepted": true}));
    let request = peer.await.unwrap();
    assert_eq!(
        request,
        json!({"id": request["id"], "method": "tools/call", "name": "click", "arguments": arguments})
    );
}

#[tokio::test]
async fn missing_failed_or_malformed_host_consent_never_forwards_a_tool() {
    use acpmux::cua_v2::Helper;
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
    for reply in [
        json!({"ok":false,"error":"unknown method"}),
        json!({"ok":true,"result":{}}),
        json!({"ok":true,"result":{"consentRequired":"false","consent":{"screen":"granted","control":"granted"}}}),
        json!({"ok":true,"result":{"consentRequired":false,"consent":{"screen":"invalid","control":"granted"}}}),
        json!({"ok":true,"result":{"consentRequired":true,"consent":{"screen":"none","control":"granted"}}}),
    ] {
        let (client, server) = tokio::io::duplex(4096);
        let peer = tokio::spawn(async move {
            let mut server = tokio::io::BufReader::new(server);
            let mut line = String::new();
            server.read_line(&mut line).await.unwrap();
            server.get_mut().write_all(b"{\"ok\":true,\"protocol\":1}\n").await.unwrap();
            line.clear();
            server.read_line(&mut line).await.unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["method"], "machine/consent");
            let mut reply = reply;
            reply["id"] = request["id"].clone();
            server.get_mut().write_all(format!("{reply}\n").as_bytes()).await.unwrap();
            line.clear();
            assert_eq!(
                server.read_line(&mut line).await.unwrap(),
                0,
                "no tool may reach the helper"
            );
        });
        let mut helper = Helper::admit(client, SECRET).await.unwrap();
        assert_eq!(
            helper.request("tools/call", Some("click"), json!({})).await.unwrap_err().to_string(),
            "consent_required"
        );
        drop(helper);
        peer.await.unwrap();
    }
}
