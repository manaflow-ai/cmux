//! `cmux-tui agent claude-wrapper [claude args...]`: starts Claude Code with
//! cmux-tui's agent hooks.
//!
//! Panes put a `claude` shim first on PATH that execs this verb, so launchers
//! that resolve `claude` from PATH and set their own CLAUDE_CONFIG_DIR are
//! covered too. The hooks travel in
//! `--settings`, which applies under any config directory. Claude Code honors
//! only the last `--settings` flag, so every `--settings` value is folded into
//! one private file that also carries the hooks. Any failure starts Claude
//! unchanged.

use std::ffi::{CString, OsStr, OsString};
use std::fs;
use std::io::Read as _;
use std::os::unix::ffi::OsStrExt as _;
use std::os::unix::fs::{FileTypeExt as _, PermissionsExt as _};
use std::os::unix::process::CommandExt as _;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime};

use anyhow::Context as _;
use serde_json::{Map, Value};
use sha2::{Digest as _, Sha256};

use crate::agent_hook_install;

const VERB: &str = "claude-wrapper";
/// Identifies the shim so the wrapper never resolves `claude` back to it.
const SHIM_MARKER: &str = "# cmux-tui-claude-shim";
/// Set on the launched Claude so a launcher that re-resolves `claude` from
/// PATH passes through instead of stacking a second set of hooks.
const WRAPPER_ACTIVE_ENV: &str = "CMUX_TUI_CLAUDE_WRAPPER_ACTIVE";
/// `1` starts Claude without cmux-tui's hooks.
const HOOKS_DISABLED_ENV: &str = "CMUX_TUI_CLAUDE_HOOKS_DISABLED";
/// Merged settings can carry a launcher's credentials, so copies that no
/// launch has reused for this long are removed.
const SETTINGS_RETENTION: Duration = Duration::from_secs(7 * 24 * 60 * 60);
const MAX_SETTINGS_BYTES: u64 = 16 * 1024 * 1024;
const MAX_SHIM_PROBE_BYTES: u64 = 4096;

/// Returns the wrapper's arguments when argv (without the program name)
/// selects `agent claude-wrapper`.
pub(crate) fn invocation(args: &[OsString]) -> Option<&[OsString]> {
    match args {
        [scope, verb, rest @ ..] if scope == "agent" && verb == VERB => Some(rest),
        _ => None,
    }
}

/// Execs the real Claude. Returns only when it could not be started.
pub(crate) fn run(args: &[OsString]) -> i32 {
    let messages = &crate::localization::catalog().agent_wrapper;
    let shim_dir = shim_directory();
    let path = std::env::var_os("PATH").unwrap_or_default();
    let Some(claude) = find_real_claude(&path, shim_dir.as_deref()) else {
        eprintln!("{}", messages.agent_not_found);
        return 127;
    };
    let mut command = Command::new(&claude);
    command.env("PATH", path_without_shims(&path, shim_dir.as_deref()));
    let mut launch_args = args.to_vec();
    if should_inject(args, |name| std::env::var_os(name)) {
        match prepare_hooks(args) {
            Ok((injected, helper)) => {
                launch_args = injected;
                command.env(WRAPPER_ACTIVE_ENV, "1");
                if let Some(helper) = helper {
                    command.env("CMUX_TUI_HOOK", helper);
                }
            }
            Err(_) => eprintln!("{}", messages.hooks_unavailable),
        }
    }
    let _error = command.args(&launch_args).exec();
    eprintln!("{}", messages.agent_start_failed);
    126
}

/// PATH for pane processes: the `claude` shim directory first, then the
/// server's PATH. `None` leaves PATH alone (the shim could not be written).
pub(crate) fn pane_path() -> Option<String> {
    let dir = shim_directory()?;
    let executable = current_executable().ok()?;
    install_shim(&dir, &executable).ok()?;
    path_with_shim_first(&std::env::var_os("PATH").unwrap_or_default(), &dir)?.into_string().ok()
}

/// Directory holding the `claude` shim, under cmux-tui's data home.
fn shim_directory() -> Option<PathBuf> {
    agent_hook_install::runtime_cmux_tui_data_home().map(|home| home.join("shims"))
}

/// This cmux-tui binary's canonical path, which the shim and fallback hooks run.
fn current_executable() -> anyhow::Result<PathBuf> {
    let executable = std::env::current_exe().context("resolve the cmux-tui executable")?;
    Ok(executable.canonicalize().unwrap_or(executable))
}

