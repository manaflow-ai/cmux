//! `cmux nightly list|install`: go back (or forward) to another recent nightly
//! build of the app behind the socket.
//!
//! Leo (2026-11-02): "austin and aziz hit it for some reason so idk if i
//! should go without a way to revert nightlies to an older version
//! convieniently". Sparkle never offers a lower build, so a Mac already on a
//! bad nightly keeps it even after the feed rollback
//! (nightly-next-rollback.yml) pulls it. `list` reads `updates.builds` (the
//! nightly track with date, commit and first change titles); `install`
//! picks the build here (`previous` is the newest installable build below the
//! running one) and asks the app for `updates.switch_build`, the same path
//! as Settings > Updates' Switch: download, signature and team check, one
//! restart with every session, and the build left behind is no longer offered.

use std::time::Duration;

use serde_json::{Value, json};

use super::super::GlobalArgs;
use super::super::OutputMode;
use super::UsageError;
use crate::localization::NightlyMessages;

/// `updates.builds` reads the feed's notes, verdicts and pulled list.
const LIST_TIMEOUT: Duration = Duration::from_secs(35);
/// `updates.switch_build` downloads a DMG before the app quits.
const INSTALL_TIMEOUT: Duration = Duration::from_secs(605);

/// A parsed `cmux nightly` command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Command {
    /// `--help`, `-h` or `help`: the usage text, with no app needed.
    Help,
    List {
        limit: u32,
    },
    Install {
        target: Target,
    },
}

/// The build `install` goes to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Target {
    /// The newest installable build below the running one.
    Previous,
    Build(String),
}

/// Parses the words after `nightly`.
pub(super) fn parse(rest: &[String]) -> Result<Command, UsageError> {
    let messages = &crate::localization::catalog().app_control;
    let usage = || UsageError::new(messages.nightly.usage);
    if rest.first().map(String::as_str) == Some("help")
        || rest.iter().any(|word| word == "--help" || word == "-h")
    {
        return Ok(Command::Help);
    }
    match rest.first().map(String::as_str) {
        Some("list") => {
            let mut limit = 10;
            let mut words = rest.iter().skip(1);
            while let Some(word) = words.next() {
                let value = match word.as_str() {
                    "--limit" => words.next().map(String::as_str),
                    other => match other.strip_prefix("--limit=") {
                        Some(value) => Some(value),
                        None => {
                            return Err(UsageError::new(
                                messages.unexpected_argument.replace("{value}", other),
                            ));
                        }
                    },
                };
                limit = value
                    .and_then(|value| value.parse::<u32>().ok())
                    .filter(|limit| (1..=50).contains(limit))
                    .ok_or_else(|| {
                        UsageError::new(messages.missing_value.replace("{flag}", "--limit"))
                    })?;
            }
            Ok(Command::List { limit })
        }
        Some("install") => {
            let target = match rest.get(1).map(String::as_str) {
                Some("previous") => Target::Previous,
                Some(build)
                    if !build.is_empty() && build.bytes().all(|byte| byte.is_ascii_digit()) =>
                {
                    Target::Build(build.to_owned())
                }
                _ => return Err(usage()),
            };
            if let Some(extra) = rest.get(2) {
                return Err(UsageError::new(
                    messages.unexpected_argument.replace("{value}", extra),
                ));
            }
            Ok(Command::Install { target })
        }
        _ => Err(usage()),
    }
}

