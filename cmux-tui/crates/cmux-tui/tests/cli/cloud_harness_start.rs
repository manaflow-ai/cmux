//! Every harness the Cloud chat picker offers, started on a fresh Cloud VM of
//! the caller's own (hq#11225). Leo, 2026-11-15: "so does cloud work? on our
//! thing? just automatically? or switching environments? claude and codex
//! alike, through gui? and other harnesses/etc too?"
//!
//! A start the app sends (`agent-session-start` with the harness the person
//! picked, `vm_kind: "owner"`, at the home folder as a new Cloud chat does)
//! either starts the chat, or, when that agent is not signed in on the VM, is
//! refused exactly `agent_session.sign_in_required` with `data.harness` naming
//! it, so the app offers that agent's own sign-in. Never a bare
//! `agent_session.refused`.
//!
//! Each run is a real daemon with its real acpmux on the test agent, whose
//! `FAKE_AUTH_FILE` stands for the agent's own sign-in: missing, it answers
//! `session/new` with ACP's auth_required (-32000 "Authentication required"),
//! as a real agent CLI does on a fresh VM.

use super::*;

/// The harnesses a Cloud chat's picker offers a sign-in for: the app's
/// `LOGIN_AGENTS` (webviews/src/agent-session/acpmux/cloudAgentLogin.ts), mirrored in
/// cmux-tui-core's `login_request` (server/agent_session_attach.rs). opencode is in the
/// picker too (no sign-in of its own there): it must start or say the same. A harness added
/// to the picker gets a row here.
const PICKER_HARNESSES: &[&str] = &["claude", "codex", "gemini", "grok", "cursor", "opencode"];

/// acpmux's config with every picker harness as the test agent under its own id (a
/// config.json entry takes the id over from PATH discovery), each with `env`.
fn picker_config(env: &Value) -> Value {
    let harnesses: serde_json::Map<String, Value> = PICKER_HARNESSES
        .iter()
        .map(|id| ((*id).to_owned(), json!({"argv": ["python3", FAKE_AGENT], "env": env})))
        .collect();
    json!({"harnesses": harnesses, "defaultHarness": "claude"})
}

/// The app's start of a new Cloud chat with `harness` on the caller's own VM: the home
/// folder (the chat gets its own trusted `~/chats/<id>`, #30363) and the owner word.
fn start_on_own_vm(vm: &Daemon, harness: &str) -> Value {
    let surface = vm.own_agent_tab();
    let home = vm.dir.join("home");
    vm.rpc(json!({"id": 60, "cmd": "agent-session-start", "surface": surface,
                  "harness": harness, "cwd": home.to_str().unwrap(), "vm_kind": "owner"}))
}

/// The precise refusal of a start whose agent is not signed in: the code, and `data`
/// naming the harness (never the agent's own words).
fn assert_sign_in_required(reply: &Value, harness: &str) {
    assert_eq!(reply["ok"], false, "{harness}: {reply}");
    assert_eq!(reply["error_code"], "agent_session.sign_in_required", "{harness}: {reply}");
    assert_eq!(reply["data"]["reason"], "agent.sign_in_required", "{harness}: {reply}");
    assert_eq!(reply["data"]["harness"], harness, "{harness}: {reply}");
    assert_eq!(reply["data"]["errorKind"], "auth.signed_out", "{harness}: {reply}");
}

/// A fresh VM, no agent signed in: every picker harness's start says
/// `sign_in_required` naming that harness, and no session is left behind.
#[test]
fn every_picker_harness_on_a_fresh_cloud_vm_says_sign_in_required_naming_it() {
    let config = picker_config(&json!({"FAKE_AUTH_FILE": "/nonexistent/cmux-test-auth"}));
    let vm = Daemon::start_in("pickout", None, Some(config), Some("owner"));
    for harness in PICKER_HARNESSES {
        let reply = start_on_own_vm(&vm, harness);
        assert_sign_in_required(&reply, harness);
    }
    assert_eq!(vm.acpmux_sessions(), 0, "a refused start left a session");
}