/// A launch gets hooks only inside a cmux-tui terminal whose session socket
/// exists, when hooks are not disabled or already injected, and when the
/// arguments start a session rather than `--version` or `mcp`-style commands.
fn should_inject(args: &[OsString], getenv: impl Fn(&str) -> Option<OsString>) -> bool {
    let is_one = |name: &str| getenv(name).is_some_and(|value| value == "1");
    if is_one(WRAPPER_ACTIVE_ENV) || is_one(HOOKS_DISABLED_ENV) {
        return false;
    }
    if getenv("CMUX_TUI_TERMINAL_ID").is_none_or(|value| value.is_empty()) {
        return false;
    }
    // Without a session to deliver to, the injected settings would only turn
    // off Claude's own notifications.
    let Some(socket) = getenv("CMUX_TUI_SOCKET").filter(|value| !value.is_empty()) else {
        return false;
    };
    if !fs::metadata(socket).is_ok_and(|metadata| metadata.file_type().is_socket()) {
        return false;
    }
    let args = args.iter().map(|arg| arg.to_string_lossy().into_owned()).collect::<Vec<_>>();
    !launch_classification::is_non_launch(&args)
}

/// Builds the launch arguments and picks the hook helper the settings use.
fn prepare_hooks(args: &[OsString]) -> anyhow::Result<(Vec<OsString>, Option<PathBuf>)> {
    let executable = current_executable()?;
    let helper = hook_helper(&executable);
    let hooks = session_hook_settings(helper.is_none().then_some(executable.as_path()))?;
    let cache = agent_hook_install::runtime_cmux_tui_data_home()
        .context("no data directory for Claude settings")?
        .join("claude-settings");
    Ok((args_with_hooks(args, hooks, &cache)?, helper))
}

/// The detached `cmux-tui-hook` helper: the one `agent hook install` placed
/// (the same path a remote host's hook install writes), else the one shipped
/// beside this binary. The installed hook commands run
/// `$CMUX_TUI_HOOK`, which the wrapper points at this absolute path.
fn hook_helper(executable: &Path) -> Option<PathBuf> {
    agent_hook_install::runtime_helper_path()
        .filter(|path| agent_hook_install::is_executable_file(path))
        .or_else(|| agent_hook_install::locate_helper_source(Some(executable)))
        .filter(|path| path.is_absolute())
}

/// The hook settings fragment merged into every wrapped launch.
fn session_hook_settings(emit_binary: Option<&Path>) -> anyhow::Result<Map<String, Value>> {
    let mut settings = agent_hook_install::claude_session_hook_settings(emit_binary)?;
    // The hooks drive cmux notifications; Claude's own would duplicate them.
    settings.insert("preferredNotifChannel".into(), Value::from("notifications_disabled"));
    Ok(settings)
}

/// Folds every `--settings` argument (inline JSON or a path) and `hooks` into
/// one settings file, passed first. Arguments after `--` stay untouched.
fn args_with_hooks(
    args: &[OsString],
    hooks: Map<String, Value>,
    cache_dir: &Path,
) -> anyhow::Result<Vec<OsString>> {
    let mut merged = Map::new();
    let mut remaining = Vec::with_capacity(args.len());
    let mut index = 0;
    while index < args.len() {
        let argument = &args[index];
        index += 1;
        if argument == "--" {
            remaining.extend_from_slice(&args[index - 1..]);
            break;
        }
        let value = if argument == "--settings" {
            let value = args.get(index).context("--settings requires a value")?;
            index += 1;
            value.clone()
        } else if let Some(value) = argument.as_bytes().strip_prefix(b"--settings=") {
            OsStr::from_bytes(value).to_owned()
        } else {
            remaining.push(argument.clone());
            continue;
        };
        merge_settings(&mut merged, read_settings_argument(&value)?);
    }
    merge_settings(&mut merged, hooks);
    let data = serde_json::to_vec(&Value::Object(merged))?;
    let path = write_settings_file(cache_dir, &data, SystemTime::now())?;
    let mut launch = vec![OsString::from("--settings"), path.into_os_string()];
    launch.extend(remaining);
    Ok(launch)
}

/// Parses one `--settings` value: inline JSON when it starts with `{`, else a file path.
fn read_settings_argument(value: &OsStr) -> anyhow::Result<Map<String, Value>> {
    let data = match value.to_str() {
        Some(text) if text.trim_start().starts_with('{') => text.as_bytes().to_vec(),
        _ => {
            let mut data = Vec::new();
            fs::File::open(value)
                .context("open settings")?
                .take(MAX_SETTINGS_BYTES + 1)
                .read_to_end(&mut data)
                .context("read settings")?;
            anyhow::ensure!(data.len() as u64 <= MAX_SETTINGS_BYTES, "settings are too large");
            data
        }
    };
    match serde_json::from_slice::<Value>(&data).context("parse settings")? {
        Value::Object(settings) => Ok(settings),
        _ => anyhow::bail!("settings must be a JSON object"),
    }
}

