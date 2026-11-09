//! `cmux chat --prompt TEXT --wait`, `cmux chat send SESSION TEXT --wait` and `cmux chat wait
//! SESSION` for a chat on this machine: start the chat (or send the prompt), wait until its turn
//! ends and print the reply, in one command, with the answer `cmux chat --on vm:… --wait` gives
//! (`session_id`, `workspace_id`, `tab_id`, `reply`). Before, a chat here took three commands
//! (`agents chat new`, `agents wait --until idle`, `agents chat read`) with three answer shapes,
//! and `agents wait` stopped at 120 s.
//!
//! Nothing here waits its own way: each slice is `agents wait --until idle` on the chat (the
//! acpmux turn state, woken by daemon events), at most [`SLICE`] long, until `--timeout`. When
//! the chat is idle, the reply is the last answer of its newest turn: the turn starts at the
//! chat's newest prompt, found by reading its events back from the end, so the read costs the
//! turn's length and never the chat's whole history.
//!
//! Exit codes match the Cloud route (cloud_start_chat.rs): 0 the reply, 1 refused or the turn
//! failed or the chat went away, 2 the agent waits on a permission, 3 `--timeout` passed
//! (`chat.wait_timeout`, its answer `timed_out: true`).

use std::path::Path;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::super::mcp::{self, Backend, CallFailure};
use super::super::{GlobalArgs, OutputMode};
use super::{AgentCommand, AgentFailure, chat, wait};
use cmux_json::JsonSet as _;

/// How long `--wait` waits when `--timeout` is absent: Cloud's default.
pub(in crate::cli) const DEFAULT_TIMEOUT: Duration = Duration::from_secs(900);
/// The longest `--timeout`: Cloud's.
pub(in crate::cli) const MAX_TIMEOUT: Duration = Duration::from_secs(4 * 60 * 60);
/// One idle wait: the MCP tool's cap, so each slice is the wait an MCP call makes.
const SLICE: Duration = Duration::from_secs(wait::MAX_TIMEOUT_SECONDS);
/// The pause when the chat is idle but the prompt's turn has not started yet.
const NOT_STARTED_PAUSE: Duration = Duration::from_secs(1);
/// Events read per page when looking back for the newest prompt.
const BACK_PAGE: u64 = 1000;
/// Pages read back before giving up on finding the prompt (a turn of more events than this
/// answers from the oldest event read).
const MAX_BACK_PAGES: usize = 16;
/// Turn statuses that ended without the reply (Cloud's `Turn::failed`).
const FAILED: &[&str] = &["failed", "error", "cancelled", "outcome_unknown"];

/// What the command begins with.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(in crate::cli) enum Begin {
    /// `cmux chat [flags] PROMPT --wait`: the words after `agents chat new`.
    New(Vec<String>),
    /// `cmux chat send SESSION TEXT --wait`.
    Send { session: String, text: String },
    /// `cmux chat wait SESSION`: no prompt, the turn running now (or the last one).
    Wait { session: String },
}

/// What the command answers: the answer, or an error object and its exit code.
#[derive(Debug, PartialEq)]
pub(in crate::cli) enum Outcome {
    Done(Value),
    Failed { error: Value, exit: i32 },
}

/// What [`run_turn`] reads and does, so its steps run in tests without an app.
pub(in crate::cli) trait Port {
    /// Starts the chat or sends the prompt: the `chat.new` or `chat.send` receipt.
    fn begin(&mut self, begin: &Begin) -> Result<Value, Value>;
    /// The chat `target` names (its acpmux id) and its last event's seq.
    fn last_seq(&mut self, target: &str) -> Result<(String, u64), Value>;
    /// Waits at most `slice` for the chat to stop working: `agents wait`'s `match`, or None.
    fn wait_idle(&mut self, chat: &str, slice: Duration) -> Result<Option<Value>, Value>;
    /// The seq of the chat's newest prompt (0: none read).
    fn turn_start(&mut self, chat: &str) -> Result<u64, Value>;
    /// The chat's transcript items after `after`, each whole.
    fn read(&mut self, chat: &str, after: u64) -> Result<Vec<Value>, Value>;
    fn pause(&mut self, duration: Duration);
    fn now(&mut self) -> Instant;
}

