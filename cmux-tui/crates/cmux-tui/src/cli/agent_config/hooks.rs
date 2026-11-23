//! `cmux agent-config hooks ...`: every Claude Code and Codex hook, listed by event, turned off
//! and on (cmux-agent-customize `hooks`, which answers its own --help).

use cmux_agent_customize::hooks_cli;
use serde_json::{Value, json};

use super::super::OutputMode;

/// `Some(exit code)` when `args` is `agent-config hooks ...`.
pub(in crate::cli) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::super::parse_action_globals(args).ok()?;
    let rest = command_args
        .split_first()
        .filter(|(scope, _)| *scope == "agent-config")
        .map(|(_, rest)| rest)?;
    let (part, words) = rest.split_first()?;
    if part != "hooks" {
        return None;
    }
    let (json_flag, words) = super::mcp::take_json_flag(words);
    Some(run(&words, json_flag || global.output == OutputMode::Json))
}

fn run(words: &[String], json_out: bool) -> i32 {
    if words.is_empty() || words.iter().any(|w| w == "--help" || w == "-h") {
        println!("{}", hooks_cli::HELP);
        return if words.is_empty() { 2 } else { 0 };
    }
    match hooks_cli::run(words) {
        Ok(value) => {
            if json_out {
                println!("{value}");
            } else if let Some(hooks) = value.get("hooks").and_then(Value::as_array) {
                print!("{}", hooks_cli::render_list(hooks, &value));
            } else {
                println!("{}", serde_json::to_string_pretty(&value).unwrap_or_default());
            }
            0
        }
        Err(error) => {
            if json_out {
                println!("{}", json!({ "ok": false, "why": format!("{error:#}") }));
            } else {
                eprintln!("cmux agent-config hooks: {error:#}");
            }
            1
        }
    }
}
