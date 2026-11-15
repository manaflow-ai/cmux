//! A recovering `remote connect` writes one stderr line as soon as its `PATH.admin` socket is
//! bound, before any dial reports. The app forwards a person's pending wait on that line
//! (`SSHMachineLink.socketReadyLine`); a first dial that stalls writes nothing else, so without
//! it the wait never reached the link within the person's deadline (review of #39200).

#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::time::{Duration, Instant};

/// The line itself, spelled as the app matches it: `LINK_SOCKET_READY_LINE` in
/// `src/remote_runtime.rs` and `SSHMachineLink.socketReadyLine` in
/// `Packages/macOS/CmuxNext/Sources/CmuxNextRemote/SSH/SSHMachineLink.swift`. A rename on either
/// side fails here.
const SOCKET_READY: &str = "remote connect: link socket ready";

#[test]
fn a_stalled_first_dial_says_its_socket_answers_before_any_dial_reports() {
    let dir = tempfile::tempdir_in("/tmp").unwrap();
    fs::set_permissions(dir.path(), fs::Permissions::from_mode(0o700)).unwrap();
    let home = dir.path().join("home");
    let state = dir.path().join("state");
    for directory in [&home, &state] {
        fs::create_dir(directory).unwrap();
        fs::set_permissions(directory, fs::Permissions::from_mode(0o700)).unwrap();
    }
    // An ssh that never answers: the first dial stalls and reports nothing.
    let ssh = dir.path().join("ssh");
    fs::write(&ssh, "#!/bin/sh\nexec /bin/sleep 30\n").unwrap();
    fs::set_permissions(&ssh, fs::Permissions::from_mode(0o755)).unwrap();
    let local_socket = dir.path().join("link.sock");
    let admin = PathBuf::from(format!("{}.admin", local_socket.display()));

    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["remote", "connect", "ssh://drill", "--session", "ready-line"])
        .args(["--headless", "--json", "--lanes", "single", "--no-install"])
        .arg("--ssh-binary")
        .arg(&ssh)
        .arg("--state-dir")
        .arg(&state)
        .arg("--local-socket")
        .arg(&local_socket)
        .args(["--connect-timeout-seconds", "30"])
        .env("HOME", &home)
        .env("XDG_STATE_HOME", home.join("state"))
        .env("XDG_CONFIG_HOME", home.join("config"))
        .env_remove("XDG_RUNTIME_DIR")
        .env("CMUX_TUI_STATE_DIR", dir.path().join("default-state"))
        .env("CMUX_TUI_CONFIG", dir.path().join("config.json"))
        .env_remove("CMUX_REMOTE_STATE_DIR")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_MUX_SOCKET")
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    let stderr = child.stderr.take().unwrap();
    let (lines, received) = mpsc::channel();
    std::thread::spawn(move || {
        for line in BufReader::new(stderr).lines().map_while(Result::ok) {
            if lines.send(line).is_err() {
                return;
            }
        }
    });

    let deadline = Instant::now() + Duration::from_secs(20);
    let mut before = Vec::new();
    let found = loop {
        let left = deadline.saturating_duration_since(Instant::now());
        match received.recv_timeout(left) {
            Ok(line) if line == SOCKET_READY => break true,
            Ok(line) => before.push(line),
            Err(_) => break false,
        }
    };
    // The socket answers by the time the line is read.
    let answers = UnixStream::connect(&admin).is_ok();
    let exited = child.try_wait().unwrap();
    let _ = child.kill();
    let _ = child.wait();

    assert!(found, "no `{SOCKET_READY}` line; stderr: {before:?}; exited: {exited:?}");
    assert!(answers, "the admin socket at {} did not answer", admin.display());
    assert!(
        !before.iter().any(|line| line.ends_with("; redialing")),
        "a dial reported before the socket line: {before:?}"
    );
}