/// The turn that ended last in `items` (a read from the turn's prompt on), when its prompt came
/// after event `baseline` (a send's: the turn before it, or one its prompt was still held for,
/// is not its turn): its end's seq and status, and its last answer.
#[derive(Debug, PartialEq, Eq)]
pub(in crate::cli) struct Ended {
    pub seq: u64,
    pub status: String,
    pub reply: Option<String>,
}

pub(in crate::cli) fn last_turn(items: &[Value], baseline: u64) -> Option<Ended> {
    fn role(item: &Value) -> &str {
        item.get("role").and_then(Value::as_str).unwrap_or_default()
    }
    let end = items.iter().rposition(|item| role(item) == "turn_end")?;
    let (before, rest) = items.split_at(end);
    let turn_end = rest.first()?;
    let seq = turn_end.get("id").and_then(Value::as_u64).unwrap_or(0);
    if seq <= baseline {
        return None;
    }
    // The turn's own items: after the prompt that started it (a steer is inside the turn).
    let prompt = before
        .iter()
        .rposition(|item| role(item) == "user" && item.get("steer") != Some(&json!(true)));
    // A send's turn has a message of the turn after the send: the prompt that started it, or the
    // send steered into a running turn.
    let newest_message = before.iter().rev().find(|item| role(item) == "user");
    let message_seq = newest_message.and_then(|item| item.get("id")).and_then(Value::as_u64);
    if baseline > 0 && message_seq.is_none_or(|message| message <= baseline) {
        return None;
    }
    let turn = before.get(prompt.map_or(0, |index| index.saturating_add(1))..).unwrap_or_default();
    let answer = turn.iter().rev().find(|item| role(item) == "assistant");
    Some(Ended {
        seq,
        status: turn_end.get("status").and_then(Value::as_str).unwrap_or("completed").to_owned(),
        reply: answer.and_then(|item| item.get("text")).and_then(Value::as_str).map(str::to_owned),
    })
}

/// The seq of the newest prompt (`user_message`) among `events`, any order. A steer is a message
/// inside a running turn, not the start of one.
pub(in crate::cli) fn newest_prompt(events: &[Value]) -> Option<u64> {
    events
        .iter()
        .filter(|event| event["dir"] == "mux" && event["kind"] == "user_message")
        .filter(|event| event.pointer("/msg/steer").and_then(Value::as_bool) != Some(true))
        .filter_map(|event| event["seq"].as_u64())
        .max()
}

/// The commands that go on with chat `session` here.
pub(in crate::cli) fn follow_ups(session: &str) -> Value {
    json!({
        "send": format!("cmux chat send {session} 'PROMPT' --wait"),
        "wait": format!("cmux chat wait {session}"),
        "read": format!("cmux chat read {session}"),
    })
}

fn failed(code: &str, message: impl Into<String>, details: Value, exit: i32) -> Outcome {
    Outcome::Failed {
        error: json!({"code": code, "message": message.into(), "details": details,
                      "retryable": false}),
        exit,
    }
}

fn text<'a>(value: &'a Value, pointer: &str) -> Option<&'a str> {
    value.pointer(pointer).and_then(Value::as_str)
}

