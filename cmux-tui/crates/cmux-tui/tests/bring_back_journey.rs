//! Bring Back Local, end to end on one Linux box with real processes: the
//! reverse of `cloud_move_journey.rs`. A folder pushed to a daemon shaped
//! like a personal Cloud VM gets an edit and a commit there, and an agent
//! chat that runs there goes back to the "Mac" daemon.
//!
//! - The Cloud VM: a headless daemon with its own acpmux and the Cloud
//!   records in the folder of the debug-only `CMUX_TEST_CLOUD_ETC` seam. Its
//!   chat runs in `~/work/app` with a finished turn, a running turn, a
//!   queued prompt and a draft, in the test agent's asking mode `normal` and
//!   with no approving policy, bound to an agent tab of the VM's store.
//! - The Mac: a second headless daemon with its own acpmux, not a Cloud
//!   host, so it takes a chat back only under the Web's control (its own
//!   guard: the folder under its `$HOME`, an asking policy and mode). The
//!   person trusted the folder here before it moved.
//!
//! The journey runs the real CLI: `cmux link sync pull` merges the VM's
//! folder back through its `fs-v1`, then `cmux link agent move` pumps the
//! chat from the VM daemon (as the trusted local client the Cloud link's
//! `remote connect` bridge makes the app there) to the Mac daemon.
//!
//! Linux only: a Cloud host is a Linux machine (`cloud_fs::is_cloud_host`).
#![cfg(target_os = "linux")]

mod journey_support;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use journey_support::*;
use serde_json::{Value, json};

const HISTORY: &str = "hello from the vm";
const QUEUED: &str = "queued for the mac";
const QUEUED_ID: &str = "p-bring-back-queued";
const DRAFT: &str = "an unsent thought on the vm";

/// A clean working copy with one commit.
fn repo_at(at: &Path) -> PathBuf {
    let repo = at.join("app");
    fs::create_dir_all(repo.join("src")).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    fs::write(repo.join("src/lib.txt"), "committed\n").unwrap();
    fs::write(repo.join("notes.txt"), "notes\n").unwrap();
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    repo
}

/// The VM's chat: a finished turn, a turn that waits for a cancel, a prompt
/// queued behind it and a draft. The connection stays open (the queued
/// prompt's sender).
fn chat_with_history_draft_and_queue(acpmux: &mut Acpmux, cwd: &Path) -> String {
    let created = acpmux.call("session/new", json!({"cwd": cwd, "mcpServers": []}));
    let session = created["sessionId"].as_str().unwrap().to_owned();
    acpmux.call("session/prompt", prompt(&session, HISTORY, "p-bring-back-history"));
    acpmux.send("session/prompt", prompt(&session, "until-cancel", "p-bring-back-running"));
    wait_until(20, "the running turn", || {
        acpmux.summary(&session).filter(|s| s["turn"].is_object()).map(|_| ())
    });
    acpmux.send("session/prompt", prompt(&session, QUEUED, QUEUED_ID));
    wait_until(20, "the queued prompt", || {
        acpmux.summary(&session).filter(|s| s["queued"].as_u64() == Some(1)).map(|_| ())
    });
    acpmux.call("_acpmux/draft_set", json!({"sessionId": session, "text": DRAFT}));
    session
}

/// `cmux link agent move` of tab `surface` of the VM to the Mac, in `cwd`.
fn move_back(vm: &Machine, mac: &Machine, surface: u64, cwd: &Path, state: &Path) -> (bool, Value) {
    move_back_with(vm, mac, surface, cwd, state, &[])
}

/// `move_back` with `extra` flags.
fn move_back_with(
    vm: &Machine,
    mac: &Machine,
    surface: u64,
    cwd: &Path,
    state: &Path,
    extra: &[&str],
) -> (bool, Value) {
    run_json(
        Command::new(bin())
            .args(["link", "agent", "move", "--from-socket"])
            .arg(&vm.socket)
            .args(["--surface", &surface.to_string(), "--to-socket"])
            .arg(&mac.socket)
            .arg("--cwd")
            .arg(cwd)
            .arg("--interrupt")
            .arg("--state-dir")
            .arg(state)
            .args(extra),
    )
}

