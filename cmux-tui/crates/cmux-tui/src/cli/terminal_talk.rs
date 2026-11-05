//! Talking to agents that run in terminals (Claude Code, Codex, … in a cmux
//! terminal), for the Chief and scripts:
//!
//! - `cmux terminal list --agents`: the terminals that run an agent, with
//!   harness, state (busy, idle, waiting-for-input, ended), age, workspace
//!   and title (roster.rs).
//! - `cmux terminal <t> send --text <msg> [--wait idle|prompt|none]
//!   [--timeout 5m] [--settle 3s] [--force]`: type the message, press
//!   Enter, wait, and print only what the terminal printed after the
//!   message (send.rs, reply.rs).
//!
//! The MCP tools `agents_terminal_list` and `agents_terminal_send`
//! (mcp/terminal_talk_tools.rs) run the same code.

pub(in crate::cli) mod reply;
pub(in crate::cli) mod roster;
pub(in crate::cli) mod send;
#[cfg(test)]
mod tests;

use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::Value;

use super::{GlobalArgs, OutputMode, UsageError, wire};
use send::{SendRequest, Wait};

/// The exit code of a send whose wait timed out, as timeout(1) has it.
const TIMEOUT_EXIT: i32 = 124;

pub(in crate::cli) fn now_ms() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_or(0, |elapsed| u64::try_from(elapsed.as_millis()).unwrap_or(u64::MAX))
}

/// `Some(exit code)` for `terminal list --agents` and `terminal <t> send`;
/// `None` for any other terminal command (`words` follow `terminal`).
pub(in crate::cli) fn run(global: &GlobalArgs, words: &[String]) -> Option<i32> {
    match words {
        [verb, flags @ ..] if verb == "list" && flags.iter().any(|flag| flag == "--agents") => {
            Some(match parse_list(flags) {
                Ok(()) => list(global),
                Err(error) => usage(global, &error),
            })
        }
        [target, verb, flags @ ..] if verb == "send" => Some(match parse_send(target, flags) {
            Ok(mut request) => {
                request.idempotency_key = global.idempotency_key.clone();
                send_command(global, &request)
            }
            Err(error) => usage(global, &error),
        }),
        _ => None,
    }
}

fn usage(global: &GlobalArgs, error: &UsageError) -> i32 {
    super::app::failure("usage.invalid", &format!("cmux: {}", error.0), global.output, 2)
}

pub(in crate::cli) fn parse_list(flags: &[String]) -> Result<(), UsageError> {
    match flags.iter().find(|flag| flag.as_str() != "--agents") {
        Some(other) => {
            Err(UsageError(format!("terminal list --agents takes no other option, not {other}")))
        }
        None => Ok(()),
    }
}

/// `--name value` or `--name=value` pairs, and bare switches.
pub(in crate::cli) fn parse_send(
    target: &str,
    flags: &[String],
) -> Result<SendRequest, UsageError> {
    if target.starts_with('-') {
        return Err(UsageError("terminal send needs a terminal before send".into()));
    }
    let mut request = SendRequest::new(target.to_owned(), String::new());
    let mut text = None;
    let mut words = flags.iter();
    while let Some(word) = words.next() {
        let (name, inline) = match word.split_once('=') {
            Some((name, value)) if name.starts_with("--") => (name, Some(value.to_owned())),
            _ => (word.as_str(), None),
        };
        if name == "--force" {
            request.force = true;
            continue;
        }
        let value = match inline {
            Some(value) => value,
            None => {
                words.next().cloned().ok_or_else(|| UsageError(format!("{name} needs a value")))?
            }
        };
        let duration = |value: &str| super::status::duration(value);
        match name {
            "--text" => text = Some(value),
            "--wait" => {
                request.wait = Wait::parse(&value).ok_or_else(|| {
                    UsageError(format!("--wait takes idle, prompt or none, not {value:?}"))
                })?;
            }
            "--timeout" => request.timeout = duration(&value)?,
            "--settle" => request.settle = duration(&value)?,
            other => {
                return Err(UsageError(format!(
                    "terminal send takes --text, --wait, --timeout, --settle and --force, not \
                     {other}"
                )));
            }
        }
    }
    request.text = match text.as_deref() {
        Some("-") => {
            let mut stdin = String::new();
            std::io::Read::read_to_string(&mut std::io::stdin(), &mut stdin)
                .map_err(|error| UsageError(format!("cannot read the message: {error}")))?;
            stdin
        }
        Some(text) => text.to_owned(),
        None => {
            return Err(UsageError("terminal send needs --text <message> (- reads stdin)".into()));
        }
    };
    if request.text.trim().is_empty() {
        return Err(UsageError("terminal send needs a message that is not blank".into()));
    }
    Ok(request)
}

fn print_json(value: &Value) {
    println!("{}", serde_json::to_string(value).unwrap_or_default());
}

fn fail(global: &GlobalArgs, failure: &super::mcp::CallFailure, exit: i32) -> i32 {
    wire::print_local_error(&failure.error, global.output, exit)
}

fn list(global: &GlobalArgs) -> i32 {
    let backend = super::mcp::cli_backend(global.clone());
    let snapshot = match send::snapshot(&backend, None) {
        Ok(snapshot) => snapshot,
        Err(failure) => return fail(global, &failure, 1),
    };
    let rows = roster::agent_rows(&snapshot);
    let now = now_ms();
    match global.output {
        OutputMode::Human => println!("{}", roster::table(&rows, now)),
        OutputMode::Quiet => {}
        OutputMode::Json => {
            print_json(&Value::Array(rows.iter().map(|row| row.to_json(now)).collect()));
        }
        OutputMode::JsonLines => rows.iter().for_each(|row| print_json(&row.to_json(now))),
    }
    0
}

fn send_command(global: &GlobalArgs, request: &SendRequest) -> i32 {
    let backend = super::mcp::cli_backend(global.clone());
    let receipt = match send::run(&backend, None, request) {
        Ok(receipt) => receipt,
        Err(failure) => return fail(global, &failure.failure, failure.exit),
    };
    let timed_out = receipt["timed_out"] == true;
    match global.output {
        OutputMode::Human => {
            let output = receipt["output"].as_str().unwrap_or_default();
            if !output.is_empty() {
                println!("{output}");
            }
            if timed_out {
                eprintln!(
                    "cmux: the terminal was still busy after {}; the output so far is above",
                    humantime(request.timeout)
                );
            } else if receipt["state"] == "waiting-for-input" {
                eprintln!("cmux: the agent now waits on a dialog (agents_dialog_list shows it)");
            }
        }
        OutputMode::Quiet => {}
        OutputMode::Json | OutputMode::JsonLines => print_json(&receipt),
    }
    if timed_out { TIMEOUT_EXIT } else { 0 }
}

fn humantime(duration: Duration) -> String {
    roster::age(u64::try_from(duration.as_millis()).unwrap_or(u64::MAX))
}
