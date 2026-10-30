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
mod tests {
    use super::*;

    fn strings(values: &[&str]) -> Vec<String> {
        values.iter().map(|value| value.to_string()).collect()
    }

    fn env(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
        pairs.iter().map(|(key, value)| (key.to_string(), value.to_string())).collect()
    }

    #[test]
    fn claude_keeps_flags_and_account_and_drops_session_and_prompt() {
        let launch = agent_launch_from_job(
            "claude",
            &strings(&[
                "/opt/homebrew/bin/claude",
                "--dangerously-skip-permissions",
                "--model",
                "opus",
                "--resume",
                "old-id",
                "--continue",
                "fix the bug",
            ]),
            &env(&[("CLAUDE_CONFIG_DIR", "/Users/a/.claude-work"), ("CODEX_HOME", "/x")]),
        )
        .unwrap();
        assert_eq!(launch.args, strings(&["--dangerously-skip-permissions", "--model", "opus"]));
        assert_eq!(launch.env, env(&[("CLAUDE_CONFIG_DIR", "/Users/a/.claude-work")]));
    }

    #[test]
    fn the_shims_arguments_win_over_the_injected_argv() {
        let args = r#"["--model","sonnet","--settings","/Users/a/s.json"]"#;
        let launch = agent_launch_from_job(
            "claude",
            &strings(&["claude", "--settings", "/cache/hooks-123.json", "--model", "sonnet"]),
            &env(&[(SHIM_ARGS_ENV, args)]),
        )
        .unwrap();
        assert_eq!(launch.args, strings(&["--model", "sonnet", "--settings", "/Users/a/s.json"]));
        assert!(launch.env.is_empty());
    }

    #[test]
    fn node_installs_and_wrappers_find_the_program_word() {
        let npm = strings(&[
            "node",
            "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js",
            "--verbose",
        ]);
        assert_eq!(
            agent_launch_from_job("claude", &npm, &[]).unwrap().args,
            strings(&["--verbose"])
        );
        let wrapped = strings(&["python3", "/tmp/fake.py", "codex", "-m", "gpt-5.5"]);
        assert_eq!(
            agent_launch_from_job("codex", &wrapped, &[]).unwrap().args,
            strings(&["-m", "gpt-5.5"])
        );
        assert!(agent_launch_from_job("claude", &strings(&["zsh", "-l"]), &[]).is_none());
        assert!(agent_launch_from_job("opencode", &strings(&["opencode"]), &[]).is_none());
    }

    #[test]
    fn codex_resume_and_non_interactive_runs() {
        let resumed = strings(&[
            "codex",
            "resume",
            "abc",
            "--dangerously-bypass-approvals-and-sandbox",
            "-m",
            "gpt",
        ]);
        assert_eq!(
            agent_launch_from_job("codex", &resumed, &[]).unwrap().args,
            strings(&["--dangerously-bypass-approvals-and-sandbox", "-m", "gpt"])
        );
        assert!(
            agent_launch_from_job("codex", &strings(&["codex", "exec", "do it"]), &[]).is_none()
        );
        assert!(agent_launch_from_job("claude", &strings(&["claude", "-p", "hi"]), &[]).is_none());
    }