#[test]
fn bring_back_journey_returns_a_vm_edit_a_commit_and_a_chat_to_the_mac() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("cbj-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let _cleanup = Cleanup(root.clone());

    let mac = Machine::start(&root, "mac", Vec::new());
    let vm = Machine::start(
        &root,
        "vm",
        vec![
            ("CMUX_TEST_CLOUD_ETC", cloud_etc(&root).to_string_lossy().into_owned()),
            ("CMUX_VM_ID", "vm-bring-back-journey".to_owned()),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    );

    // The folder went to the VM with Move to Cloud; the person trusted it
    // on the Mac before that.
    let repo = repo_at(&mac.home());
    let synced = vm.home().join("work/app");
    let (ok, pushed) = run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
            .args(["link", "sync", "push", "--socket"])
            .arg(&vm.socket)
            .arg(&repo)
            .arg(&synced),
    );
    assert!(ok && pushed["ok"] == json!(true), "sync push: {pushed}");
    let mut mac_acpmux = mac.acpmux();
    mac_acpmux.call("acp.trust.set", json!({"cwd": repo, "level": "trusted"}));

    let mut vm_acpmux = vm.acpmux();
    let session = chat_with_history_draft_and_queue(&mut vm_acpmux, &synced);
    let surface = bound_agent_tab(&vm, &session);
    let pump = root.join("pump");

    // 1. A chat that approves everything is refused on the way back, and
    // stays on the VM, open.
    let created = vm_acpmux.call(
        "session/new",
        json!({"cwd": synced, "mcpServers": [], "_meta": {"acpmux": {"harness": "fake-approve"}}}),
    );
    let approving = created["sessionId"].as_str().unwrap().to_owned();
    vm_acpmux.call("session/prompt", prompt(&approving, "hi", "p-approving"));
    let approving_tab = bound_agent_tab(&vm, &approving);
    let (ok, refused) = move_back(&vm, &mac, approving_tab, &repo, &pump);
    assert!(!ok, "an approve-all chat moved back: {refused}");
    let why = refused["error"].as_str().unwrap_or_default();
    assert!(why.contains("transfer.policy"), "{refused}");
    let kept = vm_acpmux.summary(&approving).expect("the refused chat is on the VM");
    assert_ne!(kept["status"], "closed", "{kept}");

    // 2. An edit and a commit on the VM come back to the Mac's folder.
    fs::write(synced.join("src/lib.txt"), "committed\nfrom the vm\n").unwrap();
    git(&synced, &["commit", "-q", "-am", "on the vm"]);
    fs::write(synced.join("notes.txt"), "notes\nunsaved on the vm\n").unwrap();
    let (ok, pulled) = run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
            .args(["link", "sync", "pull", "--socket"])
            .arg(&vm.socket)
            .arg(&repo)
            .arg(&synced),
    );
    assert!(ok && pulled["fast_forwarded"] == json!(true), "sync pull: {pulled}");
    assert_eq!(fs::read_to_string(repo.join("src/lib.txt")).unwrap(), "committed\nfrom the vm\n");
    assert_eq!(fs::read_to_string(repo.join("notes.txt")).unwrap(), "notes\nunsaved on the vm\n");
    assert_eq!(git(&repo, &["rev-parse", "HEAD"]), git(&synced, &["rev-parse", "HEAD"]));
    let status = ["status", "--porcelain=v2", "--branch"];
    assert_eq!(git(&repo, &status), git(&synced, &status), "git status differs from the VM's");

    // 3. The chat moves back, its running turn stopped for the move.
    let (ok, moved) = move_back(&vm, &mac, surface, &repo, &pump);
    assert!(ok && moved["ok"] == json!(true), "agent move: {moved}");
    assert_eq!(moved["session_id"], json!(session), "{moved}");

    // 4. On the Mac: the chat with its history and draft, in the folder,
    // under the Web's control, and its queued prompt ran here exactly once.
    let landed = wait_until(30, "the queued prompt's turn on the Mac", || {
        let events = mac_acpmux.events(&session);
        let done =
            events.iter().any(|e| e["kind"] == "turn_result" && e["msg"]["promptId"] == QUEUED_ID);
        done.then_some(events)
    });
    assert_eq!(count(&landed, "user_message", USER_TEXT, HISTORY), 1, "history: {landed:?}");
    assert_eq!(count(&landed, "agent_message_chunk", AGENT_TEXT, &format!("echo: {HISTORY}")), 1);
    let guarded: Vec<&Value> =
        landed.iter().filter(|e| e["kind"] == "transfer_guarded").map(|e| &e["msg"]).collect();
    assert_eq!(guarded.len(), 1, "{guarded:?}");
    assert_eq!(guarded[0]["control"], "web", "{guarded:?}");
    std::thread::sleep(Duration::from_secs(2));
    let events = mac_acpmux.events(&session);
    let queued: Vec<&Value> = events
        .iter()
        .filter(|e| e["kind"] == "queued" && e["msg"]["promptId"] == QUEUED_ID)
        .map(|e| &e["msg"])
        .collect();
    assert!(!queued.is_empty(), "no queued record: {events:?}");
    assert!(queued.iter().all(|q| q["control"] == "web"), "not the Web's: {queued:?}");
    assert_eq!(count(&events, "user_message", USER_TEXT, QUEUED), 1, "{events:?}");
    assert_eq!(count(&events, "agent_message_chunk", AGENT_TEXT, &format!("echo: {QUEUED}")), 1);
    let runs = events
        .iter()
        .filter(|e| e["kind"] == "turn_result" && e["msg"]["promptId"] == QUEUED_ID)
        .count();
    assert_eq!(runs, 1, "the queued prompt's turns: {events:?}");
    let draft = mac_acpmux.call("_acpmux/draft_get", json!({"sessionId": session}));
    assert_eq!(draft["draft"], json!(DRAFT), "{draft}");
    let here = mac_acpmux.summary(&session).expect("the chat is on the Mac");
    assert_eq!(here["cwd"], json!(fs::canonicalize(&repo).unwrap()), "{here}");
    assert_eq!(here["queued"].as_u64(), Some(0), "{here}");

    // 5. On the VM: the chat moved away, and its queued prompt never ran there.
    let left = vm_acpmux.summary(&session);
    assert!(left.as_ref().is_none_or(|s| s["status"] == "closed"), "still open: {left:?}");
    let events = vm_acpmux.events(&session);
    assert!(events.iter().any(|e| e["kind"] == "transferred"), "no transferred record");
    assert_eq!(count(&events, "user_message", USER_TEXT, QUEUED), 0, "ran on the VM too");
}

