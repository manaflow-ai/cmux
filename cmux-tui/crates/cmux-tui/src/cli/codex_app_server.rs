//! `cmux agent message` to a Codex agent through the shared Codex app-server
//! daemon (cmux #16417): `turn/start` when its thread is idle, `turn/steer`
//! when a turn is running. Codex attaches its TUI to that daemon whenever the
//! daemon runs, so the agent sees the message as its next input without
//! anything typed into the terminal.
//!
//! A thread the daemon has not loaded is left alone: resuming it there would
//! give the thread a second writer next to the Codex process in the terminal.
//! Anything short of a delivery leaves the message queued for the agent's
//! hooks. [`open`] asks the daemon whether the thread can take input before
//! [`Session::send`] hands it over, so the caller can claim the messages in
//! between and the hook that the new turn fires finds none left to repeat.

use std::io::{BufRead, BufReader, Write};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{Receiver, RecvTimeoutError, channel};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

/// One delivery, from starting the proxy to the daemon's answer.
const DEADLINE: Duration = Duration::from_secs(8);

/// Why a thread cannot take input now. The hooks deliver later either way.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Unavailable {
    /// No shared daemon runs (the usual case), or codex is not installed.
    NoDaemon,
    /// The daemon runs but this thread cannot take input; says why.
    Thread(String),
}

/// How the input reaches the thread.
#[derive(Debug, PartialEq, Eq)]
enum Target {
    Start,
    Steer(String),
}

/// A thread that can take input now. Opening it asks the daemon first, so a
/// caller can claim its messages before [`Session::send`] hands them over.
pub(super) struct Session {
    client: Client,
    thread_id: String,
    target: Target,
}

pub(super) fn open(thread_id: &str) -> Result<Session, Unavailable> {
    let mut client = Client::start().map_err(|_| Unavailable::NoDaemon)?;
    let target = client.target(thread_id).map_err(Unavailable::Thread)?;
    Ok(Session { client, thread_id: thread_id.to_owned(), target })
}

impl Session {
    /// Hand `text` to the thread as user input; the receipt's `via`.
    /// `client_message_id` lets Codex tie the input to the cmux message.
    pub(super) fn send(
        mut self,
        text: &str,
        client_message_id: &str,
    ) -> Result<&'static str, String> {
        let thread_id = self.thread_id.clone();
        match std::mem::replace(&mut self.target, Target::Start) {
            Target::Start => self.client.start_turn(&thread_id, text, client_message_id),
            Target::Steer(turn) => {
                let steered = self.client.request(
                    "turn/steer",
                    json!({
                        "threadId": thread_id,
                        "expectedTurnId": turn,
                        "input": user_input(text),
                        "clientUserMessageId": client_message_id,
                    }),
                );
                match steered {
                    Ok(_) => Ok("codex.turn-steer"),
                    // Only a turn that ended in between gets a new one.
                    Err(error) => match self.client.read_state(&thread_id) {
                        Ok(ThreadState::Idle) => {
                            self.client.start_turn(&thread_id, text, client_message_id)
                        }
                        _ => Err(error),
                    },
                }
            }
        }
    }
}

/// What the daemon reports about a thread.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum ThreadState {
    Idle,
    /// A turn is running and not waiting on the user.
    Running,
    /// Waiting on an approval or on input, not loaded, or failed.
    Unavailable(String),
}

