//! Local → Cloud → local → Cloud, end to end on one Linux box with real
//! processes: one chat and its folder make the round trip Leo asked about
//! ("and how about the moving back and forth between local and cloud/remote
//! chats?"), with the same CLI calls the app's Move to Cloud
//! (`CloudMove.swift`) and Bring Back Local (`CloudBringBack.swift`) run:
//!
//! 1. Move to Cloud: `cmux link seed push`, then `cmux link agent move
//!    --sync seed` from the Mac daemon to the VM daemon.
//! 2. A turn and a commit on the VM.
//! 3. Bring Back Local: `cmux link seed pull --or-copy`, then `cmux link
//!    agent move` from the VM daemon to the Mac daemon, onto the Mac whose
//!    acpmux still keeps that session's `transferred` record from step 1.
//! 4. A turn and an edit on the Mac.
//! 5. Move to Cloud again: onto the VM whose acpmux now keeps that session's
//!    `transferred` record from step 3.
//!
//! `cloud_move_journey.rs` and `bring_back_journey.rs` each prove one leg
//! with a chat that never was on its target before; this one proves a chat
//! comes home and goes out again with every turn, the draft and the
//! folder's changes, and prints each leg's time (`round trip leg ...`).
//!
//! Linux only: a Cloud host is a Linux machine (`cloud_fs::is_cloud_host`).
#![cfg(target_os = "linux")]

mod journey_support;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Instant, SystemTime, UNIX_EPOCH};

use journey_support::*;
use serde_json::{Value, json};

const ON_MAC: &str = "first words on the mac";
const ON_VM: &str = "then on the vm";
const BACK_ON_MAC: &str = "back on the mac";
const OUT_AGAIN: &str = "on the vm a second time";
const DRAFT: &str = "an unsent thought that travels";

/// A working copy with a commit pushed to its GitHub remote (`acme/app`
/// under `github`) and an uncommitted change, as `cloud_move_journey.rs`.
fn repo(at: &Path, github: &Path) -> PathBuf {
    let repo = at.join("app");
    fs::create_dir_all(repo.join("src")).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    git(&repo, &["config", "user.email", "journey@example.com"]);
    git(&repo, &["config", "user.name", "journey"]);
    fs::write(repo.join("src/lib.txt"), "committed\n").unwrap();
    git(&repo, &["add", "-A"]);
    git(&repo, &["commit", "-q", "-m", "first"]);
    let bare = github.join("acme/app.git");
    fs::create_dir_all(&bare).unwrap();
    git(&bare, &["init", "-q", "--bare"]);
    git(&bare, &["config", "uploadpack.allowFilter", "true"]);
    git(&repo, &["remote", "add", "origin", "https://github.com/acme/app.git"]);
    let local = format!("url.file://{}/.insteadOf", github.display());
    git(&repo, &["config", &local, "https://github.com/"]);
    git(&repo, &["-c", "protocol.file.allow=always", "push", "-q", "-u", "origin", "main"]);
    fs::write(repo.join("src/lib.txt"), "committed\nuncommitted on the mac\n").unwrap();
    repo
}

/// One finished turn of `text` in `session`.
fn turn(acpmux: &mut Acpmux, session: &str, text: &str, id: &str) {
    acpmux.call("session/prompt", prompt(session, text, id));
    wait_until(30, &format!("the turn {id}"), || {
        let events = acpmux.events(session);
        events
            .iter()
            .any(|e| e["kind"] == "turn_result" && e["msg"]["promptId"] == id)
            .then_some(())
    });
}

/// The user turns of `session` in order, as its events list them.
fn user_turns(acpmux: &mut Acpmux, session: &str) -> Vec<String> {
    acpmux
        .events(session)
        .iter()
        .filter(|e| e["kind"] == "user_message")
        .filter_map(|e| e["msg"].pointer(USER_TEXT).and_then(Value::as_str).map(str::to_owned))
        .collect()
}

/// Move to Cloud's last step: the moved chat opens in a tab of the VM's own
/// store (`registry:<store id>`); answers its surface.
fn vm_tab(vm: &Machine, session: &str) -> u64 {
    let identity = vm.rpc(json!({"id": 1, "cmd": "identify"}));
    let store = identity["data"]["session_id"].as_str().unwrap().to_owned();
    assert_eq!(vm.rpc(json!({"id": 2, "cmd": "new-workspace"}))["ok"], true);
    let tab = vm.rpc(json!({"id": 3, "cmd": "new-conversation-tab",
        "agent_session": {"host": format!("registry:{store}"), "session": session, "harness": "fake"}}));
    assert_eq!(tab["ok"], true, "the moved chat's tab on the VM: {tab}");
    tab["data"]["surface"].as_u64().unwrap()
}

