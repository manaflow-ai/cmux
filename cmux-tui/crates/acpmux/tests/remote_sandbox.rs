//! REMOTE-SANDBOX (decisions.md D-R): a remote chain's Claude Code runs in
//! the macOS Seatbelt sandbox (`sandbox/remote-chain.sb`), after a canary
//! proved the sandbox at spawn; its settings ask before every acting tool.
//! Its Bash (any child) cannot write outside the allowed folders or reach a
//! loopback port. Linux enforces the same parsed policy with bwrap, seccomp,
//! the notify supervisor and the proxy. Other platforms refuse remote Claude.
//! A local session's Claude spawns as before.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process =
    daemon_env::Process::stand_in().keep(&["ACPMUX_REQUIRE_BWRAP"]).with_env(&[
        ("ANTHROPIC_AUTH_TOKEN", "synthetic-daemon-token"),
        ("CMUX_REMOTE_TEST_SECRET", "synthetic-cmux-secret"),
        ("LC_API_TOKEN", "synthetic-locale-shaped-secret"),
        ("SSH_AUTH_SOCK", "/synthetic/ssh-agent.sock"),
        ("UNRELATED_TOKEN", "synthetic-unrelated-token"),
    ]);

use acpmux::config::{Config, StoreMode};
use acpmux::hub::Hub;
use acpmux::rpc::Message;
use acpmux::server::peer_auth::PeerAuth;
use acpmux::server::{
    ConnAuth, Origin, WsAuth, bind_ws, serve_connection_authed, serve_connection_with,
    serve_ws_with,
};
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
#[cfg(target_os = "linux")]
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

    /// A connection with `auth` as its proof: `ConnAuth::Device` as `Origin::Peer` is a paired
    /// machine's `client` credential (`pairing::origin_of`).
    fn authed(hub: &Arc<Hub>, origin: Origin, auth: ConnAuth) -> Self {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(serve_connection_authed(hub.clone(), in_rx, out_tx, origin, auth));
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
    let hub = hub(&d);
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

/// A Mac (Seatbelt) only: Linux spawns remote Claude through the keeper, which
/// needs the acpmux binary, not this test process; the production-spawn test
/// (`support/remote_sandbox_linux_stack.rs`) checks the environment there.
#[cfg(target_os = "macos")]
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

/// A Mac only, as the login-credential test above.
#[cfg(target_os = "macos")]
#[tokio::test]
async fn a_remote_chain_inherits_only_profile_and_safe_base_environment() {
    let d = dir("environment");
    let hub = hub(&d);
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

/// Nothing the guest can write turns off the sandbox. A Cloud VM's agent user
/// has sudo, so it can write an owner `/etc/cmux/vm-kind` (with no `/srv/team`),
/// and as this user it can write config.json's `vmHost`. Either way a remote
/// chain's Claude Code still goes through the bwrap probe: with no bwrap the
/// spawn is refused, never run without the sandbox. (The canary with a real
/// bwrap: `support/remote_sandbox_linux_stack.rs`.)
#[cfg(target_os = "linux")]
#[tokio::test]
async fn a_guest_written_owner_marker_or_vm_host_never_skips_the_linux_sandbox() {
    for (tag, kind, vm_host) in [
        ("owner-marker", Some("owner"), None),
        ("config-vm-host", None, Some(true)),
        ("owner-and-config", Some("owner"), Some(true)),
    ] {
        let d = dir(tag);
        if let Some(kind) = kind {
            mark(&d, kind);
        }
        let hub = hub_with(&d, vm_host);
        hub.set_linux_bwrap_probe_for_tests(d.join("missing-bwrap"));
        let mut web = Client::new(&hub, Origin::Web);
        let Err(e) = web.run(&d, "argv").await else {
            panic!("{tag}: remote Claude ran without the sandbox");
        };
        assert!(e.to_string().contains("remote.sandbox_refused"), "{tag}: {e}");
        assert!(e.to_string().contains("bwrap unavailable"), "{tag}: {e}");
        let mut local = Client::new(&hub, Origin::Local);
        let view = local.call("_acpmux/vm_host", json!({})).await;
        let _ = std::fs::remove_dir_all(&d);
        // It takes a caller's boundary, but no caller asked for one: sandboxed.
        assert_eq!(view["result"]["vmHost"], cfg!(target_os = "linux"), "{tag}: {view}");
        assert_eq!(view["result"]["cmuxVm"], kind.is_some(), "{tag}: shown: {view}");
    }
}

/// A `session/new` with this `_meta.acpmux.vmBoundary` (true asks for the VM
/// boundary), in the `work` folder, with `policy` if given.
#[cfg(target_os = "linux")]
fn vm_boundary_new(d: &Path, vm_boundary: Option<Value>, policy: Option<&str>) -> Value {
    let mut mux = json!({});
    if let Some(vm_boundary) = vm_boundary {
        mux["vmBoundary"] = vm_boundary;
    }
    let mut p = json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": mux}});
    if let Some(policy) = policy {
        p["policy"] = json!(policy);
    }
    p
}

/// A remote chain's Claude Code runs without bwrap only when its caller asked
/// for the VM boundary over its peer link (`hub/vm_boundary.rs`). With no
/// bwrap here, the sandboxed spawn is refused, so a reply means it ran
/// without the sandbox. The same field from a Web connection, the field's
/// absence, another value, and the machine's own `vmHost: false` all keep
/// the sandbox; no marker or config value is needed or used.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn only_the_callers_vm_boundary_over_its_peer_link_skips_the_linux_sandbox() {
    for (tag, origin, sandbox, vm_host, runs) in [
        ("vmb-peer", Origin::Peer, Some(json!(true)), None, true),
        ("vmb-peer-vmhost-true", Origin::Peer, Some(json!(true)), Some(true), true),
        ("vmb-peer-off", Origin::Peer, Some(json!(true)), Some(false), false),
        ("vmb-peer-none", Origin::Peer, None, None, false),
        ("vmb-peer-other", Origin::Peer, Some(json!("true")), None, false),
        ("vmb-web", Origin::Web, Some(json!(true)), None, false),
    ] {
        let d = dir(tag);
        let hub = hub_with(&d, vm_host);
        hub.set_linux_bwrap_probe_for_tests(d.join("missing-bwrap"));
        let mut c = Client::new(&hub, origin);
        let r = c.call("session/new", vm_boundary_new(&d, sandbox, None)).await;
        let session = r["result"]["sessionId"].as_str().map(str::to_owned);
        let reply = match &session {
            Some(s) => {
                let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": "argv"}]});
                c.call("session/prompt", p).await
            }
            None => r,
        };
        let events = match &session {
            Some(s) => c.call("_acpmux/events", json!({"sessionId": s, "limit": 1000})).await,
            None => json!({}),
        };
        // A Web client never controls an agent that runs unsandboxed (`remote_floor.rs`).
        let web_prompt = match (&session, runs) {
            (Some(s), true) => {
                let mut web = Client::new(&hub, Origin::Web);
                let p = json!({"sessionId": s, "prompt": [{"type": "text", "text": "argv"}]});
                web.call("session/prompt", p).await
            }
            _ => json!({}),
        };
        let _ = std::fs::remove_dir_all(&d);
        if runs {
            assert!(reply.get("error").is_none(), "{tag}: {reply}");
            let events = events["result"]["events"].as_array().unwrap();
            let marked = events
                .iter()
                .any(|e| e["kind"] == "remote_sandbox" && e["msg"]["vmBoundary"] == true);
            assert!(marked, "{tag}: no vmBoundary record: {events:?}");
            // Everything but the platform sandbox: its settings and no MCP servers.
            let argv: String = events
                .iter()
                .filter_map(|e| {
                    e.pointer("/msg/params/update/content/text").and_then(Value::as_str)
                })
                .collect();
            for flag in ["--settings", "--strict-mcp-config", "disableBypassPermissionsMode"] {
                assert!(argv.contains(flag), "{tag}: no {flag}: {argv}");
            }
            let refused = web_prompt.to_string();
            assert!(refused.contains("remote.unsandboxed_agent"), "{tag}: {refused}");
        } else {
            let e = reply.to_string();
            assert!(e.contains("remote.sandbox_refused"), "{tag}: {e}");
            assert!(e.contains("bwrap unavailable"), "{tag}: {e}");
        }
    }
}

/// Only the person's own clients control a session at the VM boundary. A paired machine's
/// `client` credential (served as a peer, `ConnAuth::Device`), and a peer forwarding for one
/// (`via: device`), are held to the Web's rules for it (`Hub::refuse_at_vm_boundary`): no prompt
/// and no fork, model change, cancel or warm start; reads stay. A Web client likewise. A
/// paired machine never turns vmHost back on either.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn a_paired_machine_or_web_client_only_reads_a_session_at_the_vm_boundary() {
    let d = dir("vmb-device");
    let hub = hub_with(&d, None);
    hub.set_linux_bwrap_probe_for_tests(d.join("missing-bwrap"));
    let mut owner = Client::new(&hub, Origin::Peer);
    let r = owner.call("session/new", vm_boundary_new(&d, Some(json!(true)), None)).await;
    let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    let prompt = |extra: Value| {
        let mut p = json!({"sessionId": id, "prompt": [{"type": "text", "text": "argv"}]});
        if !extra.is_null() {
            p["_meta"] = extra;
        }
        p
    };
    let ran = owner.call("session/prompt", prompt(Value::Null)).await;
    let mut device = Client::authed(&hub, Origin::Peer, ConnAuth::Device);
    let device_prompt = device.call("session/prompt", prompt(Value::Null)).await;
    let device_fork = device
        .call("session/fork", json!({"sessionId": id, "cwd": d.join("work"), "mcpServers": []}))
        .await;
    let mut forwarded = Client::new(&hub, Origin::Peer);
    let forwarded_prompt =
        forwarded.call("session/prompt", prompt(json!({"acpmux": {"via": "device"}}))).await;
    // Nothing but reads: no model change, no cancel, no warm start, for a paired machine or
    // a Web client; reads stay.
    let mut web = Client::new(&hub, Origin::Web);
    let model = json!({"sessionId": id, "modelId": "other"});
    let device_model = device.call("session/set_model", model.clone()).await;
    let web_model = web.call("session/set_model", model).await;
    let device_cancel = device.call("session/cancel", json!({"sessionId": id})).await;
    let warm = json!({"sessionIds": [id]});
    let device_warm = device.call("_acpmux/warm", warm.clone()).await;
    let web_warm = web.call("_acpmux/warm", warm.clone()).await;
    let owner_warm = owner.call("_acpmux/warm", warm).await;
    let device_read = device.call("_acpmux/events", json!({"sessionId": id, "limit": 5})).await;
    let device_on = device.call("_acpmux/vm_host", json!({"on": true})).await;
    let owner_on = owner.call("_acpmux/vm_host", json!({"on": true})).await;
    let sessions = hub.sessions().len();
    let _ = std::fs::remove_dir_all(&d);
    assert!(ran.get("error").is_none(), "the owner's own prompt: {ran}");
    for (what, r) in [("device prompt", &device_prompt), ("forwarded prompt", &forwarded_prompt)] {
        assert!(r.to_string().contains("remote.unsandboxed_agent"), "{what}: {r}");
    }
    assert!(device_fork.to_string().contains("remote.unsandboxed_agent"), "fork: {device_fork}");
    assert_eq!(sessions, 1, "a fork of the boundary session started");
    for (what, r) in [
        ("device model", &device_model),
        ("web model", &web_model),
        ("device cancel", &device_cancel),
    ] {
        assert!(r.to_string().contains("remote.unsandboxed_agent"), "{what}: {r}");
    }
    let warmed = |r: &Value| r["result"]["warmed"].to_string().contains(&id);
    assert!(!warmed(&device_warm), "device warm: {device_warm}");
    assert!(!warmed(&web_warm), "web warm: {web_warm}");
    assert!(warmed(&owner_warm), "owner warm: {owner_warm}");
    assert!(device_read.get("error").is_none(), "a read stays: {device_read}");
    assert!(device_on.to_string().contains("vmHost.remote"), "{device_on}");
    assert!(owner_on.get("error").is_none(), "{owner_on}");
}

