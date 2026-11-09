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
//! [`Deadline`]: past it, or for an answer that comes back past it, the start answers [`out_of_time`].
//! With `--timeout` the deadline is the only bound; with no deadline (no `--wait`) the wait stops at
//! [`MAX_WAIT`] with `cloud.folder_pending`. Under a second left, no check runs. No bootstrap and no
//! folder is a typo only on a machine older than [`YOUNG`] (`list-machines`' `created_at`; nothing there
//! says whether a bootstrap was asked for): it fails `cloud.folder_missing` with reason
//! `no_such_folder`. On a younger machine, or one whose age can't be read, the bootstrap may not have
//! written its status yet, so it is asked again like any answer that may pass later. A machine that
//! cannot run a command for the CLI at all ([`cannot_exec`]) starts the way it did before this check.
//! Any other refusal is `cloud.folder_unknown`, retryable, and never a start.

use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde_json::{Value, json};

use super::{
    Deadline, GUEST_PRELUDE, Machine, Outcome, Request, Runner, at, failed, out_of_time,
    shell_quote, step_result,
};

/// The machine's bootstrap folder (`CloudMachineBootstrap.directory`, in the work user's home).
pub(super) const BOOTSTRAP: &str = ".cmux/bootstrap";
pub(super) const LOG: &str = ".cmux/bootstrap/bootstrap.log";
/// The most one exec waits on the machine (the exec itself stops after 25 s).
pub(super) const SLICE_SECONDS: u64 = 15;
/// The longest a start with no deadline (no `--wait`) waits for a clone.
pub(super) const MAX_WAIT: Duration = Duration::from_secs(10 * 60);
/// Below this age a machine with no bootstrap status may still be getting its bootstrap: the app's
/// `CloudMachineBootstrap.start` runs a prepare exec (20 s at most), five file writes (120 s each at
/// most) and the start exec (20 s) before the runner writes `status.json`: 640 s at worst, after the
/// machine's create and boot. 15 minutes covers that with room for the boot.
pub(super) const YOUNG: Duration = Duration::from_secs(15 * 60);
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
    /// No bootstrap and no folder: missing on an old machine, asked again on a young one ([`YOUNG`]).
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
    let code = at(error, "code").as_str().unwrap_or_default();
    code.starts_with("usage.")
        || code == "action.not_found"
        || (at(error, "code").as_str() == Some("unavailable")
            && at(error, "message").as_str().is_some_and(|m| m.contains(EXEC_UNAVAILABLE)))
}

