//! `cmux perf profile|compare|ab|sim`: a profiler for the running app against a 120 Hz frame
//! (8.33 ms), and the load that stresses it (docs/cmux-next/perf-loop.md).
//!
//! - `profile` samples the app through its control socket and the host (CPU, RAM, GPU, disk)
//!   for a window and writes one JSON report: frames, main-thread stalls, layout shifts and the
//!   responsiveness of the interactive elements. Each number names its source and whether that
//!   source exists in a Release build: the native frame, hang, layout and switch timers are
//!   `debug.*` methods, registered only in Debug (and bench-hook) builds.
//! - `compare` prints two reports side by side with the change and a verdict per row.
//! - `ab` profiles, applies a patch with `scripts/cmux-next/hot-apply.py`, profiles again and
//!   compares (and rolls back with `--rollback`).
//! - `sim` drives load on a named app socket from a JSON shape file and cleans up what it made.

use std::path::PathBuf;

use super::{GlobalArgs, Options, UsageError};

mod ab;
mod compare;
mod host;
mod profile;
mod report;
mod sim;
mod stats;
#[cfg(test)]
mod tests;

pub(super) const DEFAULT_PROFILE_SECONDS: u64 = 10;
pub(super) const MAX_PROFILE_SECONDS: u64 = 600;
pub(super) const DEFAULT_SIM_SECONDS: u64 = 60;
pub(super) const DEFAULT_SIM_EVENTS: u64 = 10_000;

/// A parsed `cmux perf` command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Command {
    Profile(ProfileArgs),
    Compare { before: PathBuf, after: PathBuf },
    Ab(AbArgs),
    Sim(SimArgs),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct ProfileArgs {
    pub seconds: u64,
    pub out: Option<PathBuf>,
    pub label: Option<String>,
    /// Also drive the interactive elements (tab, sidebar, palette, typing) and time them.
    pub probe: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct AbArgs {
    pub patch: String,
    pub rollback: bool,
    pub seconds: u64,
    pub probe: bool,
    /// Where the reports go (default: a new directory under the temp dir).
    pub out_dir: Option<PathBuf>,
    /// The cmux checkout that has scripts/cmux-next/hot-apply.py.
    pub repo: Option<PathBuf>,
    /// Passed to hot-apply.py `--parts`.
    pub parts: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) struct SimArgs {
    pub profile: String,
    pub seconds: u64,
    /// Lines per burst; the shape's `burst_lines` when not given.
    pub events: Option<u64>,
    /// A shape file to use instead of the profile's.
    pub shape: Option<PathBuf>,
}

fn seconds(value: Option<&str>, default: u64, max: u64) -> Result<u64, UsageError> {
    let messages = &crate::localization::catalog().app_control.perf;
    match value {
        None => Ok(default),
        Some(text) => text
            .parse::<u64>()
            .ok()
            .filter(|seconds| (1..=max).contains(seconds))
            .ok_or_else(|| UsageError::new(messages.seconds.replace("{max}", &max.to_string()))),
    }
}

/// `args` is what follows `perf`.
pub(super) fn parse(args: &[String]) -> Result<Command, UsageError> {
    let messages = &crate::localization::catalog().app_control.perf;
    let usage = || UsageError::new(messages.usage);
    let Some(verb) = args.first() else { return Err(usage()) };
    let rest = &args[1..];
    match verb.as_str() {
        "profile" => {
            let options = Options::parse(rest, &["seconds", "out", "label"], &["probe"])?;
            Ok(Command::Profile(ProfileArgs {
                seconds: seconds(
                    options.value("seconds"),
                    DEFAULT_PROFILE_SECONDS,
                    MAX_PROFILE_SECONDS,
                )?,
                out: options.value("out").map(PathBuf::from),
                label: options.value("label").map(str::to_owned),
                probe: options.flag("probe"),
            }))
        }
        "compare" => {
            let [before, after] = rest else { return Err(usage()) };
            if before.starts_with("--") || after.starts_with("--") {
                return Err(usage());
            }
            Ok(Command::Compare { before: before.into(), after: after.into() })
        }
        "ab" => {
            let options = Options::parse(
                rest,
                &["patch", "seconds", "out-dir", "repo", "parts"],
                &["rollback", "probe"],
            )?;
            let Some(patch) = options.value("patch").filter(|patch| !patch.is_empty()) else {
                return Err(usage());
            };
            Ok(Command::Ab(AbArgs {
                patch: patch.to_owned(),
                rollback: options.flag("rollback"),
                seconds: seconds(
                    options.value("seconds"),
                    DEFAULT_PROFILE_SECONDS,
                    MAX_PROFILE_SECONDS,
                )?,
                probe: options.flag("probe"),
                out_dir: options.value("out-dir").map(PathBuf::from),
                repo: options.value("repo").map(PathBuf::from),
                parts: options.value("parts").map(str::to_owned),
            }))
        }
        "sim" => {
            let options = Options::parse(rest, &["profile", "seconds", "events", "shape"], &[])?;
            let profile = options.value("profile").unwrap_or(sim::DEFAULT_PROFILE).to_owned();
            if options.value("shape").is_none() && !sim::is_known_profile(&profile) {
                return Err(UsageError::new(messages.unknown_profile.replace("{name}", &profile)));
            }
            let events = match options.value("events") {
                None => None,
                Some(text) => Some(
                    text.parse::<u64>()
                        .ok()
                        .filter(|events| (1..=sim::MAX_EVENTS).contains(events))
                        .ok_or_else(|| UsageError::new(messages.events))?,
                ),
            };
            Ok(Command::Sim(SimArgs {
                profile,
                seconds: seconds(options.value("seconds"), DEFAULT_SIM_SECONDS, 24 * 3600)?,
                events,
                shape: options.value("shape").map(PathBuf::from),
            }))
        }
        _ => Err(usage()),
    }
}

/// Runs a parsed `cmux perf` command; the exit code.
pub(super) fn run(global: &GlobalArgs, command: &Command) -> i32 {
    match command {
        Command::Profile(args) => profile::run(global, args),
        Command::Compare { before, after } => compare::run(global, before, after),
        Command::Ab(args) => ab::run(global, args),
        Command::Sim(args) => sim::run(global, args),
    }
}

/// `{name}` placeholders filled from `pairs`.
fn fill(template: &str, pairs: &[(&str, String)]) -> String {
    pairs.iter().fold(template.to_owned(), |text, (name, value)| {
        text.replace(&format!("{{{name}}}"), value)
    })
}

fn local_error(code: &str, message: String) -> serde_json::Value {
    serde_json::json!({ "code": code, "message": message, "details": {}, "retryable": false })
}