/// A request that is not the owner's is pinned to the session its name named when it was
/// admitted (`Hub::refuse_at_vm_boundary`): a rename that makes the name a boundary session's
/// while it waits never moves it there, and a key that names several sessions is refused. A
/// new chat may take any name. And it never shuts down a daemon that runs one.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn a_non_owner_request_keeps_its_session_and_never_stops_the_boundary() {
    use acpmux::hub::Control;
    let d = dir("vmb-pin");
    let hub = hub_with(&d, None);
    let new = |name: &str, vm_boundary: bool| {
        let mut p = vm_boundary_new(&d, vm_boundary.then_some(json!(true)), None);
        p["_meta"]["acpmux"]["harness"] = json!("fakeacp");
        p["_meta"]["acpmux"]["name"] = json!(name);
        p
    };
    let mut owner = Client::new(&hub, Origin::Peer);
    let r = owner.call("session/new", new("boundary-one", true)).await;
    let boundary = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    let r = owner.call("session/new", new("plain", false)).await;
    let plain = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{r}")).to_owned();
    let mut params = json!({"session": "plain", "modelId": "other"});
    let admitted = hub.refuse_at_vm_boundary(
        ConnAuth::Device,
        Control::Peer,
        "session/set_model",
        &mut params,
    );
    let mut local = Client::new(&hub, Origin::Local);
    for (id, to) in [(&plain, "plain-old"), (&boundary, "plain")] {
        let r = local.call("_acpmux/rename", json!({"sessionId": id, "newName": to})).await;
        assert!(r.get("error").is_none(), "{r}");
    }
    // Now "plain" (the boundary session) and "plain-old" share the prefix "pla": a key that
    // names several is refused, so no rename can make it the boundary session's alone.
    let mut ambiguous = json!({"session": "pla", "modelId": "other"});
    let refused = hub.refuse_at_vm_boundary(
        ConnAuth::Device,
        Control::Peer,
        "session/set_model",
        &mut ambiguous,
    );
    // A new chat's name is its own: one whose name the boundary session's resolves to still
    // starts ("pla" names the boundary session too, with "plain-old").
    let mut device = Client::authed(&hub, Origin::Peer, ConnAuth::Device);
    let named = device.call("session/new", new("pla", false)).await;
    let shutdown = device.call("_acpmux/shutdown", json!({"endAgents": true})).await;
    let _ = std::fs::remove_dir_all(&d);
    assert!(refused.is_err(), "an ambiguous key was admitted: {ambiguous}");
    assert!(named["result"]["sessionId"].is_string(), "{named}");
    assert!(admitted.is_ok(), "{admitted:?}");
    assert_eq!(params["sessionId"], json!(plain), "not pinned: {params}");
    assert!(boundary != plain);
    assert!(shutdown.to_string().contains("remote.unsandboxed_agent"), "{shutdown}");
}

