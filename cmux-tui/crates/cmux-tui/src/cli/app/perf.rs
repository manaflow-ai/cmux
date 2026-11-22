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
mod pty;
mod report;
mod sim;
mod stats;
#[cfg(test)]
mod tests;

pub(super) const DEFAULT_PROFILE_SECONDS: u64 = 10;
pub(super) const MAX_PROFILE_SECONDS: u64 = 600;
pub(super) const DEFAULT_SIM_SECONDS: u64 = 60;
pub(super) const DEFAULT_SIM_EVENTS: u64 = 10_000;
/// Timed samples `--probe` takes per action (after its warmup), unless `--probe-samples`.
pub(super) const DEFAULT_PROBE_SAMPLES: usize = 30;
pub(super) const MAX_PROBE_SAMPLES: usize = 500;
/// The longest a sim's build may take before it is cut short and the run starts.
pub(super) const DEFAULT_SIM_BUILD_SECONDS: u64 = 180;

/// A parsed `cmux perf` command.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Command {
    Profile(ProfileArgs),
    Compare { before: PathBuf, after: PathBuf },
    Ab(AbArgs),
    Sim(SimArgs),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct ProfileArgs {
    pub seconds: u64,
    pub out: Option<PathBuf>,
    pub label: Option<String>,
    /// Also drive the interactive elements (tab, sidebar, palette, typing) and time them.
    pub probe: bool,
    /// Timed samples per action `--probe` keeps (its warmup round is taken on top).
    pub probe_samples: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct AbArgs {
    pub patch: String,
    pub rollback: bool,
    pub seconds: u64,
    pub probe: bool,
    pub probe_samples: usize,
    /// Where the reports go (default: a new directory under the temp dir).
    pub out_dir: Option<PathBuf>,
    /// The cmux checkout that has scripts/cmux-next/hot-apply.py.
    pub repo: Option<PathBuf>,
    /// Passed to hot-apply.py `--parts`.
    pub parts: Option<String>,
    /// Passed to hot-apply.py `plan` and `apply`: take a daemon not signed as the app is (a
    /// Team-signed app then fails Cloud until rollback).
    pub unsigned_daemon: bool,
    /// Apply even when the plan leaves some of the patch out.
    pub allow_partial: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct SimArgs {
    pub profile: String,
    /// The run's length, counted from the end of the build.
    pub seconds: u64,
    /// The build's hard deadline; what is not made by then is not made.
    pub build_seconds: u64,
    /// Lines per burst; the shape's `burst_lines` when not given.
    pub events: Option<u64>,
    /// A shape file to use instead of the profile's.
    pub shape: Option<PathBuf>,
    /// Every count of the shape times this (1 to 100).
    pub scale: usize,
}

fn probe_samples(value: Option<&str>) -> Result<usize, UsageError> {
    let messages = &crate::localization::catalog().app_control.perf;
    match value {
        None => Ok(DEFAULT_PROBE_SAMPLES),
        Some(text) => text
            .parse::<usize>()
            .ok()
            .filter(|n| (1..=MAX_PROBE_SAMPLES).contains(n))
            .ok_or_else(|| UsageError::new(messages.probe_samples)),
    }
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
    let Some((verb, rest)) = args.split_first() else { return Err(usage()) };
    match verb.as_str() {
        "profile" => {
            let options =
                Options::parse(rest, &["seconds", "out", "label", "probe-samples"], &["probe"])?;
            Ok(Command::Profile(ProfileArgs {
                seconds: seconds(
                    options.value("seconds"),
                    DEFAULT_PROFILE_SECONDS,
                    MAX_PROFILE_SECONDS,
                )?,
                out: options.value("out").map(PathBuf::from),
                label: options.value("label").map(str::to_owned),
                probe: options.flag("probe"),
                probe_samples: probe_samples(options.value("probe-samples"))?,
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
                &["patch", "seconds", "out-dir", "repo", "parts", "probe-samples"],
                &["rollback", "probe", "unsigned-daemon", "allow-partial"],
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
                probe_samples: probe_samples(options.value("probe-samples"))?,
                out_dir: options.value("out-dir").map(PathBuf::from),
                repo: options.value("repo").map(PathBuf::from),
                parts: options.value("parts").map(str::to_owned),
                unsigned_daemon: options.flag("unsigned-daemon"),
                allow_partial: options.flag("allow-partial"),
            }))
        }
        "sim" => {
            let options = Options::parse(
                rest,
                &["profile", "seconds", "build-seconds", "events", "shape", "scale"],
                &[],
            )?;
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
                build_seconds: seconds(
                    options.value("build-seconds"),
                    DEFAULT_SIM_BUILD_SECONDS,
                    3600,
                )?,
                events,
                shape: options.value("shape").map(PathBuf::from),
                scale: match options.value("scale") {
                    None => 1,
                    Some(text) => text
                        .parse::<usize>()
                        .ok()
                        .filter(|scale| (1..=sim::MAX_SCALE).contains(scale))
                        .ok_or_else(|| UsageError::new(messages.scale))?,
                },
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
