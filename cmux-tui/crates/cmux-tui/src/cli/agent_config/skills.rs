//! `cmux agent-config`: Claude Code's and Codex's own configuration, read and changed in the
//! agents' own files (the `cmux-agent-customize` crate). Settings > Claude Code & Codex runs these
//! verbs with `--json`. No verb needs the app or the daemon.
//!
//! `skills`: every skill and slash command each agent loads, and turning a skill on or off.

use std::path::PathBuf;

use cmux_agent_customize::Homes;
use cmux_agent_customize::skills::{self, Agent, CodexLive, Kind, ListOptions, SetEnabled};
use serde_json::{Value, json};

use super::super::OutputMode;

pub(in crate::cli) const USAGE: &str = "\
cmux agent-config: Claude Code's and Codex's own configuration, in their own files.

  cmux agent-config skills list [--agent claude|codex] [--cwd DIR] [--files-only]
      Every skill and slash command each agent loads: name, description, scope, file, on or off.
      Project skills are the working folder's (or DIR's). Codex's list is its own app-server's
      (remote plugins too) when `codex` is installed; --files-only reads its folders instead.
  cmux agent-config skills on|off FILE [--agent claude|codex] [--cwd DIR]
      Turn the skill whose SKILL.md is FILE on or off, the way the agent's own switch does:
      Claude Code `skillOverrides` in ~/.claude/settings.json (a project skill: the project's
      .claude/settings.local.json), Codex `[[skills.config]]` in ~/.codex/config.toml. The prior
      file is kept in cmux's private agent-config folder, never beside it. Slash commands and
      Claude plugin skills have no switch.

Every verb takes --json. Exit codes: 0 ok, 1 refused (the error's code says why), 2 bad arguments.";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) enum Request {
    Help,
    List { agent: Option<String>, cwd: Option<PathBuf>, files_only: bool },
    Set { enabled: bool, file: PathBuf, agent: Option<String>, cwd: Option<PathBuf> },
}

pub(in crate::cli) fn parse(words: &[String]) -> Result<Request, String> {
    let Some((part, rest)) = words.split_first() else { return Ok(Request::Help) };
    if matches!(part.as_str(), "-h" | "--help" | "help") {
        return Ok(Request::Help);
    }
    if part != "skills" {
        return Err(format!("unknown agent-config part {part:?}"));
    }
    let Some((verb, rest)) = rest.split_first() else {
        return Err("skills needs a verb: list, on or off".into());
    };
    let mut agent = None;
    let mut cwd = None;
    let mut files_only = false;
    let mut file = None;
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            "--agent" => match words.next().map(String::as_str) {
                Some(name @ ("claude" | "codex")) => agent = Some(name.to_owned()),
                Some(other) => return Err(format!("--agent takes claude or codex, not {other:?}")),
                None => return Err("--agent needs claude or codex".into()),
            },
            "--cwd" => cwd = Some(PathBuf::from(words.next().ok_or("--cwd needs a folder")?)),
            "--files-only" if verb == "list" => files_only = true,
            "-h" | "--help" => return Ok(Request::Help),
            flag if flag.starts_with('-') => {
                return Err(format!("skills {verb} does not take {flag}"));
            }
            path if verb != "list" && file.is_none() => file = Some(PathBuf::from(path)),
            other => return Err(format!("unexpected {other:?}")),
        }
    }
    match verb.as_str() {
        "list" | "ls" => Ok(Request::List { agent, cwd, files_only }),
        "on" | "off" => Ok(Request::Set {
            enabled: verb == "on",
            file: file.ok_or_else(|| format!("skills {verb} needs the skill's SKILL.md"))?,
            agent,
            cwd,
        }),
        other => Err(format!("unknown skills verb {other:?}")),
    }
}

/// `cmux [global options] agent-config ...` when `args` names it.
pub(in crate::cli) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, words) = super::super::parse_globals(args).ok()?;
    let rest =
        words.split_first().filter(|(scope, _)| *scope == "agent-config").map(|(_, rest)| rest)?;
    // `agent-config mcp ...` and bare `agent-config` are the MCP servers part's.
    if rest.iter().find(|word| *word != "--json").map(String::as_str) != Some("skills") {
        return None;
    }
    let rest: Vec<String> = rest
        .iter()
        .filter(|word| {
            let json = *word == "--json";
            if json {
                global.output = OutputMode::Json;
            }
            !json
        })
        .cloned()
        .collect();
    let request = match parse(&rest) {
        Ok(request) => request,
        Err(what) => {
            return Some(super::super::scope_usage_failure(
                global.output,
                "agent-config",
                &what,
                USAGE,
            ));
        }
    };
    Some(run(global.output, request))
}

