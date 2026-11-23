//! `cmux agent-config mcp list|add|remove|enable|disable`: the MCP servers the person gave
//! Claude Code and Codex, read and edited in those agents' own files (cmux-agent-customize
//! `mcp`). Settings > MCP Servers' "Claude Code & Codex" groups run it (`--json`), behind Labs
//! `labs.agentCustomization`.
//!
//! Leo, 2026-11-19: "when I say Claude Code, when I say Codex [...] I need you guys to be, like,
//! doing the thing."

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::time::Instant;

use cmux_agent_customize::Agent;
use cmux_agent_customize::mcp::{self, Edit, NewServer, Options, Scope, Target, Transport};
use cmux_agent_customize::paths::Paths;
use serde_json::{Value, json};

use super::super::OutputMode;

const HELP: &str = "\
cmux agent-config mcp: the MCP servers Claude Code and Codex start, in their own config files.

Usage:
  cmux agent-config mcp list [--agent claude|codex] [--project DIR] [--json]
  cmux agent-config mcp add NAME --agent claude|codex [--scope user|local|project] [--project DIR]
                            [--env KEY=VALUE]... -- COMMAND [ARGS...]
  cmux agent-config mcp add NAME --agent claude|codex [--scope ...] --url URL [--transport http|sse]
                            [--header KEY=VALUE]...
  cmux agent-config mcp remove|enable|disable NAME --agent claude|codex [--scope ...] [--project DIR]
  cmux agent-config hooks list|enable|disable|add|remove ...   (cmux agent-config hooks --help)
  cmux agent-config subagents [list] [--cwd DIR] [--json]       (cmux agent-config subagents --help)
  cmux agent-config commands add NAME --prompt TEXT [--agent claude|codex|cmux]
  cmux agent-config commands list|remove ...   (cmux agent-config commands --help)

Scopes: user (every folder: ~/.claude.json, ~/.codex/config.toml), local (Claude only: this folder,
private to you), project (this folder's .mcp.json or .codex/config.toml), plugin (Codex only: from an
installed plugin; can be turned on and off, not removed). --project defaults to the current folder;
Claude Code turns user and local servers on and off per folder. Env and header values are written to
the agent's file and never printed. Every write keeps the file before it as <file>.cmux-backup.

Skills and slash commands: `cmux agent-config skills --help`; custom slash commands (saved
prompts) made from cmux: `cmux agent-config commands --help`. Settings (model, permission or approval
mode, sandbox, env): `cmux agent-config settings --help`.
";

/// Takes `--json` out of `args`, only before `--`: after it, every word is the server's command.
pub(super) fn take_json_flag(args: &[String]) -> (bool, Vec<String>) {
    let mut json = false;
    let mut rest = Vec::with_capacity(args.len());
    let mut words = args.iter();
    for arg in words.by_ref() {
        if arg == "--" {
            rest.push(arg.clone());
            break;
        }
        if arg == "--json" {
            json = true;
        } else {
            rest.push(arg.clone());
        }
    }
    rest.extend(words.cloned());
    (json, rest)
}

/// `Some(exit code)` when `args` is `agent-config ...`.
pub(in crate::cli) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (global, command_args) = super::super::parse_action_globals(args).ok()?;
    if command_args.first().map(String::as_str) != Some("agent-config") {
        return None;
    }
    let (json_flag, rest) = take_json_flag(&command_args[1..]);
    let json_out = json_flag || global.output == OutputMode::Json;
    if rest.is_empty()
        || rest.iter().any(|a| a == "--help" || a == "-h") && !rest.contains(&"--".to_owned())
    {
        print!("{HELP}");
        return Some(if rest.is_empty() { 2 } else { 0 });
    }
    let env: BTreeMap<String, String> = std::env::vars().collect();
    Some(match run(&rest, &env, json_out) {
        Ok(code) => code,
        Err(why) => {
            if json_out {
                println!("{}", json!({ "ok": false, "why": why }));
            } else {
                eprintln!("cmux agent-config: {why}");
            }
            1
        }
    })
}

