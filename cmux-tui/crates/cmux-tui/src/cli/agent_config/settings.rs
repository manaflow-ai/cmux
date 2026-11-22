//! `cmux agent-config`: Claude Code's and Codex's own configuration, read and edited in the
//! agents' own files (cmux-agent-customize). Settings > Claude Code & Codex runs it through the
//! bundled CLI (Labs `labs.agentCustomization`).
//!
//! `settings get` prints every key on disk with the scope it comes from (env and secret values
//! masked); `settings set|unset` edits one curated key (model, effort, permission or approval
//! mode, sandbox, theme, status line, output style) in place, keeping comments, order and every
//! other key, atomically and after a backup.

use std::path::PathBuf;

use cmux_agent_customize::settings::{self, Agent, Context, SettingsError};
use serde_json::{Value, json};

use super::super::OutputMode;

const HELP: &str = "\
Usage: cmux agent-config settings get --agent claude|codex [--cwd DIR] [--json]
       cmux agent-config settings set --agent claude|codex --key KEY --value VALUE [--scope SCOPE] [--cwd DIR] [--json]
       cmux agent-config settings unset --agent claude|codex --key KEY [--scope SCOPE] [--cwd DIR] [--json]
       cmux agent-config settings allow|deny|ask --rule RULE [--remove] [--scope SCOPE] [--cwd DIR] [--json]

Claude Code's and Codex's own settings, as each agent reads them.

  get     every key in the agent's settings files, with the scope it comes from
          (env and secret values masked), the curated keys cmux edits, and the files
  set     write one curated key in one scope's file (default: user)
  unset   remove it, so the next scope or the agent's default applies
  allow, deny, ask
          add one Claude Code permission rule to permissions.allow, .deny or .ask in one
          scope's file (default: user), or take it out with --remove. A rule is a tool name
          with an optional specifier: Bash(npm run test:*), Read(./.env), WebFetch(domain:x.com),
          mcp__github. The lists merge across scopes; deny wins over ask over allow.

Keys cmux edits:
  claude  model, effortLevel, permissions.defaultMode, theme, outputStyle, statusLine.command
  codex   model, model_reasoning_effort, approval_policy, sandbox_mode
Scopes:
  claude  user (~/.claude/settings.json), project (.claude/settings.json), local (.claude/settings.local.json)
  codex   user (~/.codex/config.toml), project (.codex/config.toml, trusted projects), profile:NAME (NAME.config.toml)

Edits keep comments, key order and every other key, and back up the file in cmux's private
folder, never beside it (so a project's backups stay out of git): NAME-HASH.cmux-backup is it
before cmux's first edit (never replaced), NAME-HASH.cmux-backup-last before the latest one. The
folder is ~/Library/Application Support/cmux-tui/agent-config/backups on macOS,
$XDG_STATE_HOME/cmux-tui/agent-config/backups (~/.local/state/...) elsewhere; set and unset print
the backup's path.
--cwd names the project the project scopes resolve in (default: this folder).
";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Verb {
    Get,
    Set,
    Unset,
    /// `allow`, `deny` or `ask`: one Claude Code permission rule.
    Rule(&'static str),
}

#[derive(Debug, PartialEq, Eq)]
struct Request {
    verb: Verb,
    agent: Agent,
    key: Option<String>,
    value: Option<String>,
    scope: Option<String>,
    cwd: Option<PathBuf>,
    rule: Option<String>,
    remove: bool,
}

pub(in crate::cli) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, words) = super::super::parse_globals(args).ok()?;
    let rest =
        words.split_first().filter(|(scope, _)| *scope == "agent-config").map(|(_, rest)| rest)?;
    // `agent-config mcp ...` and bare `agent-config` are the MCP servers part's.
    if rest.iter().find(|word| *word != "--json").map(String::as_str) != Some("settings") {
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
    if rest.is_empty() || rest.iter().any(|w| w == "--help" || w == "-h" || w == "help") {
        print!("{HELP}");
        return Some(0);
    }
    let request = match parse(&rest) {
        Ok(request) => request,
        Err(what) => {
            return Some(super::super::scope_usage_failure(
                global.output,
                "agent-config",
                &what,
                HELP,
            ));
        }
    };
    let json_out = matches!(global.output, OutputMode::Json | OutputMode::JsonLines);
    let cwd = request.cwd.clone().or_else(|| std::env::current_dir().ok());
    let Some(ctx) = Context::from_env(cwd) else {
        return Some(fail(
            global.output,
            SettingsError {
                code: "agent_config.no_home",
                message: "no home folder (HOME is unset)".to_owned(),
            },
        ));
    };
    let result = match request.verb {
        Verb::Get => Ok(settings::report(&ctx, request.agent)),
        Verb::Set | Verb::Unset => settings::apply(
            &ctx,
            request.agent,
            request.key.as_deref().unwrap_or_default(),
            request.value.as_deref(),
            request.scope.as_deref(),
        )
        .map(|written| written.json()),
        Verb::Rule(list) => settings::rule(
            &ctx,
            list,
            request.rule.as_deref().unwrap_or_default(),
            !request.remove,
            request.scope.as_deref(),
        )
        .map(|written| {
            let mut answer = written.json();
            answer["rule"] = json!(request.rule);
            answer["removed"] = json!(request.remove);
            answer
        }),
    };
    Some(match result {
        Ok(answer) => {
            if json_out {
                println!("{answer}");
            } else if global.output != OutputMode::Quiet {
                print!("{}", human(&request, &answer));
            }
            0
        }
        Err(error) => fail(global.output, error),
    })
}

