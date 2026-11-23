//! Move to another Cloud machine for a chat that started on a Cloud machine, end to end on one
//! Linux box with real processes: its folder (a clone VM one made itself, with no folder of this
//! Mac's behind it) goes VM one to VM two as git, from the tip its branch tracks, which GitHub
//! has (`seed_cli::hop`); then the folder moves back to VM one, which still has it as the chat
//! left it, as only what changed since. Nothing is written on this Mac but a private bundle file.
//!
//! Linux only, as a Cloud host is.
#![cfg(target_os = "linux")]

mod journey_support;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

use journey_support::*;
use serde_json::{Value, json};

fn vm(root: &Path, name: &str, github: &Path) -> Machine {
    Machine::start(
        root,
        name,
        vec![
            ("CMUX_TEST_CLOUD_ETC", cloud_etc(root).to_string_lossy().into_owned()),
            ("CMUX_TEST_GIT_SEED_GITHUB", github.to_string_lossy().into_owned()),
            ("CMUX_VM_ID", format!("vm-git-move-{name}")),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    )
}

/// `acme/app` on the fake GitHub, with one commit on `main`.
fn publish(root: &Path, github: &Path) {
    let source = root.join("upstream-src");
    fs::create_dir_all(source.join("src")).unwrap();
    git(&source, &["init", "-q", "-b", "main"]);
    fs::write(source.join("src/lib.txt"), "committed\n").unwrap();
    fs::write(source.join("README.md"), "app\n").unwrap();
    git(&source, &["add", "-A"]);
    git(&source, &["commit", "-q", "-m", "first"]);
    let bare = github.join("acme/app.git");
    fs::create_dir_all(&bare).unwrap();
    git(&bare, &["init", "-q", "--bare", "-b", "main"]);
    git(&bare, &["config", "uploadpack.allowFilter", "true"]);
    git(&bare, &["config", "uploadpack.allowAnySHA1InWant", "true"]);
    git(&source, &["push", "-q", bare.to_str().unwrap(), "main"]);
}

/// VM one's own clone of `acme/app` (no seed: the chat started there), with the chat's work:
/// an unpushed commit, a staged file, an uncommitted edit, an untracked file and a stash.
fn started_on_vm(folder: &Path, github: &Path) {
    let bare = github.join("acme/app.git");
    fs::create_dir_all(folder.parent().unwrap()).unwrap();
    git(
        folder.parent().unwrap(),
        &["clone", "-q", "-b", "main", bare.to_str().unwrap(), folder.to_str().unwrap()],
    );
    git(folder, &["remote", "set-url", "origin", "https://github.com/acme/app.git"]);
    fs::write(folder.join("src/lib.txt"), "committed\non vm one\n").unwrap();
    git(folder, &["commit", "-q", "-am", "on vm one"]);
    fs::write(folder.join("stashme.txt"), "to stash\n").unwrap();
    git(folder, &["add", "stashme.txt"]);
    git(folder, &["stash", "push", "-q", "--", "stashme.txt"]);
    fs::write(folder.join("src/staged.txt"), "staged on vm one\n").unwrap();
    git(folder, &["add", "src/staged.txt"]);
    fs::write(folder.join("README.md"), "app\nuncommitted on vm one\n").unwrap();
    fs::write(folder.join("notes.txt"), "untracked\n").unwrap();
}

/// What must match between two machines' folders.
fn state(folder: &Path) -> Vec<String> {
    [
        &["status", "--porcelain=v2", "--branch", "--untracked-files=all"][..],
        &["rev-parse", "HEAD"],
        &["diff"],
        &["diff", "--cached"],
        &["stash", "list", "--format=%H"],
    ]
    .iter()
    .map(|args| git(folder, args))
    .collect()
}

fn has_ref(folder: &Path, name: &str) -> bool {
    !git(folder, &["for-each-ref", "--format=%(refname)", name]).trim().is_empty()
}

/// Every file under this Mac's state folder, with its size: a move writes there only its own
/// records and private bundles, never a working copy.
fn mac_files(dir: &Path) -> Vec<(PathBuf, u64)> {
    let mut found = Vec::new();
    let mut stack = vec![dir.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            let meta = fs::symlink_metadata(&path).unwrap();
            if meta.is_dir() {
                stack.push(path);
            } else {
                found.push((path, meta.len()));
            }
        }
    }
    found
}

