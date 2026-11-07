//! A chat started in a folder the machine is still cloning waits for the clone instead of failing
//! "cwd is not a directory" (cmuxterm-hq#7415, row 10). `cmux cloud new-machine --repo URL` answers
//! once the machine's bootstrap has started, and the clone into `~/work/NAME` runs in that
//! bootstrap afterwards (`CloudMachineBootstrap.runner`), so a `start-chat --cwd ~/work/NAME` right
//! after it can reach the machine before the folder does. A small GitHub repository usually won
//! that race; a GitLab one (or any larger clone) lost it.
//!
//! The rule: while it is unknown whether the folder is ready, the chat does not start. One
//! `cloud exec` asks the machine about its bootstrap (`~/.cmux/bootstrap`). The folder existing
//! proves nothing while a bootstrap runs (`git clone` makes it before its checkout ends), so it is
//! ready only when:
//!
//! - there is no bootstrap on the machine and the folder is there, or
//! - the bootstrap did not fail, and its repository step says `cloned`, `updated` or `kept`, or the
//!   whole bootstrap is `done`.
//!
//! A failed bootstrap (`status.json` `failed`, whatever the repository says) fails the start with its
//! status and log (`cloud.folder_missing`). A running bootstrap is waited on, on the machine, for at
//! most [`SLICE_SECONDS`] per exec. Everything that may pass later (a busy, starting or unreachable
//! machine, a timeout, an answer that can't be read) is asked again within the command's one
//! [`Deadline`]. No bootstrap and no folder (a typo, or a bootstrap still being put on the machine:
//! `list-machines` says nothing of a requested bootstrap) is asked again for a short [`GRACE`] only, then
//! fails `cloud.folder_missing` with reason `no_such_folder`; past it the start answers [`out_of_time`], and with no
//! deadline (no `--wait`) the wait stops at [`MAX_WAIT`] with `cloud.folder_pending`. Under a second
//! left, no check runs. A machine that cannot run a command for the CLI at all ([`cannot_exec`]) starts
//! the way it did before this check: the relay is its only way. Any other refusal is
//! `cloud.folder_unknown`, retryable, and never a start.

use std::time::Duration;

use serde_json::{Value, json};

use super::{
    Deadline, GUEST_PRELUDE, Machine, Outcome, Request, Runner, at, failed, lacks_action,
    out_of_time, shell_quote, step_result,
};

/// The machine's bootstrap folder (`CloudMachineBootstrap.directory`, in the work user's home).
pub(super) const BOOTSTRAP: &str = ".cmux/bootstrap";
pub(super) const LOG: &str = ".cmux/bootstrap/bootstrap.log";
/// The most one exec waits on the machine (the exec itself stops after 25 s).
pub(super) const SLICE_SECONDS: u64 = 15;
/// The longest a start with no deadline (no `--wait`) waits for a clone.
pub(super) const MAX_WAIT: Duration = Duration::from_secs(10 * 60);
/// How long no bootstrap and no folder is asked again before it is a missing folder (less when less of
/// the deadline is left).
pub(super) const GRACE: Duration = Duration::from_secs(30);
/// The pause before asking again after an answer that may pass later.
const RETRY_PAUSE: Duration = Duration::from_secs(2);
/// The app's refusal of `cloud exec` on a machine without API exec (`CloudStrings.execUnavailable`,
/// thrown as an `ActionFailure`, which the control socket answers with code `unavailable`). Its
/// English text is matched; a translated one reads as unknown, which never starts the chat.
const EXEC_UNAVAILABLE: &str = "can't run a command for the CLI";

/// What one check said.
#[derive(Debug, PartialEq)]
pub(super) enum Folder {
    /// The folder is ready: start.
    Ready,
    /// The bootstrap is still running; the machine already waited on it.
    Cloning,
    /// Not known yet (an unknown state, an answer that can't be read): ask again after a pause.
    Again,
    /// No bootstrap and no folder: ask again within [`GRACE`].
    Absent,
    /// The bootstrap failed; its status file.
    Missing(Value),
}

