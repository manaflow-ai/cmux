//! `cmux auth handoff mint|redeem`: sign the cmux app on another Mac of yours in to the same
//! account, with no typing there (`cmux device setup DEVICE` runs both halves).
//!
//! - `cmux auth handoff mint [--device NAME] --json` asks this Mac's signed-in app
//!   (`auth.handoff.mint`) for a one-time code: `{"code","expiresAt","user","email","device"}`.
//!   The app mints it with its own human session (cmux-api `POST /v1/auth/handoffs`); it lives at
//!   most two minutes and is spent once. Without `--json` stdout is the bare code and a newline.
//! - `cmux auth handoff redeem [--device NAME] [--json]` on the other Mac reads the code from stdin
//!   (one line; never an argument, never the environment) and hands it to that Mac's running app
//!   (`auth.handoff.redeem`), which redeems it for a new session of the same user and signs in.
//!   The tokens stay in the app. Prints `{"signedIn","alreadySignedIn","user":{"id","email"},
//!   "device":{"name"}}`.
//!
//! Exit codes: 0 signed in (or minted); 2 bad usage or bad stdin (a terminal, empty, not a code, or
//! a code given as an argument); 3 the code was spent, expired or wrong, or minting was refused
//! (signed out, SSO, rate limit); 4 the app or cmux could not be reached; 5 the app is signed in
//! as another account (the code is not spent).
//!
//! Nothing here logs, echoes or stores a code: an argument that looks like one is refused without
//! printing it.

use std::io::{IsTerminal, Read, Write};
use std::time::Duration;

use cmux_tui_core::retry::{Attempt, Patience};
use serde_json::{Map, Value, json};

use super::{GlobalArgs, OutputMode};

/// The app bounds its cmux-api call at 25 s; the CLI waits a little longer for its own answer.
const HANDOFF_TIMEOUT: Duration = Duration::from_secs(30);
/// How long a mint that cmux-api could not reach is asked again.
const UNAVAILABLE_PATIENCE: Duration = Duration::from_secs(20);
/// A code is ~73 bytes; anything past this on stdin is not a code.
const MAX_STDIN: u64 = 4096;
/// Longest device name, as cmux-api takes it.
const MAX_DEVICE: usize = 64;

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Invocation {
    Help,
    Mint { device: Option<String> },
    Redeem { device: Option<String> },
}

/// A usage error and its exit code (always 2); `message` never contains a code.
#[derive(Debug, PartialEq, Eq)]
pub(super) struct Usage(pub String);

/// Whether `value` has the shape of a hand-off code (`cmh_team_<20>.<43 base64url>`).
pub(super) fn is_code(value: &str) -> bool {
    let Some(rest) = value.strip_prefix("cmh_team_") else { return false };
    let Some((team, secret)) = rest.split_once('.') else { return false };
    team.len() == 20
        && team.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        && secret.len() == 43
        && secret.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

fn device_value(value: &str) -> Result<Option<String>, Usage> {
    let messages = &crate::localization::catalog().auth_handoff;
    let trimmed = value.trim();
    // A code typed as the device name is a code in argv: refused, never sent on as a label.
    if trimmed.starts_with("cmh_") {
        return Err(Usage(messages.code_in_argv.to_owned()));
    }
    if trimmed.chars().count() > MAX_DEVICE || trimmed.chars().any(char::is_control) {
        return Err(Usage(messages.bad_device.to_owned()));
    }
    Ok((!trimmed.is_empty()).then(|| trimmed.to_owned()))
}

/// `args` after `cmux auth handoff`.
pub(super) fn parse(args: &[String]) -> Result<Invocation, Usage> {
    let messages = &crate::localization::catalog().auth_handoff;
    let app = &crate::localization::catalog().app_control;
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        return Ok(Invocation::Help);
    }
    let (verb, tail) = match args.split_first() {
        None => return Ok(Invocation::Help),
        Some((verb, _)) if verb == "help" => return Ok(Invocation::Help),
        Some((verb, tail)) if verb == "mint" || verb == "redeem" => (verb.as_str(), tail),
        Some((verb, _)) => {
            // Never echo something that may be a code typed in the wrong place.
            let shown = if verb.starts_with("cmh_") { "…" } else { verb.as_str() };
            return Err(Usage(messages.unknown_verb.replace("{verb}", shown)));
        }
    };
    let mut device = None;
    let mut rest = tail.iter();
    while let Some(arg) = rest.next() {
        if let Some(value) = arg.strip_prefix("--device=") {
            device = device_value(value)?;
        } else if arg == "--device" {
            let value =
                rest.next().ok_or_else(|| Usage(app.missing_value.replace("{flag}", arg)))?;
            device = device_value(value)?;
        } else if arg.starts_with("cmh_") || arg == "--code" || arg.starts_with("--code=") {
            // The code is read from stdin only: an argument is visible to every process (`ps`).
            return Err(Usage(messages.code_in_argv.to_owned()));
        } else {
            return Err(Usage(app.unexpected_argument.replace("{value}", arg)));
        }
    }
    Ok(match verb {
        "mint" => Invocation::Mint { device },
        _ => Invocation::Redeem { device },
    })
}

