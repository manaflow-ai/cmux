//! `cmux agent-config hooks ...`: argument parsing and the JSON each
//! subcommand answers, kept here so the cmux CLI only routes to it.

use std::path::PathBuf;

use anyhow::{Context as _, bail};
use serde_json::{Value, json};

use crate::hooks::{self, Agent, NewHook, Scope};
use crate::hooks_paths::AgentPaths;

pub const HELP: &str = "\
cmux agent-config hooks: Claude Code and Codex hooks

  list [--agent claude|codex] [--project DIR]
  enable ID [--allow-cmux] [--project DIR]
  disable ID [--allow-cmux] [--project DIR]
  add --agent claude|codex --event EVENT --command CMD
      [--matcher M] [--timeout SECONDS] [--scope user|user-local|project|project-local] [--project DIR]
  remove ID [--allow-cmux] [--project DIR]

IDs come from `list`. cmux's own hooks are labelled cmux and change only
with --allow-cmux; plugin hooks are read-only. A disabled Claude Code hook
is kept in ~/.cmux/agent-customize/claude-disabled-hooks.json until enabled;
a disabled Codex hook is `enabled = false` in its hooks.state entry.
Add --json (cmux --json agent-config hooks list) for machine output.";

/// Runs one `hooks` subcommand; `args` start after `hooks`.
pub fn run(args: &[String]) -> anyhow::Result<Value> {
    let (action, rest) = args.split_first().context(HELP)?;
    let mut options = Options::parse(rest)?;
    let project = options.take("--project").map(PathBuf::from);
    let paths = AgentPaths::from_env(project)?;
    let allow_cmux = options.flag("--allow-cmux");
    let value = match action.as_str() {
        "list" | "ls" => {
            let agent = options.take("--agent").map(|agent| Agent::parse(&agent)).transpose()?;
            options.finish()?;
            let mut listing = hooks::list(&paths);
            if let Some(agent) = agent {
                listing.hooks.retain(|hook| hook.agent == agent);
                listing.files.retain(|file| file.agent == agent);
            }
            let claude = listing.count(Agent::Claude);
            let codex = listing.count(Agent::Codex);
            let mut value = serde_json::to_value(&listing)?;
            value["counts"] = json!({ "claude": claude, "codex": codex });
            value
        }
        "enable" | "disable" => {
            let id = options.positional()?;
            options.finish()?;
            let hook = hooks::set_enabled(&paths, &id, action == "enable", allow_cmux)?;
            json!({ "ok": true, "hook": hook })
        }
        "remove" | "rm" => {
            let id = options.positional()?;
            options.finish()?;
            let hook = hooks::remove(&paths, &id, allow_cmux)?;
            json!({ "ok": true, "removed": hook })
        }
        "add" => {
            let agent =
                Agent::parse(&options.take("--agent").context("add needs --agent claude|codex")?)?;
            let new = NewHook {
                agent,
                scope: options
                    .take("--scope")
                    .map(|scope| Scope::parse(&scope))
                    .transpose()?
                    .unwrap_or(Scope::User),
                event: options.take("--event").context("add needs --event")?,
                matcher: options.take("--matcher"),
                command: options.take("--command").context("add needs --command")?,
                timeout: options
                    .take("--timeout")
                    .map(|timeout| timeout.parse::<u64>().context("--timeout takes whole seconds"))
                    .transpose()?,
            };
            options.finish()?;
            let hook = hooks::add(&paths, &new)?;
            json!({ "ok": true, "hook": hook })
        }
        "help" | "--help" | "-h" => json!({ "help": HELP }),
        other => bail!("unknown hooks action {other:?}\n\n{HELP}"),
    };
    Ok(value)
}

struct Options {
    pairs: Vec<(String, Option<String>)>,
    positionals: Vec<String>,
}

const FLAGS: &[&str] = &["--allow-cmux"];

impl Options {
    fn parse(args: &[String]) -> anyhow::Result<Self> {
        let mut pairs = Vec::new();
        let mut positionals = Vec::new();
        let mut iter = args.iter();
        while let Some(arg) = iter.next() {
            if let Some((name, value)) =
                arg.split_once('=').filter(|(name, _)| name.starts_with("--"))
            {
                pairs.push((name.to_owned(), Some(value.to_owned())));
            } else if FLAGS.contains(&arg.as_str()) {
                pairs.push((arg.clone(), None));
            } else if arg.starts_with("--") {
                let value = iter.next().with_context(|| format!("{arg} needs a value"))?;
                pairs.push((arg.clone(), Some(value.clone())));
            } else {
                positionals.push(arg.clone());
            }
        }
        Ok(Self { pairs, positionals })
    }

    fn take(&mut self, name: &str) -> Option<String> {
        let index = self.pairs.iter().position(|(key, _)| key == name)?;
        self.pairs.remove(index).1
    }

    fn flag(&mut self, name: &str) -> bool {
        match self.pairs.iter().position(|(key, _)| key == name) {
            Some(index) => {
                self.pairs.remove(index);
                true
            }
            None => false,
        }
    }

    fn positional(&mut self) -> anyhow::Result<String> {
        if self.positionals.is_empty() {
            bail!("this action needs a hook ID (from `cmux agent-config hooks list`)");
        }
        Ok(self.positionals.remove(0))
    }

    fn finish(self) -> anyhow::Result<()> {
        if let Some((name, _)) = self.pairs.first() {
            bail!("unknown option {name}");
        }
        if let Some(extra) = self.positionals.first() {
            bail!("unexpected argument {extra:?}");
        }
        Ok(())
    }
}

/// One line per hook, grouped by agent and event, for `hooks list`.
pub fn render_list(hooks: &[Value], listing: &Value) -> String {
    let field =
        |hook: &Value, key: &str| hook.get(key).and_then(Value::as_str).unwrap_or("").to_owned();
    let mut text = String::new();
    let mut last = (String::new(), String::new());
    for hook in hooks {
        let agent = field(hook, "agent");
        let event = field(hook, "event");
        if (agent.clone(), event.clone()) != last {
            text.push_str(&format!("{agent} {event}\n"));
            last = (agent, event);
        }
        let enabled = hook.get("enabled").and_then(Value::as_bool).unwrap_or(true);
        let mut tags = vec![field(hook, "scope")];
        if field(hook, "owner") != "user" {
            tags.push(field(hook, "owner"));
        }
        if let Some(trust) =
            hook.get("trust").and_then(Value::as_str).filter(|trust| *trust != "trusted")
        {
            tags.push(trust.to_owned());
        }
        let matcher = hook
            .get("matcher")
            .and_then(Value::as_str)
            .map(|m| format!(" [{m}]"))
            .unwrap_or_default();
        let mut command = field(hook, "command");
        if command.chars().count() > 90 {
            command = command.chars().take(89).collect::<String>() + "…";
        }
        text.push_str(&format!(
            "  {} {}{} {} ({})\n",
            if enabled { "on " } else { "off" },
            field(hook, "id"),
            matcher,
            command,
            tags.join(", ")
        ));
    }
    if let Some(counts) = listing.get("counts") {
        text.push_str(&format!(
            "{} Claude Code hooks, {} Codex hooks\n",
            counts.get("claude").and_then(Value::as_u64).unwrap_or(0),
            counts.get("codex").and_then(Value::as_u64).unwrap_or(0)
        ));
    }
    text
}
