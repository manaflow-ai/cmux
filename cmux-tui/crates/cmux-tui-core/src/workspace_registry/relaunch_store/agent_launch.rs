//! How the agent CLI a terminal ran was started, kept in the relaunch record
//! with its session so a respawn after the terminal's host died (a reboot)
//! starts it the way classic cmux does: the same flags and the same account.
//!
//! - `args`: the CLI's flags, from `CMUX_TUI_AGENT_ARGS` (the cmux `claude`
//!   and `codex` shims set it to the arguments they were given) or else the
//!   process's argv after the program word. Dropped: what picks or starts a
//!   session (`--resume <id>`, `--continue`, `codex resume <id>`), prompts,
//!   an unknown flag together with the word after it (it may take a value),
//!   inline configuration (`--settings '{...}'`, codex `-c key=value`) and
//!   any flag or value with a secret word or a token prefix in it. Any other
//!   credential-looking argument drops all of them ([`stored_argv`]). A
//!   non-interactive run (`claude -p`, a codex subcommand, `muse exec`,
//!   `--version`) has no launch. Muse Code keeps no worktree flag (`-w`
//!   would make a new worktree instead of resuming in the session's) and no
//!   `--image` (it would attach the image again).
//! - `env`: the harness's account directory only (`CLAUDE_CONFIG_DIR` for
//!   Claude Code, `CODEX_HOME` for Codex; none for Muse Code), an absolute
//!   path. Never a token or key: the CLI reads its sign-in from that
//!   directory.

use std::path::Path;

use super::{TOKEN_PREFIXES, names_secret, stored_argv};

/// The variable the cmux `claude` and `codex` shims set on the CLI they start
/// to the arguments they were given, as a JSON array of strings.
pub(crate) const SHIM_ARGS_ENV: &str = "CMUX_TUI_AGENT_ARGS";

/// The environment keys read from an agent's process.
pub(crate) const AGENT_JOB_ENV_KEYS: &[&str] = &["CLAUDE_CONFIG_DIR", "CODEX_HOME", SHIM_ARGS_ENV];

/// What an agent CLI was started with.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct AgentLaunch {
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
}

/// Whether a respawn knows how to resume a session of `harness`: Claude
/// Code, Codex and Muse Code.
pub(crate) fn resumable_harness(harness: &str) -> bool {
    matches!(harness, "claude" | "codex" | "muse")
}

/// The account directory variable of a resumable harness, when it has one
/// (Muse Code keeps its sign-in in its own data folder).
pub(crate) fn account_env_key(harness: &str) -> Option<&'static str> {
    match harness {
        "claude" => Some("CLAUDE_CONFIG_DIR"),
        "codex" => Some("CODEX_HOME"),
        _ => None,
    }
}

/// The launch of `harness` from its process's `argv` and `env` (the keys of
/// [`AGENT_JOB_ENV_KEYS`] it has). `None` when the process is not that
/// harness's CLI or is not an interactive session of it.
pub(crate) fn agent_launch_from_job(
    harness: &str,
    argv: &[String],
    env: &[(String, String)],
) -> Option<AgentLaunch> {
    if !resumable_harness(harness) {
        return None;
    }
    let args = session_free(harness, &harness_args(harness, argv, env)?)?;
    let args = stored_args(harness, args);
    let value = |key: &str| env.iter().find(|(name, _)| name == key).map(|(_, value)| value);
    let env = account_env_key(harness)
        .and_then(|key| Some((key, value(key)?)))
        .filter(|(_, dir)| {
            Path::new(dir.as_str()).is_absolute() && !dir.chars().any(char::is_control)
        })
        .map(|(key, dir)| vec![(key.to_string(), dir.clone())])
        .unwrap_or_default();
    Some(AgentLaunch { args, env })
}

/// Claude Code's subcommands: none starts a session.
const CLAUDE_SUBCOMMANDS: &[&str] = &[
    "mcp",
    "config",
    "doctor",
    "update",
    "install",
    "migrate-installer",
    "setup-token",
    "plugin",
    "plugins",
];

/// Codex's subcommands that run without an interactive session (`resume`
/// and `fork` start one).
const CODEX_NON_INTERACTIVE: &[&str] = &[
    "exec",
    "e",
    "review",
    "apply",
    "a",
    "mcp",
    "mcp-server",
    "app-server",
    "login",
    "logout",
    "completion",
    "debug",
    "sandbox",
    "cloud",
    "features",
    "help",
];