/// A refusal that may pass if asked again: the machine busy or still starting, a timeout, the app or
/// the machine out of reach, a rate limit.
pub(super) fn may_pass_later(error: &Value) -> bool {
    let code = at(error, "code").as_str().unwrap_or_default().to_lowercase();
    let message = at(error, "message").as_str().unwrap_or_default().to_lowercase();
    matches!(code.as_str(), "vm_busy" | "vm_not_running" | "vm_state_conflict" | "app.unreachable")
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
    listed: &Value,
    began: Instant,
) -> Option<Outcome> {
    // MAX_WAIT counts from `began`, the folder phase's start (a wait for a create included).
    let started = began;
    // The machine's age when this wait began; unknown (an unreadable `created_at`, or not listed) is young.
    let (age, aged_from) = (machine_age(listed, machine, SystemTime::now()), runner.now());
    let young = |runner: &mut dyn Runner| {
        age.is_none_or(|age| age + runner.now().saturating_duration_since(aged_from) < YOUNG)
    };
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
        let mut outcome = failed(
            "cloud.folder_unknown",
            format!(
                "whether {cwd} is ready on the machine is not known (the check was refused: {}), so the chat \
                 did not start. Run the same command again",
                at(&refusal, "message").as_str().unwrap_or("no reason given"),
            ),
            json!({"cwd": cwd, "machine_id": machine, "refusal": refusal}),
            75,
        );
        if let Outcome::Failed { error, .. } = &mut outcome {
            error["retryable"] = json!(true);
        }
        outcome
    };
    // The machine was resumed once already (a paused machine; see the `vm_not_running` arm).
    let mut resumed = false;
    loop {
        let waited = runner.now().saturating_duration_since(started);
        // With `--timeout`, the deadline is the only bound; MAX_WAIT is for a start with none.
        let own = match deadline.left(runner) {
            Some(_) => Duration::from_secs(SLICE_SECONDS),
            None => Duration::from_secs(SLICE_SECONDS).min(MAX_WAIT.saturating_sub(waited)),
        };
        let slice = deadline.bound(runner, own);
        // Under a second left: no check (a script waits whole seconds).
        if slice < Duration::from_secs(1) {
            return if deadline.left(runner).is_some() { out(request) } else { Some(late(runner)) };
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
        let checked = step_result(&runner.cmux(&args));
        // An answer that came back past the deadline (or, with none, the cap) is late, whatever it says.
        if deadline.passed(runner) {
            return out(request);
        }
        if past_cap(runner, deadline, started) {
            return Some(late(runner));
        }
        let answer = match checked {
            Ok(ran) => {
                read(at(&ran, "exit_code").as_i64(), at(&ran, "stdout").as_str().unwrap_or(""))
            }
            Err(error) if cannot_exec(&error) => return None,
            // `cloud exec` doesn't wake a paused machine; start-session would (its connect resumes it), but
            // only after this check. So the check resumes it once, the way the server's resume does, and
            // asks again.
            Err(error)
                if !resumed
                    && matches!(
                        at(&error, "code").as_str(),
                        Some("vm_not_running" | "vm_state_conflict")
                    ) =>
            {
                resumed = true;
                let resume = vec![
                    "cloud".to_owned(),
                    "resume-machine".to_owned(),
                    "--target".to_owned(),
                    format!("machine:{machine}"),
                    "--json".to_owned(),
                ];
                let resumed = step_result(&runner.cmux(&resume));
                if deadline.passed(runner) {
                    return out(request);
                }
                if past_cap(runner, deadline, started) {
                    return Some(late(runner));
                }
                match resumed {
                    Ok(_) => continue,
                    Err(error) if may_pass_later(&error) => Folder::Again,
                    Err(error) => return Some(unknown(error)),
                }
            }
            Err(error) if may_pass_later(&error) => Folder::Again,
            Err(error) => return Some(unknown(error)),
        };
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
            // No bootstrap and no folder: a typo on an old machine; a young one may still get its bootstrap.
            Folder::Absent if !young(runner) => return no_such_folder(),
            Folder::Absent => {
                let pause = deadline.bound(runner, RETRY_PAUSE);
                runner.pause(pause);
            }
        }
    }
}

/// How old `machine` was at `now`, from `list-machines`' `created_at` (`Date.formatted(.iso8601)`, for
/// example `2026-11-07T01:23:45Z`). `None` when it is not listed or the time can't be read.
pub(super) fn machine_age(listed: &Value, machine: &str, now: SystemTime) -> Option<Duration> {
    let row = at(listed, "machines")
        .as_array()?
        .iter()
        .find(|row| at(row, "machine_id").as_str() == Some(machine))?;
    let created = unix_seconds(at(row, "created_at").as_str()?)?;
    let now = i64::try_from(now.duration_since(UNIX_EPOCH).ok()?.as_secs()).ok()?;
    Some(Duration::from_secs(u64::try_from(now - created).unwrap_or(0)))
}