/// Objects merge recursively and arrays concatenate, so hook groups from
/// every source run; any other value from `source` wins.
fn merge_settings(target: &mut Map<String, Value>, source: Map<String, Value>) {
    for (key, value) in source {
        let Some(existing) = target.get_mut(&key) else {
            target.insert(key, value);
            continue;
        };
        match (existing, value) {
            (Value::Object(existing), Value::Object(incoming)) => {
                merge_settings(existing, incoming);
            }
            (Value::Array(existing), Value::Array(incoming)) => existing.extend(incoming),
            (existing, value) => *existing = value,
        }
    }
}

/// Stores settings under a content hash so repeated launches reuse one
/// private file. The directory and file modes are re-asserted on reuse
/// because merged settings can hold a launcher's credentials.
fn write_settings_file(dir: &Path, data: &[u8], now: SystemTime) -> anyhow::Result<PathBuf> {
    fs::create_dir_all(dir).context("create the settings directory")?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    let digest = Sha256::digest(data);
    let name = digest[..16].iter().map(|byte| format!("{byte:02x}")).collect::<String>();
    let path = dir.join(format!("{name}.json"));
    prune_settings_files(dir, &path, now);
    let reusable = fs::symlink_metadata(&path).is_ok_and(|metadata| metadata.is_file())
        && fs::read(&path).is_ok_and(|existing| existing == data);
    if reusable {
        fs::set_permissions(&path, fs::Permissions::from_mode(0o600))?;
        fs::File::options().write(true).open(&path)?.set_modified(now)?;
        return Ok(path);
    }
    agent_hook_install::atomic_write(&path, data, Some(0o600))?;
    Ok(path)
}

/// Removes merged settings files, other than `keep`, idle past the retention.
fn prune_settings_files(dir: &Path, keep: &Path, now: SystemTime) {
    let Ok(entries) = fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path == keep || path.extension() != Some(OsStr::new("json")) {
            continue;
        }
        let idle = entry
            .metadata()
            .ok()
            .filter(fs::Metadata::is_file)
            .and_then(|metadata| now.duration_since(metadata.modified().ok()?).ok());
        if idle.is_some_and(|idle| idle > SETTINGS_RETENTION) {
            let _ = fs::remove_file(path);
        }
    }
}

/// Resolves `claude` from PATH, skipping the shim directory and any
/// `claude` that is (or links to) the shim.
fn find_real_claude(path: &OsStr, shim_dir: Option<&Path>) -> Option<PathBuf> {
    std::env::split_paths(path)
        .filter(|dir| !dir.as_os_str().is_empty() && !is_shim_directory(dir, shim_dir))
        .map(|dir| dir.join("claude"))
        .find(|candidate| {
            candidate.metadata().is_ok_and(|metadata| metadata.is_file())
                && current_process_can_execute(candidate)
                && !is_claude_shim(candidate)
        })
}

fn current_process_can_execute(path: &Path) -> bool {
    let Ok(path) = CString::new(path.as_os_str().as_bytes()) else {
        return false;
    };
    // SAFETY: `path` is a live NUL-terminated CString for the duration of the call.
    unsafe { libc::access(path.as_ptr(), libc::X_OK) == 0 }
}

/// Drops shim directories so Claude and everything it starts see the real
/// PATH and never re-enter the wrapper.
fn path_without_shims(path: &OsStr, shim_dir: Option<&Path>) -> OsString {
    let kept = std::env::split_paths(path).filter(|dir| {
        !dir.as_os_str().is_empty()
            && !is_shim_directory(dir, shim_dir)
            && !is_claude_shim(&dir.join("claude"))
    });
    std::env::join_paths(kept).unwrap_or_else(|_| path.to_owned())
}

/// Prepends `shim_dir` to `path`, dropping any later copy so repeated startups stay idempotent.
fn path_with_shim_first(path: &OsStr, shim_dir: &Path) -> Option<OsString> {
    let inherited = std::env::split_paths(path).filter(|dir| dir != shim_dir);
    let entries = std::iter::once(shim_dir.to_path_buf());
    if path.is_empty() {
        return std::env::join_paths(entries).ok();
    }
    std::env::join_paths(entries.chain(inherited)).ok()
}

/// Whether `dir` is the shim directory, compared literally and after canonicalization.
fn is_shim_directory(dir: &Path, shim_dir: Option<&Path>) -> bool {
    let Some(shim_dir) = shim_dir else {
        return false;
    };
    dir == shim_dir
        || matches!(
            (dir.canonicalize(), shim_dir.canonicalize()),
            (Ok(dir), Ok(shim_dir)) if dir == shim_dir
        )
}

/// Whether the file at `path` (following links) is a cmux-tui `claude` shim.
fn is_claude_shim(path: &Path) -> bool {
    let mut head = Vec::new();
    fs::File::open(path)
        .and_then(|file| file.take(MAX_SHIM_PROBE_BYTES).read_to_end(&mut head))
        .is_ok()
        && head.windows(SHIM_MARKER.len()).any(|window| window == SHIM_MARKER.as_bytes())
}

