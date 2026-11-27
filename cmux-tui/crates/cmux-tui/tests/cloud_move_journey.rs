//! Move to Cloud, end to end on one Linux box with real processes: a dirty
//! working copy and an agent chat go from a "Mac" daemon to a daemon shaped
//! like a personal Cloud VM.
//!
//! - The Mac: a headless cmux-tui daemon whose own acpmux runs the test
//!   agent (`acpmux/tests/fake_agent.py`), with a chat that has a finished
//!   turn, a turn running, a queued prompt and a draft, bound to an agent tab
//!   of the daemon's store.
//! - The Cloud VM: a second headless daemon with its own acpmux, a HOME with
//!   `~/work`, the Cloud model plane identity (`CMUX_VM_ID`,
//!   `CMUX_CODEROUTER_URL`) and the Cloud records (image stamp, vm-kind
//!   `owner`) in a folder named by the debug-only `CMUX_TEST_CLOUD_ETC` seam
//!   (link/cloud_fs.rs, agent_start_host.rs), which stands in for the
//!   root-owned `/etc/cmux`.
//!
//! The journey runs the real CLI: `cmux link seed push` seeds the folder with
//! its git state through the VM daemon's `git-seed-v1` (the VM clones the
//! folder's GitHub remote, a folder of bare repositories named by the
//! debug-only `CMUX_TEST_GIT_SEED_GITHUB` seam, and applies one bundle of the
//! local diff it got through `fs-v1`), then `cmux link agent move` pumps the
//! chat between the two daemons' `agent-transfer-v1` verbs, sending what the
//! running turn wrote since as a delta bundle (`--sync seed`). Both
//! commands are given the VM daemon's own Unix socket, as the trusted local
//! client the Cloud link's `remote connect` bridge makes the app on the VM.
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

const HISTORY: &str = "hello from the mac";
const QUEUED: &str = "queued for the cloud";
const QUEUED_ID: &str = "p-journey-queued";
const DRAFT: &str = "an unsent thought";

/// A working copy with a commit pushed to its GitHub remote (`acme/app`
/// under `github`), an uncommitted change and an untracked file.
fn dirty_repo(at: &Path, github: &Path) -> PathBuf {
    let repo = at.join("app");
    fs::create_dir_all(repo.join("src")).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
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
    fs::write(repo.join("src/lib.txt"), "committed\nuncommitted change\n").unwrap();
    fs::write(repo.join("notes.txt"), "untracked\n").unwrap();
    repo
}

