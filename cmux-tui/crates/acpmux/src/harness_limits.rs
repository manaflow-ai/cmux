//! The harness limits acpmux lifts for the sessions it starts (Leo
//! 2026-10-14, "no caps on subagents"): Claude Code and Codex cap how many
//! subagents run, how deep they nest and how long a background command may
//! run, and a chat that hit a cap had to be restarted with it raised. Every
//! session acpmux starts (direct, hosted or pooled; `agent::harness_command`)
//! gets them lifted at spawn, so a new chat has them without a restart.
//!
//! The guard against a runaway is to be a per-session resource limit the
//! session's holder enforces (a cgroup, its own process group), never a
//! count and never a process scan (plans/cmux-next/pty-holder.md 4). A value
//! the user set wins: a profile's env or the login environment for Claude;
//! for Codex, a `-c`/`--config` of the same key in the profile's command
//! line or the key in codex's own config (`config.toml`, its active profile,
//! the project's).

/// Claude Code's environment knobs and the values acpmux starts it with
/// (defaults are Claude Code 2.1.299's).
pub const CLAUDE_ENV: &[(&str, &str)] = &[
    // Subagents running at once (default 20).
    ("CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS", "1000"),
    // Subagents one session may start in all.
    ("CLAUDE_CODE_MAX_SUBAGENTS_PER_SESSION", "100000"),
    // How deep subagents may start subagents (default 3).
    ("CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH", "16"),
    // Tool calls of one response run at once (default 10).
    ("CLAUDE_CODE_MAX_TOOL_USE_CONCURRENCY", "64"),
    // The longest `timeout` a Bash call may ask for, which is also how long
    // a background command may run in an unattended session such as ours
    // (default 2 h; this is Claude Code's own ceiling, about 24.8 days).
    // `BASH_DEFAULT_TIMEOUT_MS` (30 min) stays: raising it would also hold
    // every foreground command, a subagent's included, that long before it
    // times out.
    ("BASH_MAX_TIMEOUT_MS", "2147483647"),
];

/// Codex's config keys (`-c key=value`) and their values (defaults are
/// codex 0.162.1's).
pub const CODEX_CONFIG: &[(&str, &str)] = &[
    // Agent threads one session may run at once (default 6).
    ("agents.max_concurrent_threads_per_session", "1000"),
    // How deep agent threads may nest (default 1).
    ("agents.max_depth", "16"),
];

/// A session's Claude Code (`agent::harness_command`) gets each knob its env
/// (profile, login environment) leaves unset.
pub fn lift_claude(
    cmd: &mut tokio::process::Command,
    profile: &crate::config::HarnessProfile,
    session: bool,
    inherit_ambient: bool,
) {
    if profile.kind == crate::config::HarnessKind::ClaudeStdio && session {
        let have = if inherit_ambient {
            crate::agent::command_env(cmd)
        } else {
            crate::agent::command_env_cleared(cmd)
        };
        for (key, value) in claude_env(&have) {
            cmd.env(key, value);
        }
    }
}

/// The arguments a session's harness, started in `cwd` with the profile's
/// `env`, starts with: a `codex app-server` launch's with acpmux's
/// overrides (`codex_args`), any other's as given. `None` for a launch
/// without a session.
pub fn launch_args(
    program: &str,
    args: &[String],
    session: Option<(&std::path::Path, &std::collections::BTreeMap<String, String>)>,
) -> Vec<String> {
    match session {
        Some((cwd, env)) if crate::codex_app_server::is_launch(program, args) => {
            let home = env.get("CODEX_HOME").map(std::path::PathBuf::from);
            let configs = codex_configs(cwd, home);
            codex_args(args.to_vec(), &configs)
        }
        _ => args.to_vec(),
    }
}

/// The Claude knobs `env` (what the harness would get) leaves unset, with
/// acpmux's values.
pub fn claude_env(env: &[(String, String)]) -> Vec<(&'static str, &'static str)> {
    CLAUDE_ENV.iter().copied().filter(|(k, _)| !env.iter().any(|(key, _)| key == k)).collect()
}

/// `args` of a `codex app-server` launch with acpmux's config overrides
/// first (global options go before the subcommand), each only when neither
/// `args` nor codex's `configs` set that key already.
pub fn codex_args(args: Vec<String>, configs: &[toml::Table]) -> Vec<String> {
    let profile = codex_profile(&args, configs);
    let mut lifted: Vec<String> = Vec::new();
    for (key, value) in CODEX_CONFIG {
        let in_config = configs.iter().any(|c| {
            toml_has(c, key)
                || profile.as_ref().is_some_and(|p| {
                    c.get("profiles")
                        .and_then(|ps| ps.get(p.as_str()))
                        .is_some_and(|t| t.as_table().is_some_and(|t| toml_has(t, key)))
                })
        });
        if !in_config && !sets_codex_key(&args, key) {
            lifted.push("-c".into());
            lifted.push(format!("{key}={value}"));
        }
    }
    lifted.extend(args);
    lifted
}

/// Codex's config files that apply in `cwd`: `.codex/config.toml` in `cwd`
/// and the directories above it, nearest first (a project's wins), then
/// `config.toml` in `home` (the profile's `CODEX_HOME`, else the daemon's,
/// else `~/.codex`). Unreadable ones count as empty.
fn codex_configs(cwd: &std::path::Path, home: Option<std::path::PathBuf>) -> Vec<toml::Table> {
    let home = home
        .or_else(|| std::env::var_os("CODEX_HOME").map(std::path::PathBuf::from))
        .or_else(|| dirs::home_dir().map(|h| h.join(".codex")));
    cwd.ancestors()
        .map(|d| d.join(".codex/config.toml"))
        .chain(home.map(|h| h.join("config.toml")))
        .filter_map(|path| std::fs::read_to_string(path).ok()?.parse::<toml::Table>().ok())
        .collect()
}

/// The codex profile the launch uses: `--profile`/`-p` in `args`, else
/// `profile = "…"` in a config.
fn codex_profile(args: &[String], configs: &[toml::Table]) -> Option<String> {
    let from_args = args.iter().enumerate().find_map(|(i, a)| match a.as_str() {
        "-p" | "--profile" => args.get(i + 1).cloned(),
        _ => a.strip_prefix("--profile=").map(str::to_owned),
    });
    from_args.or_else(|| {
        configs
            .iter()
            .find_map(|c| c.get("profile").and_then(toml::Value::as_str).map(str::to_owned))
    })
}

/// Whether `table` has the dotted `key`.
fn toml_has(table: &toml::Table, key: &str) -> bool {
    let mut parts = key.split('.');
    let Some(first) = parts.next() else { return false };
    let mut value = table.get(first);
    for part in parts {
        value = value.and_then(|v| v.get(part));
    }
    value.is_some()
}

/// Whether `args` sets `key` with `-c key=…`, `--config key=…` or
/// `--config=key=…`.
fn sets_codex_key(args: &[String], key: &str) -> bool {
    let sets = |value: &str| value.split_once('=').is_some_and(|(k, _)| k.trim() == key);
    args.iter().enumerate().any(|(i, a)| match a.as_str() {
        "-c" | "--config" => args.get(i + 1).is_some_and(|v| sets(v)),
        _ => a.strip_prefix("--config=").is_some_and(sets),
    })
}
