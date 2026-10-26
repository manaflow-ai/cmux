//! REMOTE-SANDBOX (decisions.md D-R): a remote chain's Claude Code runs in
//! the macOS Seatbelt sandbox (`sandbox/remote-chain.sb`), after a canary
//! proved the sandbox at spawn; its settings ask before every acting tool.
//! Its Bash (any child) cannot write outside the allowed folders or reach a
//! loopback port. Off macOS a remote chain does not run Claude Code at all.
//! A local session's Claude spawns as before.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().with_env(&[
    ("ANTHROPIC_AUTH_TOKEN", "synthetic-daemon-token"),
    ("CMUX_REMOTE_TEST_SECRET", "synthetic-cmux-secret"),
    ("LC_API_TOKEN", "synthetic-locale-shaped-secret"),
    ("SSH_AUTH_SOCK", "/synthetic/ssh-agent.sock"),
    ("UNRELATED_TOKEN", "synthetic-unrelated-token"),
]);

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::{Origin, serve_connection_with};
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;
use tokio::sync::mpsc;

const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_claude.py");
const FAKE_AGENT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

fn dir(tag: &str) -> PathBuf {
    let d = std::env::temp_dir().join(format!("ars-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&d);
    std::fs::create_dir_all(d.join("work")).unwrap();
    std::fs::canonicalize(&d).unwrap()
}

fn hub_with(d: &Path, vm_host: Option<bool>) -> Arc<Hub> {
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {
            "fakeclaude": {
                "argv": ["python3", FAKE_CLAUDE],
                "kind": "claude-stdio",
                "env": {
                    "ANTHROPIC_AUTH_TOKEN": "synthetic-profile-token",
                    "REMOTE_PROFILE_VALUE": "profile-authorized",
                    "FAKE_KEYCHAIN_PATH": d.join("work/test.keychain-db")
                }
            },
            "fakeacp": {
                "argv": ["python3", FAKE_AGENT],
                "family": "sample",
                "env": {
                    "FAKE_ASK_MODE": "1",
                    "REMOTE_PROFILE_VALUE": "profile-authorized",
                    "__ACPMUX_REMOTE_ENV_CLEARED": "profile-collision"
                }
            }
        },
        "defaultHarness": "fakeclaude",
        "permissionPolicy": "ask",
        "webRoots": [d.join("work")],
        "webAskingModes": {"sample": ["ask"]},
        "vmHost": vm_host,
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    // `_acpmux/vm_host` writes here, and reads the creation marker under
    // `d/root` (`mark`), never this machine's own `/etc/cmux`.
    cfg.path = Some(d.join("home/config.json"));
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    hub.set_vm_marker_root(d.join("root"));
    hub
}

fn hub(d: &Path) -> Arc<Hub> {
    hub_with(d, None)
}

/// Writes the creation marker cmux writes on a VM it made (`owner`), or a
/// team VM's (`team`), under the hub's marker root.
fn mark(d: &Path, kind: &str) {
    let etc = d.join("root/etc/cmux");
    std::fs::create_dir_all(&etc).unwrap();
    std::fs::write(etc.join("vm-kind"), format!("{kind}\n")).unwrap();
}

struct Client(mpsc::Sender<String>, mpsc::Receiver<String>, i64);

impl Client {
    fn new(hub: &Arc<Hub>, origin: Origin) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        Client(in_tx, out_rx, 0)
    }

    async fn call(&mut self, m: &str, params: Value) -> Value {
        self.2 += 1;
        let id = self.2;
        self.0.send(Message::request(id, m, params).to_line()).await.unwrap();
        loop {
            let line = tokio::time::timeout(Duration::from_secs(30), self.1.recv())
                .await
                .unwrap()
                .unwrap();
            let v: Value = serde_json::from_str(&line).unwrap();
            if v.get("id") == Some(&json!(id)) {
                return v;
            }
        }
    }

    /// A new session in `d/work` and one prompt; the error of whichever
    /// failed, else the text the agent streamed for the prompt.
    async fn run(&mut self, d: &Path, text: &str) -> Result<String, Value> {
        self.run_harness(d, None, text).await
    }

    async fn run_harness(
        &mut self,
        d: &Path,
        harness: Option<&str>,
        text: &str,
    ) -> Result<String, Value> {
        let mut params = json!({"cwd": d.join("work"), "mcpServers": []});
        if let Some(harness) = harness {
            params["_meta"] = json!({"acpmux": {"harness": harness}});
        }
        let r = self.call("session/new", params).await;
        let Some(s) = r["result"]["sessionId"].as_str().map(str::to_owned) else {
            return Err(r);
        };
        let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": text}]});
        let r = self.call("session/prompt", p).await;
        if r.get("error").is_some() {
            return Err(r);
        }
        let e = self.call("_acpmux/events", json!({"sessionId": s, "limit": 1000})).await;
        Ok(e["result"]["events"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|e| {
                e.pointer("/msg/params/update/sessionUpdate") == Some(&json!("agent_message_chunk"))
            })
            .filter_map(|e| e.pointer("/msg/params/update/content/text").and_then(Value::as_str))
            .collect())
    }
}

#[tokio::test]
async fn every_remote_harness_inherits_only_its_explicit_environment() {
    let d = dir("acp-environment");
    let hub = hub_with(&d, Some(true));
    let prompt = "envs: CMUX_REMOTE_TEST_SECRET,LC_API_TOKEN,SSH_AUTH_SOCK,UNRELATED_TOKEN,REMOTE_PROFILE_VALUE,HOME,PATH";
    let mut web = Client::new(&hub, Origin::Web);
    let remote: Value = serde_json::from_str(
        &web.run_harness(&d, Some("fakeacp"), prompt).await.unwrap_or_else(|e| panic!("{e}")),
    )
    .unwrap();
    assert_eq!(remote["REMOTE_PROFILE_VALUE"], "profile-authorized");
    for dropped in ["CMUX_REMOTE_TEST_SECRET", "LC_API_TOKEN", "SSH_AUTH_SOCK", "UNRELATED_TOKEN"] {
        assert_eq!(remote[dropped], "", "remote ACP child inherited {dropped}: {remote}");
    }
    assert!(remote["HOME"].as_str().is_some_and(|v| !v.is_empty()), "{remote}");
    assert!(remote["PATH"].as_str().is_some_and(|v| !v.is_empty()), "{remote}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_remote_claude_gets_only_the_selected_login_credential() {
    let d = dir("login-credential");
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fakeclaude": {
            "argv": ["python3", FAKE_CLAUDE],
            "kind": "claude-stdio"
        }},
        "defaultHarness": "fakeclaude",
        "permissionPolicy": "ask",
        "webRoots": [d.join("work")],
        "vmHost": true
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let mut web = Client::new(&hub, Origin::Web);
    let remote: Value = serde_json::from_str(
        &web.run(&d, "envs: ANTHROPIC_AUTH_TOKEN,UNRELATED_TOKEN")
            .await
            .unwrap_or_else(|e| panic!("{e}")),
    )
    .unwrap();
    assert_eq!(remote["ANTHROPIC_AUTH_TOKEN"], "synthetic-daemon-token");
    assert_eq!(remote["UNRELATED_TOKEN"], "");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_remote_chain_inherits_only_profile_and_safe_base_environment() {
    let d = dir("environment");
    // Off macOS, vmHost is the sandbox boundary and still needs the same
    // least-authority process environment. A Mac keeps Seatbelt too.
    let hub = hub_with(&d, Some(true));
    let names = [
        "ANTHROPIC_AUTH_TOKEN",
        "CMUX_REMOTE_TEST_SECRET",
        "LC_API_TOKEN",
        "SSH_AUTH_SOCK",
        "UNRELATED_TOKEN",
        "REMOTE_PROFILE_VALUE",
        "HOME",
        "PATH",
    ];
    let prompt = format!("envs: {}", names.join(","));

    let mut local = Client::new(&hub, Origin::Local);
    let inherited: Value =
        serde_json::from_str(&local.run(&d, &prompt).await.unwrap_or_else(|e| panic!("{e}")))
            .unwrap();
    assert_eq!(inherited["CMUX_REMOTE_TEST_SECRET"], "synthetic-cmux-secret");
    assert_eq!(inherited["SSH_AUTH_SOCK"], "/synthetic/ssh-agent.sock");
    assert_eq!(inherited["UNRELATED_TOKEN"], "synthetic-unrelated-token");

    let mut web = Client::new(&hub, Origin::Web);
    let remote: Value =
        serde_json::from_str(&web.run(&d, &prompt).await.unwrap_or_else(|e| panic!("{e}")))
            .unwrap();
    assert_eq!(remote["ANTHROPIC_AUTH_TOKEN"], "synthetic-profile-token");
    assert_eq!(remote["REMOTE_PROFILE_VALUE"], "profile-authorized");
    for dropped in ["CMUX_REMOTE_TEST_SECRET", "LC_API_TOKEN", "SSH_AUTH_SOCK", "UNRELATED_TOKEN"] {
        assert_eq!(remote[dropped], "", "remote child inherited {dropped}: {remote}");
    }
    assert!(remote["HOME"].as_str().is_some_and(|v| !v.is_empty()), "{remote}");
    assert!(remote["PATH"].as_str().is_some_and(|v| !v.is_empty()), "{remote}");
    let _ = std::fs::remove_dir_all(&d);
}

#[tokio::test]
async fn a_local_session_spawns_claude_without_the_remote_settings() {
    let d = dir("local");
    let hub = hub(&d);
    let mut local = Client::new(&hub, Origin::Local);
    let argv = local.run(&d, "argv").await.unwrap_or_else(|e| panic!("{e}"));
    assert!(!argv.contains("--settings"), "{argv}");
    let _ = std::fs::remove_dir_all(&d);
}

/// A VM cmux created (an owner marker, no `vmHost` key) runs a remote chain's
/// Claude Code with the VM as the sandbox; `_acpmux/vm_host` turns that off
/// and on again for the next session, with no restart.
#[cfg(not(target_os = "macos"))]
#[tokio::test]
async fn on_a_vm_cmux_created_remote_claude_runs_until_the_toggle_turns_it_off() {
    let d = dir("cmux-vm");
    mark(&d, "owner");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web);
    web.run(&d, "argv").await.unwrap_or_else(|e| panic!("on by default: {e}"));

    let mut local = Client::new(&hub, Origin::Local);
    let off = local.call("_acpmux/vm_host", json!({"on": false})).await;
    assert_eq!(off["result"]["vmHost"], false, "{off}");
    let e = web.run(&d, "argv").await.expect_err("off: a remote chain needs the sandbox again");
    assert!(e.to_string().contains("Seatbelt"), "{e}");

    let on = local.call("_acpmux/vm_host", json!({"on": true})).await;
    assert_eq!(on["result"]["vmHost"], true, "{on}");
    web.run(&d, "argv").await.unwrap_or_else(|e| panic!("on again: {e}"));
    let _ = std::fs::remove_dir_all(&d);
}