/// Writes `<dir>/claude` (0700 in a 0700 directory) when its content changed.
fn install_shim(dir: &Path, executable: &Path) -> anyhow::Result<PathBuf> {
    let script = shim_script(executable, dir)?;
    fs::create_dir_all(dir).context("create the shim directory")?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    let path = dir.join("claude");
    let current = fs::symlink_metadata(&path).is_ok_and(|metadata| metadata.is_file())
        && fs::read(&path).is_ok_and(|existing| existing == script.as_bytes());
    if current {
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700))?;
    } else {
        agent_hook_install::atomic_write(&path, script.as_bytes(), Some(0o700))?;
    }
    Ok(path)
}

/// The shim execs the wrapper. When that binary is gone (an upgrade moved
/// it), the shim runs the next `claude` on PATH instead of failing.
fn shim_script(executable: &Path, dir: &Path) -> anyhow::Result<String> {
    let executable = agent_hook_install::shell_quote(
        executable.to_str().context("the cmux-tui path is not UTF-8")?,
    );
    let dir =
        agent_hook_install::shell_quote(dir.to_str().context("the shim directory is not UTF-8")?);
    Ok(format!(
        "#!/bin/sh\n\
         {SHIM_MARKER}\n\
         # Written by cmux-tui: starts Claude Code with the terminal's agent hooks.\n\
         if [ -x {executable} ]; then\n  exec {executable} agent {VERB} \"$@\"\nfi\n\
         set -f\n\
         IFS=:\n\
         kept=\n\
         for entry in $PATH; do\n  [ \"$entry\" = {dir} ] || kept=\"${{kept:+$kept:}}$entry\"\ndone\n\
         unset IFS\n\
         set +f\n\
         PATH=$kept\n\
         export PATH\n\
         exec claude \"$@\"\n"
    ))
}

/// Claude Code arguments that do not start a session: informational flags and
/// management subcommands. They run without hooks. Unknown options classify
/// as a launch, since skipping hooks on a session costs more than adding them
/// to a management command.
mod launch_classification {
    const INFORMATIONAL: &[&str] = &["--help", "-h", "--version", "-v"];
    const MANAGEMENT_COMMANDS: &[&str] = &[
        "auth",
        "auto-mode",
        "doctor",
        "gateway",
        "install",
        "kill",
        "logs",
        "mcp",
        "plugin",
        "plugins",
        "project",
        "rm",
        "setup-token",
        "stop",
        "update",
        "upgrade",
    ];
    const DAEMON_SUBCOMMANDS: &[&str] = &["logs", "status", "stop", "uninstall"];
    const MANAGEMENT_DISQUALIFYING: &[&str] = &[
        "--background",
        "--bg",
        "--continue",
        "-c",
        "--fork-session",
        "--from-pr",
        "--no-session-persistence",
        "--print",
        "-p",
        "--remote-control",
        "--resume",
        "-r",
        "--session-id",
        "--worktree",
        "-w",
    ];
    const BOOLEAN: &[&str] = &[
        "--allow-dangerously-skip-permissions",
        "--ax-screen-reader",
        "--background",
        "--bare",
        "--bg",
        "--brief",
        "--chrome",
        "--continue",
        "-c",
        "--dangerously-skip-permissions",
        "--disable-slash-commands",
        "--exclude-dynamic-system-prompt-sections",
        "--fork-session",
        "--forward-subagent-text",
        "--ide",
        "--include-hook-events",
        "--include-partial-messages",
        "--no-chrome",
        "--no-session-persistence",
        "--print",
        "-p",
        "--replay-user-messages",
        "--safe-mode",
        "--strict-mcp-config",
        "--use-system-ca",
        "--verbose",
    ];
    const OPTIONAL_VALUE: &[&str] =
        &["--debug", "-d", "--prompt-suggestions", "--remote-control", "--worktree", "-w"];
    const VALUE: &[&str] = &[
        "--add-dir",
        "--agent",
        "--agents",
        "--allowedTools",
        "--allowed-tools",
        "--append-system-prompt",
        "--append-system-prompt-file",
        "--betas",
        "--dangerously-load-development-channels",
        "--debug-file",
        "--disallowedTools",
        "--disallowed-tools",
        "--effort",
        "--fallback-model",
        "--file",
        "--from-pr",
        "--input-format",
        "--json-schema",
        "--max-budget-usd",
        "--mcp-config",
        "--model",
        "--name",
        "-n",
        "--output-format",
        "--permission-mode",
        "--plugin-dir",
        "--plugin-url",
        "--remote-control-session-name-prefix",
        "--resume",
        "-r",
        "--session-id",
        "--setting-sources",
        "--settings",
        "--system-prompt",
        "--system-prompt-file",
        "--teammate-mode",
        "--tools",
    ];
    const VARIADIC: &[&str] = &[
        "--add-dir",
        "--allowedTools",
        "--allowed-tools",
        "--betas",
        "--dangerously-load-development-channels",
        "--disallowedTools",
        "--disallowed-tools",
        "--file",
        "--mcp-config",
        "--tools",
    ];