/// The run: begin, then wait slice by slice until the turn ends or `timeout` passes.
pub(in crate::cli) fn run_turn(port: &mut dyn Port, begin: &Begin, timeout: Duration) -> Outcome {
    let deadline = port.now() + timeout;
    let (chat, mut answer, baseline) = match begin {
        Begin::New(_) => {
            let receipt = match port.begin(begin) {
                Ok(receipt) => receipt,
                Err(error) => return Outcome::Failed { error, exit: 1 },
            };
            let result = receipt.get("result").cloned().unwrap_or(Value::Null);
            let Some(chat) = text(&result, "/chat").map(str::to_owned) else {
                return failed(
                    "chat.create_failed",
                    "the chat started without a session id",
                    json!({"receipt": receipt}),
                    1,
                );
            };
            let mut answer = json!({
                "session_id": chat,
                "workspace_id": result.get("workspace").cloned().unwrap_or(Value::Null),
                "tab_id": result.get("tab").cloned().unwrap_or(Value::Null),
                "pane_id": result.get("pane").cloned().unwrap_or(Value::Null),
                "name": result.get("name").cloned().unwrap_or(Value::Null),
                "agent": result.get("harness").cloned().unwrap_or(Value::Null),
                "placement": "here",
                "opened": result.get("opened").cloned().unwrap_or(Value::Null),
                "follow_up": follow_ups(&chat),
            });
            match text(&result, "/prompt/state") {
                // No prompt: no turn to wait on, as Cloud's start without one.
                None => {
                    answer.set("sent", json!(false));
                    return Outcome::Done(answer);
                }
                Some("failed") => {
                    return failed(
                        "chat.send_failed",
                        "the chat started, but its first prompt was not accepted",
                        json!({"answer": answer, "prompt": result.get("prompt")}),
                        1,
                    );
                }
                Some(_) => {
                    answer.set("sent", json!(true));
                }
            }
            (chat, answer, Some(0))
        }
        Begin::Send { session, .. } => {
            // Before the send: the turn that answers it ends after this event.
            let (chat, baseline) = match port.last_seq(session) {
                Ok(found) => found,
                Err(error) => return Outcome::Failed { error, exit: 1 },
            };
            let receipt = match port.begin(begin) {
                Ok(receipt) => receipt,
                Err(error) => return Outcome::Failed { error, exit: 1 },
            };
            let mut answer = json!({
                "session_id": chat,
                "placement": "here",
                "message_id": receipt.pointer("/result/message_id").cloned().unwrap_or(Value::Null),
                "follow_up": follow_ups(&chat),
            });
            match text(&receipt, "/result/state") {
                Some("failed") => {
                    answer.set("sent", json!(false));
                    return failed(
                        "chat.send_failed",
                        "the prompt was stored but not handed to the chat",
                        json!({"answer": answer, "receipt": receipt}),
                        1,
                    );
                }
                // Held for an approval: no turn starts until someone lets it through.
                Some("held") => {
                    answer.set("sent", json!(false));
                    return failed(
                        "chat.permission_waiting",
                        format!(
                            "the prompt is held for approval: approve it in the cmux app, then: \
                             cmux chat wait {chat}"
                        ),
                        json!({"answer": answer, "receipt": receipt}),
                        2,
                    );
                }
                _ => {}
            }
            answer.set("sent", json!(true));
            (chat, answer, Some(baseline))
        }
        Begin::Wait { session } => {
            let chat = match port.last_seq(session) {
                Ok((chat, _)) => chat,
                Err(error) => return Outcome::Failed { error, exit: 1 },
            };
            let answer = json!({"session_id": chat, "placement": "here",
                                "follow_up": follow_ups(&chat)});
            (chat, answer, None)
        }
    };
    let timed_out = |mut answer: Value| {
        answer.set("timed_out", json!(true));
        failed(
            "chat.wait_timeout",
            format!(
                "the turn is still running after {}s; wait on with: cmux chat wait {chat}",
                timeout.as_secs()
            ),
            json!({"answer": answer}),
            3,
        )
    };
    loop {
        let left = deadline.saturating_duration_since(port.now());
        if left.is_zero() {
            return timed_out(answer);
        }
        let found = match port.wait_idle(&chat, left.min(SLICE)) {
            Ok(Some(found)) => found,
            Ok(None) => continue,
            Err(error) => {
                return failed(
                    "chat.lost",
                    "the chat does not answer",
                    json!({"answer": answer, "error": error}),
                    1,
                );
            }
        };
        let state = found.get("state").and_then(Value::as_str).unwrap_or("idle").to_owned();
        if state == "blocked" {
            return failed(
                "chat.permission_waiting",
                format!(
                    "the agent asks for a permission: answer it in the chat's tab in the cmux \
                     app, then: cmux chat wait {chat}"
                ),
                json!({"answer": answer}),
                2,
            );
        }
        let ended = match port.turn_start(&chat).and_then(|start| {
            // From the prompt's own item (`chat read` returns items after `after`).
            port.read(&chat, start.saturating_sub(1))
        }) {
            Ok(items) => last_turn(&items, baseline.unwrap_or(0)),
            Err(error) => {
                return failed(
                    "chat.read_failed",
                    format!(
                        "the turn ended, but its reply could not be read: cmux chat read {chat}"
                    ),
                    json!({"answer": answer, "error": error}),
                    1,
                );
            }
        };
        match ended {
            Some(ended) => {
                answer.set("turn", json!({"seq": ended.seq, "status": ended.status}));
                answer.set("reply", ended.reply.map_or(Value::Null, Value::String));
                if FAILED.contains(&ended.status.as_str()) {
                    return Outcome::Failed {
                        error: json!({"code": "chat.turn_failed",
                                      "message": format!("the turn ended {}", ended.status),
                                      "details": answer, "retryable": false}),
                        exit: 1,
                    };
                }
                return Outcome::Done(answer);
            }
            // `chat wait` on a chat that never ran a turn: nothing to wait for.
            None if baseline.is_none() => {
                answer.set("turn", Value::Null);
                answer.set("reply", Value::Null);
                return Outcome::Done(answer);
            }
            None if state != "idle" => {
                return failed(
                    "chat.lost",
                    format!("the chat is {state} and its turn did not end"),
                    json!({"answer": answer}),
                    1,
                );
            }
            // Idle, and the prompt's turn has not started yet (the daemon still hands it over).
            None => {
                let left = deadline.saturating_duration_since(port.now());
                port.pause(left.min(NOT_STARTED_PAUSE));
            }
        }
    }
}

