//! `peerWakeCommand` in config.json: a command the daemon runs when a message marks a peer to
//! wake (`Peer::wake`, `peer_wanted.rs`). The mark alone reaches only a route whose ssh
//! ProxyCommand reads `ACPMUX_PEER_WAKE`; this command resumes a paused machine on any route
//! (a fleet tool that asks its cloud to resume the VM, for one).
//!
//! The value is an argv; `{peer}` in any of its arguments is replaced by the peer's name, and
//! the command also gets `ACPMUX_PEER` (the name) and `ACPMUX_PEER_WAKE=1` in its environment.
//! It runs detached from the request that marked the peer, with stdio closed, for at most
//! [`TIMEOUT`] (then its process group is killed), and at most once per peer per
//! `WAKE_FOR` (the mark's window): a person who keeps typing or a send that keeps retrying runs
//! it once, and once more only when the peer stayed marked a whole window. Each run is logged
//! with its outcome. Unset (the default), nothing runs and the mark behaves as before.

use std::sync::RwLock as StdRwLock;
use std::time::Duration;
use tokio::time::Instant;

/// How long one run may take before its process group is killed.
pub const TIMEOUT: Duration = Duration::from_secs(60);

/// What `{peer}` in an argument is replaced with.
pub const PEER_PLACEHOLDER: &str = "{peer}";

/// The environment variable that names the peer to the command.
pub const PEER_ENV: &str = "ACPMUX_PEER";

/// The daemon's `peerWakeCommand`, shared by the hub and each of its peers, so a config reload
/// reaches the running peers at once (`hub/catalog_reload.rs`).
#[derive(Debug, Default)]
pub struct WakeCommand {
    argv: StdRwLock<Option<Vec<String>>>,
}

impl WakeCommand {
    pub fn new(argv: Option<Vec<String>>) -> Self {
        Self { argv: StdRwLock::new(argv) }
    }

    pub fn set(&self, argv: Option<Vec<String>>) {
        *self.argv.write().unwrap_or_else(|e| e.into_inner()) = argv;
    }

    /// The argv to run for `peer`, or `None` when no command is set (an empty argv or an empty
    /// program is none).
    pub fn argv_for(&self, peer: &str) -> Option<Vec<String>> {
        let held = self.argv.read().unwrap_or_else(|e| e.into_inner());
        argv_for(held.as_deref()?, peer)
    }
}

/// `template` with `{peer}` replaced by `peer` in each argument; `None` when it names no program.
pub fn argv_for(template: &[String], peer: &str) -> Option<Vec<String>> {
    let program = template.first()?;
    if program.trim().is_empty() {
        return None;
    }
    Some(template.iter().map(|arg| arg.replace(PEER_PLACEHOLDER, peer)).collect())
}

/// Whether a run is due now, given when the last one started: the first, or one a whole
/// `window` after the last. Records `now` as the last run when it is.
pub fn take_due(last: &mut Option<Instant>, now: Instant, window: Duration) -> bool {
    let due = last.is_none_or(|at| now.saturating_duration_since(at) >= window);
    if due {
        *last = Some(now);
    }
    due
}

/// How one run ended.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// It exited with this code (`None`: ended by a signal).
    Exited(Option<i32>),
    /// It ran past the timeout and its process group was killed.
    TimedOut,
    /// It could not be started or waited on.
    Failed(String),
}

impl Outcome {
    pub fn succeeded(&self) -> bool {
        matches!(self, Self::Exited(Some(0)))
    }
}

/// Runs `argv` for `peer` and waits at most `timeout` for it. Blocking: call it off the runtime
/// (`tokio::task::spawn_blocking`). The child leads its own process group, which is killed when
/// it runs past `timeout` (and when its handle is dropped, `cmux_process::Child`).
pub fn run(argv: &[String], peer: &str, timeout: Duration) -> Outcome {
    let Some((program, args)) = argv.split_first() else {
        return Outcome::Failed("no program".into());
    };
    let spawned = cmux_process::Command::new(program)
        .args(args)
        .env(PEER_ENV, peer)
        .env(crate::peer::WAKE_ENV, "1")
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::null())
        .stderr(cmux_process::Stdio::null())
        .process_group(0)
        .spawn();
    let mut child = match spawned {
        Ok(child) => child,
        Err(e) => return Outcome::Failed(e.to_string()),
    };
    match child.wait_timeout(timeout) {
        Ok(Some(status)) => Outcome::Exited(status.code()),
        Ok(None) => {
            let _ = child.kill();
            let _ = child.wait();
            Outcome::TimedOut
        }
        Err(e) => Outcome::Failed(e.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn argv(parts: &[&str]) -> Vec<String> {
        parts.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn the_peer_name_replaces_each_placeholder_and_unset_runs_nothing() {
        let template = argv(&["lane-wake", "wake", "{peer}", "--tag={peer}-x", "--detach"]);
        assert_eq!(
            argv_for(&template, "lane-12"),
            Some(argv(&["lane-wake", "wake", "lane-12", "--tag=lane-12-x", "--detach"]))
        );
        assert_eq!(argv_for(&[], "p"), None, "an empty argv is no command");
        assert_eq!(argv_for(&argv(&[" "]), "p"), None, "a blank program is no command");

        let command = WakeCommand::default();
        assert_eq!(command.argv_for("p"), None, "unset by default");
        command.set(Some(argv(&["wake", "{peer}"])));
        assert_eq!(command.argv_for("p"), Some(argv(&["wake", "p"])));
        command.set(None);
        assert_eq!(command.argv_for("p"), None, "a reload that removes it stops it");
    }

    #[test]
    fn a_run_is_due_once_per_window() {
        let window = Duration::from_secs(180);
        let start = Instant::now();
        let mut last = None;
        assert!(take_due(&mut last, start, window), "the first mark runs it");
        assert!(!take_due(&mut last, start + Duration::from_secs(1), window), "a retry does not");
        assert!(!take_due(&mut last, start + window - Duration::from_millis(1), window));
        assert!(take_due(&mut last, start + window, window), "a whole window later it does");
        assert!(!take_due(&mut last, start + window + Duration::from_secs(5), window));
    }

    #[cfg(unix)]
    #[test]
    fn a_run_gets_the_peer_and_its_exit_code_and_a_hung_one_is_killed_at_the_timeout() {
        let dir = tempfile::tempdir().unwrap();
        let out = dir.path().join("seen");
        let script = format!(
            "printf '%s %s %s' \"$1\" \"${PEER_ENV}\" \"${wake}\" > '{}'; exit 3",
            out.display(),
            wake = crate::peer::WAKE_ENV
        );
        let template = argv(&["/bin/sh", "-c", &script, "sh", "{peer}"]);
        let argv = argv_for(&template, "lane-7").unwrap();
        assert_eq!(run(&argv, "lane-7", Duration::from_secs(10)), Outcome::Exited(Some(3)));
        assert_eq!(std::fs::read_to_string(&out).unwrap(), "lane-7 lane-7 1");

        let started = std::time::Instant::now();
        let hung = argv_for(&["/bin/sh".into(), "-c".into(), "sleep 30".into()], "p").unwrap();
        assert_eq!(run(&hung, "p", Duration::from_millis(200)), Outcome::TimedOut);
        assert!(started.elapsed() < Duration::from_secs(10), "{:?}", started.elapsed());

        let missing = argv(&["/nonexistent/peer-wake-command"]);
        assert!(matches!(run(&missing, "p", Duration::from_secs(1)), Outcome::Failed(_)));
        assert!(Outcome::Exited(Some(0)).succeeded() && !Outcome::TimedOut.succeeded());
    }
}
