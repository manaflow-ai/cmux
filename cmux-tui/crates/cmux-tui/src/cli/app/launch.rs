//! `cmux app launch [--on MACHINE] APP [-- ARGS...]` and `cmux app list [--on MACHINE]`: open an
//! app on this machine or a connected one, and say what can be opened and what runs there.
//!
//! Leo (2026-11-16): "it's not like i can just easily say "launch this app" from my comuputer
//! (maybe that should be a feature)". Design: cmuxterm-hq docs/design/remote-screen-share-zero-touch.md, Z6.
//!
//! Both run this binary's acpmux (`cmux acp app launch|list`, as chat start does) with the same
//! options; `--on` is acpmux's `--machine`. The app's arguments go as separate argv elements, never
//! through a shell. acpmux's exit code, stdout and stderr pass through unchanged: 0 ok, 1 the
//! machine answered no, 2 bad request, 3 not reached, not allowed or its acpmux too old.

use std::time::Duration;

#[cfg(test)]
use cmux_json::JsonSet as _;
use cmux_process::{Command as Process, Stdio};
use serde_json::json;

use super::{AppCommand, GlobalArgs, OutputMode, UsageError};

/// What acpmux bounds a list by (`LIST_BUDGET`, server/app_launch.rs).
// timeout: mirrors acpmux's LIST_BUDGET so the CLI never outwaits the daemon.
const LIST_BUDGET: Duration = Duration::from_secs(20);
/// Past acpmux's own deadline, how long before the child is ended.
// timeout: on top of acpmux's own deadline, only for a hung child.
const OUTER_SLACK: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) enum Command {
    Launch {
        on: Option<String>,
        activate: bool,
        hidden: bool,
        new: bool,
        wait: Option<u64>,
        app: String,
        args: Vec<String>,
    },
    List {
        on: Option<String>,
        all: bool,
    },
}

fn usage() -> UsageError {
    UsageError::new(crate::localization::catalog().app_control.app_launch_usage)
}

/// `rest` starts with `launch` or `list`.
pub(super) fn parse(rest: &[String]) -> Result<AppCommand, UsageError> {
    let launch = rest.first().is_some_and(|verb| verb == "launch");
    let words = rest.get(1..).unwrap_or_default();
    let (options, args) = match words.iter().position(|word| word == "--") {
        Some(at) if launch => {
            let (options, rest) = words.split_at(at);
            (options, rest.get(1..).unwrap_or_default().to_vec())
        }
        Some(_) => return Err(usage()),
        None => (words, Vec::new()),
    };
    let mut on = None;
    let (mut activate, mut hidden, mut new, mut all) = (false, false, false, false);
    let mut wait = None;
    let mut app = None;
    let mut index = 0;
    while index < options.len() {
        let Some(word) = options.get(index).map(String::as_str) else { break };
        let (name, inline) = match word.split_once('=') {
            Some((name, value)) if name.starts_with("--") => (name, Some(value.to_owned())),
            _ => (word, None),
        };
        let mut value = || -> Result<String, UsageError> {
            let value = match inline.clone() {
                Some(value) => value,
                None => {
                    index += 1;
                    options.get(index).cloned().ok_or_else(usage)?
                }
            };
            if value.is_empty() || value.starts_with('-') { Err(usage()) } else { Ok(value) }
        };
        match name {
            "--on" | "--machine" => on = Some(value()?),
            "--wait" if launch => {
                wait = Some(value()?.parse::<u64>().map_err(|_| usage())?);
            }
            "--activate" if launch && inline.is_none() => activate = true,
            "--hidden" if launch && inline.is_none() => hidden = true,
            "--new" if launch && inline.is_none() => new = true,
            "--all" if !launch && inline.is_none() => all = true,
            _ if launch && app.is_none() && !word.starts_with('-') && !word.is_empty() => {
                app = Some(word.to_owned());
            }
            _ => return Err(usage()),
        }
        index += 1;
    }
    Ok(AppCommand::AppLaunch(if launch {
        Command::Launch { on, activate, hidden, new, wait, app: app.ok_or_else(usage)?, args }
    } else {
        Command::List { on, all }
    }))
}