pub(super) fn thread_state(thread: &Value) -> ThreadState {
    let status = &thread["status"];
    match status["type"].as_str() {
        Some("idle") => ThreadState::Idle,
        Some("active") => {
            let flags: Vec<&str> = status["activeFlags"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .collect();
            if flags.is_empty() {
                ThreadState::Running
            } else {
                ThreadState::Unavailable(format!("the thread is {}", flags.join(", ")))
            }
        }
        other => ThreadState::Unavailable(format!(
            "the thread is {}",
            other.unwrap_or("in an unknown state")
        )),
    }
}

/// The running turn of a `thread/read` result read with its turns.
pub(super) fn running_turn(thread: &Value) -> Option<&str> {
    thread["turns"]
        .as_array()?
        .iter()
        .rev()
        .find(|turn| turn["status"] == "inProgress")
        .and_then(|turn| turn["id"].as_str())
}

pub(super) fn user_input(text: &str) -> Value {
    json!([{"type": "text", "text": text, "text_elements": []}])
}

struct Client {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
    next_id: u64,
    deadline: Instant,
}

impl Client {
    fn start() -> Result<Self, String> {
        let program = std::env::var_os("CMUX_CODEX_BIN").unwrap_or_else(|| "codex".into());
        let mut child = Command::new(program)
            .args(["app-server", "proxy"])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .map_err(|error| format!("cannot run codex: {error}"))?;
        let stdin = child.stdin.take().ok_or("codex app-server proxy has no stdin")?;
        let stdout = child.stdout.take().ok_or("codex app-server proxy has no stdout")?;
        let (sender, lines) = channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if sender.send(line).is_err() {
                    break;
                }
            }
        });
        let mut client =
            Self { child, stdin, lines, next_id: 1, deadline: Instant::now() + DEADLINE };
        client.request(
            "initialize",
            json!({
                "clientInfo": {
                    "name": "cmux",
                    "title": "cmux agent message",
                    "version": env!("CARGO_PKG_VERSION"),
                },
                "capabilities": {"experimentalApi": true},
            }),
        )?;
        client.send(&json!({"method": "initialized"}))?;
        Ok(client)
    }

    /// Whether `thread_id` can take input now, and how.
    fn target(&mut self, thread_id: &str) -> Result<Target, String> {
        if !self.is_loaded(thread_id)? {
            return Err("the shared Codex app-server has not loaded this thread".to_owned());
        }
        match self.read_state(thread_id)? {
            ThreadState::Idle => Ok(Target::Start),
            ThreadState::Running => {
                let read = self
                    .request("thread/read", json!({"threadId": thread_id, "includeTurns": true}))?;
                // A turn that ended in between leaves an idle thread.
                Ok(running_turn(&read["thread"])
                    .map_or(Target::Start, |turn| Target::Steer(turn.to_owned())))
            }
            ThreadState::Unavailable(reason) => Err(reason),
        }
    }

    fn read_state(&mut self, thread_id: &str) -> Result<ThreadState, String> {
        let read = self.request("thread/read", json!({"threadId": thread_id}))?;
        Ok(thread_state(&read["thread"]))
    }

    fn start_turn(
        &mut self,
        thread_id: &str,
        text: &str,
        client_message_id: &str,
    ) -> Result<&'static str, String> {
        self.request(
            "turn/start",
            json!({
                "threadId": thread_id,
                "input": user_input(text),
                "clientUserMessageId": client_message_id,
            }),
        )?;
        Ok("codex.turn-start")
    }

    fn is_loaded(&mut self, thread_id: &str) -> Result<bool, String> {
        let mut cursor = Value::Null;
        loop {
            let page = self.request("thread/loaded/list", json!({"cursor": cursor}))?;
            if page["data"].as_array().into_iter().flatten().any(|id| id == thread_id) {
                return Ok(true);
            }
            match &page["nextCursor"] {
                Value::String(next) => cursor = Value::String(next.clone()),
                _ => return Ok(false),
            }
        }
    }

    fn send(&mut self, message: &Value) -> Result<(), String> {
        writeln!(self.stdin, "{message}")
            .and_then(|()| self.stdin.flush())
            .map_err(|_| "no shared Codex app-server is running".to_owned())
    }

    fn request(&mut self, method: &str, params: Value) -> Result<Value, String> {
        let id = self.next_id;
        self.next_id += 1;
        self.send(&json!({"id": id, "method": method, "params": params}))?;
        loop {
            let left = self.deadline.saturating_duration_since(Instant::now());
            let line = match self.lines.recv_timeout(left) {
                Ok(line) => line,
                Err(RecvTimeoutError::Timeout) => {
                    return Err(format!("the Codex app-server did not answer {method} in time"));
                }
                // The proxy exits when it cannot reach the daemon.
                Err(RecvTimeoutError::Disconnected) => {
                    return Err("no shared Codex app-server is running".to_owned());
                }
            };
            let Ok(message) = serde_json::from_str::<Value>(&line) else { continue };
            // Notifications and requests from the daemon are not ours.
            if message.get("method").is_some() || message["id"] != id {
                continue;
            }
            if let Some(error) = message.get("error") {
                let text =
                    error["message"].as_str().map_or_else(|| error.to_string(), str::to_owned);
                return Err(format!("{method}: {text}"));
            }
            return Ok(message.get("result").cloned().unwrap_or(Value::Null));
        }
    }
}

