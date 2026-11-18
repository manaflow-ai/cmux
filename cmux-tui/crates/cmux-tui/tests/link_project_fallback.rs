//! Projection is the default for every attached folder (RFD 0007), so the copy is its fallback:
//! whatever step of a projection fails, the start copies the folder as before and says why
//! (`projection_fallback`), and the kill switch (`CMUX_PROJECTED_FOLDERS=0`, `cmux link project
//! disable`) sends every start down the copy without dialing a projection at all.
//!
//! One fault per step a projection can fail at: a machine without `projection-v1`, a mount that
//! fails, a manifest past what the machine takes, and a dial that drops during setup. Each machine
//! here is the real `fs-v1` service (`FsService`), so the copy is the real one; only its
//! `projection.serve` dial is scripted. No FUSE is needed.
//!
//! Leo, 2026-11-18: "Idk why you're saying projection off by default if it works while the so
//! called default doesn't / Just do it and fix the edge cases and gaps and improve on it".
#![cfg(target_os = "linux")]

use std::io::{BufRead as _, BufReader, Read as _, Write as _};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};

use cmux_tui_core::fs_ops::{self, FsService, Roots, stream};
use cmux_tui_core::projection::{PROJECTION_CAPABILITY, SERVE};
use serde_json::{Value, json};

/// How the machine's projection dial goes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Fault {
    /// The machine does not list `projection-v1` (an older image).
    NoCapability,
    /// The machine reads the manifest, then its mount fails (no `/dev/fuse`, say).
    MountFails,
    /// The machine refuses the manifest as too large.
    TooLarge,
    /// The machine reads the manifest, then the dial drops before any answer.
    DropsDial,
}

struct Machine {
    _sockets: tempfile::TempDir,
    socket: PathBuf,
    /// How many `projection.serve` dials the machine saw.
    dials: Arc<AtomicUsize>,
}

fn machine(home: &Path, fault: Fault) -> Machine {
    let sockets = tempfile::Builder::new().prefix("pf").tempdir_in("/tmp").unwrap();
    let socket = sockets.path().join("m.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let service: &'static FsService =
        Box::leak(Box::new(FsService::new(Roots::new([home.to_path_buf()]))));
    let dials = Arc::new(AtomicUsize::new(0));
    let counted = dials.clone();
    std::thread::spawn(move || {
        for connection in listener.incoming() {
            let Ok(connection) = connection else { return };
            let dials = counted.clone();
            std::thread::spawn(move || serve(connection, service, fault, &dials));
        }
    });
    Machine { _sockets: sockets, socket, dials }
}

fn send(writer: &mut UnixStream, value: &Value) -> bool {
    let mut text = value.to_string();
    text.push('\n');
    writer.write_all(text.as_bytes()).is_ok()
}

fn serve(connection: UnixStream, service: &FsService, fault: Fault, dials: &AtomicUsize) {
    let mut writer = connection.try_clone().unwrap();
    let mut reader = BufReader::new(connection);
    loop {
        let mut line = String::new();
        if reader.read_line(&mut line).unwrap_or(0) == 0 {
            return;
        }
        let request: Value = serde_json::from_str(&line).unwrap();
        let id = request["id"].clone();
        let cmd = request["cmd"].as_str().unwrap_or_default().to_string();
        if cmd == SERVE {
            dials.fetch_add(1, Ordering::SeqCst);
            let mut manifest = Vec::new();
            let take = request["manifest_bytes"].as_u64().unwrap_or(0);
            if fault != Fault::TooLarge {
                let _ = (&mut reader).take(take).read_to_end(&mut manifest);
            }
            let (code, error) = match fault {
                Fault::MountFails => ("projection.mount_failed", "fuse: /dev/fuse is missing"),
                Fault::TooLarge => ("projection.too_large", "the manifest is too large"),
                // The dial ends inside setup: no answer at all.
                Fault::DropsDial | Fault::NoCapability => return,
            };
            let _ = send(
                &mut writer,
                &json!({"id": id, "ok": false, "error": error, "error_code": code}),
            );
            return;
        }
        let reply = if cmd == "identify" {
            let mut capabilities = vec![
                fs_ops::FS_CAPABILITY,
                fs_ops::FS_SYMLINK_CAPABILITY,
                fs_ops::FS_WRITE_DEFLATE_CAPABILITY,
                fs_ops::FS_WRITE_NOFOLLOW_CAPABILITY,
            ];
            if fault != Fault::NoCapability {
                capabilities.push(PROJECTION_CAPABILITY);
            }
            json!({"id": id, "ok": true, "data": {"capabilities": capabilities}})
        } else {
            stream::answer(&id, service.call("local", &cmd, request))
        };
        if !send(&mut writer, &reply) {
            return;
        }
    }
}

struct World {
    _root: tempfile::TempDir,
    local: PathBuf,
    home: PathBuf,
    state: PathBuf,
}

fn world() -> World {
    let root = tempfile::tempdir().unwrap();
    let base = std::fs::canonicalize(root.path()).unwrap();
    let local = base.join("project");
    for (path, text) in [
        ("README.md", "# project\n"),
        ("src/main.rs", "fn main() {}\n"),
        ("src/deep/lib.rs", "pub fn f() {}\n"),
    ] {
        let at = local.join(path);
        std::fs::create_dir_all(at.parent().unwrap()).unwrap();
        std::fs::write(at, text).unwrap();
    }
    let home = base.join("home");
    std::fs::create_dir_all(home.join("work")).unwrap();
    let state = base.join("state");
    World { _root: root, local, home, state }
}

fn new_key() -> String {
    static NEXT: AtomicUsize = AtomicUsize::new(0);
    let n = NEXT.fetch_add(1, Ordering::Relaxed);
    format!("{:08x}-0b0a-4908-8706-{:012x}", std::process::id(), n)
}

/// `cmux link start-chat copy` of the world's folder; `switch` sets `CMUX_PROJECTED_FOLDERS`
/// (unset when `None`). The start's last JSON line.
fn start_chat(w: &World, socket: &Path, switch: Option<&str>) -> Value {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command.env("CMUX_TUI_STATE_DIR", &w.state).env_remove("CMUX_SYNC_COPY_RATE");
    match switch {
        Some(value) => command.env("CMUX_PROJECTED_FOLDERS", value),
        None => command.env_remove("CMUX_PROJECTED_FOLDERS"),
    };
    let key = new_key();
    let output = command
        .args(["link", "start-chat", "copy", "--key", &key, "--account", "leo"])
        .args(["--machine", "vm-a", "--socket"])
        .arg(socket)
        .arg("--local")
        .arg(&w.local)
        .arg("--work-root")
        .arg(w.home.join("work"))
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout);
    stdout.lines().rev().find_map(|line| serde_json::from_str::<Value>(line).ok()).unwrap_or_else(
        || panic!("start-chat copy: {stdout}{}", String::from_utf8_lossy(&output.stderr)),
    )
}