/// Seconds since 1970 of `YYYY-MM-DDTHH:MM:SS[.fff]Z`; `None` for anything else.
fn unix_seconds(text: &str) -> Option<i64> {
    let text = text.strip_suffix('Z')?;
    let (whole, fraction) = text.split_once('.').unwrap_or((text, "0"));
    if !fraction.bytes().all(|b| b.is_ascii_digit()) || fraction.is_empty() {
        return None;
    }
    let b = whole.as_bytes();
    let is = |at: usize, byte: u8| b.get(at) == Some(&byte);
    if b.len() != 19
        || !is(4, b'-')
        || !is(7, b'-')
        || !is(10, b'T')
        || !is(13, b':')
        || !is(16, b':')
    {
        return None;
    }
    let num = |from: usize, to: usize| -> Option<i64> {
        let part = whole.get(from..to)?;
        part.bytes().all(|b| b.is_ascii_digit()).then(|| part.parse().ok()).flatten()
    };
    let (year, month, day) = (num(0, 4)?, num(5, 7)?, num(8, 10)?);
    let (hour, minute, second) = (num(11, 13)?, num(14, 16)?, num(17, 19)?);
    if !(1..=12).contains(&month)
        || !(1..=31).contains(&day)
        || hour > 23
        || minute > 59
        || second > 60
    {
        return None;
    }
    // Days from 1970-01-01 of a proleptic Gregorian date.
    let y = if month <= 2 { year - 1 } else { year };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * (if month > 2 { month - 3 } else { month + 9 }) + 2) / 5 + day - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    Some(days * 86_400 + hour * 3600 + minute * 60 + second)
}

/// With no deadline (no `--wait`), whether [`MAX_WAIT`] from `began` is over.
fn past_cap(runner: &mut dyn Runner, deadline: Deadline, began: Instant) -> bool {
    deadline.left(runner).is_none() && runner.now().saturating_duration_since(began) >= MAX_WAIT
}

/// A `--name` whose create is still on its way (`list-machines`' `creating`): `list-machines` again until
/// the machine is listed, within the deadline (or, with none, [`MAX_WAIT`] from `began`). Every list it
/// reads replaces `listed`, so what follows judges the newest one (a create that failed is
/// `cloud.start_failed` there, not still pending). `Ok(Some)`: its id, for its folder check. `Ok(None)`:
/// no create of that name is on its way (none, one that failed, or one that is gone): nothing to wait
/// for. A list that can't be read is asked again. No list starts once the deadline (or the cap) is over.
pub(super) fn created(
    runner: &mut dyn Runner,
    request: &Request,
    name: &str,
    deadline: Deadline,
    listed: &mut Value,
    began: Instant,
) -> Result<Option<String>, Outcome> {
    let in_flight = |listed: &Value| {
        at(listed, "creating").as_array().into_iter().flatten().any(|row| {
            at(row, "name").as_str() == Some(name) && at(row, "status").as_str() != Some("failed")
        })
    };
    let made = |listed: &Value| {
        at(listed, "machines")
            .as_array()
            .into_iter()
            .flatten()
            .find(|row| at(row, "title").as_str() == Some(name))
            .and_then(|row| at(row, "machine_id").as_str().map(str::to_owned))
    };
    if !in_flight(&*listed) {
        return Ok(None);
    }
    let pending = |runner: &mut dyn Runner| {
        if deadline.left(runner).is_some() {
            out_of_time(request, &Machine::Named(name.to_owned()), Value::Null)
        } else {
            failed(
                "cloud.folder_pending",
                format!(
                    "the machine {name} is still being made, so whether its folder is ready is not known yet. \
                     Run the same command again to keep waiting"
                ),
                json!({"machine_name": name, "list": "cmux cloud list-machines --json"}),
                75,
            )
        }
    };
    loop {
        let pause = deadline.bound(runner, RETRY_PAUSE);
        if pause < Duration::from_secs(1) || past_cap(runner, deadline, began) {
            return Err(pending(runner));
        }
        runner.pause(pause);
        // The pause may have reached the deadline (or the cap): then no list starts.
        if deadline.passed(runner) || past_cap(runner, deadline, began) {
            return Err(pending(runner));
        }
        let fresh = step_result(&runner.cmux(&super::words(&["cloud", "list-machines", "--json"])));
        if deadline.passed(runner) || past_cap(runner, deadline, began) {
            return Err(pending(runner));
        }
        let Ok(fresh) = fresh else { continue };
        *listed = fresh;
        if let Some(id) = made(&*listed) {
            return Ok(Some(id));
        }
        if !in_flight(&*listed) {
            // The create ended with no machine of that name (failed, or dismissed): nothing to wait for.
            return Ok(None);
        }
    }
}