fn run(output: OutputMode, request: Request) -> i32 {
    let json_out = matches!(output, OutputMode::Json | OutputMode::JsonLines);
    let Some(homes) = Homes::from_env() else {
        return refuse(output, "home.missing", "HOME is not set");
    };
    let cwd = |dir: Option<PathBuf>| dir.or_else(|| std::env::current_dir().ok());
    match request {
        Request::Help => {
            println!("{USAGE}");
            0
        }
        Request::List { agent, cwd: dir, files_only } => {
            let started = std::time::Instant::now();
            let options = ListOptions {
                cwd: cwd(dir),
                codex_live: if files_only || agent.as_deref() == Some("claude") {
                    None
                } else {
                    CodexLive::find()
                },
            };
            let mut listing = skills::list(&homes, &options);
            if let Some(agent) = agent.as_deref().and_then(Agent::parse) {
                listing.skills.retain(|s| s.agent == agent);
                listing.problems.retain(|p| p.agent == agent);
            }
            let elapsed_ms = started.elapsed().as_secs_f64() * 1000.0;
            if json_out {
                let mut value = serde_json::to_value(&listing).unwrap_or(Value::Null);
                if let Value::Object(map) = &mut value {
                    map.insert("counts".into(), counts(&listing));
                    map.insert("elapsedMs".into(), json!((elapsed_ms * 10.0).round() / 10.0));
                }
                println!("{value}");
            } else if output != OutputMode::Quiet {
                print!("{}", table(&listing));
            }
            0
        }
        Request::Set { enabled, file, agent, cwd: dir } => {
            let agent = match agent.as_deref().and_then(Agent::parse) {
                Some(agent) => agent,
                // The file says whose it is.
                None if is_under(&file, &homes.claude)
                    || file.components().any(|c| c.as_os_str() == ".claude") =>
                {
                    Agent::Claude
                }
                None => Agent::Codex,
            };
            let change = SetEnabled {
                agent,
                path: file,
                enabled,
                cwd: cwd(dir),
                codex_live: if agent == Agent::Codex { CodexLive::find() } else { None },
            };
            match skills::set_enabled(&homes, &change) {
                Ok(skill) => {
                    if json_out {
                        println!("{}", json!({"skill": skill}));
                    } else if output != OutputMode::Quiet {
                        println!(
                            "{} {} is {}",
                            agent_name(skill.agent),
                            skill.name,
                            if skill.enabled { "on" } else { "off" }
                        );
                    }
                    0
                }
                Err(error) => refuse(output, error.code(), &error.to_string()),
            }
        }
    }
}

fn is_under(file: &std::path::Path, dir: &std::path::Path) -> bool {
    file.starts_with(dir)
        || std::fs::canonicalize(dir)
            .is_ok_and(|dir| std::fs::canonicalize(file).is_ok_and(|f| f.starts_with(dir)))
}

fn refuse(output: OutputMode, code: &str, message: &str) -> i32 {
    super::super::wire::print_local_error(
        &json!({"code": code, "message": message, "retryable": false}),
        output,
        1,
    )
}

fn agent_name(agent: Agent) -> &'static str {
    match agent {
        Agent::Claude => "Claude Code",
        Agent::Codex => "Codex",
    }
}

/// How many of each the agents load (and list), for `--json`.
fn counts(listing: &skills::Listing) -> Value {
    let pair = |agent, kind| {
        let all = listing.skills.iter().filter(|s| s.agent == agent && s.kind == kind).count();
        json!({"listed": all, "enabled": listing.enabled_count(agent, kind)})
    };
    json!({
        "claude": {"skills": pair(Agent::Claude, Kind::Skill), "commands": pair(Agent::Claude, Kind::Command)},
        "codex": {"skills": pair(Agent::Codex, Kind::Skill)},
    })
}

/// The human table: agent, kind, scope, on, name, description (one line).
pub(in crate::cli) fn table(listing: &skills::Listing) -> String {
    let width = listing.skills.iter().map(|s| s.name.chars().count()).max().unwrap_or(4).max(4);
    let mut out = format!(
        "{:6}  {:7}  {:7}  {:3}  {:width$}  DESCRIPTION\n",
        "AGENT", "KIND", "SCOPE", "ON", "NAME"
    );
    for skill in &listing.skills {
        let kind = match skill.kind {
            Kind::Skill => "skill",
            Kind::Command => "command",
        };
        let scope = serde_json::to_value(skill.scope)
            .ok()
            .and_then(|v| v.as_str().map(str::to_owned))
            .unwrap_or_default();
        let agent = if skill.agent == Agent::Claude { "claude" } else { "codex" };
        let line: String = skill.description.split_whitespace().collect::<Vec<_>>().join(" ");
        let line: String = if line.chars().count() > 80 {
            format!("{}…", line.chars().take(79).collect::<String>())
        } else {
            line
        };
        out.push_str(&format!(
            "{:<6}  {:<7}  {:<7}  {:3}  {:width$}  {line}\n",
            agent,
            kind,
            scope,
            if skill.enabled { "on" } else { "off" },
            skill.name,
        ));
    }
    for problem in &listing.problems {
        out.push_str(&format!(
            "! {} skips {}: {}\n",
            agent_name(problem.agent),
            problem.path.display(),
            problem.message
        ));
    }
    out.push_str(&format!(
        "Claude Code: {} skills, {} commands on. Codex: {} skills on ({}).\n",
        listing.enabled_count(Agent::Claude, Kind::Skill),
        listing.enabled_count(Agent::Claude, Kind::Command),
        listing.enabled_count(Agent::Codex, Kind::Skill),
        if listing.sources.codex == "app-server" { "from Codex" } else { "from its folders" },
    ));
    out
}

#[cfg(test)]
#[path = "skills_tests.rs"]
mod tests;