impl Command {
    /// The words after `cmux acp`: `[--json] app launch|list [options] [APP] [-- ARGS...]`.
    pub(in crate::cli) fn acpmux_words(&self, json: bool) -> Vec<String> {
        let mut words: Vec<String> = Vec::new();
        if json {
            words.push("--json".into());
        }
        let machine = |words: &mut Vec<String>, on: &Option<String>| {
            if let Some(on) = on {
                words.extend(["--machine".into(), on.clone()]);
            }
        };
        match self {
            Self::Launch { on, activate, hidden, new, wait, app, args } => {
                words.extend(["app".into(), "launch".into()]);
                machine(&mut words, on);
                for (flag, set) in [("--activate", activate), ("--hidden", hidden), ("--new", new)]
                {
                    if *set {
                        words.push(flag.into());
                    }
                }
                if let Some(wait) = wait {
                    words.extend(["--wait".into(), wait.to_string()]);
                }
                words.push(app.clone());
                if !args.is_empty() {
                    words.push("--".into());
                    words.extend(args.iter().cloned());
                }
            }
            Self::List { on, all } => {
                words.extend(["app".into(), "list".into()]);
                machine(&mut words, on);
                if *all {
                    words.push("--all".into());
                }
            }
        }
        words
    }

    /// How long acpmux may take before the child is ended: its own deadline plus 30 s.
    pub(in crate::cli) fn deadline(&self) -> Duration {
        let own = match self {
            Self::Launch { wait, .. } => wait
                .map(Duration::from_secs)
                .unwrap_or(acpmux::app_launch::DEFAULT_WAIT)
                .min(acpmux::app_launch::MAX_WAIT),
            Self::List { .. } => LIST_BUDGET,
        };
        own + OUTER_SLACK
    }

    /// The daemon request acpmux sends for this (its `cli/app.rs` `launch_params`; empty `args`
    /// left out, as the daemon reads them), which the palette's catalog request row must match.
    #[cfg(test)]
    pub(in crate::cli) fn request(&self) -> (&'static str, serde_json::Value) {
        match self {
            Self::Launch { on, activate, hidden, new, wait, app, args } => {
                let mut p = json!({ "app": app });
                if !args.is_empty() {
                    p.set("args", json!(args));
                }
                for (key, set) in [("activate", activate), ("hidden", hidden), ("new", new)] {
                    if *set {
                        p.set(key, json!(true));
                    }
                }
                if let Some(wait) = wait {
                    p.set("waitMs", json!(wait.saturating_mul(1000)));
                }
                if let Some(on) = on {
                    p.set("machine", json!(on));
                }
                ("_acpmux/app_launch", p)
            }
            Self::List { on, .. } => (
                "_acpmux/app_list",
                on.as_ref().map_or_else(|| json!({}), |m| json!({"machine": m})),
            ),
        }
    }

    fn on(&self) -> Option<&str> {
        match self {
            Self::Launch { on, .. } | Self::List { on, .. } => on.as_deref(),
        }
    }

    /// With `machine` (the global `--machine`, which the app scope's parsing takes before this
    /// sees it) as the target when there is no `--on`.
    pub(in crate::cli) fn or_on(mut self, machine: Option<&str>) -> Self {
        let (Self::Launch { on, .. } | Self::List { on, .. }) = &mut self;
        if on.is_none() {
            *on = machine.map(str::to_owned);
        }
        self
    }
}