/// The Mac's chat: a finished turn, a turn that waits for a cancel, a
/// prompt queued behind it and a draft. Answers its acpmux session id; the
/// connection stays open (the queued prompt's sender).
fn chat_with_history_draft_and_queue(acpmux: &mut Acpmux, cwd: &Path) -> String {
    let created = acpmux.call("session/new", json!({"cwd": cwd, "mcpServers": []}));
    let session = created["sessionId"].as_str().unwrap().to_owned();
    acpmux.call("session/prompt", prompt(&session, HISTORY, "p-journey-history"));
    // A running turn keeps the next prompt in the queue until the move.
    acpmux.send("session/prompt", prompt(&session, "until-cancel", "p-journey-running"));
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

/// The store id a `registry:` host names: `identify`'s `session_id`.
fn store_id(machine: &Machine) -> String {
    let identity = machine.rpc(json!({"id": 1, "cmd": "identify"}));
    identity["data"]["session_id"].as_str().unwrap().to_owned()
}

/// Move to Cloud's show on the machine the chat landed on: a tab of its own
/// store (`registry:` host) that names the moved session, created with
/// `new-conversation-tab`, whose `agent-transfer-source` names that session.
fn moved_chat_tab(machine: &Machine, session: &str) {
    let store = store_id(machine);
    assert_eq!(machine.rpc(json!({"id": 2, "cmd": "new-workspace"}))["ok"], true);
    let tab = machine.rpc(json!({"id": 3, "cmd": "new-conversation-tab",
        "agent_session": {"host": format!("registry:{store}"), "session": session,
                          "harness": "fake"}}));
    assert_eq!(tab["ok"], true, "{tab}");
    let surface = tab["data"]["surface"].as_u64().unwrap();
    let source = machine.rpc(json!({"id": 4, "cmd": "agent-transfer-source", "surface": surface}));
    assert_eq!(source["data"]["session"], json!(session), "{source}");
}

#[test]
fn cloud_move_journey_moves_a_dirty_folder_and_its_chat_to_a_personal_cloud_vm() {
    // A socket path must stay under SUN_LEN: a short folder under /tmp.
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("cmj-{}-{stamp}", std::process::id()));
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
            ("CMUX_VM_ID", "vm-cloud-move-journey".to_owned()),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    );

    // 1. The dirty folder goes to the VM's ~/work with its git state: a
    // clone of its GitHub remote and a bundle of the local diff.
    let repo = dirty_repo(&mac.home(), &github);
    let synced = vm.home().join("work/app");
    let (ok, summary) = run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .args(["link", "seed", "push", "--socket"])
            .arg(&vm.socket)
            .arg(&repo)
            .arg(&synced),
    );
    assert!(ok && summary["ok"] == json!(true), "seed push: {summary}");
    assert_eq!(summary["mode"], json!("seed"), "the folder was not seeded: {summary}");
    assert!(synced.join(".git").is_dir(), "no repository on the VM");
    assert_eq!(
        fs::read_to_string(synced.join("src/lib.txt")).unwrap(),
        "committed\nuncommitted change\n"
    );
    assert_eq!(fs::read_to_string(synced.join("notes.txt")).unwrap(), "untracked\n");
    let status = ["status", "--porcelain=v2", "--branch"];
    assert_eq!(git(&synced, &status), git(&repo, &status), "git status differs on the VM");
    assert_eq!(git(&synced, &["rev-parse", "HEAD"]), git(&repo, &["rev-parse", "HEAD"]));

    // 2. The chat moves mid-turn: its running turn stops for the move, and
    // what the turn wrote after the seed above goes with it (`--sync seed`, a
    // delta bundle sent once the chat is frozen).
    let mut mac_acpmux = mac.acpmux();
    let session = chat_with_history_draft_and_queue(&mut mac_acpmux, &repo);
    let surface = bound_agent_tab(&mac, &session);
    fs::write(repo.join("src/turn.txt"), "written by the running turn\n").unwrap();
    let (ok, moved) = run_json(
        Command::new(bin())
            // This Mac's state, where the seed above kept its record.
            .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .args(["link", "agent", "move", "--from-socket"])
            .arg(&mac.socket)
            .args(["--surface", &surface.to_string(), "--to-socket"])
            .arg(&vm.socket)
            .arg("--cwd")
            .arg(&synced)
            .arg("--interrupt")
            .args(["--vm-kind", "owner"])
            .args(["--sync", "seed", "--sync-socket"])
            .arg(&vm.socket)
            .arg("--sync-local")
            .arg(&repo)
            .arg("--sync-remote")
            .arg(&synced)
            .arg("--state-dir")
            .arg(root.join("pump")),
    );
    assert!(ok && moved["ok"] == json!(true), "agent move: {moved}");
    assert_eq!(moved["session_id"], json!(session), "{moved}");
    assert_eq!(
        fs::read_to_string(synced.join("src/turn.txt")).unwrap(),
        "written by the running turn\n",
        "the turn's last change stayed on the Mac"
    );

    // 3. On the VM: the chat with its history and draft, in the synced
    // folder, and its queued prompt ran there exactly once.
    let mut vm_acpmux = vm.acpmux();
    let landed = wait_until(30, "the queued prompt's turn on the VM", || {
        let events = vm_acpmux.events(&session);
        let done =
            events.iter().any(|e| e["kind"] == "turn_result" && e["msg"]["promptId"] == QUEUED_ID);
        done.then_some(events)
    });
    assert_eq!(count(&landed, "user_message", USER_TEXT, HISTORY), 1, "history: {landed:?}");
    assert_eq!(count(&landed, "agent_message_chunk", AGENT_TEXT, &format!("echo: {HISTORY}")), 1);
    // The turn the move stopped went on on the VM, before the queued prompt.
    let continued = landed
        .iter()
        .position(|e| {
            e["kind"] == "user_message"
                && e["msg"]["text"]
                    .as_str()
                    .is_some_and(|t| t.starts_with("This chat moved to another machine"))
        })
        .unwrap_or_else(|| panic!("the cut turn never went on on the VM: {landed:?}"));
    let queued_at = landed
        .iter()
        .position(|e| {
            e["kind"] == "user_message" && e["msg"].pointer(USER_TEXT) == Some(&json!(QUEUED))
        })
        .unwrap();
    assert!(continued < queued_at, "the continuation ran after the queue: {landed:?}");
    // A second look later: nothing ran it again.
    std::thread::sleep(Duration::from_secs(2));
    let events = vm_acpmux.events(&session);
    assert_eq!(count(&events, "user_message", USER_TEXT, QUEUED), 1, "{events:?}");
    assert_eq!(count(&events, "agent_message_chunk", AGENT_TEXT, &format!("echo: {QUEUED}")), 1);
    let runs = events
        .iter()
        .filter(|e| e["kind"] == "turn_result" && e["msg"]["promptId"] == QUEUED_ID)
        .count();
    assert_eq!(runs, 1, "the queued prompt's turns: {events:?}");
    let draft = vm_acpmux.call("_acpmux/draft_get", json!({"sessionId": session}));
    assert_eq!(draft["draft"], json!(DRAFT), "{draft}");
    let there = vm_acpmux.summary(&session).expect("the chat is on the VM");
    assert_eq!(there["cwd"], json!(fs::canonicalize(&synced).unwrap()), "{there}");
    assert_eq!(there["queued"].as_u64(), Some(0), "{there}");

    // 3b. The app's last step: the moved chat opens in a tab of the VM's
    // own store (`registry:<store id>`), which the VM daemon allows because
    // its own finish landed that chat.
    moved_chat_tab(&vm, &session);
    let foreign = vm.rpc(json!({"id": 5, "cmd": "new-conversation-tab",
        "agent_session": {"host": format!("registry:{}", store_id(&vm)),
                          "session": "fake-session-not-landed-here"}}));
    assert_eq!(foreign["error_code"], "conversation_tab.machine_mismatch", "{foreign}");

    // 4. On the Mac: the chat moved away, and its queued prompt never ran here.
    let left = mac_acpmux.summary(&session);
    assert!(left.as_ref().is_none_or(|s| s["status"] == "closed"), "still open: {left:?}");
    let events = mac_acpmux.events(&session);
    assert!(events.iter().any(|e| e["kind"] == "transferred"), "no transferred record");
    assert_eq!(count(&events, "user_message", USER_TEXT, QUEUED), 0, "ran on the Mac too");
}