/// Muse Code's subcommands that run without an interactive session
/// (`resume` starts one).
const MUSE_NON_INTERACTIVE: &[&str] = &[
    "exec",
    "config",
    "export",
    "trace",
    "model-profile",
    "skills",
    "voice",
    "plugins",
    "sandbox",
    "schema",
    "serve",
    "session-message",
    "mcp",
    "auth",
    "login",
    "logout",
    "usage",
    "init",
    "help",
];

/// Whether the process is `harness`'s CLI run without an interactive session
/// (`claude -p`, a Claude subcommand, `codex exec`, `--version`): a session it
/// reports cannot be resumed. Only these known forms count: a run this does
/// not recognize (`codex "fix the bug"`, a new subcommand) is interactive, as
/// are another program and another harness.
pub(crate) fn job_is_non_interactive(
    harness: &str,
    argv: &[String],
    env: &[(String, String)],
) -> bool {
    if !resumable_harness(harness) {
        return false;
    }
    let Some(args) = harness_args(harness, argv, env) else { return false };
    let mut index = 0;
    while index < args.len() {
        let argument = args[index].as_str();
        index += 1;
        if argument == "--" {
            return false; // Everything after `--` is a prompt.
        }
        if !argument.starts_with('-') || argument == "-" {
            // The first word: a subcommand, or the prompt.
            return match harness {
                "claude" => CLAUDE_SUBCOMMANDS.contains(&argument),
                "muse" => MUSE_NON_INTERACTIVE.contains(&argument),
                _ => CODEX_NON_INTERACTIVE.contains(&argument),
            };
        }
        let (flag, inline) = split_flag(harness, argument);
        match (harness, flag) {
            ("claude", "-p" | "--print" | "-v" | "--version" | "-h" | "--help")
            | ("codex" | "muse", "-V" | "--version" | "-h" | "--help") => return true,
            _ => {}
        }
        if inline.is_some() {
            continue;
        }
        // A flag's values are not the first word; an unknown flag may take one.
        match takes(harness, flag) {
            Some(Takes::Nothing) => {}
            Some(Takes::One) | None => {
                if args.get(index).is_some_and(|next| !next.starts_with('-')) {
                    index += 1;
                }
            }
            Some(Takes::Many) => {
                while args.get(index).is_some_and(|next| !next.starts_with('-')) {
                    index += 1;
                }
            }
        }
    }
    false
}

/// The arguments the harness's CLI got: the shim's (`CMUX_TUI_AGENT_ARGS`),
/// else its argv after the program word. `None` when the process is not that
/// CLI: it must be in both cases, as the shim's variable is inherited by
/// everything the CLI starts.
fn harness_args(harness: &str, argv: &[String], env: &[(String, String)]) -> Option<Vec<String>> {
    let at = argv.iter().position(|argument| is_program(harness, argument))?;
    let given = env
        .iter()
        .find(|(name, _)| name == SHIM_ARGS_ENV)
        .and_then(|(_, json)| serde_json::from_str::<Vec<String>>(json).ok());
    Some(given.unwrap_or_else(|| argv[at + 1..].to_vec()))
}

/// The arguments of a stored launch as read back: filtered again as on write.
pub(crate) fn kept_agent_args(harness: &str, args: &[String]) -> Vec<String> {
    session_free(harness, args).map(|args| stored_args(harness, args)).unwrap_or_default()
}

/// `args` as stored: all of them only when none looks like a credential
/// (the terminal command rule, [`stored_argv`]).
fn stored_args(harness: &str, args: Vec<String>) -> Vec<String> {
    let mut line = vec![harness.to_string()];
    line.extend(args);
    stored_argv(&line).map(|line| line[1..].to_vec()).unwrap_or_default()
}

/// Whether `argument` names the harness's program: `claude`, `codex`, the
/// JS entry an npm install runs under `node` (`.../claude-code/cli.js`,
/// `.../codex.js`), or the binary Muse Code's `muse` launcher `exec`s
/// (`~/.local/bin/muse-bin-1.4.14-R7309.1`).
fn is_program(harness: &str, argument: &str) -> bool {
    let name = Path::new(argument).file_name().and_then(|name| name.to_str()).unwrap_or_default();
    name == harness
        || name == format!("{harness}.js")
        || (harness == "claude" && name == "cli.js" && argument.contains("claude-code"))
        || (harness == "muse" && name.starts_with("muse-bin-"))
}