/// `cmux link ...` as this Mac runs it; answers the JSON line and the time it took.
fn link(mac: &Machine, args: &mut Command) -> (bool, Value, u128) {
    let started = Instant::now();
    let (ok, value) = run_json(
        args.env("CMUX_TUI_STATE_DIR", mac.dir.join("state")).env("GIT_CONFIG_GLOBAL", "/dev/null"),
    );
    (ok, value, started.elapsed().as_millis())
}

/// Move to Cloud of the Mac's tab `surface`: seed push, then the chat with `--sync seed`.
fn move_to_cloud(
    mac: &Machine,
    vm: &Machine,
    surface: u64,
    repo: &Path,
    synced: &Path,
    pump: &Path,
) -> u128 {
    let (ok, seeded, seed_ms) = link(
        mac,
        Command::new(bin())
            .args(["link", "seed", "push", "--socket"])
            .arg(&vm.socket)
            .arg(repo)
            .arg(synced),
    );
    assert!(ok && seeded["ok"] == json!(true), "seed push: {seeded}");
    let (ok, moved, move_ms) = link(
        mac,
        Command::new(bin())
            .args(["link", "agent", "move", "--from-socket"])
            .arg(&mac.socket)
            .args(["--surface", &surface.to_string(), "--to-socket"])
            .arg(&vm.socket)
            .arg("--cwd")
            .arg(synced)
            .args(["--interrupt", "--vm-kind", "owner", "--sync", "seed", "--sync-socket"])
            .arg(&vm.socket)
            .arg("--sync-local")
            .arg(repo)
            .arg("--sync-remote")
            .arg(synced)
            .arg("--state-dir")
            .arg(pump),
    );
    assert!(ok && moved["ok"] == json!(true), "agent move to the VM: {moved}");
    eprintln!(
        "round trip leg move-to-cloud: seed {seed_ms} ms ({}), move {move_ms} ms",
        seeded["mode"]
    );
    seed_ms + move_ms
}

/// Bring Back Local of the VM's tab `surface`: seed pull --or-copy, then the chat.
fn bring_back(
    mac: &Machine,
    vm: &Machine,
    surface: u64,
    repo: &Path,
    synced: &Path,
    pump: &Path,
) -> u128 {
    let (ok, pulled, pull_ms) = link(
        mac,
        Command::new(bin())
            .args(["link", "seed", "pull", "--socket"])
            .arg(&vm.socket)
            .arg(repo)
            .arg(synced)
            .arg("--or-copy"),
    );
    assert!(ok && pulled["ok"] == json!(true), "seed pull: {pulled}");
    let (ok, moved, move_ms) = link(
        mac,
        Command::new(bin())
            .args(["link", "agent", "move", "--from-socket"])
            .arg(&vm.socket)
            .args(["--surface", &surface.to_string(), "--to-socket"])
            .arg(&mac.socket)
            .arg("--cwd")
            .arg(repo)
            .arg("--interrupt")
            .arg("--state-dir")
            .arg(pump),
    );
    assert!(ok && moved["ok"] == json!(true), "agent move back to the Mac: {moved}");
    eprintln!("round trip leg bring-back: pull {pull_ms} ms, move {move_ms} ms");
    pull_ms + move_ms
}

/// Waits until `session` is open on `acpmux` in `cwd` and answers its summary.
fn landed(acpmux: &mut Acpmux, session: &str, cwd: &Path, side: &str) -> Value {
    let cwd = json!(fs::canonicalize(cwd).unwrap());
    wait_until(30, &format!("the chat open on the {side}"), || {
        acpmux.summary(session).filter(|s| s["status"] != "closed" && s["cwd"] == cwd)
    })
}