    /// Whether these Claude Code arguments run a command instead of starting a session.
    pub(super) fn is_non_launch(args: &[String]) -> bool {
        informational(args) || management(args)
    }

    /// The option name without an inline `=value`.
    fn option_name(argument: &str) -> &str {
        argument.split_once('=').map_or(argument, |(name, _)| name)
    }

    /// Whether an argument is a positional word rather than an option (`-` counts as positional).
    fn is_positional(argument: &str) -> bool {
        !argument.starts_with('-') || argument == "-"
    }

    /// Whether the arguments ask only for help or version output.
    fn informational(args: &[String]) -> bool {
        let mut index = 0;
        while index < args.len() {
            let argument = args[index].as_str();
            if argument == "--" {
                return false;
            }
            if is_positional(argument) {
                index += 1;
                continue;
            }
            if INFORMATIONAL.contains(&option_name(argument)) {
                return true;
            }
            let Some(width) = option_width(args, index) else {
                return false;
            };
            index += width;
        }
        false
    }

    /// Whether the first positional word is a management subcommand such as `mcp` or `doctor`.
    fn management(args: &[String]) -> bool {
        let mut index = 0;
        while index < args.len() {
            let argument = args[index].as_str();
            if argument == "--" {
                return false;
            }
            if is_positional(argument) {
                return match argument {
                    "agents" => agents_json(&args[index + 1..]),
                    "daemon" => management_subcommand(args, index + 1, DAEMON_SUBCOMMANDS),
                    command => MANAGEMENT_COMMANDS.contains(&command),
                };
            }
            let name = option_name(argument);
            // Claude's debug filter takes an optional free-form value, so a
            // following command-shaped word is ambiguous: treat it as a launch.
            if MANAGEMENT_DISQUALIFYING.contains(&name)
                || INFORMATIONAL.contains(&name)
                || (matches!(name, "--debug" | "-d") && !argument.contains('='))
            {
                return false;
            }
            let Some(width) = option_width(args, index) else {
                return false;
            };
            index += width;
        }
        false
    }

    /// Whether `agents` is followed only by `--json` (once) and `--all`.
    fn agents_json(rest: &[String]) -> bool {
        let mut saw_json = false;
        for argument in rest {
            match argument.as_str() {
                "--json" if !saw_json => saw_json = true,
                "--all" => {}
                _ => return false,
            }
        }
        saw_json
    }

    /// Whether the next positional word after skipped log options is one of `allowed`.
    fn management_subcommand(args: &[String], mut index: usize, allowed: &[&str]) -> bool {
        while index < args.len() {
            let argument = args[index].as_str();
            if argument == "--" {
                return false;
            }
            if is_positional(argument) {
                return allowed.contains(&argument);
            }
            if !matches!(option_name(argument), "--json-path" | "--log-file") {
                return false;
            }
            if argument.contains('=') {
                index += 1;
            } else if index + 1 < args.len() {
                index += 2;
            } else {
                return false;
            }
        }
        false
    }

    /// How many arguments the option at `index` spans, or `None` when it is
    /// unknown or malformed.
    fn option_width(args: &[String], index: usize) -> Option<usize> {
        let argument = args[index].as_str();
        let name = option_name(argument);
        let next = args.get(index + 1).map(String::as_str);
        if INFORMATIONAL.contains(&name) || BOOLEAN.contains(&name) {
            return Some(1);
        }
        if name == "--tmux" {
            return match argument.split_once('=') {
                Some((_, value)) => (value == "classic").then_some(1),
                None => (next == Some("classic")).then_some(2),
            };
        }
        if OPTIONAL_VALUE.contains(&name) {
            if !argument.contains('=')
                && name == "--prompt-suggestions"
                && matches!(next, Some("true" | "false"))
            {
                return Some(2);
            }
            return Some(1);
        }
        if !VALUE.contains(&name) {
            return None;
        }
        if argument.contains('=') {
            return Some(1);
        }
        next?;
        if VARIADIC.contains(&name) {
            let values =
                args[index + 1..].iter().take_while(|value| !value.starts_with('-')).count();
            return (values > 0).then_some(values + 1);
        }
        Some(2)
    }
}

#[cfg(test)]
mod tests {
    use std::os::unix::net::UnixListener;
    use std::process::Output;

    use super::*;

    /// Converts string literals into owned OS arguments.
    fn os(args: &[&str]) -> Vec<OsString> {
        args.iter().map(OsString::from).collect()
    }