#[derive(Debug, Default, PartialEq)]
struct Parsed {
    verb: String,
    name: Option<String>,
    agent: Option<Agent>,
    scope: Option<Scope>,
    project: Option<PathBuf>,
    url: Option<String>,
    transport: Option<String>,
    env: Vec<(String, String)>,
    headers: Vec<(String, String)>,
    command: Vec<String>,
}

fn pair(text: &str, flag: &str) -> Result<(String, String), String> {
    match text.split_once('=') {
        Some((key, value)) if !key.is_empty() => Ok((key.to_owned(), value.to_owned())),
        _ => Err(format!("{flag} takes KEY=VALUE")),
    }
}

fn parse(rest: &[String]) -> Result<Parsed, String> {
    let mut words = rest.iter();
    match words.next().map(String::as_str) {
        Some("mcp") => {}
        Some(other) => {
            return Err(format!(
                "unknown part {other:?}: `skills`, `subagents`, `commands`, `hooks`, `settings` or `mcp`"
            ));
        }
        None => {
            return Err("name a part: skills, subagents, commands, hooks, settings or mcp".into());
        }
    }
    let mut parsed = Parsed {
        verb: words.next().cloned().ok_or("name a verb: list, add, remove, enable or disable")?,
        ..Parsed::default()
    };
    if !matches!(parsed.verb.as_str(), "list" | "add" | "remove" | "enable" | "disable") {
        return Err(format!(
            "unknown verb {:?}: list, add, remove, enable or disable",
            parsed.verb
        ));
    }
    while let Some(arg) = words.next() {
        if arg == "--" {
            parsed.command = words.by_ref().cloned().collect();
            break;
        }
        let (flag, inline) = match arg.split_once('=') {
            Some((flag, value)) if flag.starts_with("--") => (flag, Some(value.to_owned())),
            _ => (arg.as_str(), None),
        };
        let mut value = || {
            inline
                .clone()
                .or_else(|| words.next().cloned())
                .filter(|v| !v.is_empty())
                .ok_or_else(|| format!("{flag} needs a value"))
        };
        match flag {
            "--agent" => {
                let text = value()?;
                parsed.agent = Some(
                    Agent::parse(&text)
                        .ok_or_else(|| format!("unknown agent {text:?}: claude or codex"))?,
                );
            }
            "--scope" | "-s" => {
                let text = value()?;
                parsed.scope = Some(Scope::parse(&text).ok_or_else(|| {
                    format!("unknown scope {text:?}: user, local, project or plugin")
                })?);
            }
            "--project" => parsed.project = Some(PathBuf::from(value()?)),
            "--url" => parsed.url = Some(value()?),
            "--transport" | "-t" => parsed.transport = Some(value()?),
            "--env" | "-e" => parsed.env.push(pair(&value()?, "--env")?),
            "--header" | "-H" => parsed.headers.push(pair(&value()?, "--header")?),
            other if other.starts_with('-') => return Err(format!("unknown flag {other}")),
            name if parsed.name.is_none() && parsed.verb != "list" => {
                parsed.name = Some(name.to_owned());
            }
            extra => return Err(format!("unexpected {extra:?}")),
        }
    }
    Ok(parsed)
}

