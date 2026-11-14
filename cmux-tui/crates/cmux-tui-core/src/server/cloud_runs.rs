//! The daemon's sandboxed Runs (`cloud.runs.*`): `cmux_cloud_api::sandbox`'s engine with steps
//! that run the app's own Cloud verbs, the ones `cmux cloud start-chat` runs, as children of this
//! binary. A child names the app's control socket with `--app-socket` (the `CMUX_SOCKET_PATH` the
//! app started this daemon with), never `--socket`: that flag names an app socket to an app
//! command, and a daemon's is refused as `socket.wrong_kind`. With no `CMUX_SOCKET_PATH` it finds
//! the app the way any `cmux` does, and `CMUX_TUI_SOCKET` names this daemon for the daemon parts:
//!
//! - the task: `cloud start-chat --name sandbox-<run> --agent A --prompt - --wait --timeout S`, a
//!   Cloud chat on a new small machine with the task as its prompt (on stdin, never in argv) and
//!   the turn's reply as its answer. The machine, the agent's login and the send take the same
//!   path a person's `cmux chat --on vm:new` takes, checks and approvals included. `--account`
//!   names the Run's account: start-chat starts nothing unless the app is signed in to it, and
//!   sends the task only to a machine that account's list shows;
//! - the scope, at every create, wait and cancel: `cloud run-account`, the app's `auth.status`
//!   (signed in, the person and the team, [`account_scope`]). An organization's Cloud policy
//!   leaves it open, so with Cloud turned off a Run that exists is still waited on and cancelled;
//!   the start and the cleanup's list and delete are the app's Cloud verbs, which the policy
//!   refuses: a cleanup then reads again later and finishes once Cloud is back;
//! - the cleanup: `cloud list-machines` finds the machine by its id or its title, then
//!   `cloud kill-machine --target machine:ID --confirm` asks for its delete. A delete's answer
//!   only says the delete started (`pending`, `deleting`), so the machine counts as gone only once
//!   an authoritative list (`loaded`, signed in, the Run's own scope) shows neither it nor a create
//!   of its name ([`judge`]); every other answer is read again later.
//!
//! The Runs persist in `cloud-runs.json` in the session's state directory (none for an in-memory
//! session), so a daemon that starts again resumes their cleanup ([`resume`]).
//!
//! Stop conditions: a task's child is killed at a cancel or at its bound (the task's timeout and
//! [`START_MARGIN`]); every other child at [`STEP_BOUND`]. The engine's own bounds are its module's.

use std::collections::HashMap;
use std::io::{Read as _, Write as _};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};

use cmux_cloud_api::sandbox::{Engine, Outcome, Removal, Steps, Task, Timing, account_scope};
use cmux_process::{Command, Stdio};
use serde_json::Value;

use crate::Mux;

/// Past the task's own `--timeout`: the start-chat's last read and its answer.
const START_MARGIN: Duration = Duration::from_secs(60);
/// A list or a delete.
const STEP_BOUND: Duration = Duration::from_secs(180);
/// The account read at every wait and cancel: a main-actor read in the app, under a wait's own
/// bound, so a hung app answers "not signed in" (kept, never gone) before the caller gives up.
const ACCOUNT_BOUND: Duration = Duration::from_secs(8);
/// How often a running child is checked for a cancel or its bound.
const POLL: Duration = Duration::from_millis(250);
/// Between two starts of one Run's chat while the app is still making its machine.
const START_AGAIN_PAUSE: Duration = Duration::from_secs(5);
/// The most of a child's output kept.
const MAX_OUTPUT: u64 = 4 * 1024 * 1024;
const STORE_FILE: &str = "cloud-runs.json";

static ENGINE: OnceLock<Arc<Engine>> = OnceLock::new();