fn fail(output: OutputMode, error: SettingsError) -> i32 {
    let message = if matches!(output, OutputMode::Json | OutputMode::JsonLines) {
        error.message
    } else {
        format!("cmux: {}", error.message)
    };
    super::super::wire::print_local_error(
        &json!({"code": error.code, "message": message}),
        output,
        1,
    )
}

fn parse(words: &[String]) -> Result<Request, String> {
    let mut iter = words.iter();
    match iter.next().map(String::as_str) {
        Some("settings") => {}
        Some(other) => {
            return Err(format!("unknown agent-config part {other:?}; the part is settings"));
        }
        None => return Err("agent-config needs a part (settings)".to_owned()),
    }
    let verb = match iter.next().map(String::as_str) {
        Some("get") => Verb::Get,
        Some("set") => Verb::Set,
        Some("unset") => Verb::Unset,
        Some("allow") => Verb::Rule("allow"),
        Some("deny") => Verb::Rule("deny"),
        Some("ask") => Verb::Rule("ask"),
        Some(other) => {
            return Err(format!(
                "unknown settings verb {other:?}; use get, set, unset, allow, deny or ask"
            ));
        }
        None => {
            return Err("settings needs a verb (get, set, unset, allow, deny or ask)".to_owned());
        }
    };
    let (mut agent, mut key, mut value, mut scope, mut cwd) = (None, None, None, None, None);
    let (mut rule, mut remove) = (None, false);
    while let Some(word) = iter.next() {
        let (flag, inline) = match word.split_once('=') {
            Some((flag, v)) if flag.starts_with("--") => (flag, Some(v.to_owned())),
            _ => (word.as_str(), None),
        };
        let mut take = || {
            inline
                .clone()
                .or_else(|| iter.next().cloned())
                .ok_or_else(|| format!("{flag} needs a value"))
        };
        match flag {
            "--agent" => {
                let text = take()?;
                agent = Some(
                    Agent::parse(&text)
                        .ok_or_else(|| format!("--agent is claude or codex, not {text:?}"))?,
                );
            }
            "--key" => key = Some(take()?),
            "--value" => value = Some(take()?),
            "--scope" => scope = Some(take()?),
            "--cwd" => cwd = Some(PathBuf::from(take()?)),
            "--rule" => rule = Some(take()?),
            "--remove" if inline.is_none() => remove = true,
            other => return Err(format!("settings does not take {other:?}")),
        }
    }
    if let Verb::Rule(list) = verb {
        // Permission rules are Claude Code's; Codex has approval_policy and sandbox_mode instead.
        if agent.is_some_and(|a| a != Agent::Claude) {
            return Err(format!(
                "{list} rules are Claude Code's; Codex uses approval_policy and sandbox_mode"
            ));
        }
        if key.is_some() || value.is_some() {
            return Err(format!("{list} takes --rule, not --key or --value"));
        }
        if rule.is_none() {
            return Err(format!("{list} needs --rule RULE, as in --rule 'Bash(npm run test:*)'"));
        }
        let agent = Agent::Claude;
        return Ok(Request { verb, agent, key, value, scope, cwd, rule, remove });
    }
    if rule.is_some() || remove {
        return Err("--rule and --remove go with allow, deny or ask".to_owned());
    }
    let agent = agent.ok_or("settings needs --agent claude or --agent codex")?;
    match verb {
        Verb::Get if key.is_some() || value.is_some() || scope.is_some() => {
            return Err("get takes only --agent and --cwd".to_owned());
        }
        Verb::Set if key.is_none() || value.is_none() => {
            return Err("set needs --key and --value".to_owned());
        }
        Verb::Unset if key.is_none() => return Err("unset needs --key".to_owned()),
        Verb::Unset if value.is_some() => return Err("unset takes no --value".to_owned()),
        _ => {}
    }
    Ok(Request { verb, agent, key, value, scope, cwd, rule, remove })
}