    /// A non-interactive run of the harness (`claude -p`, `codex exec`) has
    /// no session to resume; an interactive one, another program, or a
    /// process that could not be read says nothing.
    #[test]
    fn a_non_interactive_run_is_told_apart_from_an_unknown_process() {
        let non_interactive =
            |harness: &str, argv: &[&str]| job_is_non_interactive(harness, &strings(argv), &[]);
        assert!(non_interactive("claude", &["claude", "-p", "hi"]));
        assert!(non_interactive("claude", &["/bin/sh", "/tmp/x/claude", "--print", "hi"]));
        assert!(non_interactive("codex", &["codex", "exec", "do it"]));
        assert!(non_interactive("claude", &["claude", "mcp", "list"]));
        assert!(non_interactive("claude", &["claude", "--model", "opus", "-p", "hi"]));
        assert!(non_interactive("codex", &["codex", "-m", "gpt-5.5", "exec", "do it"]));
        assert!(non_interactive("codex", &["codex", "--version"]));
        assert!(!non_interactive("claude", &["claude", "--model", "opus"]));
        assert!(!non_interactive("claude", &["claude", "fix the bug"]));
        // An interactive Codex session started with its first prompt.
        assert!(!non_interactive("codex", &["codex", "fix the bug"]));
        assert!(!non_interactive("codex", &["codex", "-m", "gpt-5.5", "fix the bug"]));
        assert!(!non_interactive("codex", &["codex", "resume", "abc"]));
        assert!(!non_interactive("claude", &["zsh", "-l"]));
        assert!(!non_interactive("opencode", &["opencode", "run", "x"]));
        // The shim's arguments are the CLI's own.
        let shim = env(&[(SHIM_ARGS_ENV, r#"["-p","hi"]"#)]);
        assert!(job_is_non_interactive("claude", &strings(&["claude", "-p", "hi"]), &shim));
    }

    #[test]
    fn a_credential_drops_the_flags_and_a_relative_account_is_not_kept() {
        let launch = agent_launch_from_job(
            "claude",
            &strings(&["claude", "--model", "opus", "--api-key", "sk-ant-123"]),
            &env(&[("CLAUDE_CONFIG_DIR", "relative/dir")]),
        )
        .unwrap();
        assert_eq!(launch.args, strings(&["--model", "opus"]));
        assert!(launch.env.is_empty());
    }

    #[test]
    fn an_unknown_flag_goes_with_its_value_and_lists_keep_every_value() {
        let launch = agent_launch_from_job(
            "claude",
            &strings(&[
                "claude",
                "--output-format",
                "stream-json",
                "--add-dir",
                "a",
                "b",
                "--verbose",
                "--max-turns",
                "3",
                "--model",
                "opus",
                "--some-switch",
            ]),
            &[],
        )
        .unwrap();
        assert_eq!(
            launch.args,
            strings(&["--add-dir", "a", "b", "--verbose", "--model", "opus", "--some-switch"])
        );
    }

    #[test]
    fn inline_configuration_and_secrets_anywhere_are_dropped() {
        let claude = agent_launch_from_job(
            "claude",
            &strings(&[
                "claude",
                "--settings",
                r#"{"env":{"ANTHROPIC_BASE_URL":"x"}}"#,
                "--mcp-config",
                "/p/mcp.json",
                "--append-system-prompt",
                "use ghp_abc for it",
                "--model",
                "opus",
            ]),
            &[],
        )
        .unwrap();
        assert_eq!(claude.args, strings(&["--mcp-config", "/p/mcp.json", "--model", "opus"]));
        let codex = agent_launch_from_job(
            "codex",
            &strings(&[
                "codex",
                "-c",
                "mcp_servers.x.env={API=\"1\"}",
                "--config=a=b",
                r#"-csandbox_mode="danger-full-access""#,
                "-m",
                "gpt",
            ]),
            &[],
        )
        .unwrap();
        assert_eq!(codex.args, strings(&["-m", "gpt"]));
    }

    #[test]
    fn codex_runs_only_without_a_subcommand_or_as_resume() {
        assert!(agent_launch_from_job("codex", &strings(&["codex", "cloud"]), &[]).is_none());
        // An interactive session started with its first prompt keeps its flags and account.
        let prompted = agent_launch_from_job(
            "codex",
            &strings(&["codex", "-m", "gpt", "fix the bug"]),
            &env(&[("CODEX_HOME", "/accounts/work")]),
        )
        .unwrap();
        assert_eq!(prompted.args, strings(&["-m", "gpt"]));
        assert_eq!(prompted.env, env(&[("CODEX_HOME", "/accounts/work")]));
        assert!(
            agent_launch_from_job("claude", &strings(&["claude", "mcp", "list"]), &[]).is_none()
        );
        let plain = agent_launch_from_job("codex", &strings(&["codex", "-m", "gpt"]), &[]).unwrap();
        assert_eq!(plain.args, strings(&["-m", "gpt"]));
    }

    /// Muse Code's `muse` launcher `exec`s its versioned binary: that is the
    /// process the terminal runs. Its flags are kept; what picks a session, a
    /// worktree or an image, and inline configuration are not.
    #[test]
    fn muse_keeps_its_flags_from_the_binary_its_launcher_runs() {
        let binary = "/Users/a/.local/bin/muse-bin-1.4.14-R7309.1";
        let yolo = agent_launch_from_job("muse", &strings(&[binary, "--yolo"]), &[]).unwrap();
        assert_eq!(yolo, AgentLaunch { args: strings(&["--yolo"]), env: Vec::new() });
        let resumed = agent_launch_from_job(
            "muse",
            &strings(&[
                "muse",
                "--model",
                "muse-wonder-1.0",
                "resume",
                "01a14ec1-9cca-7b72-832c-5148ab7bcd41",
                "-w",
                "create",
                "--image",
                "/tmp/a.png",
                "-c",
                "provider.token=${T}",
                "--agents",
                "{\"a\":1}",
                "--approval-mode",
                "never",
            ]),
            &[],
        )
        .unwrap();
        assert_eq!(
            resumed.args,
            strings(&["--model", "muse-wonder-1.0", "--approval-mode", "never"])
        );
        let last = agent_launch_from_job("muse", &strings(&["muse", "resume", "--last"]), &[]);
        assert_eq!(last.unwrap().args, Vec::<String>::new());
        // A prompt starts a session; it is not kept.
        let prompted =
            agent_launch_from_job("muse", &strings(&["muse", "--effort", "max", "fix it"]), &[]);
        assert_eq!(prompted.unwrap().args, strings(&["--effort", "max"]));
        for run in [&["muse", "exec", "hi"][..], &["muse", "--version"], &["muse", "usage"]] {
            assert!(agent_launch_from_job("muse", &strings(run), &[]).is_none(), "{run:?}");
            assert!(job_is_non_interactive("muse", &strings(run), &[]), "{run:?}");
        }
        assert!(!job_is_non_interactive("muse", &strings(&[binary, "--yolo"]), &[]));
        // Another program is not Muse.
        assert!(agent_launch_from_job("muse", &strings(&["zsh", "-l"]), &[]).is_none());
        assert!(
            agent_launch_from_job("muse", &strings(&["museum"]), &[]).is_none(),
            "only muse and its launcher's binary"
        );
    }

    #[test]
    fn the_shims_arguments_need_the_harness_process() {
        let args = r#"["--model","opus"]"#;
        let other = strings(&["node", "/usr/lib/node_modules/some-tool/index.js"]);
        assert!(agent_launch_from_job("claude", &other, &env(&[(SHIM_ARGS_ENV, args)])).is_none());
    }
}