/// The session's Runs, opened on first use.
pub(super) fn engine(mux: &Mux) -> &'static Arc<Engine> {
    ENGINE.get_or_init(|| {
        let socket = mux
            .bound_socket_path
            .get()
            .cloned()
            .unwrap_or_else(|| crate::server::default_socket_path(&mux.session));
        let store = mux.session_state_directory().map(|dir| dir.join(STORE_FILE));
        let app_socket =
            std::env::var_os("CMUX_SOCKET_PATH").filter(|path| !path.is_empty()).map(PathBuf::from);
        let steps = Arc::new(AppVerbs {
            exe: std::env::current_exe().ok(),
            socket,
            app_socket,
            elsewhere: Mutex::new(HashMap::new()),
        });
        Engine::open(store, steps, Timing::default())
    })
}

/// At the daemon's start: Runs a former daemon left get their cleanup again (nothing when it left none).
pub(super) fn resume(mux: &Mux) {
    let has_store = mux.session_state_directory().is_some_and(|dir| dir.join(STORE_FILE).exists());
    if has_store {
        engine(mux);
    }
}

/// Steps that run this binary's own Cloud verbs: the app at `app_socket` (or the one `cmux` finds),
/// with `socket`, this daemon, for their daemon parts.
struct AppVerbs {
    exe: Option<PathBuf>,
    socket: PathBuf,
    app_socket: Option<PathBuf>,
    /// Per Run: the other accounts a start found the app on (`cloud.account_changed`'s
    /// `app_account`), taken once by [`Steps::elsewhere`].
    elsewhere: Mutex<HashMap<String, Vec<String>>>,
}

/// The variable that keeps a child from recording its chat as the last one (cmux-tui
/// `cli/last_chat.rs` reads the same name).
pub(super) const NO_LAST_CHAT: &str = "CMUX_LAST_CHAT_OFF";

/// A child's leading words: `--json`, and the app's control socket when it is known.
pub(super) fn leading_args(app_socket: Option<&Path>) -> Vec<std::ffi::OsString> {
    let mut args = vec![std::ffi::OsString::from("--json")];
    if let Some(path) = app_socket {
        args.push("--app-socket".into());
        args.push(path.as_os_str().to_owned());
    }
    args
}

/// One child's end: its exit code (`None`: killed or never started) and output.
struct Ran {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

impl AppVerbs {
    /// The child `exe words`: the app's socket, this daemon's, and no last-chat record. A Run's
    /// chat is the daemon's, on a machine deleted at its end: it is never the chat a person's next
    /// `cmux chat send` goes to (#39022 review at 946e940e, F3; cmux-tui `cli/last_chat.rs`).
    fn child(&self, exe: &Path, words: &[&str]) -> Command {
        let mut command = Command::new(exe);
        command
            .args(leading_args(self.app_socket.as_deref()))
            .args(words)
            .env("CMUX_TUI_SOCKET", &self.socket)
            .env(NO_LAST_CHAT, "1");
        command
    }

    fn cmux(
        &self,
        words: &[&str],
        stdin: Option<&str>,
        bound: Duration,
        cancel: Option<&AtomicBool>,
    ) -> Ran {
        let failed = |message: String| Ran { code: None, stdout: String::new(), stderr: message };
        let Some(exe) = &self.exe else { return failed("the cmux binary is not known".into()) };
        let mut command = self.child(exe, words);
        command
            .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            // It leads a group of its own: a cancel or a timeout ends what it started too.
            .process_group(0);
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => return failed(error.to_string()),
        };
        if let (Some(text), Some(mut input)) = (stdin, child.stdin.take()) {
            // The prompt is at most 16000 characters: one write, then EOF.
            let _ = input.write_all(text.as_bytes());
        }
        let (stdout, stderr) = (child.stdout.take(), child.stderr.take());
        // The pipe readers belong to this call: the scope joins them before it returns.
        std::thread::scope(move |scope| {
            let read = |pipe: Option<Box<dyn std::io::Read + Send>>| {
                scope.spawn(move || {
                    let mut text = String::new();
                    if let Some(pipe) = pipe {
                        let _ = pipe.take(MAX_OUTPUT).read_to_string(&mut text);
                    }
                    text
                })
            };
            let out = read(stdout.map(|p| Box::new(p) as Box<dyn std::io::Read + Send>));
            let err = read(stderr.map(|p| Box::new(p) as Box<dyn std::io::Read + Send>));
            let began = Instant::now();
            let code = loop {
                match child.wait_timeout(POLL) {
                    Ok(Some(status)) => break status.code(),
                    Ok(None) => {}
                    Err(_) => break None,
                }
                let cancelled = cancel.is_some_and(|flag| flag.load(Ordering::Acquire));
                if cancelled || began.elapsed() >= bound {
                    // Our own child's group, by its handle: dropped unreaped, it signals the
                    // group, then kills what is left after the grace and reaps the child
                    // (cmux_process::Child). Its pipes end with the group.
                    drop(child);
                    break None;
                }
            };
            Ran {
                code,
                stdout: out.join().unwrap_or_default(),
                stderr: err.join().unwrap_or_default(),
            }
        })
    }

