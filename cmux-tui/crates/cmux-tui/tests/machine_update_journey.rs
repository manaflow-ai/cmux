//! A Cloud machine whose cmux-tui is older than this client (cx-rppd.13), end
//! to end on one Linux box with real processes: the link CLIs that Move to
//! Cloud, Bring Back Local and local access run name it `machine_outdated`
//! before anything moves, instead of failing on a verb the old daemon does
//! not know, and a chat refused that way is not frozen: it moves to a current
//! machine right after.
//!
//! The older machine is this same binary under two debug-only seams: it
//! reports another build (`CMUX_TEST_DAEMON_BUILD_ID`, cmux-tui main.rs) and
//! leaves the newer capabilities out of `identify`
//! (`CMUX_TEST_DAEMON_HIDE_CAPABILITIES`, cmux-tui-core capabilities.rs), as
//! a Cloud VM that baked a cmux-tui from before those verbs does. The
//! machines are shaped like the Cloud move journey's (cloud_move_journey.rs).
//!
//! Linux only: a Cloud host is a Linux machine (`cloud_fs::is_cloud_host`).
#![cfg(target_os = "linux")]

mod journey_support;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use journey_support::*;
use serde_json::{Value, json};

const OLD_BUILD: &str = "0000000000000000000000000000000000000old";
const NEWER_VERBS: &str = "fs-v1,agent-transfer-v1,access-request-v1";

/// A short folder under /tmp: a socket path must stay under SUN_LEN.
fn journey_root(tag: &str) -> (PathBuf, Cleanup) {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("{tag}-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    (root.clone(), Cleanup(root))
}

/// The environment of a personal Cloud VM (cloud_move_journey.rs), plus `extra`.
fn cloud_vm(
    root: &Path,
    id: &str,
    extra: Vec<(&'static str, String)>,
) -> Vec<(&'static str, String)> {
    let mut env = vec![
        ("CMUX_TEST_CLOUD_ETC", cloud_etc(root).to_string_lossy().into_owned()),
        ("CMUX_VM_ID", id.to_owned()),
        ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
    ];
    env.extend(extra);
    env
}

fn sync_push(mac: &Machine, socket: &Path, local: &Path, remote: &Path) -> (bool, Value) {
    run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
            .args(["link", "sync", "push", "--socket"])
            .arg(socket)
            .arg(local)
            .arg(remote),
    )
}

fn agent_move(mac: &Machine, surface: u64, to: &Machine, cwd: &Path, pump: &Path) -> (bool, Value) {
    run_json(
        Command::new(bin())
            .args(["link", "agent", "move", "--from-socket"])
            .arg(&mac.socket)
            .args(["--surface", &surface.to_string(), "--to-socket"])
            .arg(&to.socket)
            .arg("--cwd")
            .arg(cwd)
            .arg("--state-dir")
            .arg(pump),
    )
}

fn assert_outdated(answer: &Value, missing: &str) {
    assert_eq!(answer["ok"], json!(false), "{answer}");
    assert_eq!(answer["error_code"], json!("machine_outdated"), "{answer}");
    let error = answer["error"].as_str().unwrap_or_default();
    assert!(error.contains(missing) && error.contains(OLD_BUILD), "{answer}");
}

/// Move to Cloud onto an older machine: the folder copy and the chat move are
/// each refused as `machine_outdated` with nothing written there, a moved
/// chat's file request triage on it is too, and the chat stays live on the
/// Mac: it moves to a current machine right after.
#[test]
fn machine_gate_refuses_an_older_machine_before_anything_moves() {
    let (root, _cleanup) = journey_root("mgo");
    let mac = Machine::start(&root, "mac", Vec::new());
    let old = Machine::start(
        &root,
        "old",
        cloud_vm(
            &root,
            "vm-machine-gate-old",
            vec![
                ("CMUX_TEST_DAEMON_BUILD_ID", OLD_BUILD.to_owned()),
                ("CMUX_TEST_DAEMON_HIDE_CAPABILITIES", NEWER_VERBS.to_owned()),
            ],
        ),
    );
    let current = Machine::start(&root, "new", cloud_vm(&root, "vm-machine-gate-new", Vec::new()));

    // The folder copy: refused, nothing written on the older machine.
    let project = mac.home().join("app");
    fs::create_dir_all(&project).unwrap();
    fs::write(project.join("notes.txt"), "stays here\n").unwrap();
    let there = old.home().join("work/app");
    let (ok, pushed) = sync_push(&mac, &old.socket, &project, &there);
    assert!(!ok, "{pushed}");
    assert_outdated(&pushed, "fs-v1");
    assert!(!there.exists(), "the push wrote to the older machine");

    // The chat move: refused before the chat froze on the Mac.
    let mut acpmux = mac.acpmux();
    let created = acpmux.call("session/new", json!({"cwd": project, "mcpServers": []}));
    let session = created["sessionId"].as_str().unwrap().to_owned();
    acpmux.call("session/prompt", prompt(&session, "before the move", "p-gate-1"));
    let surface = bound_agent_tab(&mac, &session);
    let pump = root.join("pump");
    let (ok, moved) = agent_move(&mac, surface, &old, &there, &pump);
    assert!(!ok, "{moved}");
    assert_outdated(&moved, "agent-transfer-v1");
    let events = acpmux.events(&session);
    assert!(!events.iter().any(|e| e["kind"] == "transferred"), "the chat moved: {events:?}");

    // A moved chat's file requests on the older machine: refused the same way.
    let (ok, triage) = run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
            .args(["link", "access", "triage", "--socket"])
            .arg(&old.socket)
            .args(["--machine", "vm-machine-gate-old", "--session", &session]),
    );
    assert!(!ok, "{triage}");
    assert_outdated(&triage, "access-request-v1");

    // The chat was never frozen: it moves to a current machine.
    let synced = current.home().join("work/app");
    let (ok, pushed) = sync_push(&mac, &current.socket, &project, &synced);
    assert!(ok, "sync push to the current machine: {pushed}");
    let (ok, moved) = agent_move(&mac, surface, &current, &synced, &pump);
    assert!(ok && moved["ok"] == json!(true), "agent move to the current machine: {moved}");
    assert_eq!(moved["session_id"], json!(session), "{moved}");
}

/// A machine of this client's own build that does not serve a verb (here a
/// host without the Cloud records, so no `fs-v1`) is not called outdated:
/// updating it would change nothing, so the verb's own refusal stands.
#[test]
fn machine_gate_leaves_a_same_build_machine_to_its_own_refusal() {
    let (root, _cleanup) = journey_root("mgs");
    let mac = Machine::start(&root, "mac", Vec::new());
    let plain = Machine::start(&root, "plain", Vec::new());
    let project = mac.home().join("app");
    fs::create_dir_all(&project).unwrap();
    fs::write(project.join("notes.txt"), "stays here\n").unwrap();
    let (ok, pushed) = sync_push(&mac, &plain.socket, &project, &plain.home().join("work/app"));
    assert!(!ok, "{pushed}");
    assert_ne!(pushed["error_code"], json!("machine_outdated"), "{pushed}");
    let code = pushed["error_code"].as_str().unwrap_or_default();
    assert!(code.starts_with("fs."), "not the daemon's own fs refusal: {pushed}");
}
