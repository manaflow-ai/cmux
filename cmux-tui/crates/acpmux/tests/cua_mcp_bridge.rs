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

/// What a current helper lists in its admission reply (`ConsentGate`).
const CAPABILITIES: [&str; 2] = ["machine-consent-gate-v1", "screen-lock-at-execution-v1"];
/// A current helper's admission reply line.
const HELLO: &str = "{\"ok\":true,\"protocol\":1,\"capabilities\":[\"machine-consent-gate-v1\",\"screen-lock-at-execution-v1\"]}\n";

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
        writeln!(writer, "{}", json!({"ok": true, "protocol": 1, "capabilities": CAPABILITIES}))
            .unwrap();
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

/// `acpmux cua-mcp`'s MCP loop run in this process (`serve_gated`) against the stand-in helper in
/// a folder, with the screen read as unlocked. The consent and target-scope fixtures test those
/// rules, not the lock, so they must pass on a locked Mac or one with no GUI session too (review
/// of #37239). The binary keeps its real lock read, which has its own test
/// (`a_tool_call_through_the_binary_follows_the_real_screen_lock`); nothing in the binary can be
/// told the screen is unlocked.
struct InProcessBridge {
    input: tokio::io::DuplexStream,
    output: tokio::io::BufReader<tokio::io::DuplexStream>,
    run: tokio::task::JoinHandle<anyhow::Result<()>>,
    next_id: u64,
}

impl InProcessBridge {
    fn start(dir: &Path) -> Self {
        let (input, bridge_in) = tokio::io::duplex(1 << 16);
        let (bridge_out, output) = tokio::io::duplex(1 << 16);
        let dir = dir.to_owned();
        let run = tokio::spawn(async move {
            acpmux::cua_v2::serve_gated(
                tokio::io::BufReader::new(bridge_in),
                bridge_out,
                || {
                    let dir = dir.clone();
                    async move {
                        acpmux::cua_v2::Helper::connect(&acpmux::cua_v2::read_endpoint(&dir)?).await
                    }
                },
                || false,
            )
            .await
        });
        InProcessBridge { input, output: tokio::io::BufReader::new(output), run, next_id: 0 }
    }

    /// Sends one `tools/call` and returns its reply.
    async fn call(&mut self, name: &str, arguments: Value) -> Value {
        use tokio::io::{AsyncBufReadExt, AsyncWriteExt};
        self.next_id += 1;
        let message = json!({"jsonrpc":"2.0","id":self.next_id,"method":"tools/call",
            "params":{"name":name,"arguments":arguments}});
        self.input.write_all(format!("{message}\n").as_bytes()).await.unwrap();
        let mut line = String::new();
        let read = self.output.read_line(&mut line);
        tokio::time::timeout(Duration::from_secs(20), read).await.unwrap().unwrap();
        serde_json::from_str(&line).unwrap()
    }

    async fn close(self) {
        drop(self.input);
        tokio::time::timeout(Duration::from_secs(20), self.run).await.unwrap().unwrap().unwrap();
    }
}

/// The connection predates join and remains open through grants and revocation.
/// A control grant must never implicitly grant screen capture, including a
/// screenshot returned after a click or a future unknown operation.
#[tokio::test]
async fn an_open_bridge_rechecks_independent_screen_consent_on_every_call() {
    let dir = Dir::new("consent");
    let _received = stand_in(&dir.0, 0o600);
    let mut bridge = InProcessBridge::start(&dir.0);
    assert_ne!(bridge.call("screenshot", json!({})).await["result"]["isError"], true);
    machine_state(&dir.0, "none", "granted");
    for name in ["screenshot", "get_desktop_state", "click", "future_capture_action"] {
        let result = bridge.call(name, json!({})).await;
        assert_eq!(result["result"]["isError"], true, "{name}: {result}");
        assert!(result.to_string().contains("consent_required"));
    }
    machine_state(&dir.0, "granted", "none");
    assert_ne!(bridge.call("screenshot", json!({})).await["result"]["isError"], true);
    assert_ne!(bridge.call("driver_observation", json!({})).await["result"]["isError"], true);
    assert_eq!(bridge.call("click", json!({})).await["result"]["isError"], true);
    // Inventory, not a familiar tool name, determines whether this is read-only.
    std::fs::write(
        dir.0.join("inventory.json"),
        json!({"tools":[{"name":"screenshot","annotations":{"readOnlyHint":false}}]}).to_string(),
    )
    .unwrap();
    assert_eq!(bridge.call("screenshot", json!({})).await["result"]["isError"], true);
    assert_eq!(bridge.call("unlisted_tool", json!({})).await["result"]["isError"], true);
    machine_state(&dir.0, "granted", "granted");
    assert_ne!(bridge.call("click", json!({})).await["result"]["isError"], true);
    machine_state(&dir.0, "none", "granted");
    assert_eq!(bridge.call("click", json!({})).await["result"]["isError"], true);
    bridge.close().await;
}