/// The script: waits up to `slice` seconds while the bootstrap runs, then prints one of `ready`,
/// `busy`, `absent` (no bootstrap, no folder), `unknown`, or `ended` and the status file. `cwd` is one
/// single-quoted shell word, whatever it holds.
pub(super) fn script(cwd: &str, slice: u64) -> String {
    format!(
        "{GUEST_PRELUDE}dir={dir}; b=\"$HOME/{BOOTSTRAP}\"; \
         state() {{ sed -n 's/^{{\"state\":\"\\([a-z_]*\\)\".*/\\1/p' \"$b/status.json\" 2>/dev/null; }}; \
         repo() {{ sed -n 's/^{{\"status\":\"\\([a-z_]*\\)\".*/\\1/p' \"$b/repo-status.json\" 2>/dev/null; }}; \
         ready() {{ s=$(state); [ \"$s\" = failed ] && return 1; \
         case \"$(repo)\" in cloned|updated|kept) return 0;; esac; [ \"$s\" = done ]; }}; \
         busy() {{ case \"$(state)\" in starting|running) return 0;; esac; return 1; }}; \
         i=0; while [ -f \"$b/status.json\" ] && ! ready && busy && [ \"$i\" -lt {slice} ]; do sleep 1; i=$((i+1)); done; \
         if [ ! -f \"$b/status.json\" ]; then if [ -d \"$dir\" ]; then echo ready; else echo absent; fi; \
         elif [ \"$(state)\" = failed ]; then echo ended; cat \"$b/status.json\"; \
         elif ready; then echo ready; \
         elif busy; then echo busy; \
         else echo unknown; fi",
        dir = shell_quote(cwd),
    )
}

/// Reads one answer of [`script`]: a check that exited non-zero, or printed anything else, is not known.
pub(super) fn read(exit_code: Option<i64>, stdout: &str) -> Folder {
    if exit_code != Some(0) {
        return Folder::Again;
    }
    // Exactly the script's line (and the status file's after `ended`), trailing whitespace at most:
    // anything more is malformed.
    let lines: Vec<&str> = stdout.trim_end().split('\n').map(str::trim_end).collect();
    match lines.as_slice() {
        ["ready"] => Folder::Ready,
        ["busy"] => Folder::Cloning,
        ["absent"] => Folder::Absent,
        ["ended", status] => match serde_json::from_str::<Value>(status) {
            Ok(status) if status.is_object() => Folder::Missing(status),
            _ => Folder::Again,
        },
        _ => Folder::Again,
    }
}

/// The machine cannot run a command for the CLI at all: the app's own refusal, or an app with no
/// `cloud exec`. Nothing can ask it about the folder, so the start goes the way it went before.
pub(super) fn cannot_exec(error: &Value) -> bool {
    lacks_action(error)
        || (at(error, "code").as_str() == Some("unavailable")
            && at(error, "message").as_str().is_some_and(|m| m.contains(EXEC_UNAVAILABLE)))
}

/// A refusal that may pass if asked again: the machine busy or still starting, a timeout, the app or
/// the machine out of reach, a rate limit.
pub(super) fn may_pass_later(error: &Value) -> bool {
    let code = at(error, "code").as_str().unwrap_or_default().to_lowercase();
    let message = at(error, "message").as_str().unwrap_or_default().to_lowercase();
    matches!(code.as_str(), "vm_busy" | "vm_not_running" | "app.unreachable")
        || ["timeout", "timed_out", "unreachable", "rate_limited", "not_connected"]
            .iter()
            .any(|word| code.contains(word))
        || ["timed out", "timeout", "unreachable", "not connected", "try again"]
            .iter()
            .any(|words| message.contains(words))
}

