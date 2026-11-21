//! Move to Another Machine of a chat whose folder is projected, end to end on one Linux box with
//! real processes, in the order the app runs it (`CloudBringBack.swift`, "Move to Another
//! Machine"): a Cloud chat started on a "Mac" folder (`cmux link start-chat copy`: projected onto
//! machine A), the agent edits it there, Bring Back Local's pull takes the edit home, then `cmux
//! link agent move --sync relay --sync-seed-local` moves the chat and its folder to machine B,
//! where the agent edits again, and Bring Back Local from B brings that home too.
//!
//! Both machines are headless daemons with their own acpmux (`journey_support`) and the Cloud
//! records of the debug-only `CMUX_TEST_CLOUD_ETC` seam, so both serve `fs-v1` and
//! `projection-v1`. The Mac is this binary with a home and state folder of its own.
//!
//! Leo, 2026-11-19: "the projection folder file system thing, like among all areas, among all like
//! use cases, repositories, among all variations, we need to make sure that like is reliable back
//! and forth. And especially for remote".
#![cfg(target_os = "linux")]

mod journey_support;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use journey_support::*;
use serde_json::{Value, json};

fn fuse_here() -> bool {
    Path::new("/dev/fuse").exists()
        && Command::new("fusermount3").arg("-V").output().is_ok_and(|out| out.status.success())
}