/// The same VM with every agent signed in: each picker harness's start answers a session.
#[test]
fn every_signed_in_picker_harness_starts_on_a_fresh_cloud_vm() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let auth = PathBuf::from("/tmp").join(format!("cmux-asx-auth-{}-{stamp}", std::process::id()));
    fs::write(&auth, "").unwrap();
    let config = picker_config(&json!({"FAKE_AUTH_FILE": auth.to_str().unwrap()}));
    let vm = Daemon::start_in("pickin", None, Some(config), Some("owner"));
    for harness in PICKER_HARNESSES {
        let reply = start_on_own_vm(&vm, harness);
        assert_eq!(reply["ok"], true, "{harness}: {reply}");
        assert!(
            reply["data"]["session"].as_str().is_some_and(|s| !s.is_empty()),
            "{harness}: {reply}"
        );
    }
    assert_eq!(vm.acpmux_sessions(), PICKER_HARNESSES.len());
    drop(vm);
    let _ = fs::remove_file(&auth);
}

/// An agent CLI that refuses to start at all when it is not signed in (it prints
/// "Authentication required" and exits before answering ACP's `initialize`, as some agent
/// CLIs do without a login) is the same refusal naming it, not a bare `refused`.
#[test]
fn a_picker_harness_that_dies_at_start_signed_out_says_sign_in_required_naming_it() {
    let config = json!({
        "harnesses": {"grok": {"argv": ["python3", FAKE_AGENT],
                               "env": {"FAKE_DIE_AT_START": "Authentication required"}}},
        "defaultHarness": "grok",
    });
    let vm = Daemon::start_in("pickdie", None, Some(config), Some("owner"));
    let reply = start_on_own_vm(&vm, "grok");
    assert_sign_in_required(&reply, "grok");
}

/// The test Claude Code (acpmux's stand-in for `claude -p`, no model sign-in).
const FAKE_CLAUDE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../acpmux/tests/fake_claude.py");

/// A Cloud VM of the caller's own whose acpmux runs Claude Code (the stand-in) at the
/// full-access start level. `IS_SANDBOX=1` lets it take Bypass permissions also when the test
/// runs as root, as on a Cloud VM, so a start that settles nothing stays in Bypass permissions.
fn cloud_claude_vm(name: &str) -> Daemon {
    let config = json!({
        "harnesses": {"claude": {"argv": ["python3", FAKE_CLAUDE], "kind": "claude-stdio",
                                 "family": "claude", "env": {"IS_SANDBOX": "1"}}},
        "defaultHarness": "claude",
        "defaultPermissionMode": "fullAccess",
    });
    Daemon::start_in(name, None, Some(config), Some("owner"))
}

/// The app's start of a new Cloud Claude chat with the person's start level
/// (`permission_mode`) and, if they picked one, a mode; the mode the chat runs in after it.
fn cloud_claude_start_mode(vm: &Daemon, permission_mode: &str, picked: Option<&str>) -> String {
    let surface = vm.own_agent_tab();
    let home = vm.dir.join("home");
    let mut start = json!({"id": 61, "cmd": "agent-session-start", "surface": surface,
                           "harness": "claude", "cwd": home.to_str().unwrap(), "vm_kind": "owner",
                           "permission_mode": permission_mode});
    if let Some(mode) = picked {
        start["mode"] = json!(mode);
    }
    let reply = vm.rpc(start);
    assert_eq!(reply["ok"], true, "{permission_mode} {picked:?}: {reply}");
    let session = reply["data"]["session"].as_str().unwrap_or_else(|| panic!("{reply}"));
    let info = vm.acpmux_call("_acpmux/info", json!({"sessionId": session}));
    let mode = info["result"]["modes"]["currentModeId"].as_str();
    mode.unwrap_or_else(|| panic!("no mode: {info}")).to_owned()
}

/// A new Claude chat on the caller's own Cloud VM with no mode picked starts in Claude Code's
/// Auto when the person's start level is full access (Lawrence 2026-11-20: "we need to support
/// auto mode for cloud mode for claude harness"), through the app's real start path
/// (`agent-session-start`, `server/agent_session_start.rs` `cloud_default_mode`) and the VM's
/// acpmux, with no model sign-in. A picked mode holds, and the other start levels never move the
/// chat to Auto.
#[test]
fn a_cloud_claude_chat_with_no_mode_picked_starts_in_auto() {
    let vm = cloud_claude_vm("cloudauto");
    assert_eq!(cloud_claude_start_mode(&vm, "fullAccess", None), "auto");
    assert_eq!(
        cloud_claude_start_mode(&vm, "fullAccess", Some("bypassPermissions")),
        "bypassPermissions"
    );
    assert_eq!(cloud_claude_start_mode(&vm, "fullAccess", Some("default")), "default");
    assert_eq!(cloud_claude_start_mode(&vm, "standard", None), "default");
    assert_eq!(cloud_claude_start_mode(&vm, "ask", None), "default");
}