/// The code on `input`: one line, at most [`MAX_STDIN`] bytes, trimmed, of the code's shape.
/// The error message never contains what was read.
pub(super) fn read_code(input: impl Read) -> Result<zeroize::Zeroizing<String>, Usage> {
    let messages = &crate::localization::catalog().auth_handoff;
    let mut raw = zeroize::Zeroizing::new(Vec::new());
    input
        .take(MAX_STDIN + 1)
        .read_to_end(&mut raw)
        .map_err(|_| Usage(messages.stdin_unreadable.to_owned()))?;
    if raw.len() as u64 > MAX_STDIN {
        return Err(Usage(messages.stdin_not_code.to_owned()));
    }
    let text = std::str::from_utf8(&raw).map_err(|_| Usage(messages.stdin_not_code.to_owned()))?;
    let mut lines = text.lines().map(str::trim).filter(|line| !line.is_empty());
    let Some(first) = lines.next() else {
        return Err(Usage(messages.stdin_empty.to_owned()));
    };
    if lines.next().is_some() || !is_code(first) {
        return Err(Usage(messages.stdin_not_code.to_owned()));
    }
    Ok(zeroize::Zeroizing::new(first.to_owned()))
}

/// The app method's params for a mint.
pub(super) fn mint_params(device: Option<&str>) -> Value {
    let mut params = Map::new();
    if let Some(device) = device {
        params.insert("device".into(), json!(device));
    }
    Value::Object(params)
}

/// The app method's params for a redeem. The only place the code leaves this process: the
/// app's own socket, a same-user local connection.
pub(super) fn redeem_params(code: &str, device: Option<&str>) -> Value {
    let mut params = Map::new();
    params.insert("code".into(), json!(code));
    if let Some(device) = device {
        params.insert("device".into(), json!(device));
    }
    Value::Object(params)
}

/// The exit code for an app refusal (the contract in the module docs).
pub(super) fn exit_code(error: &Value) -> i32 {
    match error.get("code").and_then(Value::as_str) {
        Some("invalid_params") => 2,
        Some(
            "handoff_invalid" | "not_signed_in" | "sso_required" | "rate_limited" | "forbidden",
        ) => 3,
        Some("other_user") => 5,
        // An app without the method, cmux-api down or unreachable.
        _ => 4,
    }
}

/// An app refusal with this CLI's own localized words for the codes it knows; the code stays.
pub(super) fn localized_error(error: &Value) -> Value {
    let messages = &crate::localization::catalog().auth_handoff;
    let message = match error.get("code").and_then(Value::as_str) {
        Some("handoff_invalid") => messages.err_handoff_invalid,
        Some("other_user") => messages.err_other_user,
        Some("not_signed_in") => messages.err_not_signed_in,
        Some("sso_required") => messages.err_sso_required,
        Some("rate_limited") => messages.err_rate_limited,
        Some("unavailable") => messages.err_unavailable,
        _ => return error.clone(),
    };
    let mut error = error.clone();
    if let Some(object) = error.as_object_mut() {
        object.insert("message".into(), json!(format!("cmux: {message}")));
    }
    error
}

/// The mint answer as printed: `{"code","expiresAt","user","email","device"}`.
pub(super) fn mint_output(value: &Value) -> Option<Value> {
    let code = value.get("code").and_then(Value::as_str).filter(|code| is_code(code))?;
    // The app writes a JSON number; a whole float (`1.7e12`) reads as the same milliseconds.
    let expires = value.get("expires_at").and_then(|v| {
        v.as_i64()
            .or_else(|| v.as_f64().filter(|f| f.fract() == 0.0 && *f >= 0.0).map(|f| f as i64))
    })?;
    let field = |key: &str| value.get(key).cloned().unwrap_or(Value::Null);
    Some(json!({
        "code": code,
        "expiresAt": expires,
        "user": field("user"),
        "email": field("email"),
        "device": field("device"),
    }))
}

/// The redeem answer as printed: `{"signedIn","alreadySignedIn","user":{"id","email"},"device":{"name"}}`.
/// `None` unless the app says it is signed in.
pub(super) fn redeem_output(value: &Value) -> Option<Value> {
    if value.get("signed_in").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let field = |key: &str| value.get(key).cloned().unwrap_or(Value::Null);
    Some(json!({
        "signedIn": true,
        "alreadySignedIn": value.get("already_signed_in").and_then(Value::as_bool).unwrap_or(false),
        "user": {"id": field("user"), "email": field("email")},
        "device": {"name": field("device")},
    }))
}

