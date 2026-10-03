//! `cmux task …`: the Tasks verbs (plans/cmux-next/tasks.md, decision T4).
//!
//! The verbs, their flags and exit codes come from the Tasks catalog in
//! `cmux-tasks`; this module only forwards. Only the words before `task`
//! are cmux global options: everything after `task` goes to the Tasks
//! parser unchanged (`task delegate --session asess_…` is a Tasks flag).
//! Before `task`, `--json`, `--jsonl` and `--idempotency-key` are forwarded;
//! the session-routing options do not apply to Tasks and are refused.
//! `task open` and `task mine --open-pane` act on the app's Tasks pane: they
//! run the app actions with those CLI names.

use super::{OutputMode, parse_globals};

/// Exit status for a usage error (the Tasks noun's code 2).
const USAGE: i32 = 2;

/// `Some(exit status)` when the command word is `task`.
pub(super) fn run_if_requested(args: &[String]) -> Option<i32> {
    let index = command_index(args)?;
    let (global, command) = match parse_globals(&args[..index]) {
        Ok(parsed) => parsed,
        Err((error, _)) => {
            eprintln!("cmux task: {}", error.0);
            return Some(USAGE);
        }
    };
    if !command.is_empty() {
        return None;
    }
    let refused = [
        ("--socket", global.socket.is_some()),
        ("--session", global.session.is_some()),
        ("--machine", global.machine.is_some()),
        ("--app-socket", global.app_socket.is_some()),
        ("--all-sessions", global.all_sessions),
        ("--quiet", global.output == OutputMode::Quiet),
    ];
    if let Some((flag, _)) = refused.iter().find(|(_, given)| *given) {
        eprintln!("cmux task: {flag} does not apply to Tasks; see `cmux task --help`");
        return Some(USAGE);
    }
    if let Some((name, rest)) = app_verb(&args[index + 1..]) {
        return Some(super::app::run_cli_action(&global, name, &rest).unwrap_or_else(|| {
            eprintln!("cmux task: `{name}` needs the running cmux app; open cmux and retry");
            OWNER_UNREACHABLE
        }));
    }
    let forwarded = forwarded(global.output, global.idempotency_key, &args[index..]);
    Some(i32::from(cmux_tasks::cli::run_code(&forwarded)))
}

/// Exit status when the owner (here the app) does not answer (the Tasks
/// noun's code 5).
const OWNER_UNREACHABLE: i32 = 5;

/// The verbs that act on the app's Tasks pane, not on Tasks data: `task open`
/// and `task mine --open-pane` run the app actions with those CLI names
/// (decision T4: one noun, no `cmux tasks`). `None` for every data verb.
fn app_verb(words: &[String]) -> Option<(&'static str, Vec<String>)> {
    let (verb, rest) = words.split_first()?;
    match verb.as_str() {
        "open" => Some(("task open", rest.to_vec())),
        "mine" if rest.iter().any(|w| w == "--open-pane") => {
            Some(("task mine", rest.iter().filter(|w| *w != "--open-pane").cloned().collect()))
        }
        _ => None,
    }
}

/// The index of `task` when it is the first word that is not a global
/// option or an option value.
fn command_index(args: &[String]) -> Option<usize> {
    let mut index = 0;
    while index < args.len() {
        let arg = args[index].as_str();
        if matches!(
            arg,
            "--socket" | "--session" | "--machine" | "--app-socket" | "--idempotency-key"
        ) {
            index += 2;
            continue;
        }
        if arg.starts_with('-') {
            index += 1;
            continue;
        }
        return (arg == "task").then_some(index);
    }
    None
}

fn forwarded(output: OutputMode, key: Option<String>, command: &[String]) -> Vec<String> {
    let mut args = Vec::with_capacity(command.len() + 3);
    if matches!(output, OutputMode::Json | OutputMode::JsonLines) {
        args.push("--json".to_owned());
    }
    if let Some(key) = key {
        args.push("--idempotency-key".to_owned());
        args.push(key);
    }
    args.extend(command.iter().cloned());
    args
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(words: &[&str]) -> Vec<String> {
        words.iter().map(|w| (*w).to_owned()).collect()
    }

    #[test]
    fn other_commands_are_not_tasks() {
        assert_eq!(run_if_requested(&strings(&["workspace", "list"])), None);
        assert_eq!(run_if_requested(&strings(&["tasks"])), None);
        assert_eq!(run_if_requested(&strings(&["workspace", "task"])), None);
    }

    #[test]
    fn globals_before_task_are_forwarded() {
        let command = strings(&["task", "list"]);
        let forwarded = forwarded(OutputMode::Json, Some("idem_1".to_owned()), &command);
        assert_eq!(forwarded, strings(&["--json", "--idempotency-key", "idem_1", "task", "list"]));
        let plain = forwarded_plain();
        assert_eq!(plain, strings(&["task", "get", "CMX-1"]));
    }

    fn forwarded_plain() -> Vec<String> {
        forwarded(OutputMode::Human, None, &strings(&["task", "get", "CMX-1"]))
    }

    /// Review finding: options after `task` belong to the Tasks parser
    /// (`task delegate --session asess_…` names the agent session).
    #[test]
    fn words_after_task_are_not_cmux_globals() {
        let args = strings(&["--json", "task", "delegate", "CMX-1", "--session", "asess_mine"]);
        assert_eq!(command_index(&args), Some(1));
        assert_eq!(command_index(&strings(&["--session", "s1", "task", "list"])), Some(2));
        assert_eq!(command_index(&strings(&["--idempotency-key", "k", "task"])), Some(2));
    }

    #[test]
    fn session_routing_options_before_task_are_refused() {
        let args = strings(&["--session", "s1", "task", "list"]);
        assert_eq!(run_if_requested(&args), Some(USAGE));
        assert_eq!(run_if_requested(&strings(&["--quiet", "task", "list"])), Some(USAGE));
    }

    #[test]
    fn pane_verbs_go_to_the_app_and_data_verbs_to_tasks() {
        assert_eq!(app_verb(&strings(&["open"])), Some(("task open", vec![])));
        assert_eq!(
            app_verb(&strings(&["mine", "--open-pane", "--json"])),
            Some(("task mine", strings(&["--json"])))
        );
        assert_eq!(app_verb(&strings(&["mine"])), None, "plain `task mine` lists data");
        assert_eq!(app_verb(&strings(&["list"])), None);
        assert_eq!(app_verb(&[]), None);
    }

    #[test]
    fn task_help_runs_through_the_tasks_parser() {
        let dir = std::env::temp_dir().join(format!("cmux-task-cli-{}", std::process::id()));
        let data = dir.to_string_lossy().into_owned();
        assert_eq!(run_if_requested(&strings(&["task", "--data", &data, "--help"])), Some(0));
        assert_eq!(run_if_requested(&strings(&["task", "--data", &data, "frobnicate"])), Some(2));
        assert!(!dir.exists(), "usage errors create nothing");
    }
}
