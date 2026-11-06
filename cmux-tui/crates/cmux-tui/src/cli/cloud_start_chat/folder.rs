//! A chat started in a folder the machine is still cloning waits for the clone instead of failing
//! "cwd is not a directory" (cmuxterm-hq#7415, row 10). `cmux cloud new-machine --repo URL` answers
//! once the machine's bootstrap has started, and the clone into `~/work/NAME` runs in that
//! bootstrap afterwards (`CloudMachineBootstrap.runner`), so a `start-chat --cwd ~/work/NAME` right
//! after it can reach the machine before the folder does. A small GitHub repository usually won
//! that race; a GitLab one (or any larger clone) lost it.
//!
//! One `cloud exec` asks the machine about its bootstrap. The folder existing proves nothing while a
//! bootstrap runs (`git clone` makes it before its checkout ends), so the start goes on only when:
//! there is no bootstrap on the machine, its repository step finished (`repo-status.json` says
//! `cloned`, `updated` or `kept`), the whole bootstrap is `done`, or it ended with no repository
//! step and the folder is there. While the bootstrap is `starting` or `running` the machine waits on
//! it for at most [`SLICE_SECONDS`] (less when less is left) and the CLI asks again until the one
//! deadline from the command's start. A bootstrap that ended any other way fails the start with its
//! status and log. An exec the machine refused leaves the start as it was.

use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::{GUEST_PRELUDE, Outcome, Request, Runner, at, exec, failed, shell_quote};

/// The machine's bootstrap folder (`CloudMachineBootstrap.directory`, in the work user's home).
pub(super) const BOOTSTRAP: &str = ".cmux/bootstrap";
pub(super) const LOG: &str = ".cmux/bootstrap/bootstrap.log";
/// The most one exec waits on the machine (the exec itself stops after 25 s).
pub(super) const SLICE_SECONDS: u64 = 15;
/// The longest a start waits for a clone without `--wait`'s `--timeout`.
pub(super) const MAX_WAIT: Duration = Duration::from_secs(10 * 60);

/// When the folder wait gives up: `--timeout` from the command's start (with `--wait`), and never past
/// [`MAX_WAIT`] from it.
pub(super) fn end(request: &Request, began: Instant) -> Instant {
    let limit = if request.wait { request.timeout.min(MAX_WAIT) } else { MAX_WAIT };
    began.checked_add(limit).unwrap_or(began)
}

/// What the machine said about `--cwd`.
#[derive(Debug, PartialEq)]
pub(super) enum Folder {
    /// Start: no bootstrap, its repository step or the bootstrap finished, or the machine could not be asked.
    Go,
    /// The bootstrap is still starting or running.
    Cloning,
    /// The bootstrap ended without a usable folder; its status file.
    Missing(Value),
}

/// The script: waits up to `slice` seconds while the bootstrap runs, then prints `ready`, `busy`,
/// `none`, or `ended` and the status file. `cwd` is one single-quoted shell word, whatever it holds.
pub(super) fn script(cwd: &str, slice: u64) -> String {
    format!(
        "{GUEST_PRELUDE}dir={dir}; b=\"$HOME/{BOOTSTRAP}\"; \
         state() {{ sed -n 's/^{{\"state\":\"\\([a-z_]*\\)\".*/\\1/p' \"$b/status.json\" 2>/dev/null; }}; \
         repo() {{ sed -n 's/^{{\"status\":\"\\([a-z_]*\\)\".*/\\1/p' \"$b/repo-status.json\" 2>/dev/null; }}; \
         ready() {{ case \"$(repo)\" in cloned|updated|kept) return 0;; esac; [ \"$(state)\" = done ]; }}; \
         busy() {{ case \"$(state)\" in starting|running) return 0;; esac; return 1; }}; \
         i=0; while [ -f \"$b/status.json\" ] && ! ready && busy && [ \"$i\" -lt {slice} ]; do sleep 1; i=$((i+1)); done; \
         if [ ! -f \"$b/status.json\" ]; then echo none; \
         elif ready; then echo ready; \
         elif busy; then echo busy; \
         elif [ -z \"$(repo)\" ] && [ -d \"$dir\" ]; then echo ready; \
         else echo ended; cat \"$b/status.json\"; fi",
        dir = shell_quote(cwd),
    )
}

/// Reads one answer of [`script`].
pub(super) fn read(stdout: &str) -> Folder {
    let mut lines = stdout.trim().splitn(2, '\n');
    match lines.next().map(str::trim) {
        Some("busy") => Folder::Cloning,
        Some("ended") => Folder::Missing(
            lines
                .next()
                .and_then(|text| serde_json::from_str::<Value>(text.trim()).ok())
                .unwrap_or(Value::Null),
        ),
        _ => Folder::Go,
    }
}

/// Waits on `machine`'s bootstrap for `cwd` until `end` (module docs). `None` starts the chat; `Some`
/// is the start's failure.
pub(super) fn wait(
    runner: &mut dyn Runner,
    machine: &str,
    cwd: &str,
    end: Instant,
) -> Option<Outcome> {
    let started = runner.now();
    loop {
        let left = end.saturating_duration_since(runner.now()).as_secs();
        let answer = if left == 0 {
            Folder::Cloning
        } else {
            let Ok(stdout) = exec(runner, machine, &script(cwd, left.min(SLICE_SECONDS))) else {
                return None;
            };
            read(&stdout)
        };
        match answer {
            Folder::Go => return None,
            Folder::Missing(status) => {
                let repo = at(at(&status, "repo"), "status").as_str().unwrap_or("none");
                return Some(failed(
                    "cloud.folder_missing",
                    format!(
                        "{cwd} is not ready on the machine: its bootstrap ended {} (step {}, repository {repo}). \
                         Read ~/{LOG} on the machine: cmux cloud file-read --target machine:{machine} --path ~/{LOG}",
                        at(&status, "state").as_str().unwrap_or("unknown"),
                        at(&status, "step").as_str().unwrap_or("unknown"),
                    ),
                    json!({"cwd": cwd, "machine_id": machine, "bootstrap": status, "log": format!("~/{LOG}")}),
                    1,
                ));
            }
            Folder::Cloning if runner.now() >= end => {
                return Some(failed(
                    "cloud.folder_pending",
                    format!(
                        "{cwd} is not ready on the machine yet: its bootstrap is still cloning the repository. \
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