    /// The app's `cloud list-machines` answer.
    fn list(&self) -> Result<Value, String> {
        let ran = self.cmux(&["cloud", "list-machines"], None, STEP_BOUND, None);
        answer(&ran).map_err(|error| {
            let message = text(&error, "message");
            if message.is_empty() { error.to_string() } else { message }
        })
    }
}

/// What one cleanup pass does after reading the list.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Judgement {
    /// The authoritative list shows neither the machine nor a create of its name.
    Gone,
    /// Ask for this machine's delete, then read again later.
    Kill(String),
    /// Read again later, for this reason.
    Wait(String),
    /// The list cannot say anything about the Run's machine (not loaded, signed out, another
    /// account's, or read before the Run's create could land): read again later, with no time
    /// toward giving up ([`Removal::Unheard`]), so a sign-in or a switch back resumes the cleanup.
    Unknown(String),
    /// The Run's own account's list shows a create of its name on its way: read again later, and
    /// never give up while it can still make the machine ([`Removal::Creating`]).
    Creating(String),
    /// A list of this other account, one the app was on during the start, shows none of it.
    Cleared(String),
}

/// Judges a `cloud list-machines` answer (`CloudHandlers.machineListFields`: `loaded`,
/// `machines` of `listedMachine` rows with `machine_id`, `title` and `status`, `creating` rows
/// with the `name` asked for, and `account`) for the Run's machine.
#[cfg(test)]
pub(super) fn judge(
    list: &Value,
    machine_name: &str,
    machine: Option<&str>,
    scope: Option<&str>,
) -> Judgement {
    judge_everywhere(list, machine_name, machine, scope, &[])
}

/// [`judge`], and for a list of another account: the Run's machine (its title, `sandbox-run_<id>`,
/// is the Run's own, made by no one else) is deleted there too, and a list of one of the
/// `elsewhere` accounts that shows none of it clears that account ([`Judgement::Cleared`]).
pub(super) fn judge_everywhere(
    list: &Value,
    machine_name: &str,
    machine: Option<&str>,
    scope: Option<&str>,
    elsewhere: &[String],
) -> Judgement {
    if list.get("loaded").and_then(Value::as_bool) != Some(true) {
        return Judgement::Unknown("the app's machine list has not loaded".into());
    }
    let Some(listed_scope) = account_scope(list) else {
        return Judgement::Unknown("the app is not signed in to Cloud".into());
    };
    // Only a list of the Run's own person and team says anything; a Run with no scope has none.
    let Some(scope) = scope else {
        return Judgement::Wait("the Run has no account to match a list to".into());
    };
    let rows = |name: &str| list.get(name).and_then(Value::as_array).into_iter().flatten();
    let field = |row: &Value, name: &str| row.get(name).and_then(Value::as_str).map(str::to_owned);
    if scope != listed_scope {
        let titled =
            rows("machines").find(|row| field(row, "title").as_deref() == Some(machine_name));
        if let Some(id) =
            titled.and_then(|row| field(row, "machine_id")).filter(|id| !id.is_empty())
        {
            let deleting = titled.and_then(|row| field(row, "status"));
            return match deleting.as_deref() {
                Some("deleting" | "deleted") => {
                    Judgement::Wait(format!("machine {id} is being deleted"))
                }
                _ => Judgement::Kill(id),
            };
        }
        let creating = rows("creating").any(|row| {
            field(row, "name").as_deref() == Some(machine_name)
                && field(row, "status").as_deref() != Some("failed")
        });
        // A create of the Run's machine still on its way in the account the app is on now (a
        // start that waits on the person's Start, then a switch): it can still make the machine,
        // so the cleanup never gives up on it (#39022 review at 0b52021c, F1).
        if creating {
            return Judgement::Creating(format!(
                "{machine_name} is still being created for {listed_scope}"
            ));
        }
        if elsewhere.contains(&listed_scope) {
            return Judgement::Cleared(listed_scope);
        }
        return Judgement::Unknown(format!(
            "the app lists {listed_scope}'s machines, not {scope}'s"
        ));
    }
    let found = rows("machines").find(|row| {
        let id = field(row, "machine_id");
        (machine.is_some() && id.as_deref() == machine)
            || field(row, "title").as_deref() == Some(machine_name)
    });
    if let Some(row) = found {
        let Some(id) = field(row, "machine_id").filter(|id| !id.is_empty()) else {
            return Judgement::Wait("the listed machine has no id".into());
        };
        return match field(row, "status").as_deref() {
            Some("deleting" | "deleted") => {
                Judgement::Wait(format!("machine {id} is being deleted"))
            }
            _ => Judgement::Kill(id),
        };
    }
    // A create that failed makes nothing more: only one still on its way holds the cleanup.
    if rows("creating").any(|row| {
        field(row, "name").as_deref() == Some(machine_name)
            && field(row, "status").as_deref() != Some("failed")
    }) {
        return Judgement::Creating(format!("{machine_name} is still being created"));
    }
    Judgement::Gone
}

