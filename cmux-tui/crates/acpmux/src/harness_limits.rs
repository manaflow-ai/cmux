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

/// The autocompact window acpmux starts a Claude Code session with when the person set none
/// (`usage_stats::claude_autocompact_unset`). Claude Code compacts only near the model's own
/// window, 1M for a `[1m]` model; Leo runs his sessions at 400k (Leo 2026-10-20: "I think I
/// usually have, like, 400K on my typical [Claude] sessions"), and Claude Code's /context then
/// reads against 400k too.
pub const CLAUDE_AUTOCOMPACT_WINDOW: (&str, &str) = ("CLAUDE_CODE_AUTO_COMPACT_WINDOW", "400000");

/// What a `claude` started in a cmux terminal or an agent chat gets on top of [`CLAUDE_ENV`]
/// (Leo 2026-11-24, on helpers dying on "503 no non-exhausted claude accounts": "we shouldn't
/// run into this, design out the error class"). A chat's own turn is continued by acpmux, but
/// a helper (Claude Code's Agent tool) runs inside the chat's process, where acpmux cannot see
/// or continue it: without the watchdog its request gave up after Claude Code's 10 retries and
/// the parent got a dead helper. Terminals first (Leo 2026-11-24:
/// "in terminals and guis alike perhaps terminal simply needs to also have the fixes and
/// enhancements"). An agent chat survives a capacity outage in acpmux: a turn that Claude
/// Code ends with "Repeated 529 Overloaded errors" is continued after a wait, with no limit
/// on attempts (`hub::auto_resume::capacity_wait`, cmux#52824). A terminal has no acpmux
/// behind it, so the same outage left the person at an "API Error: Repeated 529" prompt.
/// Claude Code waits a 529 out in place under its retry watchdog in the capacity scope
/// (`CLAUDE_CODE_RETRY_WATCHDOG=1`, `CLAUDE_CODE_RETRY_WATCHDOG_SCOPE=capacity`): it stops
/// giving up after 3 straight 529s and backs off (to 5 min a wait) with no time budget, as
/// the chat's continuation has no attempt limit; the scope keeps the watchdog's other
/// retries off. Measured on Claude Code 2.1.331 against a server answering six 529s: without
/// it `claude -p` failed after 3 requests in 4 s ("Repeated 529 Overloaded errors"); with it
/// the 7th request answered. `CLAUDE_CODE_OVERLOADED_RETRY_MAX_WAIT_MS` alone did not change
/// that run. The watchdog would also sit out a plan's usage limit until it resets; a 0 budget
/// for that keeps the usage limit in front of the person, as before. Esc still stops the wait.
/// A person who set any of [`CLAUDE_RETRY_CHOICES`] keeps theirs and gets none of these.
pub const CLAUDE_TERMINAL_ENV: &[(&str, &str)] = &[
    ("CLAUDE_CODE_RETRY_WATCHDOG", "1"),
    ("CLAUDE_CODE_RETRY_WATCHDOG_SCOPE", "capacity"),
    ("CLAUDE_CODE_RETRY_WATCHDOG_MAX_USAGE_LIMIT_WAIT_MS", "0"),
];

/// Claude Code's own retry settings: one set by the person means they chose how it retries,
/// so [`CLAUDE_TERMINAL_ENV`] is left out whole.
pub const CLAUDE_RETRY_CHOICES: &[&str] = &[
    "CLAUDE_CODE_RETRY_WATCHDOG",
    "CLAUDE_CODE_RETRY_WATCHDOG_SCOPE",
    "CLAUDE_CODE_RETRY_WATCHDOG_MAX_WAIT_MS",
    "CLAUDE_CODE_RETRY_WATCHDOG_MAX_USAGE_LIMIT_WAIT_MS",
    "CLAUDE_CODE_MAX_RETRIES",
    "CLAUDE_CODE_OVERLOADED_RETRY_MAX_WAIT_MS",
];

