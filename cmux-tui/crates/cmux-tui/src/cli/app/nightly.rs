//! `cmux nightly list|install|whats-in|which` (and its app spelling, `cmux app versions` and
//! `cmux app use previous|next|latest|<build>`): go back (or forward) to another
//! recent nightly build of the app behind the socket.
//!
//! Leo (2026-11-21): "agents being able to just say "actually let's go back to
//! this other version :)"". `cmux app use previous` goes back one build and
//! `cmux app use next` comes forward again: the switch keeps the build it leaves,
//! so the step back is undone the same way, with every session kept.
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
//! `whats-in` and `which` read the PRs each nightly carries from its signed notes (nightly/feed.rs).

use std::time::Duration;

use cmux_json::JsonGet as _;
use serde_json::{Value, json};

use super::super::GlobalArgs;
use super::super::OutputMode;
use super::UsageError;
use crate::localization::NightlyMessages;

/// `updates.builds` reads the feed's notes, verdicts and pulled list.
const LIST_TIMEOUT: Duration = Duration::from_secs(35);
/// `updates.switch_build` downloads a DMG before the app quits.
const INSTALL_TIMEOUT: Duration = Duration::from_secs(605);
/// `system.identify` answers inside the app's own 2 s control deadline.
const IDENTIFY_TIMEOUT: Duration = Duration::from_secs(3);

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
    /// `whats-in [BUILD]`: the PRs that build carries (default: the build this Mac runs).
    WhatsIn {
        build: Option<String>,
    },
    /// `which <PR>`: the first nightly that carries the PR.
    Which {
        pr: u64,
    },
}

/// The build `install` goes to.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Target {
    /// The newest installable build below the running one.
    Previous,
    /// The oldest installable build above the running one: forward one step, the undo of
    /// `previous`.
    Next,
    /// The newest installable build.
    Latest,
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
                Some("next") => Target::Next,
                Some("latest") => Target::Latest,
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
        Some("whats-in") => {
            let build = match rest.get(1).map(String::as_str) {
                None => None,
                Some(build)
                    if !build.is_empty() && build.bytes().all(|byte| byte.is_ascii_digit()) =>
                {
                    Some(build.to_owned())
                }
                Some(_) => return Err(usage()),
            };
            if let Some(extra) = rest.get(2) {
                return Err(UsageError::new(
                    messages.unexpected_argument.replace("{value}", extra),
                ));
            }
            Ok(Command::WhatsIn { build })
        }
        Some("which") => {
            let pr = rest.get(1).and_then(|word| feed::pr_number(word)).ok_or_else(usage)?;
            if let Some(extra) = rest.get(2) {
                return Err(UsageError::new(
                    messages.unexpected_argument.replace("{value}", extra),
                ));
            }
            Ok(Command::Which { pr })
        }
        _ => Err(usage()),
    }
}

/// Parses `cmux app versions ...` and `cmux app use ...`, the app spelling of
/// `cmux nightly list ...` and `cmux nightly install ...`.
pub(super) fn parse_app(verb: &str, rest: &[String]) -> Result<Command, UsageError> {
    let nightly_verb = match verb {
        "versions" => "list",
        _ => "install",
    };
    let words: Vec<String> =
        std::iter::once(nightly_verb.to_owned()).chain(rest.iter().cloned()).collect();
    parse(&words)
}