/// The Mac: `cmux-tui` with its own home and state folder.
fn mac(root: &Path) -> Command {
    let mut command = Command::new(bin());
    command
        .env("HOME", root.join("mac/home"))
        .env("CMUX_TUI_STATE_DIR", root.join("mac/state"))
        .env("CMUX_TUI_CONFIG", root.join("mac/state/config.json"))
        .env("CMUX_PROJECTED_FOLDERS", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .env_remove("ACPMUX_SOCKET")
        .env_remove("CMUX_TAG")
        .env_remove("CMUX_VM_ID")
        .env_remove("CMUX_TEST_CLOUD_ETC")
        .stdin(Stdio::null());
    command
}

fn last_json(output: &std::process::Output) -> Value {
    let stdout = String::from_utf8_lossy(&output.stdout);
    stdout.lines().rev().find_map(|line| serde_json::from_str::<Value>(line).ok()).unwrap_or_else(
        || json!({"ok": false, "stdout": stdout, "stderr": String::from_utf8_lossy(&output.stderr)}),
    )
}

fn vm(root: &Path, name: &str) -> Machine {
    Machine::start(
        root,
        name,
        vec![
            ("CMUX_TEST_CLOUD_ETC", cloud_etc(root).to_string_lossy().into_owned()),
            ("CMUX_VM_ID", format!("vm-projection-move-{name}")),
            ("CMUX_CODEROUTER_URL", "http://127.0.0.1:9".to_owned()),
        ],
    )
}

/// Bring Back Local's pull (`cmux link seed pull --or-copy`) from `machine`'s `folder`.
fn bring_back_local(root: &Path, machine: &Machine, local: &Path, folder: &Path) -> Value {
    last_json(
        &mac(root)
            .args(["link", "seed", "pull", "--socket"])
            .arg(&machine.socket)
            .arg(local)
            .arg(folder)
            .arg("--or-copy")
            .output()
            .unwrap(),
    )
}

/// Unmounts the projection before the machines stop.
struct Unmount(PathBuf, PathBuf);

impl Drop for Unmount {
    fn drop(&mut self) {
        let _ = mac(&self.1).args(["link", "project", "stop", "--at"]).arg(&self.0).output();
        let _ = Command::new("fusermount3")
            .args(["-u", "-z"])
            .arg(&self.0)
            .stderr(Stdio::null())
            .status();
    }
}

#[test]
fn a_projected_chat_moved_to_another_machine_comes_back_from_there() {
    if !fuse_here() {
        eprintln!("skipping: no FUSE here");
        return;
    }
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos() % 1_000_000_000;
    let root = PathBuf::from("/tmp").join(format!("pmj-{}-{stamp}", std::process::id()));
    fs::create_dir_all(root.join("mac/state")).unwrap();
    let root = fs::canonicalize(&root).unwrap();
    let _cleanup = Cleanup(root.clone());
    let a = vm(&root, "vm-a");
    let b = vm(&root, "vm-b");

    // The Mac's repository.
    let local = root.join("mac/home/Projects/app");
    fs::create_dir_all(local.join("src")).unwrap();
    git(&local, &["init", "-q", "-b", "main"]);
    fs::write(local.join("src/lib.txt"), "committed\n").unwrap();
    fs::write(local.join("notes.txt"), "notes\n").unwrap();
    fs::write(local.join("mac.txt"), "mac\n").unwrap();
    git(&local, &["add", "-A"]);
    git(&local, &["commit", "-q", "-m", "first"]);

    // 1. A Cloud chat on it: projected onto machine A.
    let output = mac(&root)
        .args(["link", "start-chat", "copy", "--key", "8f0c2b1e-0c0a-4908-8706-00000000a001"])
        .args(["--account", "leo", "--machine", "vm-a", "--socket"])
        .arg(&a.socket)
        .arg("--local")
        .arg(&local)
        .arg("--work-root")
        .arg(a.home().join("work"))
        .output()
        .unwrap();
    let started = last_json(&output);
    assert_eq!(started["ok"], true, "start-chat copy: {started}");
    let on_a = PathBuf::from(started["folder"].as_str().unwrap());
    let _unmount = Unmount(on_a.clone(), root.clone());
    if started["mode"] != "projected" {
        let stderr = String::from_utf8_lossy(&output.stderr);
        if stderr.contains("mount failed") {
            eprintln!("skipping: this host may not mount FUSE: {stderr}");
            return;
        }
        panic!("not projected: {started} {stderr}");
    }
    let mut a_acpmux = a.acpmux();
    let created = a_acpmux.call("session/new", json!({"cwd": on_a, "mcpServers": []}));
    let session = created["sessionId"].as_str().unwrap().to_owned();
    a_acpmux.call("session/prompt", prompt(&session, "hello", "p-projected-hello"));
    let surface = bound_agent_tab(&a, &session);

    // 2. The agent edits on A; Move to Another Machine first brings the edit home.
    fs::write(on_a.join("notes.txt"), "notes, from machine a\n").unwrap();
    let pulled = bring_back_local(&root, &a, &local, &on_a);
    assert_eq!(pulled["ok"], true, "Bring Back Local from A: {pulled}");
    assert_eq!(fs::read_to_string(local.join("notes.txt")).unwrap(), "notes, from machine a\n");

    // 3. The chat and its folder move to B: relayed machine to machine, the Mac's record follows.
    let on_b = b.home().join("work/app-b");
    let (ok, moved) = run_json(
        mac(&root)
            .args(["link", "agent", "move", "--from-socket"])
            .arg(&a.socket)
            .args(["--surface", &surface.to_string(), "--to-socket"])
            .arg(&b.socket)
            .arg("--cwd")
            .arg(&on_b)
            .arg("--interrupt")
            .args(["--vm-kind", "owner"])
            .args(["--sync", "relay", "--sync-from-socket"])
            .arg(&a.socket)
            .arg("--sync-socket")
            .arg(&b.socket)
            .arg("--sync-local")
            .arg(&on_a)
            .arg("--sync-remote")
            .arg(&on_b)
            .arg("--sync-seed-local")
            .arg(&local)
            .arg("--state-dir")
            .arg(root.join("pump")),
    );
    assert!(ok && moved["ok"] == json!(true), "agent move to B: {moved}");
    assert_eq!(fs::read_to_string(on_b.join("notes.txt")).unwrap(), "notes, from machine a\n");
    assert_eq!(fs::read_to_string(on_b.join("src/lib.txt")).unwrap(), "committed\n");

    // 4. The agent edits on B, and Bring Back Local from B brings it home over the same base.
    fs::write(on_b.join("mac.txt"), "mac, edited on machine b\n").unwrap();
    let back = bring_back_local(&root, &b, &local, &on_b);
    assert_eq!(back["ok"], true, "Bring Back Local from B: {back}");
    assert_eq!(fs::read_to_string(local.join("mac.txt")).unwrap(), "mac, edited on machine b\n");
    assert_eq!(fs::read_to_string(local.join("notes.txt")).unwrap(), "notes, from machine a\n");
    let status = ["status", "--porcelain=v2", "--branch"];
    assert_eq!(git(&local, &status), git(&on_b, &status), "git status differs from B's");
}