/// `judged`, but a list the app read before `since_ms` (`listed_at_ms`, ms since the epoch; none
/// from an app that does not say) never says [`Judgement::Gone`]: a create whose answer was lost
/// may land in the list after it (#39022 review at b1bfb468, F1). Every `cloud list-machines` of a
/// script reads the list again when it is older than the app's bound, so a later pass has one.
pub(super) fn fresh(judged: Judgement, list: &Value, since_ms: i64) -> Judgement {
    let listed_at = list.get("listed_at_ms").and_then(Value::as_i64);
    match judged {
        Judgement::Gone if listed_at.is_none_or(|at| at < since_ms) => {
            Judgement::Unknown("the app's list was read before the Run's create could land".into())
        }
        other => other,
    }
}

/// The child's JSON answer (`result` when it has one), or its error object.
fn answer(ran: &Ran) -> Result<Value, Value> {
    let parsed = |text: &str| -> Option<Value> {
        let text = text.trim();
        serde_json::from_str::<Value>(text)
            .ok()
            .or_else(|| text.lines().rev().find_map(|line| serde_json::from_str(line.trim()).ok()))
    };
    if ran.code == Some(0)
        && let Some(value) = parsed(&ran.stdout)
    {
        return Ok(value.get("result").cloned().unwrap_or(value));
    }
    Err(parsed(&ran.stderr)
        .or_else(|| parsed(&ran.stdout))
        .filter(|value| value.get("code").is_some() || value.get("message").is_some())
        .unwrap_or_else(|| {
            let text = if ran.stderr.trim().is_empty() { &ran.stdout } else { &ran.stderr };
            serde_json::json!({ "code": "step.failed", "message": text.trim() })
        }))
}

fn text(value: &Value, name: &str) -> String {
    value.get(name).and_then(Value::as_str).unwrap_or_default().to_owned()
}

/// The machine id an answer or an error's details name.
fn machine_of(value: &Value) -> Option<String> {
    ["/machine_id", "/details/machine_id", "/details/answer/machine_id"]
        .iter()
        .find_map(|path| value.pointer(path).and_then(Value::as_str))
        .filter(|id| !id.is_empty())
        .map(str::to_owned)
}

/// An account no list can name: the Run's start answered a machine its own account never listed.
/// No list clears it, so that Run's cleanup never reads `destroyed` (only `abandoned` once given up),
/// while a list of any account the app is on still deletes the Run's machine by its own name.
const UNKNOWN_ACCOUNT: &str = "unknown";