/// The answer for a person at a terminal.
fn human(request: &Request, answer: &Value) -> String {
    if let Verb::Rule(list) = request.verb {
        let what = if request.remove { "removed from" } else { "added to" };
        let mut out = format!(
            "{} {what} permissions.{list} ({} scope) in {}\n",
            request.rule.as_deref().unwrap_or_default(),
            answer["scope"].as_str().unwrap_or_default(),
            answer["path"].as_str().unwrap_or_default()
        );
        if let Some(backup) = answer["backup"].as_str() {
            out.push_str(&format!("backup: {backup}\n"));
        }
        return out;
    }
    if request.verb != Verb::Get {
        let what = if request.verb == Verb::Set { "set" } else { "unset" };
        let mut out = format!(
            "{what} {} ({} scope) in {}\n",
            answer["key"].as_str().unwrap_or_default(),
            answer["scope"].as_str().unwrap_or_default(),
            answer["path"].as_str().unwrap_or_default()
        );
        if let Some(backup) = answer["backup"].as_str() {
            out.push_str(&format!("backup: {backup}\n"));
        }
        return out;
    }
    let mut out = String::new();
    out.push_str("Files (highest first):\n");
    for file in answer["files"].as_array().into_iter().flatten() {
        let state = if let Some(error) = file["error"].as_str() {
            error.to_owned()
        } else if file["exists"] == true {
            format!("{} keys", file["keys"])
        } else {
            "absent".to_owned()
        };
        let inactive = file["inactive"].as_str().map(|why| format!(" ({why})")).unwrap_or_default();
        out.push_str(&format!(
            "  {:<14} {}  [{state}]{inactive}\n",
            file["scope"].as_str().unwrap_or_default(),
            file["path"].as_str().unwrap_or_default()
        ));
    }
    out.push_str("\nCurated:\n");
    for row in answer["curated"].as_array().into_iter().flatten() {
        let value = row["value"].as_str().unwrap_or("(default)");
        let scope = row["scope"].as_str().map(|s| format!("  [{s}]")).unwrap_or_default();
        out.push_str(&format!(
            "  {:<26} {value}{scope}\n",
            row["key"].as_str().unwrap_or_default()
        ));
    }
    out.push_str(&format!(
        "\nAll keys ({} of {} on disk shown):\n",
        answer["keysShown"], answer["keysOnDisk"]
    ));
    for entry in answer["entries"].as_array().into_iter().flatten() {
        let over: Vec<String> = entry["overridden"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|o| {
                format!(
                    "{}={}",
                    o["scope"].as_str().unwrap_or_default(),
                    o["display"].as_str().unwrap_or_default()
                )
            })
            .collect();
        let over =
            if over.is_empty() { String::new() } else { format!("  (over {})", over.join(", ")) };
        out.push_str(&format!(
            "  {:<40} {}  [{}]{over}\n",
            entry["key"].as_str().unwrap_or_default(),
            entry["display"].as_str().unwrap_or_default(),
            entry["scope"].as_str().unwrap_or_default()
        ));
    }
    for note in answer["notes"].as_array().into_iter().flatten() {
        out.push_str(&format!("\nnote: {}", note.as_str().unwrap_or_default()));
    }
    out.push('\n');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(text: &str) -> Vec<String> {
        text.split_whitespace().map(str::to_owned).collect()
    }

    #[test]
    fn parses_each_verb() {
        assert_eq!(
            parse(&words("settings get --agent codex --cwd /p")).unwrap(),
            Request {
                verb: Verb::Get,
                agent: Agent::Codex,
                key: None,
                value: None,
                scope: None,
                cwd: Some("/p".into()),
                rule: None,
                remove: false,
            }
        );
        let set =
            parse(&words("settings set --agent claude --key model --value -odd --scope=local"))
                .unwrap();
        assert_eq!(set.value.as_deref(), Some("-odd"));
        assert_eq!(set.scope.as_deref(), Some("local"));
        assert!(parse(&words("settings unset --agent claude --key model")).is_ok());
        assert!(parse(&words("settings set --agent claude --key model")).is_err());
        assert!(parse(&words("settings get --agent gemini")).is_err());
        assert!(parse(&words("settings get")).is_err());
        assert!(parse(&words("mcp list --agent claude")).is_err());
        assert!(parse(&words("settings get --agent claude --bogus")).is_err());
    }

    #[test]
    fn parses_permission_rules() {
        let allow = parse(&words("settings allow --rule Bash(npm:*) --scope project")).unwrap();
        assert_eq!(allow.verb, Verb::Rule("allow"));
        assert_eq!(allow.agent, Agent::Claude);
        assert_eq!(allow.rule.as_deref(), Some("Bash(npm:*)"));
        assert!(!allow.remove);
        let deny = parse(&words("settings deny --agent claude --rule=WebFetch --remove")).unwrap();
        assert_eq!((deny.verb, deny.remove), (Verb::Rule("deny"), true));
        assert!(parse(&words("settings ask")).is_err());
        assert!(parse(&words("settings allow --agent codex --rule Bash")).is_err());
        assert!(parse(&words("settings allow --rule Bash --key model")).is_err());
        assert!(
            parse(&words("settings set --agent claude --key model --value x --remove")).is_err()
        );
    }
}
