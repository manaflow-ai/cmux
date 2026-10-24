//! `cmux vm new|ls|get|pause|resume|rm|exec`: the cmux VM API (vm.cmux.dev)
//! from the cmux-next CLI. It adds no second client: each verb runs the
//! `cmux-vm` CLI (workers/cmux-vm/cli), which owns the API key, base URL,
//! team and typed refusals (exit 12 is a 402, 16 a quota). `--json` is
//! passed through. Opening a VM as a workspace is an app action
//! (`cmux cloud new-workspace`), not a CLI verb.

#[cfg(test)]
mod tests;

use std::ffi::OsString;

use super::{OutputMode, UsageError};

/// Override for the `cmux-vm` binary (tests, unusual installs).
const BIN_ENV: &str = "CMUX_VM_BIN";

/// `Some(args after "vm")` when `command_args` start with `vm`.
pub(super) fn split(command_args: &[String]) -> Option<&[String]> {
    let (first, rest) = command_args.split_first()?;
    (first == "vm").then_some(rest)
}

/// The `cmux-vm` argument list for `cmux vm <rest>`.
pub(super) fn plan(rest: &[String], output: OutputMode) -> Result<Vec<String>, UsageError> {
    let Some((verb, tail)) = rest.split_first() else {
        return Err(UsageError::new(
            "cmux vm needs a verb: new, ls, get, pause, resume, rm, exec (see `cmux vm --help`)",
        ));
    };
    let mapped = match verb.as_str() {
        "-h" | "--help" | "help" => {
            let mut help = vec!["--help".to_owned()];
            help.extend(tail.iter().cloned());
            return Ok(help);
        }
        "new" | "create" => "create",
        "ls" | "list" => "list",
        "rm" | "delete" => "delete",
        "get" | "pause" | "resume" | "start" | "stop" | "exec" | "fork" | "snapshot" => {
            verb.as_str()
        }
        "workspace" => {
            return Err(UsageError::new(
                "a VM opens as a workspace through the app: run `cmux cloud new-workspace`",
            ));
        }
        other => return Err(UsageError::new(format!("unknown vm verb \"{other}\""))),
    };
    let mut plan = Vec::new();
    if output == OutputMode::Json {
        plan.push("--json".to_owned());
    }
    plan.push(mapped.to_owned());
    plan.extend(tail.iter().cloned());
    Ok(plan)
}

fn binary() -> OsString {
    if let Some(path) = std::env::var_os(BIN_ENV).filter(|value| !value.is_empty()) {
        return path;
    }
    // Next to this executable (the app bundle), else the PATH.
    if let Some(sibling) = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|dir| dir.join("cmux-vm")))
        .filter(|path| path.is_file())
    {
        return sibling.into_os_string();
    }
    OsString::from("cmux-vm")
}

/// `cmux vm …`. `None` for any other command. The child runs with this
/// process's stdio and its exit status is ours.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::parse_globals(args).ok()?;
    let rest = split(&command_args)?;
    let plan = match plan(rest, global.output) {
        Ok(plan) => plan,
        Err(error) => {
            return Some(super::app::failure(
                "usage.invalid",
                &format!("cmux: {}", error.0),
                global.output,
                2,
            ));
        }
    };
    let program = binary();
    match cmux_process::Command::new(&program).args(plan).status() {
        Ok(status) => Some(status.code().unwrap_or(1)),
        Err(error) => Some(super::app::failure(
            "vm.unavailable",
            &format!("cmux: cannot start {}: {error}", std::path::Path::new(&program).display()),
            global.output,
            127,
        )),
    }
}