/// The environment a terminal's `claude` starts with beyond its own (the cmux-tui Claude
/// wrapper): every [`CLAUDE_ENV`] and [`CLAUDE_TERMINAL_ENV`] knob `getenv` leaves unset, and
/// the chats' autocompact window ([`CLAUDE_AUTOCOMPACT_WINDOW`]) when neither the launch
/// (`args`), its env nor Claude's settings choose one, exactly as [`lift_claude`] does for an
/// agent chat.
pub fn terminal_claude_env(
    args: &[String],
    cwd: &std::path::Path,
    getenv: impl Fn(&str) -> Option<String>,
) -> Vec<(&'static str, &'static str)> {
    let retry_chosen = CLAUDE_RETRY_CHOICES.iter().any(|name| getenv(name).is_some());
    let terminal = if retry_chosen { &[][..] } else { CLAUDE_TERMINAL_ENV };
    let mut lifted: Vec<(&'static str, &'static str)> = CLAUDE_ENV
        .iter()
        .chain(terminal)
        .copied()
        .filter(|(key, _)| getenv(key).is_none())
        .collect();
    let (key, value) = CLAUDE_AUTOCOMPACT_WINDOW;
    let env =
        ["CLAUDE_CONFIG_DIR", "CLAUDE_CODE_AUTO_COMPACT_WINDOW", "CLAUDE_AUTOCOMPACT_PCT_OVERRIDE"]
            .into_iter()
            .filter_map(|name| getenv(name).map(|value| (name.to_string(), value)))
            .collect();
    let source = crate::usage_stats::Source {
        family: "claude".into(),
        argv: Some(std::iter::once("claude".to_string()).chain(args.iter().cloned()).collect()),
        cwd: cwd.to_path_buf(),
        env,
        ..Default::default()
    };
    if crate::usage_stats::claude_autocompact_unset(&source) {
        lifted.push((key, value));
    }
    lifted
}

/// Codex's config keys (`-c key=value`) and their values (defaults are
/// codex 0.162.1's).
pub const CODEX_CONFIG: &[(&str, &str)] = &[
    // Agent threads one session may run at once (default 6).
    ("agents.max_concurrent_threads_per_session", "1000"),
    // How deep agent threads may nest (default 1).
    ("agents.max_depth", "16"),
    // The plan tool (`update_plan`, off by default in 0.164): the turn's task
    // list, which the bridge sends as the ACP `plan` the agent pane pins.
    ("tools.update_plan.enabled", "true"),
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
        for (key, value) in claude_retry_env(&have) {
            cmd.env(key, value);
        }
        let source = crate::usage_stats::Source {
            family: "claude".into(),
            argv: Some(command_line(cmd)),
            cwd: cmd
                .as_std()
                .get_current_dir()
                .map(std::path::Path::to_path_buf)
                .unwrap_or_default(),
            env: have.into_iter().collect(),
            ..Default::default()
        };
        if crate::usage_stats::claude_autocompact_unset(&source) {
            let (key, value) = CLAUDE_AUTOCOMPACT_WINDOW;
            cmd.env(key, value);
        }
    }
}

/// `cmd`'s program and arguments.
fn command_line(cmd: &tokio::process::Command) -> Vec<String> {
    let cmd = cmd.as_std();
    std::iter::once(cmd.get_program())
        .chain(cmd.get_args())
        .map(|a| a.to_string_lossy().into_owned())
        .collect()
}

/// The arguments a session's harness, started in `cwd` with the profile's
/// `env`, starts with: a `codex app-server` launch's (`codex_launch`, decided on the
/// profile's own program) with acpmux's overrides (`codex_args`), any other's as given.
/// `None` for a launch without a session, whose overrides only move before the subcommand.
pub fn launch_args(
    codex_launch: bool,
    args: &[String],
    session: Option<(&std::path::Path, &std::collections::BTreeMap<String, String>)>,
) -> Vec<String> {
    match session {
        Some((cwd, env)) if codex_launch => {
            let home = env.get("CODEX_HOME").map(std::path::PathBuf::from);
            let configs = codex_configs(cwd, home);
            codex_args(args.to_vec(), &configs)
        }
        // A launch with no session (a model probe) still has a credential's provider after the
        // subcommand, which would drop a launcher wrapper's root overrides (cmux#48354).
        _ if codex_launch => hoist_subcommand_config(args.to_vec()),
        _ => args.to_vec(),
    }
}

/// The Claude knobs `env` (what the harness would get) leaves unset, with
/// acpmux's values.
pub fn claude_env(env: &[(String, String)]) -> Vec<(&'static str, &'static str)> {
    CLAUDE_ENV.iter().copied().filter(|(k, _)| !env.iter().any(|(key, _)| key == k)).collect()
}

/// [`CLAUDE_TERMINAL_ENV`] (the capacity-scoped retry watchdog) for a chat whose `env` sets
/// none of [`CLAUDE_RETRY_CHOICES`]; nothing when the person chose how Claude Code retries.
/// The usage-limit wait stays 0, so a spend or plan limit still fails fast to the person.
pub fn claude_retry_env(env: &[(String, String)]) -> &'static [(&'static str, &'static str)] {
    if CLAUDE_RETRY_CHOICES.iter().any(|name| env.iter().any(|(key, _)| key == name)) {
        &[]
    } else {
        CLAUDE_TERMINAL_ENV
    }
}

