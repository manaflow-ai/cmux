//! A chat started in a folder the machine is still cloning waits for the clone instead of failing
//! "cwd is not a directory" (cmuxterm-hq#7415, row 10). `cmux cloud new-machine --repo URL` answers
//! once the machine's bootstrap has started, and the clone into `~/work/NAME` runs in that
//! bootstrap afterwards (`CloudMachineBootstrap.runner`), so a `start-chat --cwd ~/work/NAME` right
//! after it can reach the machine before the folder does. A small GitHub repository usually won
//! that race; a GitLab one (or any larger clone) lost it.
//!
//! One `cloud exec` asks the machine whether `--cwd` is there. While it is not and the bootstrap is
//! still starting or running, the machine waits on it for up to [`SLICE_SECONDS`] and the CLI asks
//! again until [`MAX_WAIT`] (or `--timeout`) runs out. A bootstrap that failed without making the
//! folder fails the start with its status and log. Anything else (the folder is there, no bootstrap
//! on the machine, an exec the machine refused) leaves the start as it was.

use std::time::Duration;

use serde_json::{Value, json};

use super::{GUEST_PRELUDE, Outcome, Runner, at, exec, failed, shell_quote};

/// The machine's bootstrap status file and log (`CloudMachineBootstrap.statusPath` and `logPath`,
/// in the work user's home).
pub(super) const STATUS: &str = ".cmux/bootstrap/status.json";
pub(super) const LOG: &str = ".cmux/bootstrap/bootstrap.log";
/// How long one exec waits on the machine (the exec itself stops after 25 s).
pub(super) const SLICE_SECONDS: u64 = 15;
/// The longest a start waits for a clone: the repo step's own clone limit.
pub(super) const MAX_WAIT: Duration = Duration::from_secs(10 * 60);

/// What the machine said about `--cwd`.
#[derive(Debug, PartialEq)]
pub(super) enum Folder {
    /// The folder is there, there is no bootstrap, or the machine could not be asked: start as before.
    Go,
    /// The bootstrap is still running and the folder is not there yet.
    Cloning,
    /// The bootstrap ended without the folder; its status file.
    Missing(Value),
}

/// The script: waits up to [`SLICE_SECONDS`] while the folder is missing and the bootstrap runs,
/// then prints `ready`, `busy`, `ended` and the status file, or `none`.
pub(super) fn script(cwd: &str) -> String {
    format!(
        "{GUEST_PRELUDE}dir={dir}; s=\"$HOME/{STATUS}\"; \
         busy() {{ grep -qE '\"state\":\"(starting|running)\"' \"$s\" 2>/dev/null; }}; \
         i=0; while [ ! -d \"$dir\" ] && busy && [ \"$i\" -lt {SLICE_SECONDS} ]; do sleep 1; i=$((i+1)); done; \
         if [ -d \"$dir\" ]; then echo ready; elif busy; then echo busy; \
         elif [ -f \"$s\" ]; then echo ended; cat \"$s\"; else echo none; fi",
        dir = shell_quote(cwd),
    )
}

/// Reads one answer of [`script`].
pub(super) fn read(stdout: &str) -> Folder {
    let mut lines = stdout.trim().splitn(2, '\n');
    match lines.next().map(str::trim) {
        Some("busy") => Folder::Cloning,
        Some("ended") => {
            let status = lines
                .next()
                .and_then(|text| serde_json::from_str::<Value>(text.trim()).ok())
                .unwrap_or(Value::Null);
            // Only a bootstrap that failed says why the folder is not there. One that finished keeps the
            // start as it was: the folder may be one the bootstrap never meant to make.
            if at(&status, "state").as_str() == Some("failed") {
                Folder::Missing(status)
            } else {
                Folder::Go
            }
        }
        _ => Folder::Go,
    }
}

/// Waits for `cwd` on `machine` while its bootstrap runs (module docs). `None` starts the chat;
/// `Some` is the start's failure.
pub(super) fn wait(
    runner: &mut dyn Runner,
    machine: &str,
    cwd: &str,
    timeout: Duration,
) -> Option<Outcome> {
    let started = runner.now();
    let limit = timeout.min(MAX_WAIT);
    let script = script(cwd);
    loop {
        let Ok(stdout) = exec(runner, machine, &script) else { return None };
        match read(&stdout) {
            Folder::Go => return None,
            Folder::Missing(status) => {
                let repo = at(&status, "repo");
                let state = at(repo, "status").as_str().unwrap_or("unknown");
                return Some(failed(
                    "cloud.folder_missing",
                    format!(
                        "{cwd} is not on the machine: its bootstrap failed (step {}, repository {state}). \
                         Read ~/{LOG} on the machine: cmux cloud file-read --target machine:{machine} --path ~/{LOG}",
                        at(&status, "step").as_str().unwrap_or("unknown"),
                    ),
                    json!({"cwd": cwd, "machine_id": machine, "bootstrap": status, "log": format!("~/{LOG}")}),
                    1,
                ));
            }
            Folder::Cloning if runner.now().saturating_duration_since(started) >= limit => {
                return Some(failed(
                    "cloud.folder_pending",
                    format!(
                        "{cwd} is not on the machine yet: its bootstrap is still cloning the repository. \
                         Run the same command again to keep waiting, or read ~/{LOG} on the machine"
                    ),
                    json!({"cwd": cwd, "machine_id": machine, "log": format!("~/{LOG}"),
                           "waited_ms": runner.now().saturating_duration_since(started).as_millis() as u64}),
                    75,
                ));
            }
            Folder::Cloning => {}
        }
    }
}