    /// Writes an executable (0755) script, creating its parent directory.
    fn write_executable(path: &Path, content: &str) {
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        crate::test_exec::write_executable(path, content);
    }

    /// The permission bits of `path`.
    fn mode(path: &Path) -> u32 {
        fs::metadata(path).unwrap().permissions().mode() & 0o777
    }

    /// Reads and parses a JSON file.
    fn read_json(path: &Path) -> Value {
        serde_json::from_slice(&fs::read(path).unwrap()).unwrap()
    }

    /// A launcher's `--settings` file and an inline `--settings` fold into one private file that keeps both.
    #[test]
    fn claude_wrapper_merges_launcher_settings_with_the_hooks() {
        let root = tempfile::tempdir().unwrap();
        // A launcher prepends its own --settings file.
        let launcher = root.path().join("launcher-settings.json");
        fs::write(
            &launcher,
            r#"{"apiKeyHelper":"launcher-helper","env":{"A":"1"},"hooks":{"Stop":[{"hooks":[{"type":"command","command":"user-stop"}]}]}}"#,
        )
        .unwrap();
        let args = os(&[
            "--settings",
            launcher.to_str().unwrap(),
            "--model",
            "opus",
            r#"--settings={"theme":"dark","env":{"B":"2"}}"#,
            "--",
            "--settings",
            "literal",
        ]);
        let cache = root.path().join("cache");
        let hooks = session_hook_settings(None).unwrap();
        let out = args_with_hooks(&args, hooks.clone(), &cache).unwrap();

        assert_eq!(out[0], "--settings");
        assert_eq!(out[2..], os(&["--model", "opus", "--", "--settings", "literal"]));
        let path = PathBuf::from(&out[1]);
        assert_eq!(mode(&path), 0o600);
        assert_eq!(mode(&cache), 0o700);
        let settings = read_json(&path);
        assert_eq!(settings["apiKeyHelper"], "launcher-helper");
        assert_eq!(settings["theme"], "dark");
        assert_eq!(settings["env"], serde_json::json!({"A":"1","B":"2"}));
        assert_eq!(settings["preferredNotifChannel"], "notifications_disabled");
        let stop = settings["hooks"]["Stop"].as_array().unwrap();
        assert_eq!(stop.len(), 2, "{stop:?}");
        assert_eq!(stop[0]["hooks"][0]["command"], "user-stop");
        assert_eq!(stop[1], hooks["hooks"]["Stop"][0]);
        for event in ["SessionStart", "UserPromptSubmit", "Notification", "SessionEnd"] {
            assert!(settings["hooks"][event].is_array(), "{event} missing");
        }

        let again = args_with_hooks(&args, hooks, &cache).unwrap();
        assert_eq!(again[1], out[1], "identical launches reuse one settings file");
        assert_eq!(fs::read_dir(&cache).unwrap().count(), 1);
    }

    /// Hook commands match `agent hook install`, or call `agent hook emit` without a helper.
    #[test]
    fn claude_wrapper_hook_commands_match_the_installed_hooks_or_fall_back_to_emit() {
        let installed = session_hook_settings(None).unwrap();
        let command = installed["hooks"]["Stop"][0]["hooks"][0]["command"].as_str().unwrap();
        assert!(command.contains("\"${h:-:}\" 'claude' 'Stop'"), "{command}");
        assert_eq!(installed["hooks"]["Stop"][0]["hooks"][0]["async"], true);

        let emit = session_hook_settings(Some(Path::new("/opt/cmux tui/cmux-tui"))).unwrap();
        let command = emit["hooks"]["Stop"][0]["hooks"][0]["command"].as_str().unwrap();
        assert!(
            command.starts_with(
                "'/opt/cmux tui/cmux-tui' agent hook emit --source 'claude' --event 'Stop' >/dev/null 2>&1||:;echo {};"
            ),
            "{command}"
        );
        assert_eq!(
            emit["hooks"].as_object().unwrap().keys().collect::<Vec<_>>(),
            installed["hooks"].as_object().unwrap().keys().collect::<Vec<_>>()
        );
    }

    /// Unreadable or malformed `--settings` values fail so the launch proceeds without hooks.
    #[test]
    fn claude_wrapper_skips_injection_for_bad_settings_arguments() {
        let root = tempfile::tempdir().unwrap();
        let hooks = session_hook_settings(None).unwrap();
        for args in [
            os(&["--model", "opus", "--settings"]),
            os(&["--settings", "/nonexistent/settings.json"]),
            os(&["--settings", "[1]"]),
            os(&["--settings={not json"]),
        ] {
            assert!(args_with_hooks(&args, hooks.clone(), root.path()).is_err(), "{args:?}");
        }
        // A non-UTF-8 `--settings=` value is still read, not passed through
        // after the merged file where it would win and drop the hooks.
        let non_utf8 = OsStr::from_bytes(b"--settings=/nonexistent/\xff.json").to_owned();
        assert!(args_with_hooks(&[non_utf8], hooks, root.path()).is_err());
    }