#[test]
fn chat_round_trip_goes_to_cloud_comes_back_and_goes_out_again_with_its_turns_draft_and_folder() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("crt-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let _cleanup = Cleanup(root.clone());

    let github = root.join("github");
    let mac = Machine::start(&root, "mac", Vec::new());
    let vm = Machine::start(
        &root,
        "vm",
        vec![
            ("CMUX_TEST_CLOUD_ETC", cloud_etc(&root).to_string_lossy().into_owned()),
            ("CMUX_TEST_GIT_SEED_GITHUB", github.to_string_lossy().into_owned()),
            ("CMUX_VM_ID", "vm-chat-round-trip".to_owned()),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    );
    let repo = repo(&mac.home(), &github);
    let synced = vm.home().join("work/app");
    let pump = root.join("pump");

    // The chat starts on the Mac, in a folder the person trusts there.
    let mut mac_acpmux = mac.acpmux();
    mac_acpmux.call("acp.trust.set", json!({"cwd": repo, "level": "trusted"}));
    let created = mac_acpmux.call("session/new", json!({"cwd": repo, "mcpServers": []}));
    let session = created["sessionId"].as_str().unwrap().to_owned();
    turn(&mut mac_acpmux, &session, ON_MAC, "p-rt-1");
    mac_acpmux.call("_acpmux/draft_set", json!({"sessionId": session, "text": DRAFT}));
    let mac_surface = bound_agent_tab(&mac, &session);

    // 1. Out to the VM.
    let out_ms = move_to_cloud(&mac, &vm, mac_surface, &repo, &synced, &pump);
    let mut vm_acpmux = vm.acpmux();
    landed(&mut vm_acpmux, &session, &synced, "VM");
    assert_eq!(
        fs::read_to_string(synced.join("src/lib.txt")).unwrap(),
        "committed\nuncommitted on the mac\n"
    );

    // 2. Work on the VM: a turn, a commit and an unsaved edit.
    turn(&mut vm_acpmux, &session, ON_VM, "p-rt-2");
    fs::write(synced.join("src/vm.txt"), "made on the vm\n").unwrap();
    git(&synced, &["add", "src/vm.txt"]);
    git(
        &synced,
        &[
            "-c",
            "user.email=vm@example.com",
            "-c",
            "user.name=vm",
            "commit",
            "-q",
            "-m",
            "on the vm",
        ],
    );
    fs::write(synced.join("notes.txt"), "unsaved on the vm\n").unwrap();
    let vm_surface = vm_tab(&vm, &session);

    // 3. Home to the Mac, which still keeps this session's record from the move out.
    let back_ms = bring_back(&mac, &vm, vm_surface, &repo, &synced, &pump);
    let here = landed(&mut mac_acpmux, &session, &repo, "Mac");
    assert_eq!(
        fs::read_to_string(repo.join("src/vm.txt")).unwrap(),
        "made on the vm\n",
        "the VM's commit stayed there"
    );
    assert_eq!(
        fs::read_to_string(repo.join("notes.txt")).unwrap(),
        "unsaved on the vm\n",
        "the VM's edit stayed there"
    );
    assert_eq!(git(&repo, &["rev-parse", "HEAD"]), git(&synced, &["rev-parse", "HEAD"]));
    assert_eq!(
        user_turns(&mut mac_acpmux, &session),
        [ON_MAC, ON_VM],
        "history back on the Mac: {here}"
    );
    let draft = mac_acpmux.call("_acpmux/draft_get", json!({"sessionId": session}));
    assert_eq!(draft["draft"], json!(DRAFT), "the draft back on the Mac: {draft}");

    // 4. Work on the Mac again.
    turn(&mut mac_acpmux, &session, BACK_ON_MAC, "p-rt-3");
    fs::write(repo.join("src/mac.txt"), "made back on the mac\n").unwrap();
    let mac_surface = bound_agent_tab(&mac, &session);

    // 5. Out to the VM a second time, which still keeps this session's record from step 3.
    let again_ms = move_to_cloud(&mac, &vm, mac_surface, &repo, &synced, &pump.join("again"));
    landed(&mut vm_acpmux, &session, &synced, "VM again");
    assert_eq!(fs::read_to_string(synced.join("src/mac.txt")).unwrap(), "made back on the mac\n");
    turn(&mut vm_acpmux, &session, OUT_AGAIN, "p-rt-4");
    assert_eq!(user_turns(&mut vm_acpmux, &session), [ON_MAC, ON_VM, BACK_ON_MAC, OUT_AGAIN]);
    let draft = vm_acpmux.call("_acpmux/draft_get", json!({"sessionId": session}));
    assert_eq!(draft["draft"], json!(DRAFT), "the draft out again: {draft}");
    // Only one machine runs the chat: the Mac's is closed.
    let left = mac_acpmux.summary(&session);
    assert!(
        left.as_ref().is_none_or(|s| s["status"] == "closed"),
        "still open on the Mac: {left:?}"
    );

    eprintln!(
        "round trip total: out {out_ms} ms, back {back_ms} ms, out again {again_ms} ms, sum {} ms",
        out_ms + back_ms + again_ms
    );
}
