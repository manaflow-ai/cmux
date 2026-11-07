//! `cmux usage report|status|path|clear`: read what opt-in usage recording kept on this
//! machine (cmux-usage). Everything is local files: no socket, no app, no network, so it works
//! with the app closed and on a machine that only runs the daemon or acpmux.
//!
//! Turning recording on or off is the `diagnostics.usageRecording` setting, which the app guards
//! with this Mac's consent record; there is deliberately no `cmux usage on`.

use std::io::Write;
use std::path::PathBuf;

use cmux_usage::{UsageDir, report};
use serde_json::{Value, json};

use super::{GlobalArgs, OutputMode, UsageError};

/// The report's window when `--days` is not given.
const DEFAULT_DAYS: u64 = 7;

#[derive(Debug, PartialEq, Eq)]
pub(super) enum Invocation {
    Help,
    Report { dir: Option<PathBuf>, days: u64 },
    Status { dir: Option<PathBuf> },
    Path { dir: Option<PathBuf> },
    Clear { dir: Option<PathBuf> },
}

/// `cmux usage …`. `None` for any other command.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let (first, rest) = command_args.split_first()?;
    if first != "usage" {
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
    let messages = &crate::localization::catalog().usage_recording;
    if rest.iter().any(|arg| arg == "--help" || arg == "-h") {
        return Ok(Invocation::Help);
    }
    let Some((verb, tail)) = rest.split_first() else { return Ok(Invocation::Help) };
    let mut dir = None;
    let mut days = DEFAULT_DAYS;
    let mut args = tail.iter();
    while let Some(arg) = args.next() {
        let mut value = |flag: &str| {
            args.next()
                .cloned()
                .ok_or_else(|| UsageError::new(app.missing_value.replace("{flag}", flag)))
        };
        match arg.as_str() {
            "--dir" => dir = Some(PathBuf::from(value("--dir")?)),
            "--days" if verb == "report" => {
                let text = value("--days")?;
                days = text.parse::<u64>().ok().filter(|d| *d > 0).ok_or_else(|| {
                    UsageError::new(app.unexpected_argument.replace("{value}", &text))
                })?;
            }
            other => {
                return Err(UsageError::new(app.unexpected_argument.replace("{value}", other)));
            }
        }
    }
    match verb.as_str() {
        "help" => Ok(Invocation::Help),
        "report" => Ok(Invocation::Report { dir, days: days.min(3650) }),
        "status" => Ok(Invocation::Status { dir }),
        "path" => Ok(Invocation::Path { dir }),
        "clear" => Ok(Invocation::Clear { dir }),
        other => Err(UsageError::new(messages.unknown_verb.replace("{verb}", other))),
    }
}

fn run(output: OutputMode, _global: &GlobalArgs, invocation: Invocation) -> i32 {
    let messages = &crate::localization::catalog().usage_recording;
    let folder = |dir: Option<PathBuf>| dir.map(UsageDir::new).or_else(UsageDir::default_location);
    match invocation {
        Invocation::Help => print(output, &json!({ "usage": messages.usage }), messages.usage),
        Invocation::Report { dir, days } => {
            let Some(dir) = folder(dir) else { return no_home(output) };
            let to = cmux_usage::now_ms();
            let from = to.saturating_sub(days * 86_400_000);
            let report = report::build(&dir.read(from), from, to);
            let value = serde_json::to_value(&report).unwrap_or(Value::Null);
            print(output, &value, &report.render())
        }
        Invocation::Status { dir } => {
            let Some(dir) = folder(dir) else { return no_home(output) };
            let (on, since) = (dir.is_enabled(), dir.enabled_since());
            let (files, bytes) = (dir.files().len(), dir.bytes());
            let template = if on { messages.status_on } else { messages.status_off };
            let since_text = since.map(report::local_time).unwrap_or_default();
            let human = template
                .replace("{since}", &since_text)
                .replace("{dir}", &dir.path().display().to_string())
                .replace("{files}", &files.to_string())
                .replace("{kb}", &(bytes / 1024).to_string());
            let value = json!({
                "on": on, "since_ms": since, "dir": dir.path(), "files": files, "bytes": bytes,
            });
            print(output, &value, &human)
        }
        Invocation::Path { dir } => {
            let Some(dir) = folder(dir) else { return no_home(output) };
            let path = dir.path().display().to_string();
            print(output, &json!({ "dir": path }), &format!("{path}\n"))
        }
        Invocation::Clear { dir } => {
            let Some(dir) = folder(dir) else { return no_home(output) };
            let files = dir.files().len();
            if let Err(error) = dir.clear() {
                return super::app::failure(
                    "usage.clear_failed",
                    &format!("cmux: {error}"),
                    output,
                    1,
                );
            }
            let human = messages
                .cleared
                .replace("{files}", &files.to_string())
                .replace("{dir}", &dir.path().display().to_string());
            print(output, &json!({ "deleted": files, "dir": dir.path() }), &human)
        }
    }
}

fn no_home(output: OutputMode) -> i32 {
    let messages = &crate::localization::catalog().usage_recording;
    super::app::failure("usage.no_dir", messages.no_home, output, 2)
}

fn print(output: OutputMode, value: &Value, human: &str) -> i32 {
    match output {
        OutputMode::Quiet => 0,
        OutputMode::Json | OutputMode::JsonLines => super::wire::print_local_success(value, output),
        OutputMode::Human => {
            let mut stdout = std::io::stdout().lock();
            let _ = stdout.write_all(human.as_bytes());
            let _ = stdout.flush();
            0
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn parses_each_verb() {
        assert_eq!(parse(&words(&[])), Ok(Invocation::Help));
        assert_eq!(
            parse(&words(&["report"])),
            Ok(Invocation::Report { dir: None, days: DEFAULT_DAYS })
        );
        assert_eq!(
            parse(&words(&["report", "--days", "2", "--dir", "/tmp/u"])),
            Ok(Invocation::Report { dir: Some(PathBuf::from("/tmp/u")), days: 2 })
        );
        assert_eq!(parse(&words(&["status"])), Ok(Invocation::Status { dir: None }));
        assert_eq!(parse(&words(&["path"])), Ok(Invocation::Path { dir: None }));
        assert_eq!(parse(&words(&["clear"])), Ok(Invocation::Clear { dir: None }));
    }

    #[test]
    fn refuses_bad_input() {
        assert!(parse(&words(&["on"])).is_err());
        assert!(parse(&words(&["report", "--days", "0"])).is_err());
        assert!(parse(&words(&["status", "--days", "3"])).is_err());
        assert!(parse(&words(&["report", "--dir"])).is_err());
    }
}