/// How a flag of the CLI takes values.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Takes {
    /// No value: `--dangerously-skip-permissions`.
    Nothing,
    /// The next argument (unless given as `--flag=value`).
    One,
    /// Every following argument up to the next flag: `--add-dir a b`.
    Many,
}

/// How `flag` of `harness` takes values; `None` for a flag this list does
/// not know.
fn takes(harness: &str, flag: &str) -> Option<Takes> {
    let found = |nothing: &[&str], one: &[&str], many: &[&str]| {
        if nothing.contains(&flag) {
            Some(Takes::Nothing)
        } else if one.contains(&flag) {
            Some(Takes::One)
        } else if many.contains(&flag) {
            Some(Takes::Many)
        } else {
            None
        }
    };
    match harness {
        "claude" => found(
            &[
                "--dangerously-skip-permissions",
                "--allow-dangerously-skip-permissions",
                "--verbose",
                "--ide",
                "--strict-mcp-config",
                "--chrome",
                "--no-chrome",
                "--disable-slash-commands",
            ],
            &[
                "--model",
                "--permission-mode",
                "--settings",
                "--setting-sources",
                "--append-system-prompt",
                "--system-prompt",
                "--agents",
                "--agent",
                "--fallback-model",
                "--debug-file",
                "--effort",
                "--permission-prompt-tool",
            ],
            &[
                "--add-dir",
                "--mcp-config",
                "--allowedTools",
                "--allowed-tools",
                "--disallowedTools",
                "--disallowed-tools",
                "--plugin-dir",
                "--betas",
            ],
        ),
        "codex" => found(
            &[
                "--dangerously-bypass-approvals-and-sandbox",
                "--yolo",
                "--full-auto",
                "--search",
                "--oss",
                "--no-alt-screen",
            ],
            &[
                "-m",
                "--model",
                "-c",
                "--config",
                "-p",
                "--profile",
                "-s",
                "--sandbox",
                "-a",
                "--ask-for-approval",
                "-C",
                "--cd",
                "--enable",
                "--disable",
                "--local-provider",
            ],
            &["-i", "--image", "--add-dir"],
        ),
        // `muse --help`, Muse Code 1.4.14. `-w`/`--worktree` takes an
        // optional value: as One, a following mode word goes with it.
        "muse" => found(
            &[
                "--yolo",
                "--disable-request-user-input",
                "--trust-workspace",
                "--disable-approval",
                "--disable-sandbox",
                "--disable-write",
                "--disable-shell",
                "--enable-shell-tool",
                "--parallel-tool-calls",
                "--no-parallel-tool-calls",
                "--subagent-worktree-isolation",
                "--no-session-log",
            ],
            &[
                "--agents",
                "--provider",
                "--preset",
                "--model",
                "--contributor-mode",
                "-c",
                "--config",
                "--reasoning-effort",
                "--effort",
                "--base-url",
                "--image",
                "--workspace",
                "-w",
                "--worktree",
                "--worktree-base",
                "--worktree-existing",
                "--approval-mode",
                "--permission-profile",
                "--approval-judge",
                "--sandbox-network",
                "--echo-delay-ms",
            ],
            &[],
        ),
        _ => None,
    }
}

/// `argument` as its flag and the value given with it: `--flag=value`, or a
/// short flag that takes a value with the value attached (`-cKEY=VALUE`,
/// `-mgpt-5.5`); else the whole argument and none.
fn split_flag<'a>(harness: &str, argument: &'a str) -> (&'a str, Option<&'a str>) {
    if let Some((flag, value)) = argument.split_once('=')
        && flag.starts_with("--")
    {
        return (flag, Some(value));
    }
    if !argument.starts_with("--") && argument.len() > 2 && argument.is_char_boundary(2) {
        let (flag, value) = argument.split_at(2);
        if matches!(takes(harness, flag), Some(Takes::One | Takes::Many)) {
            return (flag, Some(value));
        }
    }
    (argument, None)
}

/// Whether the value of `flag` is inline configuration (JSON for Claude
/// Code's `--settings`, `--mcp-config` and `--agents`, TOML for Codex's
/// `-c`), which can hold a credential that no shape check finds: never kept.
fn inline_config(harness: &str, flag: &str, value: &str) -> bool {
    match harness {
        "claude" => {
            matches!(flag, "--settings" | "--mcp-config" | "--agents")
                && matches!(value.trim_start().chars().next(), Some('{' | '['))
        }
        "codex" => matches!(flag, "-c" | "--config"),
        "muse" => {
            matches!(flag, "-c" | "--config")
                || (flag == "--agents"
                    && matches!(value.trim_start().chars().next(), Some('{' | '[')))
        }
        _ => false,
    }
}

