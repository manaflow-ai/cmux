//! Talking to agents that run in terminals (Claude Code, Codex, … in a cmux
//! terminal), for the Chief and scripts:
//!
//! - `cmux terminal list --agents`: the terminals that run an agent, with
//!   harness, status (blocked, done, working, idle, unknown; `state` keeps
//!   the older busy, idle, waiting-for-input, ended), age, workspace and
//!   title (roster.rs).
//! - `cmux terminal <t> send --text <msg> [--wait idle|prompt|none]
//!   [--timeout 5m] [--settle 3s] [--force]`: type the message, press
//!   Enter, wait, and print only what the terminal printed after the
//!   message (send.rs, reply.rs). `--pattern <regex>` also ends the wait
//!   when output after the message's echo matches; `--exit-with-status`
//!   exits with the typed command's status (OSC 133 `D`).
//! - `cmux terminal <t> run [OPTIONS] -- <command...>`: `send --wait prompt
//!   --exit-with-status`: type a command into the terminal's shell, wait
//!   for it to finish, print its output and exit with its status.
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
/// The exit code of `--exit-with-status` when the shell reported no status
/// (no OSC 133 shell integration): unknown, so neither success nor the
/// command's own failure.
const UNKNOWN_STATUS_EXIT: i32 = 125;
/// The exit code of a `--pattern` wait that ended without a match, as
/// `screen wait` has it.
const NO_MATCH_EXIT: i32 = 1;

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
        [target, verb, flags @ ..] if verb == "run" => Some(match parse_run(target, flags) {
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
        if name == "--exit-with-status" {
            request.exit_with_status = true;
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
            "--pattern" if !value.is_empty() => request.pattern = Some(value),
            other => {
                return Err(UsageError(format!(
                    "terminal send takes --text, --wait, --pattern, --timeout, --settle, --force \
                     and --exit-with-status, not {other}"
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

/// `terminal <t> run [OPTIONS] -- <command...>` (or `--text <command>`):
/// a send that waits for the prompt and exits with the command's status.
/// One word after `--` is a shell line as it is (`run -- 'make && ./a'`);
/// two or more are an argv, each word shell-quoted, so `run -- sh -c 'exit
/// 7'` runs `sh` with the two arguments `-c` and `exit 7`.
pub(in crate::cli) fn parse_run(target: &str, flags: &[String]) -> Result<SendRequest, UsageError> {
    let split = flags.iter().position(|word| word == "--").unwrap_or(flags.len());
    let (options, argv) = flags.split_at(split);
    let command = argv.split_first().map(|(_, command)| shell_line(command));
    let mut options = options.to_vec();
    if options.iter().any(|word| word == "--wait" || word.starts_with("--wait=")) {
        return Err(UsageError("terminal run waits for the prompt; it takes no --wait".into()));
    }
    if let Some(command) = command {
        if options.iter().any(|word| word == "--text" || word.starts_with("--text=")) {
            return Err(UsageError(
                "terminal run takes the command after -- or --text, not both".into(),
            ));
        }
        options.extend(["--text".to_owned(), command]);
    }
    let mut request = parse_send(target, &options).map_err(|error| {
        UsageError(error.0.replace("terminal send", "terminal run").replace(
            "--text <message> (- reads stdin)",
            "a command after -- (or --text <command>)",
        ))
    })?;
    request.wait = Wait::Prompt;
    request.exit_with_status = true;
    Ok(request)
}

/// The shell line `terminal run` types for the words after `--`: one word
/// as it is, more words each POSIX-quoted (sh, bash and zsh read them back
/// as the same words). The command word is also quoted when the shell would
/// read it as syntax: a reserved word (`if`, `{`, `!`) or an assignment
/// (`FOO=bar`). cmd.exe and PowerShell quote differently; the help tells
/// their users to pass one word.
fn shell_line(argv: &[String]) -> String {
    let [first, rest @ ..] = argv else { return String::new() };
    if rest.is_empty() {
        return first.clone();
    }
    let command =
        if first.contains('=') || SHELL_RESERVED.split_whitespace().any(|word| word == first) {
            format!("'{}'", first.replace('\'', "'\\''"))
        } else {
            super::cloud_start_chat::shell_quote(first)
        };
    std::iter::once(command)
        .chain(rest.iter().map(|word| super::cloud_start_chat::shell_quote(word)))
        .collect::<Vec<_>>()
        .join(" ")
}

/// The words sh, bash and zsh read as syntax in command position.
const SHELL_RESERVED: &str = "! { } [[ ]] case coproc do done elif else esac fi for foreach \
                              function if in nocorrect repeat select then time until while";

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
    let status = receipt.get("exit_status").and_then(Value::as_i64);
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
                eprintln!("cmux: the agent now waits on a dialog (terminal screen read shows it)");
            } else if receipt.get("matched") == Some(&Value::Bool(false)) {
                eprintln!("cmux: the command finished without output that matches --pattern");
            } else if request.exit_with_status && status.is_none() {
                eprintln!(
                    "cmux: the shell reported no exit status (it has no OSC 133 shell \
                     integration); exiting {UNKNOWN_STATUS_EXIT}"
                );
            }
        }
        OutputMode::Quiet => {}
        OutputMode::Json | OutputMode::JsonLines => print_json(&receipt),
    }
    send_exit_code(&receipt, request.exit_with_status)
}

/// The CLI's exit code for a send receipt: 124 on a timeout, 1 for a
/// `--pattern` that did not match, then with `exit_with_status` the
/// command's own status (125 when the shell reported none), else 0.
pub(in crate::cli) fn send_exit_code(receipt: &Value, exit_with_status: bool) -> i32 {
    if receipt.get("timed_out") == Some(&Value::Bool(true)) {
        return TIMEOUT_EXIT;
    }
    if receipt.get("matched") == Some(&Value::Bool(false)) {
        return NO_MATCH_EXIT;
    }
    if !exit_with_status {
        return 0;
    }
    match receipt.get("exit_status").and_then(Value::as_i64) {
        // A shell reports the status as $? (0..=255); a signal is 128 + N.
        Some(code) => i32::try_from(code.rem_euclid(256)).unwrap_or(1),
        None => UNKNOWN_STATUS_EXIT,
    }
}

fn humantime(duration: Duration) -> String {
    roster::age(u64::try_from(duration.as_millis()).unwrap_or(u64::MAX))
}
