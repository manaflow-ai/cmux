//! `cmux auth token [--team T] [--json]`: a short-lived cmux access token from
//! the cmux app's signed-in session, for the platform API and the hosted MCP
//! outside the app (cmux-platform#111, docs/cmux-next/auth-token.md).
//!
//! The app holds the session. `auth.token` mints a fresh install token for
//! one team (about ten minutes, never `execute`) and returns it; there is no
//! refresh token, so a script asks again. Text output is the bare token, so
//! `export CMUX_TOKEN=$(cmux auth token)` works; `--json` adds its team,
//! user, expiry and the API origin that issued it. Nothing here logs it.

use std::io::Write;
use std::time::Duration;

use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode, UsageError};

/// The app bounds the mint at 25 s; the CLI waits a little longer so the
/// app's own error reaches it.
const AUTH_TOKEN_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Invocation {
    Help,
    Token { team: Option<String> },
}

/// `cmux auth …`. `None` for any other command.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let rest = split(&command_args)?;
    Some(match parse(rest) {
        Ok(invocation) => run(&global, invocation),
        Err(error) => {
            super::app::failure("usage.invalid", &format!("cmux: {error}"), global.output, 2)
        }
    })
}

/// `Some(args after "auth")` when `args` (after the global options) start
/// with `auth`.
pub(super) fn split(command_args: &[String]) -> Option<&[String]> {
    let (first, rest) = command_args.split_first()?;
    (first == "auth").then_some(rest)
}

pub(super) fn parse(rest: &[String]) -> Result<Invocation, UsageError> {
    let app = &crate::localization::catalog().app_control;
    let messages = &crate::localization::catalog().auth_token;
    if rest.iter().take_while(|arg| *arg != "--").any(|arg| arg == "--help" || arg == "-h") {
        return Ok(Invocation::Help);
    }
    let tail = match rest.split_first() {
        None => return Ok(Invocation::Help),
        Some((verb, _)) if verb == "help" => return Ok(Invocation::Help),
        Some((verb, tail)) if verb == "token" => tail,
        Some((verb, _)) => {
            return Err(UsageError::new(messages.unknown_verb.replace("{verb}", verb)));
        }
    };
    let mut team = None;
    let mut args = tail.iter();
    while let Some(arg) = args.next() {
        let value = if let Some(value) = arg.strip_prefix("--team=") {
            value.to_owned()
        } else if arg == "--team" {
            args.next()
                .ok_or_else(|| UsageError::new(app.missing_value.replace("{flag}", arg)))?
                .clone()
        } else {
            return Err(UsageError::new(app.unexpected_argument.replace("{value}", arg)));
        };
        team = Some(value.trim().to_owned()).filter(|team| !team.is_empty());
    }
    Ok(Invocation::Token { team })
}

/// The app method's params.
pub(super) fn request(team: Option<&str>) -> Map<String, Value> {
    let mut params = Map::new();
    if let Some(team) = team {
        params.insert("team".into(), json!(team));
    }
    params
}

/// The exit code for an app refusal: 3 when the person must act in the app
/// (signed out, no team), 5 when the app is too old for `auth.token`.
pub(super) fn exit_code(error: &Value) -> i32 {
    match error.get("code").and_then(Value::as_str) {
        Some("not_signed_in" | "no_team") => 3,
        Some("method_not_found") => 5,
        _ => 1,
    }
}

/// The text form: the bare token and a newline, nothing else on stdout.
pub(super) fn token_line(value: &Value) -> Option<String> {
    let token = value.get("access_token").and_then(Value::as_str)?;
    (!token.is_empty() && !token.contains(char::is_whitespace)).then(|| format!("{token}\n"))
}

pub(super) fn run(global: &GlobalArgs, invocation: Invocation) -> i32 {
    let messages = &crate::localization::catalog().auth_token;
    let team = match invocation {
        Invocation::Help => {
            let mut stdout = std::io::stdout().lock();
            let _ = stdout.write_all(messages.usage.as_bytes());
            let _ = stdout.flush();
            return 0;
        }
        Invocation::Token { team } => team,
    };
    let mut stream = match super::app::connect_command(global) {
        Ok(stream) => stream,
        Err(error) => return super::wire::print_local_error(&error, global.output, 3),
    };
    let params = Value::Object(request(team.as_deref()));
    match super::app::request(&mut stream, "auth.token", params, AUTH_TOKEN_TIMEOUT) {
        Ok(Ok(value)) => match global.output {
            OutputMode::Quiet => 0,
            OutputMode::Json | OutputMode::JsonLines => {
                super::wire::print_local_success(&value, global.output)
            }
            OutputMode::Human => match token_line(&value) {
                Some(line) => {
                    let mut stdout = std::io::stdout().lock();
                    let _ = stdout.write_all(line.as_bytes());
                    let _ = stdout.flush();
                    0
                }
                None => {
                    super::app::failure("app.invalid_response", messages.no_token, global.output, 1)
                }
            },
        },
        Ok(Err(error)) => super::wire::print_local_error(&error, global.output, exit_code(&error)),
        Err(message) => super::app::failure("app.transport", &message, global.output, 3),
    }
}

#[cfg(test)]
mod tests;