/// Runs `command` against the app behind the socket.
pub(super) fn run(global: &GlobalArgs, command: &Command) -> i32 {
    let messages = &crate::localization::catalog().app_control.nightly;
    if *command == Command::Help {
        println!("{}", messages.usage);
        return 0;
    }
    let mut stream = match super::connect_command(global) {
        Ok(stream) => stream,
        Err(error) => return super::super::wire::print_local_error(&error, global.output, 3),
    };
    let limit = match command {
        Command::List { limit } => *limit,
        // `previous` and a named build are looked up among the most builds `updates.builds` lists.
        Command::Help | Command::Install { .. } => 50,
    };
    let listing = match super::exchange(
        &mut stream,
        "updates.builds",
        json!({ "limit": limit }),
        LIST_TIMEOUT,
    ) {
        Ok(Ok(value)) => value,
        Ok(Err(error)) => return super::super::wire::print_operation_error(&error, global.output),
        Err(message) => return failure("app.transport", &message, global.output),
    };
    match command {
        Command::Help => 0,
        Command::List { .. } => match global.output {
            OutputMode::Human => {
                print!("{}", human(&listing, messages));
                0
            }
            _ => super::super::wire::print_local_success(&listing, global.output),
        },
        Command::Install { target } => {
            let build = match pick(&listing, target, messages) {
                Ok(build) => build,
                Err((code, message)) => return failure(code, &message, global.output),
            };
            let installed = text(&listing, "installed").unwrap_or_default();
            if global.output == OutputMode::Human {
                println!(
                    "{}",
                    messages
                        .installing
                        .replace("{build}", &text(build, "build").unwrap_or_default())
                        .replace("{version}", &text(build, "version").unwrap_or_default())
                        .replace("{date}", &text(build, "date").unwrap_or_default())
                        .replace("{from}", &installed)
                );
            }
            let number = build.get("build").cloned().unwrap_or(Value::Null);
            let params = json!({ "build": number });
            let switching = || json!({ "switching_to": number });
            match switch_build(&mut stream, params) {
                Switched::Answer(Ok(value)) => match global.output {
                    OutputMode::Human => 0,
                    _ => super::super::wire::print_local_success(&value, global.output),
                },
                Switched::Answer(Err(error)) => {
                    super::super::wire::print_operation_error(&error, global.output)
                }
                // The app quits into the new build once the swap is done: the connection closing
                // with no answer after the request went out is that restart.
                Switched::Restarted => match global.output {
                    OutputMode::Human => 0,
                    _ => super::super::wire::print_local_success(&switching(), global.output),
                },
                Switched::Failed(message) => failure("app.transport", &message, global.output),
            }
        }
    }
}

/// How `updates.switch_build` ended.
#[derive(Debug)]
pub(super) enum Switched {
    /// The app answered: the switch's result or its refusal.
    Answer(Result<Value, Value>),
    /// The connection closed with no answer after the request went out: the app restarted.
    Restarted,
    /// The request could not be sent, the wait timed out, or the answer was unreadable.
    Failed(String),
}

fn switch_build(stream: &mut std::os::unix::net::UnixStream, params: Value) -> Switched {
    use std::io::{BufRead, BufReader, Read};
    let line = json!({ "id": 1, "method": "updates.switch_build", "params": params });
    if let Err(message) = super::send_line(stream, &line) {
        return Switched::Failed(message);
    }
    if let Err(error) = stream.set_read_timeout(Some(INSTALL_TIMEOUT)) {
        return Switched::Failed(error.to_string());
    }
    let reader = match stream.try_clone() {
        Ok(clone) => clone,
        Err(error) => return Switched::Failed(error.to_string()),
    };
    let mut response = String::new();
    match BufReader::new(reader.take(super::MAX_RESPONSE_BYTES)).read_line(&mut response) {
        Ok(_) => switched(&response),
        // A process that exits with the request unread resets the connection instead of closing it.
        Err(error) if error.kind() == std::io::ErrorKind::ConnectionReset => Switched::Restarted,
        Err(error) => Switched::Failed(super::read_error(&error, Some(INSTALL_TIMEOUT))),
    }
}

/// The answer line read after `updates.switch_build` went out; empty is the connection closing.
pub(super) fn switched(response: &str) -> Switched {
    if response.trim().is_empty() {
        return Switched::Restarted;
    }
    match super::parse_response(response) {
        Ok(answer) => Switched::Answer(answer),
        Err(message) => Switched::Failed(message),
    }
}

fn failure(code: &str, message: &str, output: OutputMode) -> i32 {
    super::super::wire::print_local_error(&json!({ "code": code, "message": message }), output, 1)
}