/// Whether one argument may hold a credential anywhere in it: a secret word
/// ([`names_secret`]) or a token prefix at any position.
fn holds_secret(argument: &str) -> bool {
    names_secret(argument) || TOKEN_PREFIXES.iter().any(|prefix| argument.contains(prefix))
}

/// `args` without what picks or starts a session, without prompts, inline
/// configuration or a credential-looking flag or value; `None` when they do
/// not start an interactive session (a subcommand, `-p`, `--version`).
fn session_free(harness: &str, args: &[String]) -> Option<Vec<String>> {
    let mut kept = Vec::with_capacity(args.len());
    let mut index = 0;
    let mut first_word = true;
    while index < args.len() {
        let argument = args[index].as_str();
        index += 1;
        if argument == "--" {
            break; // Everything after `--` is a prompt.
        }
        if !argument.starts_with('-') || argument == "-" {
            if first_word {
                first_word = false;
                match (harness, argument) {
                    // `codex resume <id>`, `codex resume --last` or `codex fork
                    // <id>`: the session is picked anew.
                    ("codex", "resume" | "fork") => {
                        if args.get(index).is_some_and(|next| !next.starts_with('-')) {
                            index += 1;
                        }
                        continue;
                    }
                    // A Codex first word that is not a known subcommand is the
                    // session's first prompt, dropped like Claude's.
                    // `muse resume <session-ref>` or `muse resume --last`.
                    ("muse", "resume") => {
                        if args.get(index).is_some_and(|next| !next.starts_with('-')) {
                            index += 1;
                        }
                        continue;
                    }
                    ("codex", word) if CODEX_NON_INTERACTIVE.contains(&word) => return None,
                    ("claude", word) if CLAUDE_SUBCOMMANDS.contains(&word) => return None,
                    ("muse", word) if MUSE_NON_INTERACTIVE.contains(&word) => return None,
                    _ => {}
                }
            }
            continue; // A prompt.
        }
        let (flag, inline) = split_flag(harness, argument);
        match (harness, flag) {
            ("claude", "-p" | "--print" | "-v" | "--version" | "-h" | "--help")
            | ("codex" | "muse", "-V" | "--version" | "-h" | "--help") => return None,
            ("claude", "--resume" | "-r" | "--session-id" | "--from-pr") => {
                if inline.is_none() && args.get(index).is_some_and(|next| !next.starts_with('-')) {
                    index += 1;
                }
                continue;
            }
            ("claude", "--continue" | "-c" | "--fork-session")
            | ("codex", "--last" | "--all")
            | ("muse", "--last") => {
                continue;
            }
            // A worktree flag would make a new worktree instead of resuming in
            // the session's; an image would be attached again.
            (
                "muse",
                "-w" | "--worktree" | "--worktree-base" | "--worktree-existing" | "--image",
            ) => {
                if inline.is_none()
                    && takes(harness, flag) == Some(Takes::One)
                    && args.get(index).is_some_and(|next| !next.starts_with('-'))
                {
                    index += 1;
                }
                continue;
            }
            _ => {}
        }
        let mut values = Vec::new();
        match (takes(harness, flag), inline) {
            (Some(Takes::Nothing), _) => {}
            (Some(_), Some(value)) => values.push(value.to_string()),
            (Some(Takes::One), None) => {
                if let Some(value) = args.get(index) {
                    values.push(value.clone());
                    index += 1;
                }
            }
            (Some(Takes::Many), None) => {
                while let Some(value) = args.get(index).filter(|value| !value.starts_with('-')) {
                    values.push(value.clone());
                    index += 1;
                }
            }
            (None, Some(_)) => {}
            (None, None) => {
                // An unknown flag that took a value would take the next word
                // of the resume command instead: drop it with that value. One
                // followed by a flag (or nothing) is a boolean and is kept.
                if args.get(index).is_some_and(|next| !next.starts_with('-')) {
                    index += 1;
                    continue;
                }
            }
        }
        if holds_secret(flag)
            || values.iter().any(|value| holds_secret(value) || inline_config(harness, flag, value))
        {
            continue;
        }
        match inline {
            Some(_) => kept.push(argument.to_string()),
            None => {
                kept.push(argument.to_string());
                kept.extend(values);
            }
        }
    }
    Some(kept)
}

#[cfg(test)]
mod tests;