/// Approve-all follows the caller's VM boundary under vmHost's old rule: the
/// owner's peer daemon's session with no policy runs approve-all; one with a
/// policy keeps it, and without the boundary it asks. An ACP harness, so no
/// sandbox decides whether the session starts.
#[cfg(target_os = "linux")]
#[tokio::test]
async fn the_callers_vm_boundary_starts_a_peer_session_with_no_policy_approve_all() {
    for (tag, sandbox, vm_host, policy, want) in [
        ("vmb-approve", Some(json!(true)), None, None, "approve-all"),
        ("vmb-asked", Some(json!(true)), None, Some("ask"), "ask"),
        ("vmb-none", None, None, None, "ask"),
        ("vmb-off", Some(json!(true)), Some(false), None, "ask"),
    ] {
        let d = dir(tag);
        let hub = hub_with(&d, vm_host);
        let mut peer = Client::new(&hub, Origin::Peer);
        let mut new = vm_boundary_new(&d, sandbox, policy);
        new["_meta"]["acpmux"]["harness"] = json!("fakeacp");
        let r = peer.call("session/new", new).await;
        let id = r["result"]["sessionId"].as_str().unwrap_or_else(|| panic!("{tag}: {r}"));
        let mut local = Client::new(&hub, Origin::Local);
        let list = local.call("_acpmux/sessions", json!({})).await;
        let _ = std::fs::remove_dir_all(&d);
        let row = list["result"]["sessions"]
            .as_array()
            .unwrap()
            .iter()
            .find(|s| s["sessionId"] == id)
            .cloned()
            .unwrap_or_else(|| panic!("{tag}: {list}"));
        assert_eq!(row["policy"], want, "{tag}: {row}");
    }
}

