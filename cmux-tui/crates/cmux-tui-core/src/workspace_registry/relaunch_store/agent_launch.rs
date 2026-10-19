//! How the agent CLI a terminal ran was started, kept in the relaunch record
//! with its session so a respawn after the terminal's host died (a reboot)
//! starts it the way classic cmux does: the same flags and the same account.
//!
//! - `args`: the CLI's arguments without the ones that pick or start a
//!   session (`--resume <id>`, `--continue`, `codex resume <id>`, ...) and
//!   without a positional first prompt (it would be sent again). Taken from
//!   `CMUX_TUI_AGENT_ARGS`, which the cmux `claude` and `codex` shims set to
//!   the arguments they were given, else from the process's argv after the
//!   program word. A non-interactive run (`claude -p`, `codex exec`, ...) has
//!   no launch. Arguments that look like a credential drop all of them
//!   ([`stored_argv`]): the resume then starts the CLI with no flags.
//! - `env`: the harness's account directory only (`CLAUDE_CONFIG_DIR` for
//!   Claude Code, `CODEX_HOME` for Codex), an absolute path. Never a token
//!   or key: the CLI reads its sign-in from that directory.

use std::path::Path;

use super::stored_argv;

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

/// The account directory variable of a resumable harness.
pub(crate) fn account_env_key(harness: &str) -> Option<&'static str> {
    match harness {
        "claude" => Some("CLAUDE_CONFIG_DIR"),
        "codex" => Some("CODEX_HOME"),
        _ => None,
    }
}

/// The launch of `harness` from its process's `argv` and `env` (the keys of
/// [`AGENT_JOB_ENV_KEYS`] it has). `None` when the process is not that
/// harness's CLI or is a non-interactive run.
pub(crate) fn agent_launch_from_job(
    harness: &str,
    argv: &[String],
    env: &[(String, String)],
) -> Option<AgentLaunch> {
    let account_key = account_env_key(harness)?;
    let value = |key: &str| env.iter().find(|(name, _)| name == key).map(|(_, value)| value);
    let given = value(SHIM_ARGS_ENV).and_then(|json| serde_json::from_str::<Vec<String>>(json).ok());
    let args = match given {
        Some(args) => args,
        None => {
            let at = argv.iter().position(|argument| is_program(harness, argument))?;
            argv[at + 1..].to_vec()
        }
    };
    let args = session_free(harness, &args)?;
    let mut line = vec![harness.to_string()];
    line.extend(args);
    let args = stored_argv(&line).map(|line| line[1..].to_vec()).unwrap_or_default();
    let env = value(account_key)
        .filter(|dir| Path::new(dir.as_str()).is_absolute() && !dir.chars().any(char::is_control))
        .map(|dir| vec![(account_key.to_string(), dir.clone())])
        .unwrap_or_default();
    Some(AgentLaunch { args, env })
}

/// Whether `argument` names the harness's program: `claude`, `codex`, or the
/// JS entry an npm install runs under `node` (`.../claude-code/cli.js`,
/// `.../codex.js`).
fn is_program(harness: &str, argument: &str) -> bool {
    let name = Path::new(argument).file_name().and_then(|name| name.to_str()).unwrap_or_default();
    name == harness
        || name == format!("{harness}.js")
        || (harness == "claude" && name == "cli.js" && argument.contains("claude-code"))
}

/// Flags of each CLI that take a value (the next argument, unless given as
/// `--flag=value`). Any other bare argument is a positional prompt.
fn takes_value(harness: &str, flag: &str) -> bool {
    let claude: &[&str] = &[
        "--model",
        "--permission-mode",
        "--add-dir",
        "--settings",
        "--setting-sources",
        "--mcp-config",
        "--allowedTools",
        "--allowed-tools",
        "--disallowedTools",
        "--disallowed-tools",
        "--append-system-prompt",
        "--system-prompt",
        "--agents",
        "--agent",
        "--fallback-model",
        "--plugin-dir",
        "--betas",
        "--debug-file",
    ];
    let codex: &[&str] = &[
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
        "-i",
        "--image",
        "--enable",
        "--disable",
        "--add-dir",
        "--local-provider",
    ];
    match harness {
        "claude" => claude.contains(&flag),
        "codex" => codex.contains(&flag),
        _ => false,
    }
}

