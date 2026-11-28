//! `cmux chat --prompt TEXT --wait`, `cmux chat send SESSION TEXT --wait` and `cmux chat wait
//! SESSION` for a chat on this machine: start the chat (or send the prompt), wait until its turn
//! ends and print the reply, in one command, with the answer `cmux chat --on vm:… --wait` gives
//! (`session_id`, `workspace_id`, `tab_id`, `reply`). Before, a chat here took three commands
//! (`agents chat new`, `agents wait --until idle`, `agents chat read`) with three answer shapes,
//! and `agents wait` stopped at 120 s.
//!
//! Nothing here waits its own way: each slice is acpmux's own `_acpmux/wait` on the chat (as
//! `acpmux wait` does: the daemon answers on the chat's events), at most [`SLICE`] long, until
//! `--timeout`. When the chat is idle, the reply is the last answer of its newest turn: the turn
//! starts at the chat's newest prompt, found by reading its events back from the end, so the read
//! costs the turn's length and never the chat's whole history.
//!
//! The chat is found and scope-checked once ([`chat::scoped_chat`]) and every later step reaches
//! its acpmux directly. Before, each slice was `agents wait --until idle`, which woke on the cmux
//! daemon's events (none of which is the chat's turn end) or its 1 s recheck and then read the
//! daemon's snapshot and the app's twice, and the reply's read found the chat twice more (an
//! acpmux lookup and a daemon snapshot each): about 200 to 330 ms from the turn's end to the
//! command's exit on a Mac (goal local-instant-start).
//!
//! Exit codes match the Cloud route (cloud_start_chat.rs): 0 the reply, 1 refused or the turn
//! failed or the chat went away, 2 the agent waits on a permission, 3 `--timeout` passed
//! (`chat.wait_timeout`, its answer `timed_out: true`).

use std::path::Path;
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

use super::super::mcp::{self, Backend, CallFailure};
use super::super::{GlobalArgs, OutputMode};
use super::{AgentFailure, chat, wait};
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
    /// The chat's harness id (`_acpmux/info`'s `harness`), when it can be read.
    fn harness(&mut self, chat: &str) -> Option<String>;
    fn pause(&mut self, duration: Duration);
    fn now(&mut self) -> Instant;
}

/// The turn that ended last in `items` (a read from the turn's prompt on), when its prompt came
/// after event `baseline` (a send's: the turn before it, or one its prompt was still held for,
/// is not its turn): its end's seq and status, its last answer, and why it failed.
#[derive(Debug, PartialEq, Eq)]
pub(in crate::cli) struct Ended {
    pub seq: u64,
    pub status: String,
    pub reply: Option<String>,
    /// What its end says of why it failed (`chat::turn_failure`): `error`, `code`, `error_kind`,
    /// `recovery`, `detail`, ...; empty when it said nothing.
    pub failure: Map<String, Value>,
}

/// The keys of a `turn_end` item that say why its turn failed (`chat::turn_failure`).
const FAILURE_KEYS: &[&str] = &[
    "error",
    "error_code",
    "code",
    "error_kind",
    "error_source",
    "recovery",
    "detail",
    "stalled_ms",
];