#[cfg(not(target_os = "macos"))]
#[tokio::test]
async fn off_macos_a_remote_chain_never_runs_claude_code() {
    let d = dir("nomac");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web);
    let r = web.run(&d, "argv").await;
    let e = r.expect_err("a remote chain ran Claude Code without the Seatbelt sandbox");
    assert!(e.to_string().contains("Seatbelt"), "{e}");
    let _ = std::fs::remove_dir_all(&d);
}

#[cfg(target_os = "macos")]
#[tokio::test]
async fn a_remote_chain_runs_claude_with_settings_that_ask_before_it_acts() {
    let d = dir("settings");
    let hub = hub(&d);
    let mut web = Client::new(&hub, Origin::Web);
    let argv: Vec<String> =
        serde_json::from_str(&web.run(&d, "argv").await.unwrap_or_else(|e| panic!("{e}"))).unwrap();
    let at = argv.iter().position(|a| a == "--settings").expect("--settings");
    let settings: Value = serde_json::from_str(&argv[at + 1]).unwrap();
    // Claude's own sandbox cannot nest in the profile: off; every acting
    // tool asks, over the user's allow rules.
    assert_eq!(settings["sandbox"]["enabled"], json!(false), "{settings}");
    assert_eq!(settings["sandbox"]["autoAllowBashIfSandboxed"], json!(false), "{settings}");
    let ask = settings["permissions"]["ask"].as_array().expect("ask rules");
    assert!(ask.contains(&json!("Bash")), "{settings}");
    let _ = std::fs::remove_dir_all(&d);
}