/// `args` without what picks or starts a session and without positional
/// prompts; `None` for a non-interactive run.
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
        let flag = argument.split('=').next().unwrap_or(argument);
        let has_value = argument.contains('=');
        if !argument.starts_with('-') {
            if harness == "codex" && first_word {
                match argument {
                    // `codex resume <id>` or `codex resume --last`: the session is picked anew.
                    "resume" => {
                        if args.get(index).is_some_and(|next| !next.starts_with('-')) {
                            index += 1;
                        }
                        first_word = false;
                        continue;
                    }
                    "exec" | "e" | "login" | "logout" | "mcp" | "mcp-server" | "app-server"
                    | "apply" | "a" | "sandbox" | "debug" | "completion" | "cloud" | "fork"
                    | "proto" | "generate-ts" | "help" => return None,
                    _ => {}
                }
            }
            first_word = false;
            continue; // A prompt.
        }
        match (harness, flag) {
            ("claude", "-p" | "--print") | ("claude", "-v" | "--version") | ("claude", "-h" | "--help") => {
                return None;
            }
            ("codex", "-V" | "--version" | "-h" | "--help") => return None,
            ("claude", "--resume" | "-r" | "--session-id") => {
                if !has_value && args.get(index).is_some_and(|next| !next.starts_with('-')) {
                    index += 1;
                }
                continue;
            }
            ("claude", "--continue" | "-c" | "--fork-session") | ("codex", "--last" | "--all") => {
                continue;
            }
            _ => {}
        }
        kept.push(argument.to_string());
        if !has_value && takes_value(harness, flag) && let Some(value) = args.get(index) {
            kept.push(value.clone());
            index += 1;
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
        let npm = strings(&["node", "/usr/lib/node_modules/@anthropic-ai/claude-code/cli.js", "--verbose"]);
        assert_eq!(agent_launch_from_job("claude", &npm, &[]).unwrap().args, strings(&["--verbose"]));
        let wrapped = strings(&["python3", "/tmp/fake.py", "codex", "-m", "gpt-5.5"]);
        assert_eq!(agent_launch_from_job("codex", &wrapped, &[]).unwrap().args, strings(&["-m", "gpt-5.5"]));
        assert!(agent_launch_from_job("claude", &strings(&["zsh", "-l"]), &[]).is_none());
        assert!(agent_launch_from_job("opencode", &strings(&["opencode"]), &[]).is_none());
    }

    #[test]
    fn codex_resume_and_non_interactive_runs() {
        let resumed = strings(&["codex", "resume", "abc", "--dangerously-bypass-approvals-and-sandbox", "-m", "gpt"]);
        assert_eq!(
            agent_launch_from_job("codex", &resumed, &[]).unwrap().args,
            strings(&["--dangerously-bypass-approvals-and-sandbox", "-m", "gpt"])
        );
        assert!(agent_launch_from_job("codex", &strings(&["codex", "exec", "do it"]), &[]).is_none());
        assert!(agent_launch_from_job("claude", &strings(&["claude", "-p", "hi"]), &[]).is_none());
    }

    #[test]
    fn a_credential_drops_the_flags_and_a_relative_account_is_not_kept() {
        let launch = agent_launch_from_job(
            "claude",
            &strings(&["claude", "--model", "opus", "--api-key", "sk-ant-123"]),
            &env(&[("CLAUDE_CONFIG_DIR", "relative/dir")]),
        )
        .unwrap();
        assert!(launch.args.is_empty());
        assert!(launch.env.is_empty());
    }
}