/// Runs `command` against the app behind the socket.
pub(super) fn run(global: &GlobalArgs, command: &Command) -> i32 {
    let messages = &crate::localization::catalog().app_control.nightly;
    if *command == Command::Help {
        println!("{}", messages.usage);
        return 0;
    }
    match command {
        Command::WhatsIn { build } => return whats_in(global, build.as_deref(), messages),
        Command::Which { pr } => return which(*pr, global.output, messages),
        _ => {}
    }
    let mut stream = match super::connect_command(global) {
        Ok(stream) => stream,
        Err(error) => return super::super::wire::print_local_error(&error, global.output, 3),
    };
    let limit = match command {
        Command::List { limit } => *limit,
        // `previous` and a named build are looked up among the most builds `updates.builds` lists.
        _ => 50,
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
        Command::Help | Command::WhatsIn { .. } | Command::Which { .. } => 0,
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
            let installed = listing.get_str("installed").unwrap_or_default();
            if global.output == OutputMode::Human {
                println!(
                    "{}",
                    messages
                        .installing
                        .replace("{build}", build.get_str("build").unwrap_or_default())
                        .replace("{version}", build.get_str("version").unwrap_or_default())
                        .replace("{date}", build.get_str("date").unwrap_or_default())
                        .replace("{from}", installed)
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

pub(super) fn switch_build(stream: &mut std::os::unix::net::UnixStream, params: Value) -> Switched {
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
    let builds = listing.get_array("builds");
    let installed = listing.get_str("installed").unwrap_or_default();
    match target {
        Target::Previous => switchable(builds)
            .filter(|build| {
                build.get_nonempty_str("build").is_some_and(|number| older(number, installed))
            })
            .max_by(by_build)
            .ok_or_else(|| {
                ("nightly.no_previous", messages.no_previous.replace("{build}", installed))
            }),
        Target::Next => switchable(builds)
            .filter(|build| {
                build.get_nonempty_str("build").is_some_and(|number| older(installed, number))
            })
            .min_by(by_build)
            .ok_or_else(|| ("nightly.no_next", messages.no_next.replace("{build}", installed))),
        Target::Latest => switchable(builds)
            .max_by(by_build)
            .filter(|build| {
                build.get_nonempty_str("build").is_some_and(|number| older(installed, number))
            })
            .ok_or_else(|| ("nightly.no_next", messages.no_next.replace("{build}", installed))),
        Target::Build(number) => {
            let Some(build) =
                builds.iter().find(|build| build.get_nonempty_str("build") == Some(number))
            else {
                return Err((
                    "nightly.unknown_build",
                    messages.unknown_build.replace("{build}", number),
                ));
            };
            if build.get_bool("installed") == Some(true) {
                return Err((
                    "nightly.installed",
                    messages.installed_already.replace("{build}", number),
                ));
            }
            if build.get("health").and_then(Value::as_str) == Some("pulled") {
                let reason = build.get_str("pulled_reason").unwrap_or_default();
                return Err((
                    "nightly.pulled",
                    messages.pulled.replace("{build}", number).replace("{reason}", reason),
                ));
            }
            if build.get_bool("switchable") != Some(true) {
                return Err(("nightly.cannot_switch", messages.cannot_switch.to_owned()));
            }
            Ok(build)
        }
    }
}

/// The builds the app would switch to (not the running one, not a pulled one).
fn switchable(builds: &[Value]) -> impl Iterator<Item = &Value> {
    builds.iter().filter(|build| build.get_bool("switchable") == Some(true))
}

fn by_build(left: &&Value, right: &&Value) -> std::cmp::Ordering {
    order(left.get_str("build").unwrap_or_default(), right.get_str("build").unwrap_or_default())
}

/// Numeric build order (CFBundleVersion is a monotonic number).
pub(super) fn order(left: &str, right: &str) -> std::cmp::Ordering {
    let (left, right) = (left.trim_start_matches('0'), right.trim_start_matches('0'));
    left.len().cmp(&right.len()).then_with(|| left.cmp(right))
}

pub(super) fn older(build: &str, than: &str) -> bool {
    order(build, than) == std::cmp::Ordering::Less
}

/// One line per build, newest first: `*` marks the running one.
pub(super) fn human(listing: &Value, messages: &NightlyMessages) -> String {
    let builds = listing.get_array("builds");
    if builds.is_empty() {
        return format!("{}\n", messages.no_builds);
    }
    let mut out = String::new();
    for build in builds {
        let mut tags = Vec::new();
        if build.get_bool("installed") == Some(true) {
            tags.push(messages.here);
        }
        if build.get_bool("kept") == Some(true) {
            tags.push(messages.kept);
        }
        if build.get("health").and_then(Value::as_str) == Some("pulled") {
            tags.push(messages.pulled_tag);
        }
        let commit: String = build.get_str("commit").unwrap_or_default().chars().take(8).collect();
        let titles = build
            .get("titles")
            .and_then(Value::as_array)
            .map(|titles| titles.iter().filter_map(Value::as_str).collect::<Vec<_>>().join("; "))
            .unwrap_or_default();
        out.push_str(&format!(
            "{} {:<14} {:<10} {:<8} {:<20} {}\n",
            if build.get_bool("installed") == Some(true) { "*" } else { " " },
            build.get_str("build").unwrap_or_default(),
            build.get_str("date").unwrap_or_default(),
            commit,
            tags.join(", "),
            titles,
        ));
    }
    out
}

/// The build this Mac runs, from `system.identify`; `None` with no app behind the socket.
fn running_build(global: &GlobalArgs) -> Option<String> {
    let mut stream = super::connect_command(global).ok()?;
    let identify =
        super::exchange(&mut stream, "system.identify", json!({}), IDENTIFY_TIMEOUT).ok()?.ok()?;
    feed::build_number(identify.get_nonempty_str("build")?)
}

/// `cmux nightly whats-in [BUILD]`.
fn whats_in(global: &GlobalArgs, build: Option<&str>, messages: &NightlyMessages) -> i32 {
    let build = build.map(str::to_owned).or_else(|| running_build(global));
    let mut names = vec!["index.json".to_owned()];
    names.extend(build.iter().map(|build| format!("{build}.json")));
    let mut fetched = feed::fetch_all(&names).into_iter();
    let index = match fetched.next() {
        Some(Ok(feed::Fetched::Found(index))) => Some(index),
        _ => None,
    };
    let (build, notes) = match build {
        Some(build) => (build, fetched.next()),
        // No app answered: the newest build the feed lists.
        None => {
            let Some(newest) = index.as_ref().and_then(feed::newest) else {
                return failure(
                    "nightly.feed",
                    &messages.feed_unreadable.replace("{error}", "notes/index.json"),
                    global.output,
                );
            };
            let notes = feed::fetch_all(&[format!("{newest}.json")]).into_iter().next();
            (newest, notes)
        }
    };
    let notes = match notes {
        Some(Ok(feed::Fetched::Found(notes))) => notes,
        Some(Ok(feed::Fetched::Missing)) => {
            return failure(
                "nightly.unknown_build",
                &messages.no_notes.replace("{build}", &build),
                global.output,
            );
        }
        Some(Err(error)) => {
            return failure(
                "nightly.feed",
                &messages.feed_unreadable.replace("{error}", &error),
                global.output,
            );
        }
        None => {
            return failure(
                "nightly.feed",
                &messages.feed_unreadable.replace("{error}", &build),
                global.output,
            );
        }
    };
    let report = feed::whats_in(&notes, index.as_ref());
    match global.output {
        OutputMode::Human => {
            print!("{}", feed::whats_in_human(&report, messages));
            0
        }
        _ => super::super::wire::print_local_success(&report, global.output),
    }
}

/// `cmux nightly which <PR>`: `pr-index.json` when the feed has it, else every listed build's notes.
fn which(pr: u64, output: OutputMode, messages: &NightlyMessages) -> i32 {
    let unreadable = |error: &str| {
        failure("nightly.feed", &messages.feed_unreadable.replace("{error}", error), output)
    };
    let fetched = feed::fetch_all(&["pr-index.json".to_owned(), "index.json".to_owned()]);
    let index = match &fetched[1] {
        Ok(feed::Fetched::Found(index)) => index.clone(),
        Ok(feed::Fetched::Missing) => return unreadable("notes/index.json: 404"),
        Err(error) => return unreadable(error),
    };
    let oldest = index
        .get_array("builds")
        .iter()
        .filter_map(|build| build.get_nonempty_str("build"))
        .min_by(|a, b| order(a, b))
        .map(str::to_owned);
    let answer = match &fetched[0] {
        Ok(feed::Fetched::Found(pr_index)) => feed::which_from_pr_index(pr_index, pr),
        Err(error) => return unreadable(error),
        Ok(feed::Fetched::Missing) => {
            let names: Vec<String> = index
                .get_array("builds")
                .iter()
                .filter_map(|build| build.get_nonempty_str("build"))
                .map(|build| format!("{build}.json"))
                .collect();
            let mut notes = Vec::new();
            for result in feed::fetch_all(&names) {
                match result {
                    Ok(feed::Fetched::Found(value)) => notes.push(value),
                    Ok(feed::Fetched::Missing) => {}
                    Err(error) => return unreadable(&error),
                }
            }
            feed::which_from_notes(&notes, pr)
        }
    }
    .unwrap_or_else(|| feed::not_shipped(pr, oldest.as_deref()));
    match output {
        OutputMode::Human => {
            print!("{}", feed::which_human(&answer, messages));
            0
        }
        _ => super::super::wire::print_local_success(&answer, output),
    }
}

mod feed;
#[cfg(test)]
mod tests;