/// The caller decides the VM boundary (`hub/vm_boundary.rs`): a Cloud link's
/// lease with `vmBoundary` (the Cloud API said this caller owns the VM) makes
/// each `session/new` the caller's own clients forward there carry it, and the
/// VM records it on the session. A lease without it never does, and neither
/// does a `vmBoundary` field the caller's client sent, nor a session a Web
/// client of the caller starts there (`via: web`).
#[tokio::test]
async fn only_a_vm_boundary_lease_starts_the_peers_sessions_at_the_vm_boundary() {
    for (tag, vm_boundary) in [("lease-vmb", true), ("lease-plain", false)] {
        let d = dir(tag);
        let vm = hub(&d);
        let home = d.join("peer-home");
        let auth = PeerAuth::create(&home).unwrap();
        let peer_token =
            std::fs::read_to_string(acpmux::server::peer_auth::token_path(&home)).unwrap();
        let l = bind_ws("127.0.0.1:0").await.unwrap();
        let port = l.local_addr().unwrap().port();
        let ws = WsAuth { local_app: None, peer: Some(Arc::new(auth)) };
        tokio::spawn(serve_ws_with(vm.clone(), l, "tok".into(), ws));

        let mac = hub(&d);
        let mut c = Client::new(&mac, Origin::Local);
        let mut lease = json!({"name": "cloud-vm", "url": format!("ws://127.0.0.1:{port}"),
            "token": "tok", "peerToken": peer_token, "wait": true});
        if vm_boundary {
            lease["vmBoundary"] = json!(true);
        }
        let r = c.call("_acpmux/peer_lease", lease).await;
        assert!(r.get("error").is_none(), "{tag}: {r}");
        let new = |name: &str| {
            json!({"cwd": d.join("work"), "mcpServers": [], "_meta": {"acpmux": {
                "peer": "cloud-vm", "harness": "fakeacp", "name": name, "vmBoundary": true}}})
        };
        let r = c.call("session/new", new("own")).await;
        assert!(r["result"]["sessionId"].is_string(), "{tag}: {r}");
        let mut web = Client::new(&mac, Origin::Web);
        let r = web.call("session/new", new("web")).await;
        assert!(r["result"]["sessionId"].is_string(), "{tag}: {r}");
        // A paired machine's `client` credential on the Mac (`ConnAuth::Device`): not the
        // person's own client, so not at the boundary, if the Mac forwards it at all.
        let mut device = Client::authed(&mac, Origin::Peer, ConnAuth::Device);
        let device_new = device.call("session/new", new("device")).await;
        let started: Vec<_> = vm.sessions().into_iter().map(|s| s.meta()).collect();
        let _ = std::fs::remove_dir_all(&d);
        let forwarded = usize::from(device_new["result"]["sessionId"].is_string());
        assert_eq!(started.len(), 2 + forwarded, "{tag}: {device_new}");
        for meta in &started {
            assert!(meta.remote_origin, "{tag}");
            let want = vm_boundary && meta.name == "own";
            assert_eq!(meta.vm_boundary, want, "{tag}: {}", meta.name);
        }
    }
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
#[tokio::test]
async fn unsupported_platform_never_runs_remote_claude_code() {
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

#[cfg(target_os = "linux")]
#[tokio::test]
async fn linux_unavailable_bwrap_refuses_the_spawn_with_its_reason() {
    let d = dir("missing-bwrap");
    let hub = hub_with(&d, Some(false));
    hub.set_linux_bwrap_probe_for_tests(d.join("missing-bwrap"));
    let mut web = Client::new(&hub, Origin::Web);
    let error = web.run(&d, "argv").await.expect_err("unavailable bwrap must refuse");
    let _ = std::fs::remove_dir_all(d);
    assert!(error.to_string().contains("remote.sandbox_refused"), "{error}");
    assert!(error.to_string().contains("bwrap unavailable"), "{error}");
    assert!(error.to_string().contains("bwrap not installed"), "{error}");
}

#[cfg(target_os = "linux")]
#[path = "support/remote_sandbox_linux_stack.rs"]
mod linux_stack;