/// `args` of a `codex app-server` launch with acpmux's config overrides
/// first (global options go before the subcommand), each only when neither
/// `args` nor codex's `configs` set that key already.
///
/// The model codex's config names (its active profile's, else the top-level
/// `model`) goes first too, as `-m <model>`, when `args` name none (cmux#48354).
/// A chat's app-server is told its model over the protocol (`thread/start`),
/// after it started, so a launcher that routes by the model on its command
/// line (a subrouter wrapper installed as `codex`) saw none and sent the
/// configured model to the plain provider, which refused it (400
/// `model_not_found`), while `codex` in a terminal, whose wrapper puts the
/// configured model on the command line, worked. Codex itself takes `-m` before
/// a subcommand and the chat's model still comes from the protocol.
pub fn codex_args(args: Vec<String>, configs: &[toml::Table]) -> Vec<String> {
    let profile = codex_profile(&args, configs);
    let mut lifted: Vec<String> = Vec::new();
    if !names_codex_model(&args)
        && let Some(model) = codex_config_model(configs, profile.as_deref())
    {
        lifted.push("-m".into());
        lifted.push(model);
    }
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
    hoist_subcommand_config(lifted)
}

/// `args` with every `-c`/`--config` after the `app-server` word moved before it, in order
/// (cmux#48354). Some codex builds (0.160, the cmux fork) drop every override before the
/// subcommand once the subcommand has one of its own, so cmux's `app-server -c
/// developer_instructions=…` (`context_inventory::launch_args`) and credentials' provider
/// (`agent_credentials::codex_config_index`) dropped acpmux's lifted limits and the root-level
/// overrides a launcher wrapper adds (a subrouter `codex` wrapper's `-c model_provider=…`): the
/// chat went to the plain provider and was refused (400 `model_not_found`) while `codex` in a
/// terminal worked. Every codex reads a root override, and the subcommand's come after the
/// root's in its merge, so the order kept here keeps which one wins.
fn hoist_subcommand_config(args: Vec<String>) -> Vec<String> {
    let mut i = 0;
    let sub = loop {
        let Some(a) = args.get(i) else { return args };
        if a == "app-server" {
            break i;
        }
        if !a.starts_with('-') {
            return args;
        }
        i += if a.contains('=') { 1 } else { 2 };
    };
    let mut hoisted = Vec::new();
    let mut rest = Vec::new();
    let mut after = args.iter().skip(sub + 1).cloned();
    while let Some(a) = after.next() {
        if a == "-c" || a == "--config" {
            // A flag with no value stays where it was: codex refuses it there, rather than
            // taking the subcommand as its value.
            match after.next() {
                Some(value) => hoisted.extend([a, value]),
                None => rest.push(a),
            }
        } else if a.starts_with("--config=")
            || (a.starts_with("-c") && a.len() > 2 && !a.starts_with("--"))
        {
            hoisted.push(a);
        } else {
            rest.push(a);
        }
    }
    let mut out: Vec<String> = args.iter().take(sub).cloned().collect();
    out.extend(hoisted);
    out.push("app-server".into());
    out.extend(rest);
    out
}

