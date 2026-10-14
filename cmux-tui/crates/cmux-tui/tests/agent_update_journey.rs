//! Update Everything for agent CLIs (`agent-update-v1`, cx-1mbnu), end to end
//! on one box with real processes: a headless cmux-tui daemon and its own
//! acpmux, whose one harness is an agent CLI installed by its vendor's own
//! installer (Claude's layout under `~/.local/share/claude`) and outdated.
//! The daemon's `agent-update-plan` lists it with the machine's chats,
//! `agent-update-apply` runs its updater through acpmux and answers the new
//! version, and the chat restarts on that version and keeps its conversation.
//!
//! The harness is a script: `--version` prints the installed version,
//! `update` installs the newer one, and anything else runs the test agent
//! with the installed version in `FAKE_HARNESS_VERSION`, which the agent's
//! `env:` prompt reads back. acpmux asks no registry: the newest version
//! comes from its saved health check (`harness-health.json`).
#![cfg(unix)]

mod journey_support;

use std::fs;
use std::os::unix::fs::PermissionsExt as _;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

use journey_support::*;
use serde_json::json;

/// A short folder under /tmp (a socket path must stay under SUN_LEN),
/// canonical (macOS's /tmp is a symlink): acpmux tells the install's channel
/// from the CLI's real path under the home.
fn journey_root(tag: &str) -> (PathBuf, Cleanup) {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("{tag}-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    (root.clone(), Cleanup(root))
}

/// A machine whose acpmux runs the outdated `fake` harness at
/// `~/.local/bin/claude` (2.0.5; the newest is 2.0.9).
fn machine(root: &Path) -> Machine {
    let dir = root.join("machine");
    for sub in ["home/work", "home/.local/bin", "home/.local/share/claude/versions", "acpmux"] {
        fs::create_dir_all(dir.join(sub)).unwrap();
    }
    fs::set_permissions(dir.join("acpmux"), fs::Permissions::from_mode(0o700)).unwrap();
    let home = dir.join("home");
    let installed = dir.join("installed-version");
    let runs = dir.join("update-runs");
    fs::write(&installed, "2.0.5 (Claude Code)\n").unwrap();
    let script = home.join(".local/share/claude/versions/current");
    fs::write(
        &script,
        format!(
            "#!/bin/sh\ncase \"$1\" in\n  --version) cat '{installed}' ;;\n  update) echo run >> '{runs}'; echo '2.0.9 (Claude Code)' > '{installed}'; echo updated ;;\n  *) FAKE_HARNESS_VERSION=\"$(cat '{installed}')\" exec python3 '{FAKE_AGENT}' \"$@\" ;;\nesac\n",
            installed = installed.display(),
            runs = runs.display(),
        ),
    )
    .unwrap();
    fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
    let claude = home.join(".local/bin/claude");
    std::os::unix::fs::symlink(&script, &claude).unwrap();
    let config = json!({"harnesses": {"fake": {"argv": [claude], "family": "fake"}},
                        "defaultHarness": "fake"});
    fs::write(dir.join("acpmux/config.json"), config.to_string()).unwrap();
    // The newest version as the last check read it, fresh: no registry is asked.
    let now = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as u64;
    let saved = json!([{
        "id": "fake", "program": claude, "path": claude, "channel": "native",
        "package": "@anthropic-ai/claude-code", "version": "2.0.5", "latest": "2.0.9",
        "latestCheckedAt": now, "outdated": true, "auth": "unknown", "authDetail": null,
        "login": null, "problem": null, "checkedAt": now,
        "update": {"argv": [claude, "update"], "command": format!("{} update", claude.display()),
                   "elevated": false},
    }]);
    fs::write(dir.join("acpmux/harness-health.json"), saved.to_string()).unwrap();
    let machine = Machine {
        socket: dir.join("mux.sock"),
        session: "agent-update-journey".to_owned(),
        dir,
        env: vec![
            ("ACPMUX_HEALTH_FETCH", "0".to_owned()),
            ("ACPMUX_REGISTRY_FETCH", "0".to_owned()),
        ],
    };
    let _ = fs::remove_file(&machine.socket);
    let ensure = machine.server("ensure").output().unwrap();
    assert!(ensure.status.success(), "ensure: {}", String::from_utf8_lossy(&ensure.stderr));
    machine
}

fn start_acpmux(machine: &Machine) {
    let started = machine.command().args(["acp", "daemon", "start"]).output().unwrap();
    assert!(started.status.success(), "acp: {}", String::from_utf8_lossy(&started.stderr));
}

/// What the chat's harness process says its installed version is.
fn harness_version(acpmux: &mut Acpmux, session: &str, prompt_id: &str) -> usize {
    acpmux.call("session/prompt", prompt(session, "env: FAKE_HARNESS_VERSION", prompt_id));
    let events = acpmux.events(session);
    count(&events, "agent_message_chunk", AGENT_TEXT, "FAKE_HARNESS_VERSION=2.0.9 (Claude Code)")
}

/// The plan lists the outdated CLI and the machine's chat; the apply updates
/// it through acpmux (no command from the client), answers the new version,
/// and restarts the idle chat on it, which keeps its conversation. A second
/// plan has nothing left to update.
#[test]
fn agent_update_plan_and_apply_update_the_cli_and_continue_the_chat() {
    let (root, _cleanup) = journey_root("aup");
    let machine = machine(&root);
    let identify = machine.rpc(json!({"id": 1, "cmd": "identify"}));
    assert!(identify["data"]["capabilities"].to_string().contains("agent-update-v1"), "{identify}");

    // No acpmux runs yet: nothing to update, and the plan does not start it.
    let empty = machine.rpc(json!({"id": 2, "cmd": "agent-update-plan"}));
    assert_eq!(
        empty["data"],
        json!({"harnesses": [], "live_threads": 0, "running_threads": 0}),
        "{empty}"
    );
    assert!(!machine.dir.join("acpmux/acpmux.sock").exists(), "the plan started acpmux");

    start_acpmux(&machine);
    let mut acpmux = machine.acpmux();
    let created =
        acpmux.call("session/new", json!({"cwd": machine.home().join("work"), "mcpServers": []}));
    let session = created["sessionId"].as_str().unwrap().to_owned();
    acpmux.call("session/prompt", prompt(&session, "env: FAKE_HARNESS_VERSION", "p-before"));
    let events = acpmux.events(&session);
    let before = "FAKE_HARNESS_VERSION=2.0.5 (Claude Code)";
    assert_eq!(count(&events, "agent_message_chunk", AGENT_TEXT, before), 1, "{events:?}");

    let plan = machine.rpc(json!({"id": 3, "cmd": "agent-update-plan"}));
    assert_eq!(plan["ok"], true, "{plan}");
    let harnesses = plan["data"]["harnesses"].as_array().cloned().unwrap_or_default();
    assert_eq!(harnesses.len(), 1, "{plan}");
    assert_eq!(
        (
            harnesses[0]["id"].as_str(),
            harnesses[0]["version"].as_str(),
            harnesses[0]["latest"].as_str()
        ),
        (Some("fake"), Some("2.0.5"), Some("2.0.9")),
        "{plan}"
    );
    assert_eq!(
        (plan["data"]["live_threads"].as_u64(), plan["data"]["running_threads"].as_u64()),
        (Some(1), Some(0)),
        "{plan}"
    );

    // A command, or any param the verb does not take, is refused before acpmux.
    let smuggled = machine.rpc(json!({"id": 4, "cmd": "agent-update-apply", "ids": ["fake"],
                                      "argv": ["sh", "-c", "true"]}));
    assert_eq!(smuggled["error_code"], "agent_update.bad_request", "{smuggled}");
    assert!(!machine.dir.join("update-runs").exists(), "a refused apply ran the update");

    let applied = machine.rpc(json!({"id": 5, "cmd": "agent-update-apply", "ids": ["fake"],
                                     "continue_threads": true}));
    assert_eq!(applied["ok"], true, "{applied}");
    assert_eq!(
        applied["data"],
        json!({"results": [{"id": "fake", "ok": true, "version": "2.0.9"}],
               "threads_restarted": 1, "threads_after_turn": 0}),
        "{applied}"
    );
    let runs = fs::read_to_string(machine.dir.join("update-runs")).unwrap();
    assert_eq!(runs.lines().count(), 1, "one update run");

    // The chat runs the new version now, in the same conversation.
    assert_eq!(harness_version(&mut acpmux, &session, "p-after"), 1);
    let summary = acpmux.summary(&session).expect("the chat is still there");
    assert_eq!(summary["status"], "ready", "{summary}");

    let after = machine.rpc(json!({"id": 6, "cmd": "agent-update-plan"}));
    assert_eq!(after["data"]["harnesses"], json!([]), "{after}");
    assert_eq!(after["data"]["live_threads"], 1, "{after}");
}

/// An apply that names no harness of this machine runs nothing: acpmux
/// answers it as not ok with why, and no chat restarts. A plan takes no
/// param.
#[test]
fn agent_update_apply_of_an_unknown_harness_runs_nothing() {
    let (root, _cleanup) = journey_root("aun");
    let machine = machine(&root);
    start_acpmux(&machine);
    let applied = machine.rpc(json!({"id": 1, "cmd": "agent-update-apply", "ids": ["nope"],
                                     "continue_threads": true}));
    assert_eq!(applied["ok"], true, "{applied}");
    let results = applied["data"]["results"].as_array().cloned().unwrap_or_default();
    assert_eq!(results.len(), 1, "{applied}");
    assert_eq!(
        (results[0]["id"].as_str(), results[0]["ok"].as_bool()),
        (Some("nope"), Some(false))
    );
    assert!(results[0]["error"].as_str().is_some_and(|e| !e.is_empty()), "{applied}");
    assert_eq!(
        (
            applied["data"]["threads_restarted"].as_u64(),
            applied["data"]["threads_after_turn"].as_u64()
        ),
        (Some(0), Some(0)),
        "{applied}"
    );
    assert!(!machine.dir.join("update-runs").exists(), "an update ran");
    let bad = machine.rpc(json!({"id": 2, "cmd": "agent-update-plan", "ids": ["fake"]}));
    assert_eq!(bad["error_code"], "agent_update.bad_request", "{bad}");
}
