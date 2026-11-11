//! Bench round 6 N5 (W7-F), found by the real-build check on an AWS mini:
//! `acpmux worktree remove` removed the worktree of a session that was still
//! open, because a live session's `session.json` is not written yet (with
//! `--memory`, never). The removal asks the running daemon for its live
//! sessions, refuses while one works in the worktree (naming `acpmux session
//! stop`), and removes it once that session is stopped.

#![cfg(unix)]

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/).
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

use serde_json::{Value, json};
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};

const FAKE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");

/// A real daemon (`daemon run --memory`) in `state`, killed on drop.
struct Daemon {
    child: Child,
    root: PathBuf,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// `acpmux` in the hermetic environment, pointed at the daemon in `state`.
fn acpmux(scratch: &Path, state: &Path) -> Command {
    let mut cmd = daemon_env::command(scratch, daemon_env::Agents::StandIn, &[]);
    cmd.env("ACPMUX_HOME", state)
        .env("ACPMUX_SOCKET", state.join("s.sock"))
        .env("ACPMUX_LOGIN_ENV", "0");
    cmd
}

fn run(scratch: &Path, state: &Path, args: &[&str]) -> Output {
    acpmux(scratch, state).args(args).stdin(Stdio::null()).output().unwrap()
}

fn said(output: &Output) -> String {
    format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
}

fn git(dir: &Path, args: &[&str]) {
    let out = Command::new("git")
        .arg("-C")
        .arg(dir)
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"])
        .args(["-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null"])
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&out.stderr));
}

#[test]
fn w7f_worktree_remove_refuses_while_a_live_session_works_there_and_removes_it_after_stop() {
    // Short: the socket path must stay under the macOS limit.
    let root = std::env::temp_dir().join(format!("amw7f-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let scratch = root.join("x");
    let state = root.join("s");
    let repo = root.join("proj");
    for dir in [&scratch, &state, &repo] {
        std::fs::create_dir_all(dir).unwrap();
    }
    let root = std::fs::canonicalize(&root).unwrap();
    let (scratch, state, repo) = (root.join("x"), root.join("s"), root.join("proj"));
    git(&repo, &["init", "-q"]);
    git(&repo, &["commit", "-q", "--allow-empty", "-m", "first"]);
    std::fs::write(
        state.join("config.json"),
        json!({
            "harnesses": {"fake": {"argv": ["python3", FAKE]}},
            "defaultHarness": "fake",
            "permissionPolicy": "approve-all",
        })
        .to_string(),
    )
    .unwrap();
    let mut child = acpmux(&scratch, &state)
        .args(["daemon", "run", "--memory", "--ready-fd", "1", "--log", "warn"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let ready = BufReader::new(child.stdout.take().unwrap())
        .lines()
        .map_while(Result::ok)
        .any(|line| serde_json::from_str::<Value>(&line).is_ok_and(|v| v["ready"] == true));
    let _daemon = Daemon { child, root: root.clone() };
    assert!(ready, "the daemon exited before its ready line");

    let repo_text = repo.to_str().unwrap();
    let made = run(&scratch, &state, &["new", "fake", "-n", "live", "--worktree", repo_text, "-d"]);
    assert!(made.status.success(), "{}", said(&made));
    let worktree = daemon_env::home(&scratch).join(".cmux/worktrees/proj/live");
    assert!(worktree.is_dir(), "{}", said(&made));

    // The session is open: the removal is refused and names the stop command.
    let refused = run(&scratch, &state, &["worktree", "remove", "live", "--discard"]);
    assert_eq!(refused.status.code(), Some(1), "{}", said(&refused));
    assert!(said(&refused).contains("acpmux session stop live"), "{}", said(&refused));
    assert!(worktree.is_dir(), "a live session's worktree was removed");

    // Stopped, it goes.
    let stopped = run(&scratch, &state, &["session", "stop", "live"]);
    assert!(stopped.status.success(), "{}", said(&stopped));
    let removed = run(&scratch, &state, &["worktree", "remove", "live"]);
    assert!(removed.status.success(), "{}", said(&removed));
    assert!(!worktree.exists(), "{}", said(&removed));
}