/// Whether the daemon's `identify` lists `capability`.
fn advertises(machine: &Machine, capability: &str) -> bool {
    let identity = machine.rpc(json!({"id": 1, "cmd": "identify"}));
    identity["data"]["capabilities"]
        .as_array()
        .unwrap_or_else(|| panic!("no capabilities: {identity}"))
        .iter()
        .any(|value| value == capability)
}

/// A VM made fresh from the devbox image: the daemon's unit carries no model
/// plane identity and no shell wrote a per-home model-plane.env. The image's
/// baked `/etc/cmux/model-plane.env` has the coderouter origin but no
/// `CMUX_VM_ID`; the bind agent wrote the machine's id to
/// `/etc/cmux/daemon-instance-id`. That daemon serves `fs-v1`, so
/// `cmux link sync push` (Move to Cloud, Cloud first send) works with no
/// manual step; without the bound id it does not.
#[test]
fn a_fresh_image_vm_serves_fs_v1_from_the_baked_env_and_the_bound_id() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("cmf-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let _cleanup = Cleanup(root.clone());

    let etc = cloud_etc(&root);
    fs::write(
        etc.join("model-plane.env"),
        "# generated by cmux; the same for every machine; managed, do not edit\n\
         export OPENAI_BASE_URL='https://coderouter.cmux.internal/v1'\n\
         export OPENAI_API_KEY='cmux-vm-edge-placeholder'\n\
         export CMUX_CODEROUTER_URL='http://127.0.0.1:9'\n\
         export ANTHROPIC_BASE_URL='https://coderouter.cmux.internal'\n\
         export ANTHROPIC_API_KEY='cmux-vm-edge-placeholder'\n",
    )
    .unwrap();
    let seam = vec![("CMUX_TEST_CLOUD_ETC", etc.to_string_lossy().into_owned())];

    // No bound id yet: no identity, no fs-v1 (as before the fix, a fresh VM).
    let unbound = Machine::start(&root, "unbound", seam.clone());
    assert!(!advertises(&unbound, "fs-v1"), "fs-v1 without a machine id");
    drop(unbound);

    fs::write(etc.join("daemon-instance-id"), "vm-fresh-image\n").unwrap();
    let mac = Machine::start(&root, "mac", Vec::new());
    let vm = Machine::start(&root, "vm", seam);
    assert!(advertises(&vm, "fs-v1"), "a fresh image VM does not serve fs-v1");
    assert!(
        !vm.home().join(".config/cmux/model-plane.env").exists(),
        "the daemon must not write a per-home model-plane.env (it would shadow the image's)"
    );

    let repo = dirty_repo(&mac.home(), &root.join("github"));
    let synced = vm.home().join("work/app");
    let (ok, summary) = run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
            .args(["link", "sync", "push", "--socket"])
            .arg(&vm.socket)
            .arg(&repo)
            .arg(&synced),
    );
    assert!(ok && summary["ok"] == json!(true), "sync push: {summary}");
    assert_eq!(fs::read_to_string(synced.join("notes.txt")).unwrap(), "untracked\n");
}

