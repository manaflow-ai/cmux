//! `cmux perf record`: a profile of the running cmux app on any build, as one
//! Perfetto trace plus a summary (the cmux-perf crate; plans/cmux-next/trace.md,
//! "Quick capture on any build").
//!
//! This file finds the app and parses the options; cmux-perf records. The app
//! is `--app` (a `.app` bundle or a pid), else the bundle this `cmux` is in,
//! else the newest running process of a cmux bundle (`*.app/Contents/MacOS/*`
//! with `Contents/Resources/bin/cmux`). On Linux, with no `--app`, it is the
//! `cmux*` and `acpmux*` processes run from this `cmux`'s `bin` folder.
//!
//! Exit codes: 0 recorded, 1 nothing to record or the files could not be
//! written, 2 usage.

use std::io::Write;
use std::path::{Path, PathBuf};
use std::time::Duration;

use cmux_perf::process::{self, Target};

use super::{GlobalArgs, OutputMode, UsageError};

#[derive(Debug, PartialEq, Eq)]
pub(super) struct Options {
    pub seconds: u64,
    pub interval_ms: u64,
    pub out: Option<PathBuf>,
    pub app: Option<String>,
    pub signposts: bool,
}

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Invocation {
    Help,
    Record(Options),
}

/// `cmux perf …`. `None` for any other command.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let (first, rest) = command_args.split_first()?;
    if first != "perf" {
        return None;
    }
    let json = rest.iter().any(|arg| arg == "--json");
    let rest: Vec<String> = rest.iter().filter(|arg| *arg != "--json").cloned().collect();
    let output = if json { OutputMode::Json } else { global.output };
    Some(match parse(&rest) {
        Ok(invocation) => run(output, &global, invocation),
        Err(error) => super::app::failure("usage.invalid", &format!("cmux: {error}"), output, 2),
    })
}

pub(super) fn parse(rest: &[String]) -> Result<Invocation, UsageError> {
    let app = &crate::localization::catalog().app_control;
    let messages = &crate::localization::catalog().perf;
    if rest.iter().any(|arg| arg == "--help" || arg == "-h") {
        return Ok(Invocation::Help);
    }
    let Some((verb, tail)) = rest.split_first() else { return Ok(Invocation::Help) };
    match verb.as_str() {
        "help" => return Ok(Invocation::Help),
        "record" => {}
        other => return Err(UsageError::new(messages.unknown_verb.replace("{verb}", other))),
    }
    let mut options = Options {
        seconds: cmux_perf::DEFAULT_SECONDS,
        interval_ms: cmux_perf::DEFAULT_INTERVAL_MS,
        out: None,
        app: None,
        signposts: true,
    };
    let bounded = |text: String, range: &std::ops::RangeInclusive<u64>, message: &str| {
        text.parse::<u64>()
            .ok()
            .filter(|value| range.contains(value))
            .ok_or_else(|| UsageError::new(message.replace("{value}", &text)))
    };
    let mut args = tail.iter();
    while let Some(arg) = args.next() {
        let (flag, inline) = match arg.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (arg.as_str(), None),
        };
        let mut value = || {
            inline
                .clone()
                .or_else(|| args.next().cloned())
                .ok_or_else(|| UsageError::new(app.missing_value.replace("{flag}", flag)))
        };
        match flag {
            "--seconds" => {
                options.seconds = bounded(value()?, &cmux_perf::SECONDS, messages.bad_seconds)?;
            }
            "--interval-ms" => {
                options.interval_ms =
                    bounded(value()?, &cmux_perf::INTERVAL_MS, messages.bad_interval)?;
            }
            "--out" => options.out = Some(PathBuf::from(value()?)),
            "--app" => options.app = Some(value()?),
            "--no-signposts" if inline.is_none() => options.signposts = false,
            other => {
                return Err(UsageError::new(app.unexpected_argument.replace("{value}", other)));
            }
        }
    }
    Ok(Invocation::Record(options))
}

fn run(output: OutputMode, _global: &GlobalArgs, invocation: Invocation) -> i32 {
    let messages = &crate::localization::catalog().perf;
    let options = match invocation {
        Invocation::Help => {
            let mut stdout = std::io::stdout().lock();
            let _ = stdout.write_all(messages.usage.as_bytes());
            let _ = stdout.flush();
            return 0;
        }
        Invocation::Record(options) => options,
    };
    let app = match resolve(options.app.as_deref()) {
        Ok(app) => app,
        Err(message) => return super::app::failure("perf.no_app", &message, output, 1),
    };
    let dir = options.out.clone().unwrap_or_else(|| {
        let stamp = cmux_perf::clock::utc_stamp(cmux_perf::clock::now_us());
        PathBuf::from(format!("cmux-perf-{stamp}"))
    });
    let dir = std::path::absolute(&dir).unwrap_or(dir);
    let config = cmux_perf::Config {
        target: app.target,
        app: app.name.clone(),
        bundle_id: app.bundle_id,
        version: app.version,
        seconds: options.seconds,
        interval: Duration::from_millis(options.interval_ms),
        signposts: options.signposts,
        diagnostics: app.diagnostics,
    };
    if output != OutputMode::Quiet {
        eprintln!(
            "{}",
            messages
                .recording
                .replace("{seconds}", &options.seconds.to_string())
                .replace("{app}", &app.name)
        );
    }
    let recording = cmux_perf::record(&config, &dir.join("trace.json"));
    if let Err(error) = recording.write(&dir) {
        let message = messages
            .write_failed
            .replace("{dir}", &dir.display().to_string())
            .replace("{error}", &error.to_string());
        return super::app::failure("perf.write_failed", &message, output, 1);
    }
    match output {
        OutputMode::Human => {
            let mut stdout = std::io::stdout().lock();
            let _ = stdout.write_all(cmux_perf::summary::text(&recording.summary).as_bytes());
            let _ = stdout.flush();
            0
        }
        _ => super::wire::print_local_success(&recording.summary, output),
    }
}