#[test]
fn a_chat_started_on_a_cloud_vm_moves_to_another_as_git_and_back() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("cmg-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let _cleanup = Cleanup(root.clone());

    let github = root.join("github");
    publish(&root, &github);
    let mac = Machine::start(&root, "mac", Vec::new());
    let one = vm(&root, "one", &github);
    let two = vm(&root, "two", &github);
    let first = one.home().join("work/app");
    started_on_vm(&first, &github);
    let state_dir = mac.dir.join("state");

    // 1. The chat runs on VM one in the folder it started in.
    let mut one_acpmux = one.acpmux();
    let created = one_acpmux.call("session/new", json!({"cwd": first, "mcpServers": []}));
    let session = created["sessionId"].as_str().unwrap().to_owned();
    one_acpmux.call("session/prompt", prompt(&session, "hello from vm one", "p-git-history"));
    let surface = bound_agent_tab(&one, &session);

    let agent_move = |from: &Machine,
                      from_folder: &Path,
                      surface: u64,
                      to: &Machine,
                      to_folder: &Path,
                      pump: &str| {
        let output = Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", &state_dir)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .args(["link", "agent", "move", "--from-socket"])
            .arg(&from.socket)
            .args(["--surface", &surface.to_string(), "--to-socket"])
            .arg(&to.socket)
            .arg("--cwd")
            .arg(to_folder)
            .args(["--vm-kind", "owner"])
            .args(["--sync", "relay", "--sync-from-socket"])
            .arg(&from.socket)
            .arg("--sync-socket")
            .arg(&to.socket)
            .arg("--sync-local")
            .arg(from_folder)
            .arg("--sync-remote")
            .arg(to_folder)
            .arg("--state-dir")
            .arg(root.join(pump))
            .output()
            .unwrap();
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
        let line: Value = serde_json::from_str(stdout.lines().last().unwrap_or_default())
            .unwrap_or_else(|_| panic!("no JSON line: {stdout}{stderr}"));
        (output.status.success(), line, stderr)
    };

    // 2. Move to VM two: no folder of this Mac's, so the folder goes from its upstream as git,
    // and only VM one's own work crosses this Mac.
    fs::write(first.join("src/turn.txt"), "written by the turn\n").unwrap();
    let second = two.home().join("work/app");
    let (ok, moved, stderr) = agent_move(&one, &first, surface, &two, &second, "pump-out");
    assert!(ok && moved["ok"] == json!(true), "agent move: {moved} {stderr}");
    assert!(!stderr.contains("hop_fell_back"), "the move copied file by file: {stderr}");
    assert_eq!(state(&second), state(&first), "VM two differs from VM one");
    assert_eq!(fs::read_to_string(second.join("src/turn.txt")).unwrap(), "written by the turn\n");
    // As git: VM two cloned from GitHub and applied VM one's export, which VM one keeps apart
    // from any seed record (it has none).
    assert!(has_ref(&second, "refs/cmux-seed/work"), "VM two was not seeded");
    assert!(has_ref(&first, "refs/cmux-move/work"), "VM one made no move export");
    assert!(!has_ref(&first, "refs/cmux-seed"), "a move wrote VM one's seed records");
    assert!(!has_ref(&first, "refs/cmux-back"), "a move wrote VM one's seed records");
    // This Mac keeps no folder and no bundle: at most a few small records, and no relay ran.
    let kept = mac_files(&state_dir.join("link-seed"));
    assert!(kept.iter().all(|(_, size)| *size < 64 * 1024), "a big file on this Mac: {kept:?}");
    assert!(mac_files(&state_dir.join("link-relay")).is_empty(), "the folder was relayed");
    let mut two_acpmux = two.acpmux();
    let there = wait_until(30, "the chat on VM two", || two_acpmux.summary(&session));
    assert_eq!(there["cwd"], json!(fs::canonicalize(&second).unwrap()), "{there}");

    // 3. Moving back to VM one, which still has the folder as the chat left it: only VM two's
    // changes since go, as a delta on what VM one kept.
    fs::write(second.join("src/on-two.txt"), "made on vm two\n").unwrap();
    fs::write(second.join("README.md"), "app\nedited on vm two\n").unwrap();
    let theirs = one.home().join("work/theirs");
    // First a folder VM one has that the chat never left there: refused, and nothing written.
    git(
        one.home().join("work").as_path(),
        &["clone", "-q", "-b", "main", github.join("acme/app.git").to_str().unwrap(), "theirs"],
    );
    git(&theirs, &["remote", "set-url", "origin", "https://github.com/acme/app.git"]);
    fs::write(theirs.join("keep.txt"), "not ours\n").unwrap();
    let theirs_before = state(&theirs);
    let back_surface = bound_agent_tab(&two, &session);
    let (ok, refused, _) = agent_move(&two, &second, back_surface, &one, &theirs, "pump-theirs");
    assert!(!ok, "a move into VM one's own folder: {refused}");
    assert_eq!(state(&theirs), theirs_before, "a move wrote into someone's folder");
    assert_eq!(fs::read_to_string(theirs.join("keep.txt")).unwrap(), "not ours\n");

    // The folder goes back (`cmux link seed move`, the hop the move runs). Whether VM one's
    // acpmux takes the same chat back is acpmux's own rule (`transfer.exists`), not this one's.
    let (ok, back) = run_json(
        Command::new(bin())
            .env("CMUX_TUI_STATE_DIR", &state_dir)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .args(["link", "seed", "move", "--from-socket"])
            .arg(&two.socket)
            .arg("--socket")
            .arg(&one.socket)
            .arg(&second)
            .arg(&first),
    );
    assert!(ok && back["ok"] == json!(true), "move back: {back}");
    assert_eq!(state(&first), state(&second), "VM one differs from VM two after the move back");
    assert_eq!(fs::read_to_string(first.join("src/on-two.txt")).unwrap(), "made on vm two\n");
    assert!(mac_files(&state_dir.join("link-relay")).is_empty(), "the folder was relayed");
}