/// Whether a `cloud start-chat` answer says its start-session ran: a start the app took
/// (`cloud.start_pending` before any send) or a machine it answered.
fn reached_start(result: &Result<Value, Value>) -> bool {
    match result {
        Ok(_) => true,
        Err(error) => {
            text(error, "code") == "cloud.start_pending"
                || error.pointer("/details/machine_id").and_then(Value::as_str).is_some()
        }
    }
}

/// `cloud start-chat --account`'s refusal of a started machine its account's list never showed.
fn refused_unlisted(result: &Result<Value, Value>) -> bool {
    matches!(result, Err(error) if text(error, "code") == "cloud.account_changed"
        && error.pointer("/details/machine_id").and_then(Value::as_str).is_some())
}

/// The other account a `cloud start-chat --account` refusal found the app on (`app_account`): the
/// Run's machine may be there once a start of the Run reached start-session ([`reached_start`]).
fn app_account(result: &Result<Value, Value>) -> Option<String> {
    let Err(error) = result else { return None };
    if text(error, "code") != "cloud.account_changed" {
        return None;
    }
    error.pointer("/details/app_account").and_then(Value::as_str).map(str::to_owned)
}

/// Whether a `cloud start-chat` answer is a start the app has not finished with nothing sent yet
/// (`cloud.start_pending`, not the one whose prompt may be on the machine, `sent: "unknown"`):
/// the same start is asked again, and finds the same machine by its name.
fn start_again(result: &Result<Value, Value>) -> bool {
    let Err(error) = result else { return false };
    text(error, "code") == "cloud.start_pending"
        && error.pointer("/details/sent").and_then(Value::as_str) != Some("unknown")
}

/// The Run's task: `attempt` (one `cloud start-chat` given the time left) again while the app is
/// still making the machine ([`start_again`]), `pause` apart, until the task's `timeout` has no
/// room for another or a cancel; then its outcome. The app answers a start pending at the end of
/// its own start window (190 s), well inside a Run's default 10 minutes (Codex's review of #39022
/// at 1bf18b3d, F3): that is no timeout of the Run.
fn start_until(
    timeout: Duration,
    cancel: &AtomicBool,
    pause: Duration,
    mut attempt: impl FnMut(Duration) -> Ran,
) -> Outcome {
    let began = Instant::now();
    loop {
        let left = timeout.saturating_sub(began.elapsed());
        let started = Instant::now();
        let ran = attempt(left);
        let cancelled = cancel.load(Ordering::Acquire);
        let out_of_time =
            ran.code.is_none() && !cancelled && started.elapsed() >= left + START_MARGIN;
        let result = answer(&ran);
        if cancelled || out_of_time || !start_again(&result) || began.elapsed() + pause >= timeout {
            return outcome(ran.code, result, cancelled, out_of_time);
        }
        let until = Instant::now() + pause;
        while !cancel.load(Ordering::Acquire) {
            let now = Instant::now();
            if now >= until {
                break;
            }
            std::thread::sleep(POLL.min(until - now));
        }
        if cancel.load(Ordering::Acquire) {
            return outcome(ran.code, result, true, false);
        }
    }
}

/// How a `cloud start-chat --wait` child ended, as a Run's outcome.
pub(super) fn outcome(
    code: Option<i32>,
    result: Result<Value, Value>,
    cancelled: bool,
    out_of_time: bool,
) -> Outcome {
    let machine = match &result {
        Ok(value) | Err(value) => machine_of(value),
    };
    if cancelled {
        return Outcome::Cancelled { machine };
    }
    if out_of_time {
        return Outcome::TimedOut { machine };
    }
    match result {
        Ok(value) => match value.get("reply").and_then(Value::as_str) {
            Some(reply) => Outcome::Replied { reply: reply.to_owned(), machine },
            None => Outcome::Failed {
                code: "run.no_reply".into(),
                message: "the chat answered no reply".into(),
                reply: None,
                machine,
            },
        },
        Err(error) => {
            let code_text = text(&error, "code");
            if matches!(code_text.as_str(), "cloud.start_pending" | "chat.wait_timeout") {
                return Outcome::TimedOut { machine };
            }
            let reply = error.pointer("/details/reply").and_then(Value::as_str).map(str::to_owned);
            Outcome::Failed {
                code: if code_text.is_empty() {
                    format!("exit {}", code.unwrap_or(-1))
                } else {
                    code_text
                },
                message: text(&error, "message"),
                reply,
                machine,
            }
        }
    }
}