/// The app to record and what its bundle says about itself.
#[derive(Debug)]
struct App {
    target: Target,
    name: String,
    bundle_id: Option<String>,
    version: Option<String>,
    diagnostics: Option<PathBuf>,
}

fn resolve(app: Option<&str>) -> Result<App, String> {
    let messages = &crate::localization::catalog().perf;
    if let Some(text) = app {
        if let Ok(pid) = text.parse::<i32>() {
            let Some(exe) = process::executable(pid) else {
                return Err(messages.no_process.replace("{pid}", text));
            };
            return Ok(match crate::app_identity::containing_app_bundle(&exe) {
                Some(bundle) => from_bundle(bundle, Some(pid)),
                None => from_bin(&exe, Some(pid)),
            });
        }
        let path = std::fs::canonicalize(text).unwrap_or_else(|_| PathBuf::from(text));
        if path.extension().is_none_or(|extension| extension != "app") || !path.is_dir() {
            return Err(messages.not_an_app.replace("{path}", text));
        }
        return Ok(from_bundle(path, None));
    }
    let own = std::env::current_exe().and_then(std::fs::canonicalize).ok();
    if let Some(bundle) = own.as_deref().and_then(crate::app_identity::containing_app_bundle) {
        return Ok(from_bundle(bundle, None));
    }
    if cfg!(target_os = "macos") {
        return newest_running_app()
            .map(|bundle| from_bundle(bundle, None))
            .ok_or_else(|| messages.no_app.to_owned());
    }
    own.map(|exe| from_bin(&exe, None)).ok_or_else(|| messages.no_app.to_owned())
}

/// The newest running process of a cmux bundle: `*.app/Contents/MacOS/*` with `Contents/Resources/bin/cmux`.
fn newest_running_app() -> Option<PathBuf> {
    process::processes()
        .into_iter()
        .filter(|candidate| candidate.command.contains(".app/Contents/MacOS/"))
        .filter_map(|candidate| {
            let exe = process::executable(candidate.pid)?;
            let bundle = crate::app_identity::containing_app_bundle(&exe)?;
            let is_main = exe.parent() == Some(bundle.join("Contents/MacOS").as_path());
            let is_cmux = bundle.join("Contents/Resources/bin/cmux").is_file()
                && bundle_string(&bundle, "CFBundleIdentifier")
                    .is_some_and(|id| id.starts_with("com.cmuxterm.app"));
            (is_main && is_cmux).then_some((candidate.start, bundle))
        })
        .max_by_key(|(start, _)| *start)
        .map(|(_, bundle)| bundle)
}

fn bundle_string(bundle: &Path, key: &str) -> Option<String> {
    let info = plist::Value::from_file(bundle.join("Contents/Info.plist")).ok()?;
    info.as_dictionary()?.get(key)?.as_string().map(str::to_owned)
}

fn from_bundle(bundle: PathBuf, pid: Option<i32>) -> App {
    let bundle = std::fs::canonicalize(&bundle).unwrap_or(bundle);
    let bundle_id = bundle_string(&bundle, "CFBundleIdentifier");
    let home = std::env::var_os("HOME").map(PathBuf::from).unwrap_or_default();
    let diagnostics = bundle_id
        .as_ref()
        .map(|id| home.join("Library/Application Support").join(id).join("diagnostics"));
    App {
        name: bundle
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_default(),
        version: bundle_string(&bundle, "CFBundleShortVersionString"),
        bundle_id,
        diagnostics,
        target: Target { root: bundle, pid },
    }
}

/// A cmux outside any bundle (Linux): the folder above its `bin`.
fn from_bin(exe: &Path, pid: Option<i32>) -> App {
    let root = exe.parent().and_then(Path::parent).unwrap_or(Path::new("/")).to_path_buf();
    App {
        name: exe.file_name().map(|name| name.to_string_lossy().into_owned()).unwrap_or_default(),
        bundle_id: None,
        version: None,
        diagnostics: None,
        target: Target { root, pid },
    }
}

#[cfg(test)]
mod tests;
