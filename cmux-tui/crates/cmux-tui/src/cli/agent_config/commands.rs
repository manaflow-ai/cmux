//! `cmux agent-config commands add|list|remove`: custom slash commands (saved prompts) made from
//! cmux, written where each agent reads them (cmux-agent-customize `commands`): Claude Code's
//! `~/.claude/commands/NAME.md`, Codex's `~/.codex/prompts/NAME.md`, or cmux's own
//! `~/.config/cmux/commands/NAME.md`, which the daemon's `apps.composer.list` answers so the
//! composer's `/` menu lists it in every chat. Settings > Skills > New Command runs `add --json`.
//! No verb needs the app or the daemon.

use std::io::Read as _;
use std::path::PathBuf;

use cmux_agent_customize::Homes;
use cmux_agent_customize::commands::{self, NewCommand, SavedCommand, Target};
use serde_json::json;

use super::super::OutputMode;

pub(in crate::cli) const USAGE: &str = "\
cmux agent-config commands: custom slash commands (saved prompts), made from cmux.

  cmux agent-config commands add NAME (--prompt TEXT | --prompt-file FILE|-) [--agent claude|codex|cmux]
                                 [--description TEXT] [--replace]
      Save a prompt as the slash command /NAME, in the agent's own folder: claude (default)
      ~/.claude/commands/NAME.md, Claude Code's /NAME; codex ~/.codex/prompts/NAME.md, Codex's
      /prompts:NAME; cmux NAME.md in $CMUX_COMMANDS_DIR (else cmux/commands in the config folder),
      in every chat's / menu whatever its agent, picking it writes the prompt into the draft. The description defaults to the
      prompt's first line. A name already saved is refused unless --replace.
  cmux agent-config commands list [--agent claude|codex|cmux]
      The saved commands in those folders: agent, what to type, description, file.
  cmux agent-config commands remove NAME [--agent claude|codex|cmux]
      Delete the command's file; its text is kept in cmux's private agent-config folder.

Every verb takes --json. Exit codes: 0 ok, 1 refused (the error's code says why), 2 bad arguments.";

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) enum Prompt {
    Text(String),
    File(PathBuf),
    Stdin,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(in crate::cli) enum Request {
    Help,
    Add { agent: Target, name: String, prompt: Prompt, description: String, replace: bool },
    List { agent: Option<Target> },
    Remove { agent: Target, name: String },
}

pub(in crate::cli) fn parse(words: &[String]) -> Result<Request, String> {
    let Some((verb, rest)) = words.split_first() else { return Ok(Request::Help) };
    if matches!(verb.as_str(), "-h" | "--help" | "help") {
        return Ok(Request::Help);
    }
    let mut agent = None;
    let mut name = None;
    let mut prompt = None;
    let mut description = String::new();
    let mut replace = false;
    let mut words = rest.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            "--agent" => {
                let word = words.next().ok_or("--agent needs claude, codex or cmux")?;
                agent =
                    Some(Target::parse(word).ok_or_else(|| {
                        format!("--agent takes claude, codex or cmux, not {word:?}")
                    })?);
            }
            "--prompt" if verb == "add" => {
                prompt = Some(Prompt::Text(words.next().ok_or("--prompt needs the text")?.clone()))
            }
            "--prompt-file" if verb == "add" => {
                let file = words.next().ok_or("--prompt-file needs a file, or - for stdin")?;
                prompt = Some(if file == "-" { Prompt::Stdin } else { Prompt::File(file.into()) });
            }
            "--description" if verb == "add" => {
                description = words.next().ok_or("--description needs the text")?.clone()
            }
            "--replace" if verb == "add" => replace = true,
            "-h" | "--help" => return Ok(Request::Help),
            flag if flag.starts_with('-') => {
                return Err(format!("commands {verb} does not take {flag}"));
            }
            word if verb != "list" && name.is_none() => name = Some(word.to_owned()),
            other => return Err(format!("unexpected {other:?}")),
        }
    }
    let named = || name.clone().ok_or_else(|| format!("commands {verb} needs the command's NAME"));
    match verb.as_str() {
        "add" => Ok(Request::Add {
            agent: agent.unwrap_or(Target::Claude),
            name: named()?,
            prompt: prompt.ok_or("commands add needs --prompt TEXT or --prompt-file FILE")?,
            description,
            replace,
        }),
        "list" | "ls" => Ok(Request::List { agent }),
        "remove" | "rm" => {
            Ok(Request::Remove { agent: agent.unwrap_or(Target::Claude), name: named()? })
        }
        other => Err(format!("unknown commands verb {other:?}: add, list or remove")),
    }
}