/// cx-rppd.10: "Ask first, then bring back". The Mac's guard refuses a VM
/// chat that approves on its own (`transfer.policy`) or runs in a mode that
/// does not ask (`transfer.mode`), and the chat stays on the VM unchanged.
/// The same move with `--ask-first` narrows the chat on the VM first (an
/// asking policy, an asking mode) and then brings it back, still under the
/// Mac's unchanged guard.
#[test]
fn bring_back_ask_first_narrows_a_refused_vm_chat_then_brings_it_back() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("cba-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let _cleanup = Cleanup(root.clone());

    let mac = Machine::start(&root, "mac", Vec::new());
    let vm = Machine::start(
        &root,
        "vm",
        vec![
            ("CMUX_TEST_CLOUD_ETC", cloud_etc(&root).to_string_lossy().into_owned()),
            ("CMUX_VM_ID", "vm-bring-back-ask-first".to_owned()),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    );
    let repo = repo_at(&mac.home());
    let synced = vm.home().join("work/app");
    fs::create_dir_all(&synced).unwrap();
    let mut mac_acpmux = mac.acpmux();
    mac_acpmux.call("acp.trust.set", json!({"cwd": repo, "level": "trusted"}));
    let mut vm_acpmux = vm.acpmux();
    let pump = root.join("pump");

    // A chat that approves everything, and one in a mode that does not ask.
    let created = vm_acpmux.call(
        "session/new",
        json!({"cwd": synced, "mcpServers": [], "_meta": {"acpmux": {"harness": "fake-approve"}}}),
    );
    let approving = created["sessionId"].as_str().unwrap().to_owned();
    vm_acpmux.call("session/prompt", prompt(&approving, "hi", "p-ask-first-approving"));
    let created = vm_acpmux.call("session/new", json!({"cwd": synced, "mcpServers": []}));
    let strict = created["sessionId"].as_str().unwrap().to_owned();
    // The agent leaves the asking mode on its own (only the person's app may
    // pick a mode that does not ask).
    vm_acpmux.call("session/prompt", prompt(&strict, "set-mode: strict", "p-ask-first-strict"));
    wait_until(20, "the strict mode", || {
        vm_acpmux.summary(&strict).filter(|s| s["currentModeId"] == json!("strict")).map(|_| ())
    });

    for (session, refusal) in [(&approving, "transfer.policy"), (&strict, "transfer.mode")] {
        let tab = bound_agent_tab(&vm, session);
        // Refused as it is, and kept on the VM, open.
        let (ok, refused) = move_back(&vm, &mac, tab, &repo, &pump);
        assert!(!ok, "{session} moved back as it was: {refused}");
        let why = refused["error"].as_str().unwrap_or_default();
        assert!(why.contains(refusal), "{refused}");
        let kept = vm_acpmux.summary(session).expect("the refused chat is on the VM");
        assert_ne!(kept["status"], "closed", "{kept}");

        // Ask first, then bring back.
        let (ok, moved) = move_back_with(&vm, &mac, tab, &repo, &pump, &["--ask-first"]);
        assert!(ok && moved["ok"] == json!(true), "ask first, then bring back: {moved}");
        assert_eq!(moved["session_id"], json!(session), "{moved}");
        let here = mac_acpmux.summary(session).expect("the chat is on the Mac");
        assert_eq!(here["cwd"], json!(fs::canonicalize(&repo).unwrap()), "{here}");
        assert!(matches!(here["policy"].as_str(), None | Some("ask")), "{here}");
        assert_eq!(here["currentModeId"], json!("normal"), "{here}");
        let left = vm_acpmux.summary(session);
        assert!(left.as_ref().is_none_or(|s| s["status"] == "closed"), "still open: {left:?}");
    }
}
