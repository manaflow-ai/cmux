//! Runs a catalog-gated TypeScript code-mode script through the bundled runner.

use std::env;
use std::path::PathBuf;
use std::process::{Command, ExitStatus, Stdio};

use super::{GlobalArgs, UsageError};

#[derive(Clone, Debug)]
pub(super) struct Plan {
    pub(super) script: String,
    pub(super) args: Vec<String>,
    pub(super) global: GlobalArgs,
}

pub(super) fn command(
    args: &[String],
    global: GlobalArgs,
) -> Result<Option<super::command::ParsedCommand>, UsageError> {
    if args.first().map(String::as_str) != Some("run") {
        return Ok(None);
    }
    if args[1..].iter().any(|arg| matches!(arg.as_str(), "-h" | "--help")) {
        return Ok(Some(super::command::ParsedCommand::Help(Some("run".to_owned()))));
    }
    Ok(Some(super::command::ParsedCommand::CodeMode(parse(&args[1..], global)?)))
}

pub(super) fn parse(args: &[String], global: GlobalArgs) -> Result<Plan, UsageError> {
    let Some(script) = args.first() else {
        return Err(UsageError::new("cmux run needs a TypeScript script path"));
    };
    if global.machine.is_some() {
        return Err(UsageError::new(
            "cmux run does not support --machine; use a machine-scoped socket",
        ));
    }
    let args = args[1..].strip_prefix(&["--".to_owned()]).unwrap_or(&args[1..]).to_vec();
    Ok(Plan { script: script.clone(), args, global })
}

pub(super) fn help() -> &'static str {
    "USAGE\n  cmux run <script.ts> [-- <script args>]\n\nRun a TypeScript cmux script in the locked-down code-mode sandbox.\n"
}

pub(super) fn run(plan: Plan) -> i32 {
    let runner = std::env::current_exe()
        .ok()
        .and_then(|path| path.parent().map(|dir| dir.join("cmux-code-mode-run")))
        .filter(|path| path.is_file())
        .unwrap_or_else(|| PathBuf::from("cmux-code-mode-run"));
    let mut command = Command::new(runner);
    command.arg(&plan.script).args(&plan.args);
    command.stdin(Stdio::inherit()).stdout(Stdio::inherit()).stderr(Stdio::inherit());
    if let Some(socket) = plan.global.socket {
        command.env("CMUX_TUI_SOCKET", socket);
    }
    if let Some(session) = plan.global.session {
        command.env("CMUX_TUI_SESSION", session);
    }
    match command.status() {
        Ok(status) => exit_code(status),
        Err(error) => {
            eprintln!("cmux run: cannot start code-mode runner: {error}");
            2
        }
    }
}

fn exit_code(status: ExitStatus) -> i32 {
    status.code().unwrap_or_else(|| {
        eprintln!("cmux run: runner terminated");
        1
    })
}