/// `cmux [global options] agent-config commands ...` when `args` names it.
pub(in crate::cli) fn run_if_requested(args: &[String]) -> Option<i32> {
    let (mut global, words) = super::super::parse_globals(args).ok()?;
    let rest =
        words.split_first().filter(|(scope, _)| *scope == "agent-config").map(|(_, rest)| rest)?;
    let at = rest.iter().position(|word| word != "--json")?;
    if rest[at] != "commands" {
        return None;
    }
    // `--json` anywhere but as a flag's value (a prompt may be the word itself).
    let mut words = Vec::new();
    let mut value_next = false;
    for word in rest.iter().skip(at + 1).chain(rest[..at].iter()) {
        if !value_next && word == "--json" {
            global.output = OutputMode::Json;
            continue;
        }
        value_next = !value_next
            && matches!(word.as_str(), "--agent" | "--prompt" | "--prompt-file" | "--description");
        words.push(word.clone());
    }
    let request = match parse(&words) {
        Ok(request) => request,
        Err(what) => {
            return Some(super::super::scope_usage_failure(
                global.output,
                "agent-config commands",
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
    match request {
        Request::Help => {
            println!("{USAGE}");
            0
        }
        Request::List { agent } => {
            let found = commands::list(&homes, agent);
            if json_out {
                println!("{}", json!({ "commands": found }));
            } else if output != OutputMode::Quiet {
                print!("{}", table(&found));
            }
            0
        }
        Request::Add { agent, name, prompt, description, replace } => {
            let prompt = match prompt {
                Prompt::Text(text) => text,
                Prompt::File(file) => match std::fs::read_to_string(&file) {
                    Ok(text) => text,
                    Err(error) => {
                        return refuse(
                            output,
                            "command.io",
                            &format!("{}: {error}", file.display()),
                        );
                    }
                },
                Prompt::Stdin => {
                    let mut text = String::new();
                    if let Err(error) = std::io::stdin().read_to_string(&mut text) {
                        return refuse(output, "command.io", &format!("stdin: {error}"));
                    }
                    text
                }
            };
            let new = NewCommand { agent, name, description, prompt, replace };
            match commands::add(&homes, &new) {
                Ok(saved) => {
                    if json_out {
                        println!("{}", json!({ "command": saved }));
                    } else if output != OutputMode::Quiet {
                        println!(
                            "{} {} saved in {}",
                            agent.display(),
                            saved.invocation,
                            saved.path.display()
                        );
                    }
                    0
                }
                Err(error) => refuse(output, error.code(), &error.to_string()),
            }
        }
        Request::Remove { agent, name } => match commands::remove(&homes, agent, &name) {
            Ok(path) => {
                if json_out {
                    println!("{}", json!({ "removed": path, "agent": agent }));
                } else if output != OutputMode::Quiet {
                    println!("{} {} removed ({})", agent.display(), name, path.display());
                }
                0
            }
            Err(error) => refuse(output, error.code(), &error.to_string()),
        },
    }
}

fn refuse(output: OutputMode, code: &str, message: &str) -> i32 {
    super::super::wire::print_local_error(
        &json!({"code": code, "message": message, "retryable": false}),
        output,
        1,
    )
}

/// The human table: agent, what to type, description (one line), file.
pub(in crate::cli) fn table(found: &[SavedCommand]) -> String {
    if found.is_empty() {
        return "No saved commands. `cmux agent-config commands add NAME --prompt TEXT` makes one.\n"
            .into();
    }
    let width = found.iter().map(|c| c.invocation.chars().count()).max().unwrap_or(4).max(4);
    let mut out = format!("{:6}  {:width$}  DESCRIPTION\n", "AGENT", "TYPE");
    for command in found {
        let line: String = command.description.split_whitespace().collect::<Vec<_>>().join(" ");
        let line: String = if line.chars().count() > 70 {
            format!("{}…", line.chars().take(69).collect::<String>())
        } else {
            line
        };
        out.push_str(&format!(
            "{:<6}  {:width$}  {line}  ({})\n",
            command.agent.id(),
            command.invocation,
            command.path.display()
        ));
    }
    out
}

#[cfg(test)]
#[path = "commands_tests.rs"]
mod tests;