    /// Resolution skips the shim directory, copies of the shim, and links to it.
    #[test]
    fn claude_wrapper_resolves_the_real_claude_past_the_shim() {
        let root = tempfile::tempdir().unwrap();
        let executable = root.path().join("bin/cmux-tui");
        write_executable(&executable, "#!/bin/sh\n");
        let shim_dir = root.path().join("data/shims");
        install_shim(&shim_dir, &executable).unwrap();
        // A copy of the shim elsewhere on PATH, and a link back to it.
        let copied = root.path().join("copied");
        write_executable(
            &copied.join("claude"),
            &fs::read_to_string(shim_dir.join("claude")).unwrap(),
        );
        let linked = root.path().join("linked");
        fs::create_dir_all(&linked).unwrap();
        std::os::unix::fs::symlink(shim_dir.join("claude"), linked.join("claude")).unwrap();
        // A searchable directory named `claude` satisfies access(X_OK) but
        // cannot be executed as the Claude binary.
        let directory_candidate = root.path().join("directory-candidate");
        fs::create_dir_all(directory_candidate.join("claude")).unwrap();
        // An owned file with only the "other execute" bit set looks
        // executable to a bitmask check but is not executable by its owner.
        let inaccessible = root.path().join("inaccessible");
        fs::create_dir_all(&inaccessible).unwrap();
        fs::write(inaccessible.join("claude"), "#!/bin/sh\n").unwrap();
        fs::set_permissions(inaccessible.join("claude"), fs::Permissions::from_mode(0o001))
            .unwrap();
        let real = root.path().join("real");
        write_executable(&real.join("claude"), "#!/bin/sh\n");

        let path = std::env::join_paths([
            &shim_dir,
            &copied,
            &linked,
            &directory_candidate,
            &inaccessible,
            &real,
        ])
        .unwrap();
        assert_eq!(find_real_claude(&path, Some(shim_dir.as_path())), Some(real.join("claude")));
        assert_eq!(
            path_without_shims(&path, Some(shim_dir.as_path())),
            std::env::join_paths([&directory_candidate, &inaccessible, &real]).unwrap()
        );
        let only_shims = std::env::join_paths([&shim_dir, &copied]).unwrap();
        assert_eq!(find_real_claude(&only_shims, Some(shim_dir.as_path())), None);
    }

    /// Injection needs a live terminal and a session launch, and respects re-entry and the disable flag.
    #[test]
    fn claude_wrapper_injects_only_into_session_launches_in_a_live_terminal() {
        let root = tempfile::tempdir().unwrap();
        let socket = root.path().join("mux.sock");
        let _listener = UnixListener::bind(&socket).unwrap();
        let env = |overrides: &'static [(&'static str, &'static str)]| {
            let socket = socket.clone();
            move |name: &str| -> Option<OsString> {
                if let Some((_, value)) = overrides.iter().find(|(key, _)| *key == name) {
                    return Some(OsString::from(value));
                }
                match name {
                    "CMUX_TUI_TERMINAL_ID" => Some("term_1".into()),
                    "CMUX_TUI_SOCKET" => Some(socket.clone().into_os_string()),
                    _ => None,
                }
            }
        };

