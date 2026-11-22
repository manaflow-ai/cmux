//! `cmux agent move SESSION --machine NAME|auto`.
//!
//! The move implementation belongs to acpmux (`session move`).  This small
//! alias keeps the public `agent` vocabulary while forwarding every move
//! option to that one implementation, so the menu, palette and CLI cannot
//! drift apart.

use std::time::Duration;

use cmux_process::Command;

use super::{GlobalArgs, UsageError, chat_start::joined, wire};

const MOVE_DEADLINE: Duration = Duration::from_secs(20 * 60);

#[derive(Debug, PartialEq, Eq)]
struct MoveRequest {
    sessions: Vec<String>,
    machine: String,
    options: Vec<String>,
}

/// Handles the alias before the noun-first parser sees `agent move`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command) = super::parse_globals(args).ok()?;
    if command.first().map(String::as_str) != Some("agent")
        || command.get(1).map(String::as_str) != Some("move")
    {
        return None;
    }
    if command.iter().any(|word| word == "--help" || word == "-h") {
        println!(
            "Usage: cmux agent move SESSION [SESSION…] --machine NAME|auto [--after-turn|--interrupt] [--leave-dirty] [--carry-changes] [--cwd PATH] [--from MACHINE] [--dry-run]"
        );
        return Some(0);
    }
    let request = match parse_request(&global, command.get(2..).unwrap_or_default()) {
        Ok(request) => request,
        Err(error) => return Some(usage(&global, &error.0)),
    };

    let mut words = vec!["session".to_owned(), "move".to_owned()];
    words.extend(request.sessions);
    words.push("--machine".to_owned());
    words.push(request.machine);
    words.extend(request.options);
    // run_acp parses the final JSON value, but acpmux otherwise defaults to a
    // human report with no JSON to return to this command.
    words.push("--json".to_owned());
    let refs: Vec<&str> = words.iter().map(String::as_str).collect();
    let executable = match std::env::current_exe() {
        Ok(executable) => executable,
        Err(error) => {
            return Some(wire::print_local_error(
                &serde_json::json!({"code":"acpmux.unreachable","message":format!("cannot find cmux: {error}"),"details":{},"retryable":true}),
                global.output,
                3,
            ));
        }
    };
    let mut command = Command::new(executable);
    command.arg0("cmux");
    let command = joined::acp_command(command, &refs);
    match joined::run_acp(command, &refs, None, MOVE_DEADLINE) {
        Ok(value) => Some(wire::print_local_success(&value, global.output)),
        Err(error) => Some(wire::print_local_error(&error, global.output, 1)),
    }
}

fn parse_request(global: &GlobalArgs, args: &[String]) -> Result<MoveRequest, UsageError> {
    let machine = global
        .machine
        .clone()
        .ok_or_else(|| UsageError::new("agent move requires --machine NAME|auto"))?;
    if machine.trim().is_empty() {
        return Err(UsageError::new("agent move requires a non-empty --machine value"));
    }
    let mut sessions = Vec::new();
    let mut options = Vec::new();
    let mut words = args.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            "--interrupt" | "--after-turn" | "--leave-dirty" | "--carry-changes" | "--dry-run" => {
                options.push(word.clone());
            }
            "--cwd" | "--from" => {
                let value = words
                    .next()
                    .filter(|value| !value.starts_with('-'))
                    .ok_or_else(|| UsageError::new(format!("agent move: {word} needs a value")))?;
                options.push(word.clone());
                options.push(value.clone());
            }
            value if value.starts_with('-') => {
                return Err(UsageError::new(format!("agent move: unknown option {value}")));
            }
            session => sessions.push(session.to_owned()),
        }
    }
    if sessions.is_empty() {
        return Err(UsageError::new("agent move requires at least one SESSION"));
    }
    Ok(MoveRequest { sessions, machine, options })
}

fn usage(global: &GlobalArgs, message: &str) -> i32 {
    let error = serde_json::json!({
        "code": "usage.invalid",
        "message": message,
        "details": {},
        "retryable": false,
    });
    wire::print_local_error(&error, global.output, 2)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn global(machine: &str) -> GlobalArgs {
        GlobalArgs { machine: Some(machine.into()), ..GlobalArgs::default() }
    }

    #[test]
    fn parses_machine_and_forwards_move_options_in_order() {
        let request = parse_request(
            &global("gcp-3"),
            &[
                "chat".into(),
                "--interrupt".into(),
                "--cwd".into(),
                "/tmp/chat".into(),
                "--from".into(),
                "mini".into(),
                "--dry-run".into(),
            ],
        )
        .unwrap();
        assert_eq!(request.sessions, vec!["chat"]);
        assert_eq!(request.machine, "gcp-3");
        assert_eq!(
            request.options,
            vec!["--interrupt", "--cwd", "/tmp/chat", "--from", "mini", "--dry-run"]
        );
    }

    #[test]
    fn requires_machine_and_session() {
        assert!(parse_request(&GlobalArgs::default(), &["chat".into()]).is_err());
        assert!(parse_request(&global("auto"), &[]).is_err());
    }

    #[test]
    fn global_scan_keeps_multiple_sessions_before_move_switches() {
        let args = [
            "--json".into(),
            "agent".into(),
            "move".into(),
            "first".into(),
            "second".into(),
            "--interrupt".into(),
            "--machine".into(),
            "auto".into(),
        ];
        let (global, command) = super::super::parse_globals(&args).expect("globals parse");
        assert!(matches!(global.output, super::super::OutputMode::Json));
        assert_eq!(global.machine.as_deref(), Some("auto"));
        assert_eq!(command, vec!["agent", "move", "first", "second", "--interrupt"]);
    }
}
