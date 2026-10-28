//! A promptless `acpmux new` from a pipe fails with usage, without starting a
//! daemon and waiting for the full-screen TUI that has no terminal to draw on.
#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
const HERMETIC: daemon_env::Process = daemon_env::Process::deny();

use std::fs;
use std::io::{Read, Write};
use std::os::unix::fs::PermissionsExt;
use std::process::Stdio;
use std::time::Duration;
use wait_timeout::ChildExt;

struct Cleanup(std::path::PathBuf);

impl Drop for Cleanup {
    fn drop(&mut self) {
        // A pre-fix process can start a daemon before getting stuck in the TUI;
        // stop it even when the bounded assertion fails.
        let mut shutdown = daemon_env::command(&self.0, daemon_env::Agents::Deny, &[]);
        shutdown
            .args(["daemon", "shutdown", "--end-agents"])
            .env("ACPMUX_HOME", &self.0)
            .env("ACPMUX_LOGIN_ENV", "0")
            .current_dir(&self.0);
        let _ = shutdown.output();
        let _ = fs::remove_dir_all(&self.0);
    }
}

#[test]
fn promptless_new_from_a_pipe_exits_with_usage_without_starting_a_daemon() {
    let root = std::env::temp_dir().join(format!("acpmux-new-pipe-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    fs::create_dir_all(&root).unwrap();
    fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
    let _cleanup = Cleanup(root.clone());

    let mut cmd = daemon_env::command(&root, daemon_env::Agents::Deny, &[]);
    cmd.args(["new", "-m", "claude"])
        .env("ACPMUX_HOME", &root)
        .env("ACPMUX_LOGIN_ENV", "0")
        .current_dir(&root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = cmd.spawn().expect("spawn acpmux new");
    child.stdin.take().unwrap().write_all(b"\n").unwrap();

    let status = match child.wait_timeout(Duration::from_secs(3)).expect("wait for acpmux new") {
        Some(status) => status,
        None => {
            let _ = child.kill();
            let _ = child.wait();
            panic!("promptless new did not exit promptly");
        }
    };
    let mut stdout = String::new();
    child.stdout.take().unwrap().read_to_string(&mut stdout).unwrap();
    let mut stderr = String::new();
    child.stderr.take().unwrap().read_to_string(&mut stderr).unwrap();

    assert_eq!(status.code(), Some(2), "stdout: {stdout}\nstderr: {stderr}");
    assert!(stderr.contains("usage"), "stderr: {stderr}");
    assert!(stderr.contains("needs a terminal"), "stderr: {stderr}");
    assert!(fs::read_dir(&root).unwrap().next().is_none(), "daemon side effects in {root:?}");
}