/// The bridge reads no target scope from its env (this process has one, `HERMETIC`) or from the
/// model's arguments: the request reaches the helper with the arguments as sent and no scope.
#[tokio::test]
async fn target_scope_cannot_come_from_bridge_env_or_model_arguments() {
    assert!(std::env::var("CMUX_CUA_ALLOWED_TARGET_BUNDLE_IDS").is_ok());
    let dir = Dir::new("target-scope");
    let received = stand_in(&dir.0, 0o600);
    let mut bridge = InProcessBridge::start(&dir.0);
    let arguments = json!({"pid": 42,
        "allowed_target_bundle_ids": "com.cmuxterm.app",
        "_cua_allowed_target_bundle_ids": ["com.cmuxterm.app"]});
    let reply = bridge.call("click", arguments.clone()).await;
    assert_ne!(reply["result"]["isError"], true, "{reply}");
    bridge.close().await;
    let _hello = received.recv_timeout(Duration::from_secs(5)).unwrap();
    let request: Value =
        serde_json::from_str(&received.recv_timeout(Duration::from_secs(5)).unwrap()).unwrap();
    assert!(request.get("allowed_target_bundle_ids").is_none(), "request: {request}");
    assert_eq!(request["arguments"], arguments);
}

/// The binary reads the real screen lock: a call it gets reaches the helper only while
/// `computer_use_held` says the screen is in use (unlocked, or not a Mac), and answers
/// `mac_locked` without connecting otherwise. This holds on whatever host runs it.
#[test]
fn a_tool_call_through_the_binary_follows_the_real_screen_lock() {
    let dir = Dir::new("real-lock");
    let received = stand_in(&dir.0, 0o600);
    let held = acpmux::mac_lock::computer_use_held();
    let mut child = daemon_env::acpmux(&dir.0)
        .arg("cua-mcp")
        .env("CMUX_NEXT_CUA_V2_DIR", &dir.0)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let mut stdin = child.stdin.take().unwrap();
    writeln!(
        stdin,
        "{}",
        json!({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
            "params": {"name": "click", "arguments": {"pid": 42}}})
    )
    .unwrap();
    drop(stdin);
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success());
    let text = String::from_utf8(output.stdout).unwrap();
    let reply: Value = serde_json::from_str(text.lines().next().expect("a reply line")).unwrap();
    if held {
        assert_eq!(reply["result"]["structuredContent"]["error"], "mac_locked", "{reply}");
        assert!(
            received.recv_timeout(Duration::from_millis(500)).is_err(),
            "a locked Mac connected to the helper"
        );
    } else {
        assert_ne!(reply["result"]["isError"], true, "{reply}");
        let _hello = received.recv_timeout(Duration::from_secs(5)).unwrap();
        let request: Value =
            serde_json::from_str(&received.recv_timeout(Duration::from_secs(5)).unwrap()).unwrap();
        assert_eq!(request["name"], "click", "{request}");
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
        server.get_mut().write_all(HELLO.as_bytes()).await.unwrap();
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
    let result =
        helper.request("tools/call", Some("click"), arguments.clone(), || false).await.unwrap();
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
            server.get_mut().write_all(HELLO.as_bytes()).await.unwrap();
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
            helper
                .request("tools/call", Some("click"), json!({}), || false)
                .await
                .unwrap_err()
                .to_string(),
            "consent_required"
        );
        drop(helper);
        peer.await.unwrap();
    }
}

/// A locked screen (design/lock-bridge.md, item 3): every tool call waits with the typed
/// `mac_locked` result and never reaches the helper, which is not even connected.
#[tokio::test]
async fn a_tool_call_while_the_mac_is_locked_answers_mac_locked_and_never_reaches_the_helper() {
    use acpmux::cua_v2::{Helper, serve_gated};
    use std::sync::atomic::{AtomicUsize, Ordering};

    let connects = AtomicUsize::new(0);
    let input = [
        json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"click","arguments":{"x":1,"y":2}}}),
        json!({"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"screenshot","arguments":{}}}),
    ]
    .iter()
    .map(|m| format!("{m}\n"))
    .collect::<String>();
    let mut output = Vec::new();
    serve_gated(
        tokio::io::BufReader::new(input.as_bytes()),
        &mut output,
        || {
            connects.fetch_add(1, Ordering::SeqCst);
            async { Err::<Helper<tokio::io::DuplexStream>, _>(anyhow::anyhow!("no helper")) }
        },
        || true,
    )
    .await
    .unwrap();
    let replies: Vec<Value> = String::from_utf8(output)
        .unwrap()
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(replies.len(), 2, "{replies:?}");
    for (reply, id) in replies.iter().zip([1, 2]) {
        assert_eq!(reply["id"], id);
        assert_eq!(reply["result"]["isError"], true);
        assert_eq!(reply["result"]["structuredContent"]["error"], "mac_locked", "{reply}");
    }
    assert_eq!(connects.load(Ordering::SeqCst), 0, "a locked Mac never connects to the helper");
}