/// The app's answer to one request: its value or refusal, or a transport failure.
pub(super) type AppAnswer = Result<Result<Value, Value>, String>;

/// Asks again while the app answers `unavailable` (cmux-api down or unreachable), inside
/// `patience`. `Err` is a connect failure to the app itself, which ends at once.
pub(super) fn retry_unavailable(
    patience: Patience,
    mut ask: impl FnMut() -> Result<AppAnswer, Value>,
) -> Result<AppAnswer, Value> {
    patience
        .run(|| {
            let answer = ask().map_err(|error| Attempt::Fail(Err(error)))?;
            let unavailable = matches!(&answer, Ok(Err(error))
                if error.get("code").and_then(Value::as_str) == Some("unavailable"));
            if unavailable { Err(Attempt::Retry(Ok(answer))) } else { Ok(answer) }
        })
        .or_else(|ended| ended)
}

/// `cmux auth handoff …` (`args` after `handoff`).
pub(super) fn run(global: &GlobalArgs, args: &[String]) -> i32 {
    match parse(args) {
        Ok(invocation) => run_invocation(global, invocation, std::io::stdin()),
        Err(Usage(message)) => {
            super::app::failure("usage.invalid", &format!("cmux: {message}"), global.output, 2)
        }
    }
}

fn run_invocation(global: &GlobalArgs, invocation: Invocation, stdin: std::io::Stdin) -> i32 {
    let messages = &crate::localization::catalog().auth_handoff;
    let (method, params, mint) = match invocation {
        Invocation::Help => {
            let mut stdout = std::io::stdout().lock();
            let _ = stdout.write_all(messages.usage.as_bytes());
            let _ = stdout.flush();
            return 0;
        }
        Invocation::Mint { device } => ("auth.handoff.mint", mint_params(device.as_deref()), true),
        Invocation::Redeem { device } => {
            // A person at a terminal would type the code where it can be seen: stdin must be a pipe.
            if stdin.is_terminal() {
                return super::app::failure(
                    "usage.invalid",
                    &format!("cmux: {}", messages.stdin_terminal),
                    global.output,
                    2,
                );
            }
            let code = match read_code(stdin.lock()) {
                Ok(code) => code,
                Err(Usage(message)) => {
                    return super::app::failure(
                        "usage.invalid",
                        &format!("cmux: {message}"),
                        global.output,
                        2,
                    );
                }
            };
            ("auth.handoff.redeem", redeem_params(&code, device.as_deref()), false)
        }
    };
    // A new code costs nothing and an unused one expires by itself, so a mint cmux-api could
    // not reach is asked again; a redeem is asked once, as a lost answer may have spent its code.
    let total = if mint { UNAVAILABLE_PATIENCE } else { Duration::ZERO };
    let patience = Patience::new("cmux to be reachable", total);
    let answer = match retry_unavailable(patience, || {
        let mut stream = super::app::connect_command(global)?;
        Ok(super::app::request(&mut stream, method, params.clone(), HANDOFF_TIMEOUT))
    }) {
        Ok(answer) => answer,
        Err(error) => return super::wire::print_local_error(&error, global.output, 4),
    };
    match answer {
        Ok(Ok(value)) => {
            let shaped = if mint { mint_output(&value) } else { redeem_output(&value) };
            let Some(shaped) = shaped else {
                return super::app::failure(
                    "app.invalid_response",
                    messages.bad_answer,
                    global.output,
                    4,
                );
            };
            match global.output {
                OutputMode::Quiet => 0,
                OutputMode::Json | OutputMode::JsonLines => {
                    super::wire::print_local_success(&shaped, global.output)
                }
                OutputMode::Human => {
                    let line = if mint {
                        let code = shaped.get("code").and_then(Value::as_str);
                        format!("{}\n", code.unwrap_or_default())
                    } else {
                        let who = shaped
                            .pointer("/user/email")
                            .and_then(Value::as_str)
                            .or_else(|| shaped.pointer("/user/id").and_then(Value::as_str))
                            .unwrap_or("?");
                        format!("{}\n", messages.signed_in.replace("{user}", who))
                    };
                    let mut stdout = std::io::stdout().lock();
                    let _ = stdout.write_all(line.as_bytes());
                    let _ = stdout.flush();
                    0
                }
            }
        }
        Ok(Err(error)) => super::wire::print_local_error(
            &localized_error(&error),
            global.output,
            exit_code(&error),
        ),
        Err(message) => super::app::failure("app.transport", &message, global.output, 4),
    }
}

#[cfg(test)]
mod tests;
