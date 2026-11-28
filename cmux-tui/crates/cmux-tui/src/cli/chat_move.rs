//! `cmux chat move SESSION --on local|cloud|auto`: move a chat between Local, Cloud and AutoCloud
//! at any point (Leo, 2026-11-25: "cli stuff/agents being able to toggle to and from and whatever
//! autocloud and such").
//!
//! It runs `acpmux session place SESSION --on PLACE --json` (acpmux `chat_place.rs`), which makes
//! the move one Auto `set`: the store's fenced handoff. From the person's terminal any move goes;
//! from an agent's shell only its own chat, off the Mac, while AutoCloud is on, and the answer
//! says `needs_person` with this command otherwise. An agent in a chat has the same move as its
//! `move_chat` tool.

use std::time::Duration;

use cmux_process::Command;

use super::{UsageError, chat_start::joined, cloud_start_chat, wire};

pub(super) const USAGE: &str = "\
usage: cmux chat move SESSION --on local|cloud|auto [--reason TEXT] [--json]

Moves the chat SESSION to where it should run:

  local   this Mac (Auto off); the Cloud's changes come back into the folder
  cloud   cmux Cloud, staying there when the Mac comes back
  auto    AutoCloud: here while the Mac is up, in the Cloud while it sleeps

From an agent's shell only its own chat moves, off the Mac, while the AutoCloud setting is on;
otherwise the answer is needs_person and the person runs this command.

  cmux chat move s-1 --on cloud
  cmux chat move s-1 --on local --json
";

const TAKES_VALUE: &[&str] = &["--on", "--reason"];

/// The handoff copies the chat and its folder: bounded, not instant.
const MOVE_DEADLINE: Duration = Duration::from_secs(10 * 60);

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Parsed {
    Help,
    Run { session: String, on: String, reason: Option<String> },
}

pub(super) fn parse(words: &[String]) -> Result<Parsed, UsageError> {
    let (mut session, mut on, mut reason) = (None, None, None);
    let mut it = words.iter();
    while let Some(word) = it.next() {
        match word.as_str() {
            "--help" | "-h" | "help" => return Ok(Parsed::Help),
            "--on" | "--to" => on = it.next().cloned(),
            "--reason" => reason = it.next().cloned(),
            w if w.starts_with("--on=") => on = Some(w["--on=".len()..].to_owned()),
            w if w.starts_with('-') => return Err(UsageError(format!("unknown flag {w}"))),
            w if session.is_none() => session = Some(w.to_owned()),
            w => return Err(UsageError(format!("one SESSION only (got {w:?} too)"))),
        }
    }
    let session = session.ok_or_else(|| UsageError("SESSION is required".to_owned()))?;
    let on = on.ok_or_else(|| UsageError("--on local|cloud|auto is required".to_owned()))?;
    if !matches!(
        on.to_ascii_lowercase().as_str(),
        "local"
            | "here"
            | "mac"
            | "laptop"
            | "cloud"
            | "auto"
            | "autocloud"
            | "auto-cloud"
            | "auto_cloud"
    ) {
        return Err(UsageError(format!("--on must be local, cloud or auto (got {on:?})")));
    }
    Ok(Parsed::Run { session, on, reason })
}

pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, command) = super::parse_globals(args).ok()?;
    let [scope, verb, rest @ ..] = command.as_slice() else { return None };
    if scope != "chat" || verb != "move" {
        return None;
    }
    let words = cloud_start_chat::lift_output_of(rest, &mut global.output, TAKES_VALUE);
    let (session, on, reason) = match parse(&words) {
        Ok(Parsed::Help) => {
            print!("{USAGE}");
            return Some(0);
        }
        Ok(Parsed::Run { session, on, reason }) => (session, on, reason),
        Err(error) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {}\n{USAGE}", error.0),
                global.output,
                2,
            ));
        }
    };
    let mut words = vec!["session".to_owned(), "place".to_owned(), session, "--on".to_owned(), on];
    if let Some(reason) = reason {
        words.extend(["--reason".to_owned(), reason]);
    }
    words.push("--json".to_owned());
    let refs: Vec<&str> = words.iter().map(String::as_str).collect();
    let executable = match std::env::current_exe() {
        Ok(executable) => executable,
        Err(error) => {
            return Some(wire::print_local_error(
                &serde_json::json!({"code":"acpmux.unreachable","message":format!("cannot find cmux: {error}"),"details":{},"retryable":true}),
                global.output,
                3,
            ));
        }
    };
    let mut command = Command::new(executable);
    command.arg0("cmux");
    let command = joined::acp_command(command, &refs);
    match joined::run_acp(command, &refs, None, MOVE_DEADLINE) {
        Ok(value) => Some(wire::print_local_success(&value, global.output)),
        Err(error) => Some(wire::print_local_error(&error, global.output, 1)),
    }
}

#[cfg(test)]
#[path = "chat_move_tests.rs"]
mod tests;