/// A folder the chat left on VM one that changed there since is never written over by a move
/// back: the move is refused (`relay.target_exists`) and the folder keeps its work.
#[test]
fn a_move_back_onto_a_folder_that_changed_since_is_refused() {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("cmgc-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let _cleanup = Cleanup(root.clone());

    let github = root.join("github");
    publish(&root, &github);
    let mac = Machine::start(&root, "mac", Vec::new());
    let one = vm(&root, "one", &github);
    let two = vm(&root, "two", &github);
    let first = one.home().join("work/app");
    started_on_vm(&first, &github);
    let second = two.home().join("work/app");
    let seed_move = |from: &Machine, from_folder: &Path, to: &Machine, to_folder: &Path| {
        run_json(
            Command::new(bin())
                .env("CMUX_TUI_STATE_DIR", mac.dir.join("state"))
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .args(["link", "seed", "move", "--from-socket"])
                .arg(&from.socket)
                .arg("--socket")
                .arg(&to.socket)
                .arg(from_folder)
                .arg(to_folder),
        )
    };
    let (ok, moved) = seed_move(&one, &first, &two, &second);
    assert!(ok && moved["ok"] == json!(true), "move: {moved}");
    assert_eq!(state(&second), state(&first));

    // Someone works in VM one's folder after the chat left it.
    fs::write(first.join("theirs.txt"), "made on vm one after\n").unwrap();
    let before = state(&first);
    fs::write(second.join("src/on-two.txt"), "made on vm two\n").unwrap();
    let (ok, refused) = seed_move(&two, &second, &one, &first);
    assert!(!ok, "a move back over changed work: {refused}");
    assert_eq!(refused["error_code"], json!("relay.target_exists"), "{refused}");
    assert_eq!(state(&first), before, "the move back wrote over VM one's work");
    assert!(!first.join("src/on-two.txt").exists());

    // Once that work is gone again, the move back goes.
    fs::remove_file(first.join("theirs.txt")).unwrap();
    let (ok, back) = seed_move(&two, &second, &one, &first);
    assert!(ok && back["ok"] == json!(true), "move back: {back}");
    assert_eq!(state(&first), state(&second));
}