fn project(w: &World, action: &str) -> Value {
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .env("CMUX_TUI_STATE_DIR", &w.state)
        .env_remove("CMUX_PROJECTED_FOLDERS")
        .args(["link", "project", action])
        .output()
        .unwrap();
    serde_json::from_slice(&output.stdout).unwrap()
}

/// The start copied the whole folder, and says why it was not projected.
fn copied(answer: &Value, why: &str) {
    assert_eq!(answer["ok"], true, "{answer}");
    assert_ne!(answer["mode"], "projected", "{answer}");
    assert_eq!(answer["projection_fallback"], why, "{answer}");
    let folder = PathBuf::from(answer["folder"].as_str().unwrap());
    assert_eq!(std::fs::read_to_string(folder.join("README.md")).unwrap(), "# project\n");
    assert_eq!(std::fs::read_to_string(folder.join("src/deep/lib.rs")).unwrap(), "pub fn f() {}\n");
    assert_eq!(std::fs::read_to_string(folder.join("src/main.rs")).unwrap(), "fn main() {}\n");
}

#[test]
fn a_machine_without_projection_v1_gets_a_copy_and_no_dial() {
    let w = world();
    let m = machine(&w.home, Fault::NoCapability);
    copied(&start_chat(&w, &m.socket, None), "projection.unavailable");
    assert_eq!(m.dials.load(Ordering::SeqCst), 0);
}

#[test]
fn a_mount_that_fails_falls_back_to_the_copy() {
    let w = world();
    let m = machine(&w.home, Fault::MountFails);
    copied(&start_chat(&w, &m.socket, None), "projection.failed");
    assert_eq!(m.dials.load(Ordering::SeqCst), 1);
}

#[test]
fn a_manifest_the_machine_refuses_as_too_large_falls_back_to_the_copy() {
    let w = world();
    let m = machine(&w.home, Fault::TooLarge);
    copied(&start_chat(&w, &m.socket, None), "projection.too_large");
    assert_eq!(m.dials.load(Ordering::SeqCst), 1);
}

#[test]
fn a_dial_that_drops_during_setup_falls_back_to_the_copy() {
    let w = world();
    let m = machine(&w.home, Fault::DropsDial);
    copied(&start_chat(&w, &m.socket, None), "projection.failed");
    assert_eq!(m.dials.load(Ordering::SeqCst), 1);
}

#[test]
fn the_env_kill_switch_copies_without_dialing() {
    let w = world();
    let m = machine(&w.home, Fault::MountFails);
    copied(&start_chat(&w, &m.socket, Some("0")), "projection.off");
    assert_eq!(m.dials.load(Ordering::SeqCst), 0, "CMUX_PROJECTED_FOLDERS=0 never dials");
}

#[test]
fn disable_copies_without_dialing_and_enable_projects_again() {
    let w = world();
    let m = machine(&w.home, Fault::MountFails);
    assert_eq!(project(&w, "status")["enabled"], true, "on by default");
    assert_eq!(project(&w, "disable")["enabled"], false);
    assert_eq!(project(&w, "status")["enabled"], false);
    copied(&start_chat(&w, &m.socket, None), "projection.off");
    assert_eq!(m.dials.load(Ordering::SeqCst), 0, "`disable` never dials");
    // The env switch wins over the setting, both ways.
    copied(&start_chat(&w, &m.socket, Some("1")), "projection.failed");
    assert_eq!(m.dials.load(Ordering::SeqCst), 1);
    assert_eq!(project(&w, "enable")["enabled"], true);
    copied(&start_chat(&w, &m.socket, None), "projection.failed");
    assert_eq!(m.dials.load(Ordering::SeqCst), 2, "`enable` tries the projection first again");
}