/// The build `target` names in `updates.builds`' answer, or why none can be installed.
pub(super) fn pick<'a>(
    listing: &'a Value,
    target: &Target,
    messages: &NightlyMessages,
) -> Result<&'a Value, (&'static str, String)> {
    if listing.get("switches").and_then(Value::as_bool) == Some(false) {
        return Err(("nightly.cannot_switch", messages.cannot_switch.to_owned()));
    }
    let builds: &[Value] =
        listing.get("builds").and_then(Value::as_array).map_or(&[], Vec::as_slice);
    let installed = text(listing, "installed").unwrap_or_default();
    match target {
        Target::Previous => builds
            .iter()
            .filter(|build| flag(build, "switchable"))
            .filter(|build| text(build, "build").is_some_and(|number| older(&number, &installed)))
            .max_by(|left, right| {
                order(
                    &text(left, "build").unwrap_or_default(),
                    &text(right, "build").unwrap_or_default(),
                )
            })
            .ok_or_else(|| {
                ("nightly.no_previous", messages.no_previous.replace("{build}", &installed))
            }),
        Target::Build(number) => {
            let Some(build) =
                builds.iter().find(|build| text(build, "build").as_deref() == Some(number))
            else {
                return Err((
                    "nightly.unknown_build",
                    messages.unknown_build.replace("{build}", number),
                ));
            };
            if flag(build, "installed") {
                return Err((
                    "nightly.installed",
                    messages.installed_already.replace("{build}", number),
                ));
            }
            if build.get("health").and_then(Value::as_str) == Some("pulled") {
                let reason = text(build, "pulled_reason").unwrap_or_default();
                return Err((
                    "nightly.pulled",
                    messages.pulled.replace("{build}", number).replace("{reason}", &reason),
                ));
            }
            if !flag(build, "switchable") {
                return Err(("nightly.cannot_switch", messages.cannot_switch.to_owned()));
            }
            Ok(build)
        }
    }
}

/// Numeric build order (CFBundleVersion is a monotonic number).
fn order(left: &str, right: &str) -> std::cmp::Ordering {
    let (left, right) = (left.trim_start_matches('0'), right.trim_start_matches('0'));
    left.len().cmp(&right.len()).then_with(|| left.cmp(right))
}

fn older(build: &str, than: &str) -> bool {
    order(build, than) == std::cmp::Ordering::Less
}

/// One line per build, newest first: `*` marks the running one.
pub(super) fn human(listing: &Value, messages: &NightlyMessages) -> String {
    let builds: &[Value] =
        listing.get("builds").and_then(Value::as_array).map_or(&[], Vec::as_slice);
    if builds.is_empty() {
        return format!("{}\n", messages.no_builds);
    }
    let mut out = String::new();
    for build in builds {
        let mut tags = Vec::new();
        if flag(build, "installed") {
            tags.push(messages.here);
        }
        if flag(build, "kept") {
            tags.push(messages.kept);
        }
        if build.get("health").and_then(Value::as_str) == Some("pulled") {
            tags.push(messages.pulled_tag);
        }
        let commit: String = text(build, "commit").unwrap_or_default().chars().take(8).collect();
        let titles = build
            .get("titles")
            .and_then(Value::as_array)
            .map(|titles| titles.iter().filter_map(Value::as_str).collect::<Vec<_>>().join("; "))
            .unwrap_or_default();
        out.push_str(&format!(
            "{} {:<14} {:<10} {:<8} {:<20} {}\n",
            if flag(build, "installed") { "*" } else { " " },
            text(build, "build").unwrap_or_default(),
            text(build, "date").unwrap_or_default(),
            commit,
            tags.join(", "),
            titles,
        ));
    }
    out
}

fn flag(value: &Value, key: &str) -> bool {
    value.get(key).and_then(Value::as_bool).unwrap_or(false)
}

fn text(value: &Value, key: &str) -> Option<String> {
    value.get(key).and_then(Value::as_str).filter(|value| !value.is_empty()).map(str::to_owned)
}

#[cfg(test)]
mod tests;