/// Prints the outcome and answers the exit code, as Cloud's `--wait` does: the reply alone for a
/// person (the ids on stderr), the answer for `--json`.
pub(in crate::cli) fn report(outcome: &Outcome, output: OutputMode) -> i32 {
    match outcome {
        Outcome::Failed { error, exit } => {
            super::super::wire::print_local_error(error, output, *exit)
        }
        Outcome::Done(answer) if output == OutputMode::Human => {
            match answer.get("reply").and_then(Value::as_str) {
                Some(reply) => println!("{}", super::super::wire::sanitize_remote_text(reply)),
                None => println!(
                    "{} {}.",
                    if answer.get("sent") == Some(&json!(false)) { "Started" } else { "Done:" },
                    text(answer, "/session_id").unwrap_or_default()
                ),
            }
            eprintln!(
                "session_id {}  workspace_id {}  tab_id {}",
                text(answer, "/session_id").unwrap_or_default(),
                text(answer, "/workspace_id").unwrap_or_default(),
                text(answer, "/tab_id").unwrap_or_default()
            );
            0
        }
        Outcome::Done(answer) => super::super::wire::print_local_success(answer, output),
    }
}

/// The run against this machine's app and acpmux.
pub(in crate::cli) fn run(global: &GlobalArgs, begin: &Begin, timeout: Duration) -> i32 {
    let mut port = Live { global, backend: mcp::cli_backend(global.clone()) };
    report(&run_turn(&mut port, begin, timeout), global.output)
}

struct Live<'a, B> {
    global: &'a GlobalArgs,
    backend: B,
}

fn owner_error(failure: AgentFailure) -> Value {
    match failure {
        AgentFailure::Usage(message) => {
            json!({"code": "usage.invalid", "message": message, "details": {}, "retryable": false})
        }
        AgentFailure::Owner(failure) => mcp::agent_failure_value(failure),
    }
}

fn call_error(failure: CallFailure) -> Value {
    mcp::agent_failure_value(failure)
}