impl Steps for AppVerbs {
    fn scope(&self) -> Option<String> {
        // The app's sign-in (`cmux cloud run-account`, its `auth.status`), never its machine list:
        // an organization's Cloud policy refuses the list, and a Run that exists is still waited on
        // and cancelled with Cloud turned off (its cleanup reads the list again once it is back).
        let ran = self.cmux(&["cloud", "run-account"], None, ACCOUNT_BOUND, None);
        answer(&ran).ok().as_ref().and_then(account_scope)
    }

    fn run(&self, task: &Task, cancel: &AtomicBool) -> Outcome {
        // Whether a start of this Run reached the app's start-session, so a machine may exist.
        let mut reached = false;
        start_until(task.timeout, cancel, START_AGAIN_PAUSE, |left| {
            let seconds = left.as_secs().max(1).to_string();
            let words = [
                "cloud",
                "start-chat",
                "--name",
                task.machine_name.as_str(),
                "--agent",
                task.agent.as_str(),
                "--prompt",
                "-",
                "--wait",
                "--timeout",
                seconds.as_str(),
                "--account",
                task.account.as_str(),
            ];
            let ran = self.cmux(&words, Some(&task.prompt), left + START_MARGIN, Some(cancel));
            let result = answer(&ran);
            let started = reached_start(&result);
            reached |= started || ran.code.is_none();
            let mut others = Vec::new();
            // Once a start may have made the machine (this attempt or an earlier one): the account
            // the refusal found the app on, and the one it is on now, are where it may be.
            if reached {
                others.extend(app_account(&result));
                others.extend(self.scope().filter(|now| *now != task.account));
            }
            // A refusal for a machine the Run's own account never listed, the app on that account
            // again (a switch there and back during the start): made where no list can say.
            if started && app_account(&result).is_none() && refused_unlisted(&result) {
                others.push(UNKNOWN_ACCOUNT.to_owned());
            }
            if !others.is_empty() {
                let mut seen =
                    self.elsewhere.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
                seen.entry(task.run.clone()).or_default().extend(others);
            }
            ran
        })
    }

    fn elsewhere(&self, run: &str) -> Vec<String> {
        self.elsewhere
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(run)
            .unwrap_or_default()
    }

    fn remove(
        &self,
        machine_name: &str,
        machine: Option<&str>,
        scope: Option<&str>,
        elsewhere: &[String],
        listed_since_ms: i64,
    ) -> Removal {
        let list = match self.list() {
            Ok(list) => list,
            // No list at all (the app not running, or Cloud turned off): no time toward giving up.
            Err(message) => return Removal::Unheard(message),
        };
        let judged = judge_everywhere(&list, machine_name, machine, scope, elsewhere);
        let id = match fresh(judged, &list, listed_since_ms) {
            Judgement::Gone => return Removal::Gone,
            Judgement::Unknown(reason) => return Removal::Unheard(reason),
            Judgement::Cleared(other) => return Removal::Cleared(other),
            Judgement::Wait(reason) => return Removal::Later(reason),
            Judgement::Creating(reason) => return Removal::Creating(reason),
            Judgement::Kill(id) => id,
        };
        let target = format!("machine:{id}");
        let ran = self.cmux(
            &["cloud", "kill-machine", "--target", &target, "--confirm"],
            None,
            STEP_BOUND,
            None,
        );
        // An accepted delete is only started (`pending`, `deleting`): a later list confirms it.
        Removal::Later(match answer(&ran) {
            Ok(_) => format!("asked to delete machine {id}"),
            Err(error) => text(&error, "message"),
        })
    }
}

#[cfg(test)]
mod tests;
