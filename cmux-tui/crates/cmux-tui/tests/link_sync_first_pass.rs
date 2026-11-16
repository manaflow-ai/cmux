//! A Cloud chat from a folder past what a copy sends whole (Leo's `~/Projects`: no repository
//! itself, repositories inside it, more than 20 GB) starts at once: the start's folder check goes
//! on, and the copy, against the real `FsService` over a link with a round trip, sends a first pass
//! (each repository's files, none of their histories, never the 21 GiB file) instead of refusing.
//!
//! Leo, 2026-11-15, on that refusal: "why are you guys still blocking on these?"
#![cfg(unix)]

use std::io::{BufRead as _, BufReader, Write as _};
use std::os::unix::net::UnixListener;
use std::path::Path;
use std::process::Command;
use std::time::{Duration, Instant};

use cmux_tui_core::fs_ops::{self, FsService, Roots, stream};
use serde_json::{Value, json};

/// The link's round trip: about Leo's to a Cloud machine.
const RTT: Duration = Duration::from_millis(50);

/// Serves `fs.*` lines on `socket` over `home`, each answer `RTT` after its request came.
fn serve(socket: &Path, home: &Path) {
    let listener = UnixListener::bind(socket).unwrap();
    let service: &'static FsService =
        Box::leak(Box::new(FsService::new(Roots::new([home.to_path_buf()]))));
    std::thread::spawn(move || {
        for connection in listener.incoming() {
            let Ok(connection) = connection else { return };
            std::thread::spawn(move || {
                let mut writer = connection.try_clone().unwrap();
                let (answers, due) = std::sync::mpsc::channel::<(Instant, String)>();
                std::thread::spawn(move || {
                    for (at, text) in due {
                        std::thread::sleep(at.saturating_duration_since(Instant::now()));
                        if writer.write_all(text.as_bytes()).is_err() {
                            return;
                        }
                    }
                });
                for line in BufReader::new(connection).lines() {
                    let Ok(line) = line else { return };
                    let came = Instant::now();
                    let request: Value = serde_json::from_str(&line).unwrap();
                    let id = request["id"].clone();
                    let cmd = request["cmd"].as_str().unwrap_or_default().to_string();
                    let reply = if cmd == "identify" {
                        json!({"id": id, "ok": true, "data": {"capabilities": [
                            fs_ops::FS_CAPABILITY, fs_ops::FS_SYMLINK_CAPABILITY,
                            fs_ops::FS_WRITE_DEFLATE_CAPABILITY, fs_ops::FS_WRITE_NOFOLLOW_CAPABILITY,
                        ]}})
                    } else {
                        stream::answer(&id, service.call("local", &cmd, request))
                    };
                    let mut text = reply.to_string();
                    text.push('\n');
                    if answers.send((came + RTT, text)).is_err() {
                        return;
                    }
                }
            });
        }
    });
}

fn write(path: &Path, text: &str) {
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    std::fs::write(path, text).unwrap();
}

fn git(dir: &Path, args: &[&str]) {
    let status = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@example.invalid"])
        .args(args)
        .status()
        .unwrap();
    assert!(status.success(), "git {args:?}");
}

/// `~/Projects`' shape: repositories right inside it and one level down, a few loose notes and
/// small files, and a sparse 21 GiB disk image (no disk spent) that puts it past 20 GB.
fn projects(at: &Path) {
    for name in ["FEX", "cmux", "work/api"] {
        let repo = at.join(name);
        std::fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "-q"]);
        write(&repo.join("src/main.rs"), &format!("// {name}\nfn main() {{}}\n"));
        write(&repo.join("README.md"), &format!("# {name}\n"));
        git(&repo, &["add", "."]);
        git(&repo, &["commit", "-qm", "init"]);
    }
    write(&at.join("notes.md"), "a parent of repositories\n");
    write(&at.join("cmux-matrix-word.txt"), "pelican\n");
    for index in 0..500 {
        write(&at.join(format!("scratch/d{}/f{index:04}.txt", index % 10)), &format!("{index}\n"));
    }
    let image = at.join("Downloads/disk.img");
    std::fs::create_dir_all(image.parent().unwrap()).unwrap();
    std::fs::File::create(&image).unwrap().set_len(21 * 1024 * 1024 * 1024).unwrap();
}

fn cmux(state: &Path, args: &[&str]) -> (bool, Value, String) {
    let output = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .env("CMUX_TUI_STATE_DIR", state)
        .args(args)
        .output()
        .unwrap();
    let stdout = String::from_utf8_lossy(&output.stdout).to_string();
    let line = stdout.lines().rev().find_map(|line| serde_json::from_str::<Value>(line).ok());
    (
        output.status.success(),
        line.unwrap_or(Value::Null),
        format!("{stdout}{}", String::from_utf8_lossy(&output.stderr)),
    )
}

#[test]
fn a_projects_folder_past_the_limits_starts_at_once_from_a_first_pass() {
    let root = tempfile::tempdir().unwrap();
    let root = std::fs::canonicalize(root.path()).unwrap();
    let local = root.join("Projects");
    projects(&local);
    let state = root.join("state");
    let home = root.join("home");
    std::fs::create_dir_all(home.join("work")).unwrap();
    let sockets = tempfile::Builder::new().prefix("fp").tempdir_in("/tmp").unwrap();
    let socket = sockets.path().join("m.sock");
    serve(&socket, &home);
    let remote = home.join("work/Projects");
    let local_text = local.to_str().unwrap();

    // The start's folder check, before any machine: it goes on (it was `copy.too_large`).
    let (ok, answer, text) =
        cmux(&state, &["link", "start-chat", "preflight", "--local", local_text]);
    assert!(ok, "preflight refused: {text}");
    assert_eq!(answer, json!({"ok": true}), "{text}");

    // The copy: a first pass, not a refusal.
    let started = Instant::now();
    let (ok, summary, text) = cmux(
        &state,
        &[
            "link",
            "sync",
            "push",
            "--socket",
            socket.to_str().unwrap(),
            local_text,
            remote.to_str().unwrap(),
        ],
    );
    let took = started.elapsed();
    assert!(ok, "the copy refused: {text}");
    println!(
        "first pass of a ~/Projects-shaped folder: {} ms at {} ms a round trip; {summary}",
        took.as_millis(),
        RTT.as_millis()
    );

    // Each repository's files and the folder's own are on the machine: the chat reads them.
    for path in [
        "FEX/src/main.rs",
        "cmux/README.md",
        "work/api/src/main.rs",
        "notes.md",
        "cmux-matrix-word.txt",
        "scratch/d3/f0003.txt",
    ] {
        assert!(remote.join(path).is_file(), "{path} is not on the machine: {summary}");
    }
    assert_eq!(std::fs::read_to_string(remote.join("cmux-matrix-word.txt")).unwrap(), "pelican\n");
    // Never the 21 GiB image, never a history.
    assert!(!remote.join("Downloads/disk.img").exists());
    assert!(!remote.join("cmux/.git").exists());
    assert!(summary["skipped_counts"]["left_on_mac"].as_u64().unwrap_or(0) >= 1, "{summary}");
    // At once: well under a minute for the first pass, where a refusal sent nothing at all.
    assert!(took < Duration::from_secs(60), "took {took:?}");
}