/// The `chat.turn_failed` message for `ended`: its status and the reason its end carries, or,
/// when it carries none, says so and where to look, never a bare "the turn ended failed".
pub(in crate::cli) fn failed_turn_message(ended: &Ended, chat: &str) -> String {
    let status = ended.status.as_str();
    let field = |key: &str| {
        ended.failure.get(key).and_then(Value::as_str).map(str::trim).filter(|v| !v.is_empty())
    };
    let mut message = match field("error") {
        Some(error) => format!("the turn ended {status}: {error}"),
        None if field("detail") == Some("stalled") || ended.failure.contains_key("stalled_ms") => {
            match ended.failure.get("stalled_ms").and_then(Value::as_u64) {
                Some(ms) => format!(
                    "the turn ended {status}: the agent stalled, with no output for {} s",
                    ms / 1000
                ),
                None => format!("the turn ended {status}: the agent stalled"),
            }
        }
        None if status == "cancelled" => "the turn ended cancelled".to_owned(),
        None => {
            let code = ended
                .failure
                .get("code")
                .or_else(|| ended.failure.get("error_code"))
                .filter(|code| !code.is_null())
                .map(|code| match code {
                    Value::String(code) => format!(" (code {code})"),
                    other => format!(" (code {other})"),
                })
                .unwrap_or_default();
            format!(
                "the turn ended {status}{code} and acpmux recorded no reason; \
                 cmux chat read {chat} shows what it did"
            )
        }
    };
    if let Some(recovery) = field("recovery")
        && !message.contains(recovery)
    {
        message.push_str(if message.ends_with(['.', '!', '?']) { " " } else { ". " });
        message.push_str(recovery);
    }
    message
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
    let failure = FAILURE_KEYS
        .iter()
        .filter_map(|key| {
            turn_end
                .get(*key)
                .filter(|value| !value.is_null())
                .map(|v| ((*key).to_owned(), v.clone()))
        })
        .collect();
    Some(Ended {
        seq,
        status: turn_end.get("status").and_then(Value::as_str).unwrap_or("completed").to_owned(),
        reply: answer.and_then(|item| item.get("text")).and_then(Value::as_str).map(str::to_owned),
        failure,
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
                // Queued behind a failed turn: the queue is paused, so no turn answers it
                // until someone resumes the chat; waiting would only run out the clock.
                Some("queued") if text(&receipt, "/result/waits_for") == Some("resume") => {
                    answer.set("sent", json!(false));
                    answer.set("queued", json!(true));
                    let reason = text(&receipt, "/result/reason")
                        .unwrap_or("the chat's queue is paused after a failed turn");
                    return failed(
                        "chat.queue_paused",
                        format!("{reason}; then: cmux chat wait {chat}"),
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
                let mut turn = json!({"seq": ended.seq, "status": ended.status});
                for (key, value) in &ended.failure {
                    turn.set(key, value.clone());
                }
                answer.set("turn", turn);
                let failed = FAILED
                    .contains(&ended.status.as_str())
                    .then(|| failed_turn_message(&ended, &chat));
                answer.set("reply", ended.reply.map_or(Value::Null, Value::String));
                if let Some(message) = failed {
                    let mut error = json!({"code": "chat.turn_failed", "message": message,
                                           "details": answer, "retryable": false});
                    // An account out of usage or turned off says so, and the ways on (cmux#55066).
                    // A send or a wait names no agent in its answer: the chat's own harness.
                    if let Some(said) = ended.failure.get("error").and_then(Value::as_str) {
                        let harness = match error["details"].get("agent").and_then(Value::as_str) {
                            Some(agent) => agent.to_owned(),
                            None => port.harness(&chat).unwrap_or_default(),
                        };
                        crate::cli::account_limit::explain(&mut error, said, &harness);
                    }
                    return Outcome::Failed { error, exit: 1 };
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
    let mut port = Live { global, backend: mcp::cli_backend(global.clone()), found: None };
    report(&run_turn(&mut port, begin, timeout), global.output)
}

struct Live<'a, B> {
    global: &'a GlobalArgs,
    backend: B,
    /// The chat found the first time, with the target that named it: the steps after reach it
    /// with no second lookup.
    found: Option<(String, chat::Chat)>,
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

    /// The chat `target` names (`acp:` and its id, its id, its name) and the acpmux it runs in:
    /// found and scope-checked once, then remembered. A chat this command started is known
    /// from its start ([`chat::started`]) and is not looked up at all.
    fn socket(&mut self, target: &str) -> Result<(String, Option<std::path::PathBuf>), Value> {
        let target = target.strip_prefix("acp:").unwrap_or(target);
        if let Some((named, found)) = &self.found
            && (named == target || found.id == target)
        {
            return Ok((found.id.clone(), found.app.clone()));
        }
        let found = match chat::started(target) {
            Some(found) => found,
            None => chat::scoped_chat(self.global, target).map_err(call_error)?,
        };
        let answer = (found.id.clone(), found.app.clone());
        self.found = Some((target.to_owned(), found));
        Ok(answer)
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
        let (chat, socket) = self.socket(chat)?;
        let answer =
            chat::acp::wait_turn(&chat, slice, socket.as_deref()).map_err(unavailable(&chat))?;
        Ok(waited(&chat, &answer))
    }

    fn turn_start(&mut self, chat: &str) -> Result<u64, Value> {
        let (chat, socket) = self.socket(chat)?;
        newest_prompt_back(&chat, socket.as_deref())
    }

    fn read(&mut self, chat: &str, after: u64) -> Result<Vec<Value>, Value> {
        let (id, app) = self.socket(chat)?;
        chat::turn_items_of(&chat::Chat { id, app }, after).map_err(call_error)
    }

    fn harness(&mut self, chat: &str) -> Option<String> {
        let (chat, socket) = self.socket(chat).ok()?;
        let (_, info) = chat::acp::lookup(&chat, socket.as_deref()).ok()?;
        info.get("harness").and_then(Value::as_str).map(str::to_owned)
    }

    fn pause(&mut self, duration: Duration) {
        std::thread::sleep(duration);
    }

    fn now(&mut self) -> Instant {
        Instant::now()
    }
}

/// What one `_acpmux/wait` slice answered, as [`run_turn`] reads a wait's match: `None` when it
/// timed out, else the chat's `state` (`blocked` on a permission or question, `closed`,
/// `disconnected` or `failed` when its agent is gone, else `idle`).
pub(in crate::cli) fn waited(chat: &str, answer: &Value) -> Option<Value> {
    if answer.get("timedOut").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    let row = answer
        .pointer("/resolved/0")
        .or_else(|| answer.pointer("/sessions/0"))
        .unwrap_or(&Value::Null);
    let status = row.get("status").and_then(Value::as_str).unwrap_or("closed");
    let pending = row.get("pendingPermissions").and_then(Value::as_u64).unwrap_or(0) > 0;
    let state = match status {
        _ if pending => "blocked",
        // Not an answer a resolved wait gives: wait again.
        "running" | "starting" | "pending" => return None,
        "waiting" | "waiting-for-input" => "blocked",
        "closed" | "disconnected" | "failed" => status,
        _ if row.get("missing") == Some(&Value::Bool(true)) => "closed",
        _ => "idle",
    };
    Some(json!({"target": chat, "chat": chat, "state": state}))
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
        let events =
            page.get("events").and_then(Value::as_array).map(Vec::as_slice).unwrap_or_default();
        if let Some(seq) = newest_prompt(events) {
            return Ok(seq);
        }
        let oldest = events.iter().filter_map(|event| event["seq"].as_u64()).min();
        match oldest {
            Some(oldest)
                if page.get("hasMore").and_then(Value::as_bool) == Some(true) && oldest > 1 =>
            {
                before = oldest;
            }
            _ => return Ok(0),
        }
    }
    Ok(before)
}

#[cfg(test)]
#[path = "turn_tests.rs"]
mod tests;