/// Whether a `codex app-server` launch of `args` in `cwd` (`home`: the profile's `CODEX_HOME`)
/// already has the dotted config `key`: from its command line, or from codex's own config
/// (`config.toml`, its active profile, the project's), as [`codex_args`] reads them.
pub fn codex_sets(
    args: &[String],
    cwd: &std::path::Path,
    home: Option<std::path::PathBuf>,
    key: &str,
) -> bool {
    if sets_codex_key(args, key) {
        return true;
    }
    let configs = codex_configs(cwd, home);
    let profile = codex_profile(args, &configs);
    configs.iter().any(|c| {
        toml_has(c, key)
            || profile.as_ref().is_some_and(|p| {
                c.get("profiles")
                    .and_then(|ps| ps.get(p.as_str()))
                    .is_some_and(|t| t.as_table().is_some_and(|t| toml_has(t, key)))
            })
    })
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

/// The model codex's `configs` (nearest first) name for a launch on `profile`:
/// the first config whose active profile names one, else whose top level does.
fn codex_config_model(configs: &[toml::Table], profile: Option<&str>) -> Option<String> {
    fn model(t: &toml::Table) -> Option<&str> {
        t.get("model").and_then(toml::Value::as_str).map(str::trim).filter(|m| !m.is_empty())
    }
    let in_profile = profile.and_then(|p| {
        configs.iter().find_map(|c| c.get("profiles")?.get(p)?.as_table().and_then(model))
    });
    in_profile.or_else(|| configs.iter().find_map(model)).map(str::to_owned)
}

/// Whether `args` name a model: `-m`, `--model` (with its value, or `=value`), `-m<value>`, or
/// a `-c model=…` override.
fn names_codex_model(args: &[String]) -> bool {
    sets_codex_key(args, "model")
        || args.iter().any(|a| {
            a == "-m"
                || a == "--model"
                || a.starts_with("--model=")
                || (a.starts_with("-m") && a.len() > 2 && !a.starts_with("--"))
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

/// Whether `args` sets `key` with `-c key=…`, `-ckey=…`, `--config key=…` or
/// `--config=key=…`.
fn sets_codex_key(args: &[String], key: &str) -> bool {
    let sets = |value: &str| value.split_once('=').is_some_and(|(k, _)| k.trim() == key);
    args.iter().enumerate().any(|(i, a)| match a.as_str() {
        "-c" | "--config" => args.get(i + 1).is_some_and(|v| sets(v)),
        _ => a
            .strip_prefix("--config=")
            .or_else(|| a.strip_prefix("-c").filter(|rest| !rest.is_empty()))
            .is_some_and(sets),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(w: &[&str]) -> Vec<String> {
        w.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn overrides_after_the_subcommand_move_before_it_in_order() {
        let args = words(&[
            "-c",
            "agents.max_depth=2",
            "app-server",
            "--listen",
            "stdio://",
            "-c",
            "model_provider=\"openai_api_key\"",
            "--config=x=1",
            "-cy=2",
            "-c",
            "developer_instructions=\"rules\"",
        ]);
        assert_eq!(
            hoist_subcommand_config(args),
            words(&[
                "-c",
                "agents.max_depth=2",
                "-c",
                "model_provider=\"openai_api_key\"",
                "--config=x=1",
                "-cy=2",
                "-c",
                "developer_instructions=\"rules\"",
                "app-server",
                "--listen",
                "stdio://",
            ])
        );
        // No subcommand, or another one: as given.
        let other = words(&["exec", "-c", "a=1"]);
        assert_eq!(hoist_subcommand_config(other.clone()), other);
        let none = words(&["-c", "a=1"]);
        assert_eq!(hoist_subcommand_config(none.clone()), none);
        // A dangling flag never takes the subcommand as its value.
        let dangling = words(&["-c", "a=1", "app-server", "-c"]);
        assert_eq!(hoist_subcommand_config(dangling.clone()), dangling);
        // A launch with no session (a model probe) is moved too.
        assert_eq!(
            launch_args(true, &words(&["app-server", "-c", "model_provider=\"x\""]), None),
            words(&["-c", "model_provider=\"x\"", "app-server"])
        );
        assert_eq!(
            launch_args(false, &words(&["exec", "-c", "a=1"]), None),
            words(&["exec", "-c", "a=1"])
        );
    }

    #[test]
    fn a_chat_waits_out_capacity_unless_the_person_chose_its_retries() {
        let none: Vec<(String, String)> = vec![("PATH".into(), "/bin".into())];
        let lifted = claude_retry_env(&none);
        assert!(lifted.contains(&("CLAUDE_CODE_RETRY_WATCHDOG", "1")), "{lifted:?}");
        assert!(lifted.contains(&("CLAUDE_CODE_RETRY_WATCHDOG_SCOPE", "capacity")), "{lifted:?}");
        // A spend or plan limit still fails fast: no usage-limit wait.
        assert!(
            lifted.contains(&("CLAUDE_CODE_RETRY_WATCHDOG_MAX_USAGE_LIMIT_WAIT_MS", "0")),
            "{lifted:?}"
        );
        for choice in CLAUDE_RETRY_CHOICES {
            let chosen = vec![((*choice).to_owned(), "7".to_owned())];
            assert!(claude_retry_env(&chosen).is_empty(), "{choice}");
        }
    }

    #[test]
    fn a_launch_has_no_override_after_app_server() {
        let out = codex_args(
            words(&["app-server", "-c", "developer_instructions=\"rules\""]),
            &[toml::Table::new()],
        );
        let at = out.iter().position(|a| a == "app-server").unwrap();
        assert_eq!(at, out.len() - 1, "{out:?}");
        assert!(out.windows(2).any(|w| w == ["-c", "developer_instructions=\"rules\""]), "{out:?}");
    }
}