/// A plain chat on `acpmux` with one finished turn.
fn plain_chat(acpmux: &mut Acpmux, cwd: &Path, text: &str) -> String {
    let created = acpmux.call("session/new", json!({"cwd": cwd, "mcpServers": []}));
    let session = created["sessionId"].as_str().unwrap().to_owned();
    acpmux.call("session/prompt", prompt(&session, text, &format!("p-{text}")));
    session
}

fn ok(reply: Value) -> Value {
    assert_eq!(reply["ok"], json!(true), "{reply}");
    reply["data"].clone()
}

/// The pump's steps up to the finish, over the two daemons' sockets: begin on
/// `from`, receive on `to` in `cwd` and every bundle page copied. Answers the
/// begin's transfer id and the receive id.
fn begin_and_receive(from: &Machine, surface: u64, to: &Machine, cwd: &Path) -> (String, String) {
    let begun = ok(from.rpc(json!({"id": 10, "cmd": "agent-transfer-begin", "surface": surface})));
    let transfer_id = begun["transfer_id"].as_str().unwrap().to_owned();
    let manifest = begun["manifest"].clone();
    // The VM's own `owner` record never lets a chat in: only the caller's
    // word that the Cloud API said `owner`.
    for kind in [json!(null), json!("team")] {
        let refused = to.rpc(json!({"id": 11, "cmd": "agent-transfer-receive",
                                    "manifest": manifest, "cwd": cwd, "vm_kind": kind}));
        assert_eq!(refused["error_code"], json!("agent_session.host_unverified"), "{refused}");
    }
    let received = ok(to.rpc(json!({"id": 11, "cmd": "agent-transfer-receive",
                                   "manifest": manifest, "cwd": cwd, "vm_kind": "owner"})));
    let receive_id = received["receive_id"].as_str().unwrap().to_owned();
    for file in manifest["files"].as_array().unwrap() {
        let (path, size) = (file["path"].as_str().unwrap(), file["size"].as_u64().unwrap());
        let mut offset = 0;
        while offset < size {
            let page = ok(from.rpc(json!({"id": 12, "cmd": "agent-transfer-read",
                "transfer_id": transfer_id, "path": path, "offset": offset})));
            let written = ok(to.rpc(json!({"id": 13, "cmd": "agent-transfer-write",
                "receive_id": receive_id, "path": path, "offset": offset,
                "data": page["data"]})));
            offset = written["next"].as_u64().unwrap();
        }
    }
    (transfer_id, receive_id)
}