impl<B: Backend> Live<'_, B> {
    fn execute(&self, words: Vec<String>) -> Result<Value, Value> {
        let command =
            super::command(&words).map_err(|error| owner_error(AgentFailure::Usage(error.0)))?;
        super::execute(
            &self.backend,
            None,
            &command,
            self.global.idempotency_key.as_deref(),
            "agents",
        )
        .map_err(owner_error)
    }

    /// The chat `target` names (`acp:` and its id, its id, its name) and the acpmux it runs in.
    fn socket(&self, target: &str) -> Result<(String, Option<std::path::PathBuf>), Value> {
        let target = target.strip_prefix("acp:").unwrap_or(target);
        let found = chat::scoped_chat(self.global, target).map_err(call_error)?;
        Ok((found.id, found.app))
    }
}

impl<B: Backend> Port for Live<'_, B> {
    fn begin(&mut self, begin: &Begin) -> Result<Value, Value> {
        let mut words = vec!["chat".to_owned()];
        match begin {
            Begin::New(rest) => {
                words.push("new".to_owned());
                words.extend(rest.iter().cloned());
            }
            Begin::Send { session, text } => {
                words.extend(["send".to_owned(), session.clone(), "--".to_owned(), text.clone()]);
            }
            Begin::Wait { .. } => return Ok(Value::Null),
        }
        self.execute(words)
    }

    fn last_seq(&mut self, target: &str) -> Result<(String, u64), Value> {
        let (chat, socket) = self.socket(target)?;
        let page = chat::acp::events(&chat, 0, 1, socket.as_deref()).map_err(unavailable(&chat))?;
        Ok((chat, page.get("lastSeq").and_then(Value::as_u64).unwrap_or(0)))
    }

    fn wait_idle(&mut self, chat: &str, slice: Duration) -> Result<Option<Value>, Value> {
        let request = wait::WaitRequest {
            until: wait::Until::Idle,
            target: Some(chat.to_owned()),
            text: None,
            regex: false,
            timeout: slice,
        };
        let receipt =
            super::execute(&self.backend, None, &AgentCommand::Wait(request), None, "agents")
                .map_err(owner_error)?;
        let matched = receipt.get("matched").and_then(Value::as_bool) == Some(true);
        Ok(matched.then(|| receipt.get("match").cloned().unwrap_or(Value::Null)))
    }

    fn turn_start(&mut self, chat: &str) -> Result<u64, Value> {
        let (chat, socket) = self.socket(chat)?;
        newest_prompt_back(&chat, socket.as_deref())
    }

    fn read(&mut self, chat: &str, after: u64) -> Result<Vec<Value>, Value> {
        chat::turn_items(self.global, chat, after).map_err(call_error)
    }

    fn pause(&mut self, duration: Duration) {
        std::thread::sleep(duration);
    }

    fn now(&mut self) -> Instant {
        Instant::now()
    }
}

fn unavailable(chat: &str) -> impl Fn(String) -> Value + '_ {
    move |error| {
        json!({"code": "chat.unavailable", "message": format!("cannot read chat {chat}: {error}"),
               "details": {}, "retryable": true})
    }
}

/// The seq of chat `chat`'s newest prompt, read back from its last event a page at a time
/// (`beforeSeq`, newest first): the cost is the turn's length, not the chat's. 0 when the chat has
/// no prompt; the oldest seq read when [`MAX_BACK_PAGES`] pages hold none.
fn newest_prompt_back(chat: &str, socket: Option<&Path>) -> Result<u64, Value> {
    let mut before = u64::MAX;
    for _ in 0..MAX_BACK_PAGES {
        let page =
            chat::acp::events_before(chat, before, BACK_PAGE, socket).map_err(unavailable(chat))?;
        let events = page.get("events").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
        if let Some(seq) = newest_prompt(events) {
            return Ok(seq);
        }
        let oldest = events.iter().filter_map(|event| event["seq"].as_u64()).min();
        match oldest {
            Some(oldest) if page.get("hasMore").and_then(Value::as_bool) == Some(true) && oldest > 1 => before = oldest,
            _ => return Ok(0),
        }
    }
    Ok(before)
}

#[cfg(test)]
#[path = "turn_tests.rs"]
mod tests;