#[cfg(target_os = "macos")]
#[tokio::test]
async fn a_remote_chain_cannot_write_outside_its_folders_or_reach_a_loopback_port() {
    let d = dir("probe");
    let hub = hub(&d);
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    listener.set_nonblocking(true).unwrap();
    let port = listener.local_addr().unwrap().port();
    // Outside the session folder and the temporary folders. The name has a space, as a home under
    // `Application Support` does (cx-0o66n): the agent must read the whole path.
    let home = std::fs::canonicalize(dirs_home()).unwrap();
    let outside = home.join(format!(".acpmux test probe-{}", std::process::id()));
    let _ = std::fs::remove_file(&outside);
    let probe = format!("sandbox-probe {} {port}", outside.display());
    // The control: a local session's agent may do all three.
    let mut local = Client::new(&hub, Origin::Local);
    let seen: Value =
        serde_json::from_str(&local.run(&d, &probe).await.unwrap_or_else(|e| panic!("{e}")))
            .unwrap();
    assert_eq!(seen, json!({"outside": "allowed", "loopback": "allowed", "cwd": "allowed"}));
    let _ = std::fs::remove_file(&outside);
    // A remote chain's agent: only its folder.
    let mut web = Client::new(&hub, Origin::Web);
    let seen: Value =
        serde_json::from_str(&web.run(&d, &probe).await.unwrap_or_else(|e| panic!("{e}"))).unwrap();
    assert_eq!(seen, json!({"outside": "denied", "loopback": "denied", "cwd": "allowed"}));
    assert!(!outside.exists(), "the sandboxed agent wrote {}", outside.display());
    let _ = std::fs::remove_dir_all(&d);
}