/// Runs `cmux acp WORDS` with this process's stdout and stderr; its exit code is the answer.
pub(super) fn run(global: &GlobalArgs, command: &Command) -> i32 {
    let command = &command.clone().or_on(global.machine.as_deref());
    let json_out = global.output == OutputMode::Json;
    let words = command.acpmux_words(json_out);
    let words: Vec<&str> = words.iter().map(String::as_str).collect();
    let limit = command.deadline();
    let on = command.on().map_or_else(String::new, |on| format!(" --on {on}"));
    let fail = |message: String, next: String| {
        if json_out {
            println!(
                "{}",
                json!({"ok": false, "reason": "app.unreachable", "error": message, "next": next})
            );
        } else {
            eprintln!("{message}");
            eprintln!("next: {next}");
        }
        3
    };
    let exe = match std::env::current_exe() {
        Ok(exe) => exe,
        Err(error) => return fail(format!("cannot find cmux: {error}"), "`cmux version`".into()),
    };
    let mut process = Process::new(exe);
    process.arg0("cmux");
    let mut process = super::super::chat_start::joined::acp_command(process, &words);
    process.stdin(Stdio::null()).stdout(Stdio::inherit()).stderr(Stdio::inherit());
    let mut child = match process.spawn() {
        Ok(child) => child,
        Err(error) => {
            return fail(format!("cannot run cmux acp: {error}"), "`cmux acp host ls`".into());
        }
    };
    match child.wait_timeout(limit) {
        // A signal has no code: it did not answer.
        Ok(Some(status)) => status.code().unwrap_or(3),
        // Dropping the child ends it (SIGTERM, then SIGKILL).
        Ok(None) => {
            drop(child);
            fail(
                format!("acpmux did not answer within {} s", limit.as_secs()),
                format!("`cmux acp host ls`, then `cmux app list{on}`"),
            )
        }
        Err(error) => {
            drop(child);
            fail(format!("cmux acp did not finish: {error}"), "`cmux acp host ls`".into())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(words: &[&str]) -> Vec<String> {
        words.iter().map(|word| (*word).to_owned()).collect()
    }

    fn parsed(words: &[&str]) -> Command {
        match parse(&strings(words)) {
            Ok(AppCommand::AppLaunch(command)) => command,
            other => panic!("{words:?}: {other:?}"),
        }
    }

    #[test]
    fn launch_maps_on_to_machine_and_passes_every_option() {
        let command = parsed(&[
            "launch",
            "--on",
            "mini",
            "--activate",
            "--hidden",
            "--new",
            "--wait",
            "20",
            "Safari",
        ]);
        assert_eq!(
            command.acpmux_words(true),
            strings(&[
                "--json",
                "app",
                "launch",
                "--machine",
                "mini",
                "--activate",
                "--hidden",
                "--new",
                "--wait",
                "20",
                "Safari"
            ])
        );
        assert_eq!(command.deadline(), Duration::from_secs(50));
    }

    #[test]
    fn without_on_it_is_this_machine() {
        let command = parsed(&["launch", "Safari"]);
        assert_eq!(command.acpmux_words(false), strings(&["app", "launch", "Safari"]));
        assert_eq!(command.deadline(), Duration::from_secs(45));
    }

    #[test]
    fn the_global_machine_is_the_target_when_there_is_no_on() {
        let command = parsed(&["list"]).or_on(Some("mini"));
        assert_eq!(command.acpmux_words(false), strings(&["app", "list", "--machine", "mini"]));
    }

    #[test]
    fn arguments_after_the_separator_stay_one_argv_element_each() {
        let command =
            parsed(&["launch", "--on=mini", "Terminal", "--", "; rm -rf ~", "$(id)", "--hidden"]);
        assert_eq!(
            command.acpmux_words(false),
            strings(&[
                "app",
                "launch",
                "--machine",
                "mini",
                "Terminal",
                "--",
                "; rm -rf ~",
                "$(id)",
                "--hidden"
            ])
        );
        let Command::Launch { hidden, args, .. } = command else { panic!() };
        assert!(!hidden);
        assert_eq!(args, strings(&["; rm -rf ~", "$(id)", "--hidden"]));
    }

    #[test]
    fn list_passes_all_and_on() {
        let command = parsed(&["list", "--on", "mini", "--all"]);
        assert_eq!(
            command.acpmux_words(true),
            strings(&["--json", "app", "list", "--machine", "mini", "--all"])
        );
        assert_eq!(command.deadline(), Duration::from_secs(50));
    }

    #[test]
    fn wrong_requests_are_usage_errors() {
        for words in [
            &["launch"][..],
            &["launch", "A", "B"],
            &["launch", "--on"],
            &["launch", "--on", "--hidden", "A"],
            &["launch", "--wait", "soon", "A"],
            &["launch", "--bogus", "A"],
            &["launch", "--", "A"],
            &["list", "--hidden"],
            &["list", "Safari"],
            &["list", "--", "x"],
        ] {
            assert!(parse(&strings(words)).is_err(), "{words:?}");
        }
    }
}