        assert!(should_inject(&[], env(&[])));
        assert!(should_inject(&os(&["--model", "opus", "fix the bug"]), env(&[])));
        assert!(should_inject(&os(&["--resume"]), env(&[])));
        for args in [
            os(&["--version"]),
            os(&["-h"]),
            os(&["--model", "opus", "--help"]),
            os(&["mcp", "list"]),
            os(&["--verbose", "doctor"]),
            os(&["agents", "--json"]),
            os(&["daemon", "status"]),
        ] {
            assert!(!should_inject(&args, env(&[])), "{args:?} must pass through");
        }
        assert!(!should_inject(&[], env(&[(WRAPPER_ACTIVE_ENV, "1")])), "re-entry");
        assert!(!should_inject(&[], env(&[(HOOKS_DISABLED_ENV, "1")])), "disabled");
        assert!(!should_inject(&[], env(&[("CMUX_TUI_TERMINAL_ID", "")])), "no terminal");
        assert!(!should_inject(&[], env(&[("CMUX_TUI_SOCKET", "")])), "no socket");
        let missing = &[("CMUX_TUI_SOCKET", "/nonexistent/cmux-tui.sock")];
        assert!(!should_inject(&[], env(missing)), "dead socket");
    }

    /// Reuse restores private modes and refreshes the idle clock; idle copies are pruned.
    #[test]
    fn claude_wrapper_settings_cache_stays_private_and_prunes_idle_copies() {
        let root = tempfile::tempdir().unwrap();
        let dir = root.path().join("settings");
        let data = br#"{"env":{"TOKEN":"x"}}"#;
        let now = SystemTime::now();
        let path = write_settings_file(&dir, data, now).unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();

        let stale = dir.join("stale.json");
        let recent = dir.join("recent.json");
        let idle = now - SETTINGS_RETENTION - Duration::from_secs(3600);
        for (file, modified) in [(&stale, idle), (&recent, now), (&path, idle)] {
            if file != &path {
                fs::write(file, b"{}").unwrap();
            }
            fs::File::options().write(true).open(file).unwrap().set_modified(modified).unwrap();
        }

        assert_eq!(write_settings_file(&dir, data, now).unwrap(), path);
        assert_eq!(mode(&path), 0o600);
        assert_eq!(mode(&dir), 0o700);
        assert!(!stale.exists(), "idle copy was not pruned");
        assert!(recent.exists(), "recent copy was pruned");
        let modified = fs::metadata(&path).unwrap().modified().unwrap();
        assert!(modified >= now - Duration::from_secs(1), "reuse must refresh the idle clock");
    }

    /// Runs the shim script through `/bin/sh` with the given `PATH`.
    fn run_shim(shim: &Path, path: &OsStr, args: &[&str]) -> Output {
        Command::new("/bin/sh").arg(shim).args(args).env("PATH", path).output().unwrap()
    }

    /// The shim execs the wrapper, rewrites idempotently, and falls back when the binary is gone.
    #[test]
    fn claude_wrapper_shim_execs_the_wrapper_and_falls_back_to_the_real_claude() {
        let root = tempfile::tempdir().unwrap();
        let executable = root.path().join("cmux tui/cmux-tui");
        write_executable(&executable, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n");
        let shim_dir = root.path().join("data/shims");
        let shim = install_shim(&shim_dir, &executable).unwrap();
        assert_eq!(shim, shim_dir.join("claude"));
        assert_eq!(mode(&shim), 0o700);
        assert_eq!(mode(&shim_dir), 0o700);
        let script = fs::read_to_string(&shim).unwrap();
        assert!(script.starts_with(&format!("#!/bin/sh\n{SHIM_MARKER}\n")), "{script}");
        assert!(is_claude_shim(&shim));

        fs::set_permissions(&shim, fs::Permissions::from_mode(0o755)).unwrap();
        assert_eq!(install_shim(&shim_dir, &executable).unwrap(), shim);
        assert_eq!(fs::read_to_string(&shim).unwrap(), script, "rewrite is idempotent");
        assert_eq!(mode(&shim), 0o700);

        let real = root.path().join("real");
        write_executable(
            &real.join("claude"),
            "#!/bin/sh\nprintf 'real %s|%s\\n' \"$*\" \"$PATH\"\n",
        );
        let path = std::env::join_paths([
            shim_dir.as_path(),
            real.as_path(),
            Path::new("/usr/bin"),
            Path::new("/bin"),
        ])
        .unwrap();
        let output = run_shim(&shim, &path, &["--model", "a b"]);
        assert!(output.status.success(), "{output:?}");
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            "agent\nclaude-wrapper\n--model\na b\n"
        );

        fs::remove_file(&executable).unwrap();
        let output = run_shim(&shim, &path, &["--model", "a b"]);
        assert!(output.status.success(), "{output:?}");
        let expected_path = format!("{}:/usr/bin:/bin", real.display());
        assert_eq!(
            String::from_utf8_lossy(&output.stdout),
            format!("real --model a b|{expected_path}\n")
        );
    }

    /// The pane PATH starts with the shim directory exactly once.
    #[test]
    fn claude_wrapper_pane_path_puts_the_shim_first_once() {
        let shim = Path::new("/data/cmux-tui/shims");
        assert_eq!(
            path_with_shim_first(OsStr::new("/usr/bin:/data/cmux-tui/shims:/bin"), shim).unwrap(),
            "/data/cmux-tui/shims:/usr/bin:/bin"
        );
        assert_eq!(path_with_shim_first(OsStr::new(""), shim).unwrap(), "/data/cmux-tui/shims");
    }

    /// Only `agent claude-wrapper` argv selects the wrapper.
    #[test]
    fn claude_wrapper_invocation_selects_only_the_hidden_verb() {
        let args = os(&["agent", "claude-wrapper", "--settings", "x"]);
        assert_eq!(invocation(&args), Some(&args[2..]));
        assert_eq!(invocation(&os(&["agent", "claude-wrapper"])), Some(&[][..]));
        assert_eq!(invocation(&os(&["agent", "list"])), None);
        assert_eq!(invocation(&os(&["claude-wrapper"])), None);
    }
}