/// The lock is read again at execution (review of #37239, F1): a call that passed the gate while
/// the screen was unlocked, then waited on the helper connection and the consent answer while the
/// Mac locked, answers `mac_locked` and is never sent to the helper.
#[tokio::test]
async fn a_call_whose_mac_locks_during_the_consent_wait_never_reaches_the_helper() {
    use acpmux::cua_v2::{Helper, serve_gated};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

    let locked = Arc::new(AtomicBool::new(false));
    let (client, server) = tokio::io::duplex(4096);
    let client = std::sync::Mutex::new(Some(client));
    let peer = tokio::spawn({
        let locked = locked.clone();
        async move {
            let mut server = tokio::io::BufReader::new(server);
            let mut line = String::new();
            server.read_line(&mut line).await.unwrap();
            server.get_mut().write_all(HELLO.as_bytes()).await.unwrap();
            line.clear();
            server.read_line(&mut line).await.unwrap();
            let request: Value = serde_json::from_str(&line).unwrap();
            assert_eq!(request["method"], "machine/consent");
            // The person locks the Mac while the consent answer is on its way, then it grants.
            locked.store(true, Ordering::SeqCst);
            let reply = json!({"id":request["id"],"ok":true,"result":{"consentRequired":true,
                "consent":{"screen":"granted","control":"granted"}}});
            server.get_mut().write_all(format!("{reply}\n").as_bytes()).await.unwrap();
            line.clear();
            assert_eq!(
                server.read_line(&mut line).await.unwrap(),
                0,
                "a call reached the helper: {line}"
            );
        }
    });
    let input = format!(
        "{}\n",
        json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"click","arguments":{"x":1,"y":2}}})
    );
    let mut output = Vec::new();
    serve_gated(
        tokio::io::BufReader::new(input.as_bytes()),
        &mut output,
        || {
            let stream = client.lock().unwrap().take();
            async move {
                Helper::admit(stream.ok_or_else(|| anyhow::anyhow!("one helper"))?, SECRET).await
            }
        },
        || locked.load(Ordering::SeqCst),
    )
    .await
    .unwrap();
    let reply: Value = serde_json::from_slice(&output).unwrap();
    assert_eq!(reply["id"], 1);
    assert_eq!(reply["result"]["structuredContent"]["error"], "mac_locked", "{reply}");
    peer.await.unwrap();
}

/// A v2 helper built before it read the screen lock at execution (review of #37239, round 8): a
/// call the bridge passed while unlocked could wait in it on consent or a takeover and run after
/// the Mac locked. Its admission reply does not list the lock capability, so the bridge sends it
/// no call: each one answers `cua_helper_outdated`, unlocked or not.
#[tokio::test]
async fn a_v2_helper_that_does_not_say_it_checks_the_lock_gets_no_call() {
    use acpmux::cua_v2::{Helper, serve_gated};
    use tokio::io::{AsyncBufReadExt, AsyncWriteExt};

    let (client, server) = tokio::io::duplex(4096);
    let client = std::sync::Mutex::new(Some(client));
    let peer = tokio::spawn(async move {
        let mut server = tokio::io::BufReader::new(server);
        let mut line = String::new();
        server.read_line(&mut line).await.unwrap();
        // What a helper built before the lock check answers.
        let hello = json!({"ok":true,"protocol":1,"capabilities":["machine-consent-gate-v1"]});
        server.get_mut().write_all(format!("{hello}\n").as_bytes()).await.unwrap();
        let mut calls = Vec::new();
        loop {
            line.clear();
            if server.read_line(&mut line).await.unwrap() == 0 {
                return calls;
            }
            let request: Value = serde_json::from_str(&line).unwrap();
            let reply = if request["method"] == "machine/consent" {
                json!({"id":request["id"],"ok":true,"result":{"consentRequired":true,
                    "consent":{"screen":"granted","control":"granted"}}})
            } else {
                calls.push(request.clone());
                json!({"id":request["id"],"ok":true,"result":{"content":[]}})
            };
            server.get_mut().write_all(format!("{reply}\n").as_bytes()).await.unwrap();
        }
    });
    let input = format!(
        "{}\n",
        json!({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"click","arguments":{"x":1,"y":2}}})
    );
    let mut output = Vec::new();
    serve_gated(
        tokio::io::BufReader::new(input.as_bytes()),
        &mut output,
        || {
            let stream = client.lock().unwrap().take();
            async move {
                Helper::admit(stream.ok_or_else(|| anyhow::anyhow!("one helper"))?, SECRET).await
            }
        },
        || false,
    )
    .await
    .unwrap();
    let reply: Value = serde_json::from_slice(&output).unwrap();
    assert_eq!(reply["id"], 1);
    assert_eq!(reply["result"]["isError"], true, "{reply}");
    assert_eq!(reply["result"]["structuredContent"]["error"], "cua_helper_outdated", "{reply}");
    let calls = peer.await.unwrap();
    assert!(calls.is_empty(), "the older helper got a call: {calls:?}");
}
