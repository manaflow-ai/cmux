//! `cmux agent-config subagents list`: Claude Code's subagents (`.claude/agents`), which one of a
//! name Claude Code uses, and why a file is skipped (cmux-agent-customize `subagents`).

use std::path::PathBuf;

use cmux_agent_customize::Homes;
use cmux_agent_customize::subagents::{self, Listing, Scope};
use serde_json::{Value, json};

use super::super::OutputMode;

pub(in crate::cli) const USAGE: &str = "\
cmux agent-config subagents: Claude Code's subagents, in its own folders.

  cmux agent-config subagents [list] [--cwd DIR] [--json]
      Every subagent Claude Code loads: the project's .claude/agents (the working folder's, or
      DIR's, up to its git root), ~/.claude/agents and each enabled plugin's agents/. One name
      used twice: project wins over user over plugin, and the loser shows the winner's file.
      Shows name, scope, tools (none: every tool), model, color, file, and files Claude Code skips.

Exit codes: 0 ok, 2 bad arguments.";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) enum Request {
    Help,
    List { cwd: Option<PathBuf> },
}

/// `words` start after `subagents`.
pub(in crate::cli) fn parse(words: &[String]) -> Result<Request, String> {
    // A bare `subagents` (or one that starts with a flag) lists.
    let rest = match words.split_first() {
        None => words,
        Some((verb, rest)) => match verb.as_str() {
            "-h" | "--help" | "help" => return Ok(Request::Help),
            "list" | "ls" => rest,
            flag if flag.starts_with('-') => words,
            other => return Err(format!("unknown subagents verb {other:?}: list")),
        },
    };
    let mut cwd = None;
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            "--cwd" | "--project" => {
                cwd = Some(PathBuf::from(words.next().ok_or("--cwd needs a folder")?));
            }
            "-h" | "--help" => return Ok(Request::Help),
            other => return Err(format!("subagents list does not take {other:?}")),
        }
    }
    Ok(Request::List { cwd })
}

/// `Some(exit code)` when `args` is `agent-config subagents ...`.
pub(in crate::cli) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::super::parse_action_globals(args).ok()?;
    let rest = command_args
        .split_first()
        .filter(|(scope, _)| *scope == "agent-config")
        .map(|(_, rest)| rest)?;
    let (json_flag, rest) = super::mcp::take_json_flag(rest);
    let (part, words) = rest.split_first()?;
    if !matches!(part.as_str(), "subagents" | "agents") {
        return None;
    }
    let json_out = json_flag || matches!(global.output, OutputMode::Json | OutputMode::JsonLines);
    let output = if json_out { OutputMode::Json } else { global.output };
    let request = match parse(words) {
        Ok(request) => request,
        Err(what) => {
            return Some(super::super::scope_usage_failure(output, "agent-config", &what, USAGE));
        }
    };
    Some(run(output, request))
}

fn run(output: OutputMode, request: Request) -> i32 {
    let Request::List { cwd } = request else {
        println!("{USAGE}");
        return 0;
    };
    let Some(homes) = Homes::from_env() else {
        return super::super::wire::print_local_error(
            &json!({"code": "home.missing", "message": "HOME is not set", "retryable": false}),
            output,
            1,
        );
    };
    let started = std::time::Instant::now();
    let cwd = cwd.or_else(|| std::env::current_dir().ok());
    let listing = subagents::list(&homes, cwd.as_deref());
    if output == OutputMode::Json {
        let mut value = serde_json::to_value(&listing).unwrap_or(Value::Null);
        if let Value::Object(map) = &mut value {
            map.insert(
                "counts".into(),
                json!({"listed": listing.subagents.len(), "active": listing.active_count()}),
            );
            let ms = started.elapsed().as_secs_f64() * 1000.0;
            map.insert("elapsedMs".into(), json!((ms * 10.0).round() / 10.0));
        }
        println!("{value}");
    } else if output != OutputMode::Quiet {
        print!("{}", table(&listing));
    }
    0
}

/// The human table: scope, on, name, model, tools, description (one line).
pub(in crate::cli) fn table(listing: &Listing) -> String {
    let width = listing.subagents.iter().map(|a| a.name.chars().count()).max().unwrap_or(4).max(4);
    let mut out = format!(
        "{:7}  {:3}  {:width$}  {:8}  {:16}  DESCRIPTION\n",
        "SCOPE", "ON", "NAME", "MODEL", "TOOLS"
    );
    for agent in &listing.subagents {
        let scope = match agent.scope {
            Scope::Project => "project",
            Scope::User => "user",
            Scope::Plugin => "plugin",
        };
        let tools = if agent.tools.is_empty() { "all".to_owned() } else { agent.tools.join(",") };
        let tools = clip(&tools, 16);
        let line = clip(&agent.description.split_whitespace().collect::<Vec<_>>().join(" "), 72);
        out.push_str(&format!(
            "{scope:<7}  {:3}  {:width$}  {:8}  {tools:16}  {line}\n",
            if agent.active { "on" } else { "off" },
            agent.name,
            agent.model.as_deref().unwrap_or("inherit"),
        ));
        if let Some(winner) = &agent.shadowed_by {
            out.push_str(&format!("{:16}↳ hidden by {}\n", "", winner.display()));
        }
    }
    for problem in &listing.problems {
        out.push_str(&format!(
            "! Claude Code skips {}: {}\n",
            problem.path.display(),
            problem.message
        ));
    }
    out.push_str(&format!(
        "Claude Code: {} subagents on, {} listed.\n",
        listing.active_count(),
        listing.subagents.len()
    ));
    out
}

fn clip(text: &str, max: usize) -> String {
    if text.chars().count() > max {
        format!("{}…", text.chars().take(max.saturating_sub(1)).collect::<String>())
    } else {
        text.to_owned()
    }
}

#[cfg(test)]
#[path = "subagents_tests.rs"]
mod tests;
