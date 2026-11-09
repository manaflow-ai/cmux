//! The daemon's sandboxed Runs (`cloud.runs.*`): `cmux_cloud_api::sandbox`'s engine with steps
//! that run the app's own Cloud verbs, the ones `cmux cloud start-chat` runs, as children of this
//! binary pointed at this daemon's socket (the CLI reaches the app that owns the daemon):
//!
//! - the task: `cloud start-chat --name sandbox-<run> --agent A --prompt - --wait --timeout S`, a
//!   Cloud chat on a new small machine with the task as its prompt (on stdin, never in argv) and
//!   the turn's reply as its answer. The machine, the agent's login and the send take the same
//!   path a person's `cmux chat --on vm:new` takes, checks and approvals included;
//! - the cleanup: `cloud list-machines` to find the machine by its name when its id is not known,
//!   then `cloud kill-machine --target machine:ID --confirm`.
//!
//! The Runs persist in `cloud-runs.json` in the session's state directory (none for an in-memory
//! session), so a daemon that starts again resumes their cleanup ([`resume`]).
//!
//! Stop conditions: a task's child is killed at a cancel or at its bound (the task's timeout and
//! [`START_MARGIN`]); every other child at [`STEP_BOUND`]. The engine's own bounds are its module's.

use std::io::{Read as _, Write as _};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};

use cmux_cloud_api::sandbox::{Engine, Outcome, Removal, Steps, Task, Timing};
use cmux_process::{Command, Stdio};
use serde_json::Value;

use crate::Mux;

/// Past the task's own `--timeout`: the start-chat's last read and its answer.
const START_MARGIN: Duration = Duration::from_secs(60);
/// A list or a delete.
const STEP_BOUND: Duration = Duration::from_secs(180);
/// How often a running child is checked for a cancel or its bound.
const POLL: Duration = Duration::from_millis(250);
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
        let steps = Arc::new(AppVerbs { exe: std::env::current_exe().ok(), socket });
        Engine::open(store, steps, Timing::default())
    })
}

/// At the daemon's start: Runs a former daemon left get their cleanup again (nothing when it left none).
pub(super) fn resume(mux: &Mux) {
    let has_store = mux
        .session_state_directory()
        .is_some_and(|dir| dir.join(STORE_FILE).exists());
    if has_store {
        engine(mux);
    }
}

/// Steps that run this binary's own Cloud verbs against `socket`.
struct AppVerbs {
    exe: Option<PathBuf>,
    socket: PathBuf,
}

/// One child's end: its exit code (`None`: killed or never started) and output.
struct Ran {
    code: Option<i32>,
    stdout: String,
    stderr: String,
}

impl AppVerbs {
    fn cmux(&self, words: &[&str], stdin: Option<&str>, bound: Duration, cancel: Option<&AtomicBool>) -> Ran {
        let failed = |message: String| Ran { code: None, stdout: String::new(), stderr: message };
        let Some(exe) = &self.exe else { return failed("the cmux binary is not known".into()) };
        let mut command = Command::new(exe);
        command
            .arg("--json")
            .arg("--socket")
            .arg(&self.socket)
            .args(words)
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

    fn machines(&self) -> Result<Vec<(String, Option<String>)>, String> {
        let ran = self.cmux(&["cloud", "list-machines"], None, STEP_BOUND, None);
        let listed = answer(&ran).map_err(|error| text(&error, "message"))?;
        Ok(listed
            .get("machines")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|row| {
                let id = row.get("machine_id").and_then(Value::as_str)?;
                Some((id.to_owned(), row.get("name").and_then(Value::as_str).map(str::to_owned)))
            })
            .collect())
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

/// How a `cloud start-chat --wait` child ended, as a Run's outcome.
pub(super) fn outcome(code: Option<i32>, result: Result<Value, Value>, cancelled: bool, out_of_time: bool) -> Outcome {
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
                code: if code_text.is_empty() { format!("exit {}", code.unwrap_or(-1)) } else { code_text },
                message: text(&error, "message"),
                reply,
                machine,
            }
        }
    }
}

impl Steps for AppVerbs {
    fn run(&self, task: &Task, cancel: &AtomicBool) -> Outcome {
        let seconds = task.timeout.as_secs().max(1).to_string();
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
        ];
        let bound = task.timeout + START_MARGIN;
        let began = Instant::now();
        let ran = self.cmux(&words, Some(&task.prompt), bound, Some(cancel));
        let cancelled = cancel.load(Ordering::Acquire);
        let out_of_time = ran.code.is_none() && !cancelled && began.elapsed() >= bound;
        outcome(ran.code, answer(&ran), cancelled, out_of_time)
    }

    fn remove(&self, machine_name: &str, machine: Option<&str>) -> Removal {
        let listed = match self.machines() {
            Ok(listed) => listed,
            Err(message) => return Removal::Later(message),
        };
        let id = machine
            .filter(|id| listed.iter().any(|(listed, _)| listed == id))
            .map(str::to_owned)
            .or_else(|| {
                listed.iter().find(|(_, name)| name.as_deref() == Some(machine_name)).map(|(id, _)| id.clone())
            });
        let Some(id) = id else { return Removal::Gone };
        let target = format!("machine:{id}");
        let ran = self.cmux(&["cloud", "kill-machine", "--target", &target, "--confirm"], None, STEP_BOUND, None);
        match answer(&ran) {
            Ok(_) => Removal::Deleted,
            Err(error) => Removal::Later(text(&error, "message")),
        }
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
            assert_eq!(outcome(Some(3), Err(error), false, false), Outcome::TimedOut { machine: Some("m2".into()) });
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
        assert_eq!(outcome(None, Err(error), true, false), Outcome::Cancelled { machine: Some("m3".into()) });
    }

    #[test]
    fn an_answer_is_read_from_stdout_and_an_error_from_stderr() {
        let ran = Ran { code: Some(0), stdout: "noise\n{\"reply\":\"r\"}\n".into(), stderr: String::new() };
        assert_eq!(answer(&ran), Ok(json!({ "reply": "r" })));
        let ran = Ran { code: Some(1), stdout: String::new(), stderr: "{\"code\":\"cloud.signed_out\",\"message\":\"sign in\"}".into() };
        assert_eq!(answer(&ran).unwrap_err()["code"], "cloud.signed_out");
        let ran = Ran { code: None, stdout: String::new(), stderr: "boom".into() };
        assert_eq!(answer(&ran).unwrap_err(), json!({ "code": "step.failed", "message": "boom" }));
    }
}