/// Waits on `machine`'s bootstrap for `cwd` within `deadline` (module docs). `None` starts the chat;
/// `Some` is the start's failure.
pub(super) fn wait(
    runner: &mut dyn Runner,
    request: &Request,
    machine: &str,
    cwd: &str,
    deadline: Deadline,
) -> Option<Outcome> {
    let started = runner.now();
    let late = |runner: &mut dyn Runner| {
        let waited = runner.now().saturating_duration_since(started);
        failed(
            "cloud.folder_pending",
            format!(
                "{cwd} is not ready on the machine yet: its bootstrap has not finished cloning the repository. \
                 Run the same command again to keep waiting, or read ~/{LOG} on the machine"
            ),
            json!({"cwd": cwd, "machine_id": machine, "log": format!("~/{LOG}"),
                   "waited_ms": waited.as_millis() as u64}),
            75,
        )
    };
    let out = |request: &Request| {
        Some(out_of_time(request, &Machine::Target(machine.to_owned()), Value::Null))
    };
    let no_such_folder = || {
        Some(failed(
            "cloud.folder_missing",
            format!(
                "{cwd} is not on the machine, and no bootstrap is making it: check the folder, \
                 or start without --cwd"
            ),
            json!({"cwd": cwd, "machine_id": machine, "reason": "no_such_folder"}),
            1,
        ))
    };
    // A refusal that leaves it unknown whether the folder is ready: retryable, and never a start.
    let unknown = |refusal: Value| {
        let Outcome::Failed { mut error, exit } = failed(
            "cloud.folder_unknown",
            format!(
                "whether {cwd} is ready on the machine is not known (the check was refused: {}), so the chat \
                 did not start. Run the same command again",
                at(&refusal, "message").as_str().unwrap_or("no reason given"),
            ),
            json!({"cwd": cwd, "machine_id": machine, "refusal": refusal}),
            75,
        ) else {
            unreachable!("failed() answers a failure")
        };
        error["retryable"] = json!(true);
        Outcome::Failed { error, exit }
    };
    // The machine was resumed once already (a paused machine; see the `vm_not_running` arm).
    let mut resumed = false;
    // The last answer was `absent`: when time runs out, the folder is missing, not late.
    let mut absent = false;
    loop {
        let waited = runner.now().saturating_duration_since(started);
        if absent && waited >= GRACE {
            return no_such_folder();
        }
        let own = Duration::from_secs(SLICE_SECONDS).min(MAX_WAIT.saturating_sub(waited));
        let slice = deadline.bound(runner, own);
        // Under a second left: no check (a script waits whole seconds), so out of time.
        if slice < Duration::from_secs(1) {
            if absent {
                return no_such_folder();
            }
            return if deadline.left(runner).is_some_and(|left| left < Duration::from_secs(1)) {
                out(request)
            } else {
                Some(late(runner))
            };
        }
        let args = vec![
            "cloud".to_owned(),
            "exec".to_owned(),
            "--target".to_owned(),
            format!("machine:{machine}"),
            "--command".to_owned(),
            script(cwd, slice.as_secs()),
            "--json".to_owned(),
        ];
        let answer = match step_result(&runner.cmux(&args)) {
            Ok(ran) => {
                read(at(&ran, "exit_code").as_i64(), at(&ran, "stdout").as_str().unwrap_or(""))
            }
            Err(error) if cannot_exec(&error) => return None,
            // `cloud exec` doesn't wake a paused machine; start-session would (its connect resumes it), but
            // only after this check. So the check resumes it once, the way the server's resume does, and
            // asks again.
            Err(error) if !resumed && at(&error, "code").as_str() == Some("vm_not_running") => {
                resumed = true;
                let resume = vec![
                    "cloud".to_owned(),
                    "resume-machine".to_owned(),
                    "--target".to_owned(),
                    format!("machine:{machine}"),
                    "--json".to_owned(),
                ];
                match step_result(&runner.cmux(&resume)) {
                    Ok(_) => continue,
                    Err(error) if may_pass_later(&error) => Folder::Again,
                    Err(error) => return Some(unknown(error)),
                }
            }
            Err(error) if may_pass_later(&error) => Folder::Again,
            Err(error) => return Some(unknown(error)),
        };
        absent = answer == Folder::Absent;
        match answer {
            Folder::Ready => return None,
            Folder::Missing(status) => {
                let repo = at(at(&status, "repo"), "status").as_str().unwrap_or("none");
                return Some(failed(
                    "cloud.folder_missing",
                    format!(
                        "{cwd} is not ready on the machine: its bootstrap failed (step {}, repository {repo}). \
                         Read ~/{LOG} on the machine: cmux cloud file-read --target machine:{machine} --path ~/{LOG}",
                        at(&status, "step").as_str().unwrap_or("unknown"),
                    ),
                    json!({"cwd": cwd, "machine_id": machine, "bootstrap": status, "log": format!("~/{LOG}")}),
                    1,
                ));
            }
            Folder::Cloning => {}
            Folder::Again => {
                let pause = deadline.bound(runner, RETRY_PAUSE);
                runner.pause(pause);
            }
            Folder::Absent => {
                let grace = GRACE.saturating_sub(runner.now().saturating_duration_since(started));
                let pause = deadline.bound(runner, RETRY_PAUSE.min(grace));
                runner.pause(pause);
            }
        }
    }
}
