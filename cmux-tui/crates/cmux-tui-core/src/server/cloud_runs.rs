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
//! - the scope, before the task: `cloud list-machines`' `account` (signed in, the person and the
//!   team, [`account_scope`]);
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
    fn cmux(
        &self,
        words: &[&str],
        stdin: Option<&str>,
        bound: Duration,
        cancel: Option<&AtomicBool>,
    ) -> Ran {
        let failed = |message: String| Ran { code: None, stdout: String::new(), stderr: message };
        let Some(exe) = &self.exe else { return failed("the cmux binary is not known".into()) };
        let mut command = Command::new(exe);
        command
            .args(leading_args(self.app_socket.as_deref()))
            .args(words)
            .env("CMUX_TUI_SOCKET", &self.socket)
            .stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let mut child = match command.spawn() {
            Ok(child) => child,
            Err(error) => return failed(error.to_string()),
        };
        if let (Some(text), Some(mut input)) = (stdin, child.stdin.take()) {
            // The prompt is at most 16000 characters: one write, then EOF.
            let _ = input.write_all(text.as_bytes());
        }
        let read = |pipe: Option<Box<dyn std::io::Read + Send>>| {
            std::thread::spawn(move || {
                let mut text = String::new();
                if let Some(pipe) = pipe {
                    let _ = pipe.take(MAX_OUTPUT).read_to_string(&mut text);
                }
                text
            })
        };
        let out = read(child.stdout.take().map(|p| Box::new(p) as Box<dyn std::io::Read + Send>));
        let err = read(child.stderr.take().map(|p| Box::new(p) as Box<dyn std::io::Read + Send>));
        let began = Instant::now();
        let code = loop {
            match child.wait_timeout(POLL) {
                Ok(Some(status)) => break status.code(),
                Ok(None) => {}
                Err(_) => break None,
            }
            let cancelled = cancel.is_some_and(|flag| flag.load(Ordering::Acquire));
            if cancelled || began.elapsed() >= bound {
                // Our own child, by its handle.
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
        };
        Ran { code, stdout: out.join().unwrap_or_default(), stderr: err.join().unwrap_or_default() }
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
        return Judgement::Wait("the app's machine list has not loaded".into());
    }
    let Some(listed_scope) = account_scope(list) else {
        return Judgement::Wait("the app is not signed in to Cloud".into());
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
        let creating =
            rows("creating").any(|row| field(row, "name").as_deref() == Some(machine_name));
        if !creating && elsewhere.contains(&listed_scope) {
            return Judgement::Cleared(listed_scope);
        }
        return Judgement::Wait(format!("the app lists {listed_scope}'s machines, not {scope}'s"));
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
    if rows("creating").any(|row| field(row, "name").as_deref() == Some(machine_name)) {
        return Judgement::Wait(format!("{machine_name} is still being created"));
    }
    Judgement::Gone
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
        self.list().ok().as_ref().and_then(account_scope)
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
    ) -> Removal {
        let list = match self.list() {
            Ok(list) => list,
            Err(message) => return Removal::Later(message),
        };
        let id = match judge_everywhere(&list, machine_name, machine, scope, elsewhere) {
            Judgement::Gone => return Removal::Gone,
            Judgement::Cleared(other) => return Removal::Cleared(other),
            Judgement::Wait(reason) => return Removal::Later(reason),
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
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_reply_is_the_runs_answer_and_names_its_machine() {
        let got = outcome(Some(0), Ok(json!({ "reply": "hi", "machine_id": "m1" })), false, false);
        assert_eq!(got, Outcome::Replied { reply: "hi".into(), machine: Some("m1".into()) });
    }

    #[test]
    fn the_start_chats_own_timeouts_are_a_timed_out_run() {
        for code in ["cloud.start_pending", "chat.wait_timeout"] {
            let error = json!({ "code": code, "message": "m", "details": { "answer": { "machine_id": "m2" } } });
            assert_eq!(
                outcome(Some(3), Err(error), false, false),
                Outcome::TimedOut { machine: Some("m2".into()) }
            );
        }
        assert_eq!(outcome(None, Err(json!({})), false, true), Outcome::TimedOut { machine: None });
    }

    #[test]
    fn a_failed_turn_keeps_its_reply_and_a_cancel_wins() {
        let error = json!({ "code": "chat.turn_failed", "message": "the turn ended failed",
                            "details": { "reply": "partial", "machine_id": "m3" } });
        assert_eq!(
            outcome(Some(1), Err(error.clone()), false, false),
            Outcome::Failed {
                code: "chat.turn_failed".into(),
                message: "the turn ended failed".into(),
                reply: Some("partial".into()),
                machine: Some("m3".into())
            }
        );
        assert_eq!(
            outcome(None, Err(error), true, false),
            Outcome::Cancelled { machine: Some("m3".into()) }
        );
    }

    #[test]
    fn an_answer_is_read_from_stdout_and_an_error_from_stderr() {
        let ran = Ran {
            code: Some(0),
            stdout: "noise\n{\"reply\":\"r\"}\n".into(),
            stderr: String::new(),
        };
        assert_eq!(answer(&ran), Ok(json!({ "reply": "r" })));
        let ran = Ran {
            code: Some(1),
            stdout: String::new(),
            stderr: "{\"code\":\"cloud.signed_out\",\"message\":\"sign in\"}".into(),
        };
        assert_eq!(answer(&ran).unwrap_err()["code"], "cloud.signed_out");
        let ran = Ran { code: None, stdout: String::new(), stderr: "boom".into() };
        assert_eq!(answer(&ran).unwrap_err(), json!({ "code": "step.failed", "message": "boom" }));
    }

    const NAME: &str = "sandbox-run_1";

    /// `cloud list-machines` as `CloudHandlers.machineListFields` answers it: `listedMachine`
    /// rows (`machine_id`, `target`, `title`, `status`, `owner`, …), `listedCreation` rows and the
    /// account.
    /// `user` None: signed out.
    fn list(
        loaded: bool,
        user: Option<&str>,
        team: Option<&str>,
        machines: Value,
        creating: Value,
    ) -> Value {
        let count = machines.as_array().map_or(0, Vec::len);
        json!({
            "loaded": loaded,
            "machines": if loaded { machines } else { json!([]) },
            "count": count,
            "creating": creating,
            "account": { "signed_in": user.is_some(), "user_id": user, "team_id": team },
        })
    }

    fn listed(id: &str, title: &str, status: &str) -> Value {
        json!({
            "machine_id": id, "target": format!("machine:{id}"), "title": title, "status": status,
            "owner": "team", "created_by": "u1", "created_at": "2026-11-09T00:00:00Z", "error": null,
        })
    }

    const U1_T1: Option<&str> = Some("user:u1|team:t1");
    const U1: Option<&str> = Some("user:u1|personal");

    #[test]
    fn a_run_machine_is_found_by_its_title_or_its_id_and_deleted() {
        let machines =
            json!([listed("m-other", "other", "running"), listed("m-9", NAME, "running")]);
        let answer = list(true, Some("u1"), Some("t1"), machines, json!([]));
        assert_eq!(judge(&answer, NAME, None, U1_T1), Judgement::Kill("m-9".into()));
        let renamed = list(
            true,
            Some("u1"),
            Some("t1"),
            json!([listed("m-9", "renamed", "paused")]),
            json!([]),
        );
        assert_eq!(judge(&renamed, NAME, Some("m-9"), U1_T1), Judgement::Kill("m-9".into()));
    }

    #[test]
    fn only_a_loaded_signed_in_list_of_the_runs_own_person_and_team_says_gone() {
        let empty = json!([]);
        let gone = list(
            true,
            Some("u1"),
            Some("t1"),
            json!([listed("m-x", "x", "running")]),
            empty.clone(),
        );
        assert_eq!(judge(&gone, NAME, Some("m-9"), U1_T1), Judgement::Gone);
        // Not loaded yet (a relaunch, a slow first list): its empty list says nothing.
        let not_loaded = list(false, Some("u1"), Some("t1"), empty.clone(), empty.clone());
        assert!(matches!(judge(&not_loaded, NAME, Some("m-9"), U1_T1), Judgement::Wait(_)));
        // Signed out: loaded is false and the list is empty.
        let signed_out = list(false, None, None, empty.clone(), empty.clone());
        assert!(matches!(judge(&signed_out, NAME, Some("m-9"), U1_T1), Judgement::Wait(_)));
        // Signed in to another team (or personal): that list is not the Run's.
        let other = list(true, Some("u1"), Some("t2"), empty.clone(), empty.clone());
        assert!(matches!(judge(&other, NAME, Some("m-9"), U1_T1), Judgement::Wait(_)));
        let personal = list(true, Some("u1"), None, empty.clone(), empty);
        assert!(matches!(judge(&personal, NAME, None, U1_T1), Judgement::Wait(_)));
        assert_eq!(judge(&personal, NAME, None, U1), Judgement::Gone);
        // A Run with no scope matches no list.
        assert!(matches!(judge(&personal, NAME, None, None), Judgement::Wait(_)));
    }

    #[test]
    fn another_person_on_the_same_team_or_personal_never_says_gone() {
        // Two personal accounts are two scopes.
        let theirs = list(true, Some("u2"), None, json!([]), json!([]));
        assert!(matches!(judge(&theirs, NAME, Some("m-9"), U1), Judgement::Wait(_)));
        // The same team under another person is another scope too.
        let teammate = list(true, Some("u2"), Some("t1"), json!([]), json!([]));
        assert!(matches!(judge(&teammate, NAME, None, U1_T1), Judgement::Wait(_)));
        // A list naming no user (an older app) is no one's.
        let mut nameless = list(true, Some("u1"), None, json!([]), json!([]));
        nameless["account"].as_object_mut().unwrap().remove("user_id");
        assert_eq!(account_scope(&nameless), None);
        assert!(matches!(judge(&nameless, NAME, None, U1), Judgement::Wait(_)));
        // A scope stored before scopes named the person matches no list.
        let t1 = list(true, Some("u1"), Some("t1"), json!([]), json!([]));
        assert!(matches!(judge(&t1, NAME, None, Some("team:t1")), Judgement::Wait(_)));
    }

    /// Codex's review of #39022 at 8c2c83b0 (after 551a7dca's F3): a machine of the Run's own name
    /// on another account (a switch during its start) is deleted there, and only a list of an
    /// account the start found the app on, showing none of it, clears that account.
    #[test]
    fn the_runs_machine_on_another_account_is_deleted_there_and_its_list_clears_it() {
        let elsewhere = ["user:u2|personal".to_owned()];
        let theirs =
            list(true, Some("u2"), None, json!([listed("m-b", NAME, "running")]), json!([]));
        assert_eq!(
            judge_everywhere(&theirs, NAME, None, U1_T1, &elsewhere),
            Judgement::Kill("m-b".into())
        );
        // Another machine's id on that account is never the Run's: only its own name.
        let id_only =
            list(true, Some("u2"), None, json!([listed("m-9", "dev", "running")]), json!([]));
        assert!(matches!(
            judge_everywhere(&id_only, NAME, Some("m-9"), U1_T1, &elsewhere),
            Judgement::Cleared(_)
        ));
        let empty = list(true, Some("u2"), None, json!([]), json!([]));
        assert_eq!(
            judge_everywhere(&empty, NAME, None, U1_T1, &elsewhere),
            Judgement::Cleared("user:u2|personal".into())
        );
        // An account the start never found the app on clears nothing.
        assert!(matches!(judge_everywhere(&empty, NAME, None, U1_T1, &[]), Judgement::Wait(_)));
        // A create of the name still on its way there clears nothing.
        let creating = json!([{ "creation_id": "c1", "name": NAME, "status": "creating" }]);
        let on_its_way = list(true, Some("u2"), None, json!([]), creating);
        assert!(matches!(
            judge_everywhere(&on_its_way, NAME, None, U1_T1, &elsewhere),
            Judgement::Wait(_)
        ));
        // A start-chat refusal names that account.
        let refusal = Err(json!({ "code": "cloud.account_changed", "message": "x",
                                  "details": { "account": "user:u1|team:t1", "app_account": "user:u2|personal",
                                               "machine_id": "vm-1" } }));
        assert_eq!(app_account(&refusal).as_deref(), Some("user:u2|personal"));
        assert!(reached_start(&refusal) && refused_unlisted(&refusal));
        // A refusal before any start answered a machine reached nothing.
        let before = Err(json!({ "code": "cloud.account_changed", "message": "x",
                                 "details": { "account": "user:u1|team:t1", "app_account": "user:u2|personal",
                                              "machine_id": null } }));
        assert!(!reached_start(&before) && !refused_unlisted(&before));
        assert!(reached_start(&Err(json!({ "code": "cloud.start_pending" }))));
        // The account no list names is never cleared.
        let empty = list(true, Some("u2"), None, json!([]), json!([]));
        let unknown = [UNKNOWN_ACCOUNT.to_owned()];
        assert!(matches!(
            judge_everywhere(&empty, NAME, None, U1_T1, &unknown),
            Judgement::Wait(_)
        ));
        assert_eq!(app_account(&Err(json!({ "code": "cloud.start_pending" }))), None);
    }

    #[test]
    fn a_machine_being_deleted_or_still_being_created_is_read_again() {
        let deleting =
            list(true, Some("u1"), None, json!([listed("m-9", NAME, "deleting")]), json!([]));
        assert!(matches!(judge(&deleting, NAME, Some("m-9"), U1), Judgement::Wait(_)));
        let creating = json!([{ "creation_id": "c1", "name": NAME, "status": "creating" }]);
        let on_its_way = list(true, Some("u1"), None, json!([]), creating);
        assert!(matches!(judge(&on_its_way, NAME, None, U1), Judgement::Wait(_)));
    }

    #[test]
    fn the_scope_is_the_lists_person_and_team() {
        assert_eq!(
            account_scope(&list(true, Some("u1"), Some("t1"), json!([]), json!([]))).as_deref(),
            U1_T1
        );
        assert_eq!(
            account_scope(&list(true, Some("u1"), None, json!([]), json!([]))).as_deref(),
            U1
        );
        assert_eq!(account_scope(&list(false, None, None, json!([]), json!([]))), None);
    }

    fn ran(code: i32, stderr: Value) -> Ran {
        Ran { code: Some(code), stdout: String::new(), stderr: stderr.to_string() }
    }

    fn pending(sent: Option<&str>) -> Ran {
        let details = match sent {
            Some(sent) => json!({ "machine_id": "m-1", "sent": sent }),
            None => json!({ "machine_name": NAME, "stage": { "status": "provisioning" } }),
        };
        ran(
            75,
            json!({ "code": "cloud.start_pending", "message": "still starting", "details": details }),
        )
    }

    fn replied() -> Ran {
        let stdout = json!({ "result": { "reply": "done", "machine_id": "m-1" } }).to_string();
        Ran { code: Some(0), stdout, stderr: String::new() }
    }

    /// Runs `start_until` over `answers` in turn; answers the outcome and the time left each
    /// attempt was given.
    fn started(
        timeout: Duration,
        answers: Vec<Ran>,
        cancel: &AtomicBool,
    ) -> (Outcome, Vec<Duration>) {
        let mut answers = answers.into_iter();
        let mut given = Vec::new();
        let outcome = start_until(timeout, cancel, Duration::from_millis(1), |left| {
            given.push(left);
            answers.next().expect("an answer for every attempt")
        });
        (outcome, given)
    }

    /// Codex's review of #39022 at 1bf18b3d (F3): a start the app answers pending (its own start
    /// window ended) is asked again within the Run's time, never taken as the Run's timeout.
    #[test]
    fn a_pending_start_is_asked_again_within_the_runs_time() {
        let cancel = AtomicBool::new(false);
        let timeout = Duration::from_secs(600);
        let (got, given) = started(timeout, vec![pending(None), pending(None), replied()], &cancel);
        assert_eq!(got, Outcome::Replied { reply: "done".into(), machine: Some("m-1".into()) });
        assert_eq!(given.len(), 3);
        assert!(
            given.windows(2).all(|pair| pair[1] <= pair[0]) && given[0] <= timeout,
            "{given:?}"
        );
    }

    #[test]
    fn a_start_is_not_asked_again_once_the_prompt_may_be_there_or_the_time_is_gone() {
        let cancel = AtomicBool::new(false);
        // The prompt may have reached the machine: asking again could send it twice.
        let (got, given) =
            started(Duration::from_secs(600), vec![pending(Some("unknown"))], &cancel);
        assert!(matches!(got, Outcome::TimedOut { .. }), "{got:?}");
        assert_eq!(given.len(), 1);
        // A turn that did not end in time is the Run's timeout.
        let wait_timeout = ran(75, json!({ "code": "chat.wait_timeout", "message": "x" }));
        let (got, given) = started(Duration::from_secs(600), vec![wait_timeout], &cancel);
        assert!(matches!(got, Outcome::TimedOut { .. }), "{got:?}");
        assert_eq!(given.len(), 1);
        // No room left for another start.
        let (got, given) = started(Duration::from_millis(1), vec![pending(None)], &cancel);
        assert!(matches!(got, Outcome::TimedOut { .. }), "{got:?}");
        assert_eq!(given.len(), 1);
        // A cancel ends it.
        let cancel = AtomicBool::new(true);
        let (got, given) = started(Duration::from_secs(600), vec![pending(None)], &cancel);
        assert!(matches!(got, Outcome::Cancelled { .. }), "{got:?}");
        assert_eq!(given.len(), 1);
    }

    #[test]
    fn a_child_names_the_app_socket_never_the_daemons() {
        let args = leading_args(Some(Path::new("/tmp/app.sock")));
        assert_eq!(args, ["--json", "--app-socket", "/tmp/app.sock"].map(std::ffi::OsString::from));
        assert_eq!(leading_args(None), [std::ffi::OsString::from("--json")]);
    }
}