fn run(rest: &[String], env: &BTreeMap<String, String>, json_out: bool) -> Result<i32, String> {
    let parsed = parse(rest)?;
    let paths = Paths::from_env(env).ok_or("no HOME: cannot find the agents' files")?;
    let project = match &parsed.project {
        Some(project) => Some(std::path::absolute(project).map_err(|e| format!("--project: {e}"))?),
        None => std::env::current_dir().ok(),
    };
    let options = Options { project: project.clone(), codex_cli: mcp::find_codex_cli(env) };
    if parsed.verb == "list" {
        let started = Instant::now();
        let agents: Vec<Agent> =
            parsed.agent.map(|a| vec![a]).unwrap_or_else(|| Agent::ALL.to_vec());
        let mut servers = Vec::new();
        let mut problems = Vec::new();
        for agent in agents {
            let listing = mcp::list(&paths, agent, &options);
            servers.extend(listing.servers);
            problems.extend(
                listing.problems.into_iter().map(|p| json!({ "agent": agent.id(), "why": p })),
            );
        }
        let elapsed = started.elapsed().as_secs_f64() * 1000.0;
        if json_out {
            let body = json!({
                "ok": true,
                "project": project.as_ref().map(|p| p.display().to_string()),
                "servers": servers,
                "problems": problems,
                "elapsedMs": (elapsed * 10.0).round() / 10.0,
            });
            println!("{body}");
        } else {
            print_table(&servers, &problems);
        }
        return Ok(0);
    }
    let agent = parsed.agent.ok_or("--agent claude|codex is required")?;
    let name = parsed.name.clone().ok_or("name the server")?;
    let edit = match parsed.verb.as_str() {
        "add" => Edit::Add(new_server(&parsed, &name)?),
        "remove" => Edit::Remove,
        "enable" => Edit::Enable,
        _ => Edit::Disable,
    };
    let target = Target { agent, name, scope: parsed.scope, project };
    let outcome = mcp::apply(&paths, &target, &edit, &options)?;
    if json_out {
        let mut body = serde_json::to_value(&outcome).unwrap_or(Value::Null);
        if let Value::Object(map) = &mut body {
            map.insert("ok".into(), Value::Bool(true));
        }
        println!("{body}");
    } else if outcome.changed {
        println!(
            "{} {} ({}): {} {}",
            outcome.agent,
            outcome.name,
            outcome.scope.id(),
            parsed.verb,
            outcome.file
        );
    } else {
        println!(
            "{} {} ({}): already so in {}",
            outcome.agent,
            outcome.name,
            outcome.scope.id(),
            outcome.file
        );
    }
    Ok(0)
}

fn new_server(parsed: &Parsed, name: &str) -> Result<NewServer, String> {
    let transport = match (&parsed.url, parsed.command.split_first()) {
        (Some(_), Some(_)) => return Err("give --url or a command after --, not both".into()),
        (None, None) => return Err("give the server's command after -- or its --url".into()),
        (None, Some((command, args))) => {
            Transport::Stdio { command: command.clone(), args: args.to_vec() }
        }
        (Some(url), None) => {
            if !(url.starts_with("https://") || url.starts_with("http://")) {
                return Err(format!("{url:?} is not an http(s) URL"));
            }
            match parsed.transport.as_deref() {
                None | Some("http") | Some("streamable-http") => {
                    Transport::Http { url: url.clone() }
                }
                Some("sse") => Transport::Sse { url: url.clone() },
                Some(other) => return Err(format!("unknown transport {other:?}: http or sse")),
            }
        }
    };
    if matches!(transport, Transport::Stdio { .. }) && !parsed.headers.is_empty() {
        return Err("--header is for a --url server".into());
    }
    Ok(NewServer {
        name: name.to_owned(),
        transport,
        env: parsed.env.clone(),
        headers: parsed.headers.clone(),
    })
}

fn print_table(servers: &[mcp::Server], problems: &[Value]) {
    if servers.is_empty() {
        println!("No MCP servers configured for Claude Code or Codex.");
    }
    for server in servers {
        let what = match (&server.command, &server.url) {
            (_, Some(url)) => url.clone(),
            (Some(command), None) => std::iter::once(command.clone())
                .chain(server.args.iter().cloned())
                .collect::<Vec<_>>()
                .join(" "),
            _ => String::new(),
        };
        let mut state = if server.enabled { "on" } else { "off" }.to_owned();
        if server.approval == Some("pending") {
            state.push_str(", pending approval");
        }
        if server.shadowed {
            state.push_str(", shadowed");
        }
        println!(
            "{:<6} {:<8} {:<24} {:<6} [{state}] {what}",
            server.agent,
            server.scope.id(),
            server.name,
            server.transport
        );
    }
    for problem in problems {
        eprintln!("problem: {}", problem["why"].as_str().unwrap_or(""));
    }
}

#[cfg(test)]
#[path = "mcp_tests.rs"]
mod tests;