#[cfg(target_os = "macos")]
fn dirs_home() -> PathBuf {
    PathBuf::from(std::env::var("HOME").expect("HOME"))
}

#[cfg(target_os = "macos")]
#[tokio::test]
async fn a_remote_chain_cannot_query_the_keychain() {
    let d = dir("keychain");
    let keychain = d.join("work/test.keychain-db");
    let created = std::process::Command::new("/usr/bin/security")
        .args(["create-keychain", "-p", "synthetic-password"])
        .arg(&keychain)
        .status()
        .unwrap();
    assert!(created.success());
    let added = std::process::Command::new("/usr/bin/security")
        .args([
            "add-generic-password",
            "-a",
            "synthetic-account",
            "-s",
            "synthetic-service",
            "-w",
            "synthetic-value",
        ])
        .arg(&keychain)
        .status()
        .unwrap();
    assert!(added.success());
    let hub = hub(&d);
    // The control: a local session's agent may.
    let mut local = Client::new(&hub, Origin::Local);
    let seen: Value = serde_json::from_str(
        &local.run(&d, "keychain-probe").await.unwrap_or_else(|e| panic!("{e}")),
    )
    .unwrap();
    assert_eq!(seen, json!({"keychain": "allowed"}));
    let mut web = Client::new(&hub, Origin::Web);
    let seen: Value = serde_json::from_str(
        &web.run(&d, "keychain-probe").await.unwrap_or_else(|e| panic!("{e}")),
    )
    .unwrap();
    assert_eq!(seen, json!({"keychain": "denied"}));
    let _ = std::fs::remove_dir_all(&d);
}

/// A harness that reaches its model through a proxy on this Mac (the `cmux`
/// harness's local relay, a loopback `ANTHROPIC_BASE_URL`): the remote
/// chain reaches exactly that port, and still no other loopback port
/// (cnx-ios parity round 2: such agents never answered from a phone).
#[cfg(target_os = "macos")]
#[tokio::test]
async fn a_remote_chain_reaches_its_own_loopback_model_proxy_and_nothing_else() {
    let d = dir("proxy");
    let proxy = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    proxy.set_nonblocking(true).unwrap();
    let proxy_port = proxy.local_addr().unwrap().port();
    let other = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    other.set_nonblocking(true).unwrap();
    let other_port = other.local_addr().unwrap().port();
    let mut cfg: Config = serde_json::from_value(json!({
        "harnesses": {"fakeclaude": {
            "argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio",
            "env": {"ANTHROPIC_BASE_URL": format!("http://127.0.0.1:{proxy_port}"), "ANTHROPIC_AUTH_TOKEN": "relay-key"},
        }},
        "defaultHarness": "fakeclaude",
        "permissionPolicy": "ask",
        "webRoots": [d.join("work")],
    }))
    .unwrap();
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);
    let outside = d.join("outside-probe");
    let mut web = Client::new(&hub, Origin::Web);
    let seen: Value = serde_json::from_str(
        &web.run(&d, &format!("sandbox-probe {} {proxy_port}", outside.display()))
            .await
            .unwrap_or_else(|e| panic!("{e}")),
    )
    .unwrap();
    assert_eq!(seen["loopback"], "allowed", "the model proxy port: {seen}");
    let mut web = Client::new(&hub, Origin::Web);
    let seen: Value = serde_json::from_str(
        &web.run(&d, &format!("sandbox-probe {} {other_port}", outside.display()))
            .await
            .unwrap_or_else(|e| panic!("{e}")),
    )
    .unwrap();
    assert_eq!(seen["loopback"], "denied", "another loopback port: {seen}");
    // The inline settings pin that endpoint and skip the user settings
    // source, whose env would replace the route's endpoint and key.
    let mut web = Client::new(&hub, Origin::Web);
    let argv: Vec<String> =
        serde_json::from_str(&web.run(&d, "argv").await.unwrap_or_else(|e| panic!("{e}"))).unwrap();
    let at = argv.iter().position(|a| a == "--settings").expect("--settings");
    let settings: Value = serde_json::from_str(&argv[at + 1]).unwrap();
    assert_eq!(settings["env"]["ANTHROPIC_BASE_URL"], format!("http://127.0.0.1:{proxy_port}"));
    let sources = argv.iter().position(|a| a == "--setting-sources").expect("--setting-sources");
    assert_eq!(argv[sources + 1], "project,local");
    let _ = std::fs::remove_dir_all(&d);
}