/// Stops the machine's daemon and starts it again on the same state (its
/// acpmux keeps running, as it does when only the daemon restarts).
fn restart_daemon(machine: &Machine) {
    let pid = |machine: &Machine| {
        let identity = machine.rpc(json!({"id": 1, "cmd": "identify"}));
        identity["data"]["pid"].clone()
    };
    let before = pid(machine);
    assert!(before.is_u64(), "no daemon pid: {before}");
    let stopped = machine.server("stop").output().unwrap();
    assert!(stopped.status.success(), "stop: {}", String::from_utf8_lossy(&stopped.stderr));
    let ensure = machine.server("ensure").output().unwrap();
    assert!(ensure.status.success(), "ensure: {}", String::from_utf8_lossy(&ensure.stderr));
    assert_ne!(pid(machine), before, "the daemon did not restart");
}

/// cx-rppd.7: the pump settles a move whose finish answer it lost by asking
/// the VM daemon (`agent-transfer-receive-abort`). That question still gets a
/// real answer after the VM daemon restarts: a finished move answers landed,
/// an unfinished one is forgotten there (so it can never land later) and
/// answers not landed, so the Mac commits or gives the chat back instead of
/// leaving it frozen or running in two places.
#[test]
fn cloud_move_resolves_a_lost_finish_after_the_vm_daemon_restarts() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("cmr-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let _cleanup = Cleanup(root.clone());

    let mac = Machine::start(&root, "mac", Vec::new());
    let vm = Machine::start(
        &root,
        "vm",
        vec![
            ("CMUX_TEST_CLOUD_ETC", cloud_etc(&root).to_string_lossy().into_owned()),
            ("CMUX_VM_ID", "vm-cloud-move-restart".to_owned()),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    );
    let here = mac.home().join("app");
    let there = vm.home().join("work/app");
    fs::create_dir_all(&here).unwrap();
    fs::create_dir_all(&there).unwrap();
    let mut mac_acpmux = mac.acpmux();

    // A move whose finish landed the chat on the VM, its answer lost.
    let landed = plain_chat(&mut mac_acpmux, &here, "landed-chat");
    let landed_tab = bound_agent_tab(&mac, &landed);
    let (_, landed_receive) = begin_and_receive(&mac, landed_tab, &vm, &there);
    let bare =
        vm.rpc(json!({"id": 14, "cmd": "agent-transfer-finish", "receive_id": landed_receive}));
    assert_eq!(bare["error_code"], json!("agent_session.host_unverified"), "{bare}");
    ok(vm.rpc(json!({"id": 14, "cmd": "agent-transfer-finish", "receive_id": landed_receive,
                     "vm_kind": "owner"})));

    // A move whose finish never reached the VM.
    let stranded = plain_chat(&mut mac_acpmux, &here, "stranded-chat");
    let stranded_tab = bound_agent_tab(&mac, &stranded);
    let (_, stranded_receive) = begin_and_receive(&mac, stranded_tab, &vm, &there);

    restart_daemon(&vm);

    // The finished move: landed.
    let asked = vm.rpc(json!({"id": 15, "cmd": "agent-transfer-receive-abort",
                              "receive_id": landed_receive}));
    let answer = ok(asked);
    assert_eq!(answer["landed"], json!(true), "{answer}");
    // Asked again (the pump retries a lost answer): the same.
    let again = ok(vm.rpc(json!({"id": 16, "cmd": "agent-transfer-receive-abort",
                                 "receive_id": landed_receive})));
    assert_eq!(again["landed"], json!(true), "{again}");

    // The unfinished move: forgotten on the VM, not landed.
    let asked = ok(vm.rpc(json!({"id": 17, "cmd": "agent-transfer-receive-abort",
                                 "receive_id": stranded_receive})));
    assert_eq!(asked["landed"], json!(false), "{asked}");
    assert_eq!(asked["forgotten"], json!(true), "{asked}");
    let mut vm_acpmux = vm.acpmux();
    assert!(vm_acpmux.summary(&stranded).is_none(), "the stranded chat landed on the VM");
    assert!(vm_acpmux.summary(&landed).is_some(), "the landed chat is not on the VM");

    // A receive id this daemon never answered stays unknown.
    let unknown = vm.rpc(json!({"id": 18, "cmd": "agent-transfer-receive-abort",
                                "receive_id": "rcv-never-made-here"}));
    assert_eq!(unknown["error_code"], json!("agent_transfer.unknown_receive"), "{unknown}");
}