impl Drop for Client {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_thread_waiting_on_the_user_or_not_loaded_is_left_for_the_hooks() {
        assert_eq!(thread_state(&json!({"status": {"type": "idle"}})), ThreadState::Idle);
        assert_eq!(
            thread_state(&json!({"status": {"type": "active", "activeFlags": []}})),
            ThreadState::Running
        );
        assert!(matches!(
            thread_state(&json!({"status": {"type": "active", "activeFlags": ["waitingOnApproval"]}})),
            ThreadState::Unavailable(reason) if reason.contains("waitingOnApproval")
        ));
        assert!(matches!(
            thread_state(&json!({"status": {"type": "notLoaded"}})),
            ThreadState::Unavailable(_)
        ));
        assert!(matches!(thread_state(&json!({})), ThreadState::Unavailable(_)));
    }

    #[test]
    fn the_running_turn_is_the_last_one_in_progress() {
        let thread = json!({"turns": [
            {"id": "t1", "status": "completed"},
            {"id": "t2", "status": "inProgress"},
        ]});
        assert_eq!(running_turn(&thread), Some("t2"));
        assert_eq!(running_turn(&json!({"turns": [{"id": "t1", "status": "completed"}]})), None);
    }

    #[cfg(unix)]
    #[test]
    fn a_fake_daemon_gets_a_turn_start_for_an_idle_loaded_thread_and_nothing_for_others() {
        let dir = std::env::temp_dir().join(format!("cmux-codex-fake-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let log = dir.join("requests.jsonl");
        let script = dir.join("codex");
        // Answers each request by method and records it.
        std::fs::write(
            &script,
            format!(
                r#"#!/bin/sh
while IFS= read -r line; do
  printf '%s\n' "$line" >> '{log}'
  id=$(printf '%s' "$line" | sed -n 's/.*"id":\([0-9]*\).*/\1/p')
  [ -z "$id" ] && continue
  case "$line" in
    *'"thread/loaded/list"'*) printf '{{"id":%s,"result":{{"data":["thr_idle"],"nextCursor":null}}}}\n' "$id" ;;
    *'"thread/read"'*) printf '{{"method":"thread/status/changed","params":{{}}}}\n{{"id":%s,"result":{{"thread":{{"status":{{"type":"idle"}}}}}}}}\n' "$id" ;;
    *) printf '{{"id":%s,"result":{{}}}}\n' "$id" ;;
  esac
done
"#,
                log = log.display()
            ),
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o755)).unwrap();
        // SAFETY: only this test reads CMUX_CODEX_BIN.
        unsafe { std::env::set_var("CMUX_CODEX_BIN", &script) };

        let session = open("thr_idle").unwrap_or_else(|_| panic!("the idle thread is open"));
        assert_eq!(session.send("hello", "msg_1"), Ok("codex.turn-start"));
        assert!(matches!(open("thr_other"), Err(Unavailable::Thread(_))));

        let requests: Vec<Value> = std::fs::read_to_string(&log)
            .unwrap()
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        let started: Vec<&Value> =
            requests.iter().filter(|request| request["method"] == "turn/start").collect();
        assert_eq!(started.len(), 1);
        assert_eq!(started[0]["params"]["threadId"], "thr_idle");
        assert_eq!(started[0]["params"]["input"][0]["text"], "hello");
        assert_eq!(started[0]["params"]["clientUserMessageId"], "msg_1");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
