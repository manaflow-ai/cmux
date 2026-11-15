//! `cmux-tui agent codex-wrapper [codex args...]`: starts Codex with
//! per-invocation cmux hook context.
//!
//! Codex may execute hooks from a shared app-server daemon. That daemon does
//! not retain the terminal environment that started it, so persistent hooks
//! which rely on `CMUX_TUI_SOCKET` cannot identify their terminal. The wrapper
//! puts the socket, terminal id, and helper path directly in each hook command
//! passed to Codex for this launch.

use std::ffi::{OsStr, OsString};
use std::fs;
use std::io::Read as _;
use std::os::unix::fs::{FileTypeExt as _, PermissionsExt as _};
use std::os::unix::process::CommandExt as _;
use std::path::{Path, PathBuf};
use std::process::Command;

use anyhow::Context as _;

use crate::agent_hook_install;

const VERB: &str = "codex-wrapper";
const SHIM_MARKER: &str = "# cmux-tui-codex-shim";
const HOOKS_DISABLED_ENV: &str = "CMUX_TUI_CODEX_HOOKS_DISABLED";

/// Returns the wrapper's arguments when argv (without the program name)
/// selects `agent codex-wrapper`.
pub(crate) fn invocation(args: &[OsString]) -> Option<&[OsString]> {
    match args {
        [scope, verb, rest @ ..] if scope == "agent" && verb == VERB => Some(rest),
        _ => None,
    }
}

/// Execs the real Codex. If the launch is not a session or the terminal has
/// no live cmux socket, the original argv is passed through unchanged.
pub(crate) fn run(args: &[OsString]) -> i32 {
    let messages = &crate::localization::catalog().agent_wrapper;
    let path = std::env::var_os("PATH").unwrap_or_default();
    let shim_dir =
        current_executable().ok().and_then(|exe| crate::own_build_helpers::wrapper_shim_dir(&exe));
    let Some(codex) = find_real_codex(&path, shim_dir.as_deref()) else {
        eprintln!("{}", messages.agent_not_found);
        return 127;
    };

    let mut command = Command::new(&codex);
    command.env("PATH", path_without_shims(&path, shim_dir.as_deref()));
    // The arguments as given, before the hooks are added (see claude_wrapper).
    command
        .env(crate::claude_wrapper::AGENT_ARGS_ENV, crate::claude_wrapper::agent_args_json(args));
    let mut launch_args = args.to_vec();
    if should_inject(args, |name| std::env::var_os(name)) {
        match prepare_hooks(args) {
            Ok(Some(injected)) => {
                launch_args = injected;
                command.env("CMUX_TUI_CODEX_WRAPPER_ACTIVE", "1");
            }
            Ok(None) => {}
            Err(_) => eprintln!("{}", messages.hooks_unavailable),
        }
    }
    let _error = command.args(&launch_args).exec();
    eprintln!("{}", messages.agent_start_failed);
    126
}

fn current_executable() -> anyhow::Result<PathBuf> {
    let executable = std::env::current_exe().context("resolve the cmux-tui executable")?;
    Ok(executable.canonicalize().unwrap_or(executable))
}

fn prepare_hooks(args: &[OsString]) -> anyhow::Result<Option<Vec<OsString>>> {
    // A tool command of a Codex session in the shared daemon has the
    // daemon's inherited environment, which names some other terminal.
    if cmux_tui_core::platform::descends_from_codex_app_server_daemon() {
        return Ok(None);
    }
    let Some((socket, Some(terminal))) = crate::hook_helper::session_route("codex") else {
        return Ok(None);
    };
    if !fs::metadata(&socket).is_ok_and(|metadata| metadata.file_type().is_socket()) {
        return Ok(None);
    }
    let executable = current_executable()?;
    let mut launch = vec![OsString::from("--enable"), OsString::from("hooks")];
    for setting in agent_hook_install::codex_session_hook_settings(&socket, &terminal, &executable)?
    {
        launch.push(OsString::from("-c"));
        launch.push(OsString::from(setting));
    }
    // cmux's server, Computer Use behind it (agent_computer_use.rs), once the
    // person said yes to cmux's tools in agents started in cmux
    // (agent_mcp_choice.rs).
    let cwd = std::env::current_dir().unwrap_or_default();
    let settings = mcp_settings(
        &McpLaunch { args, cwd: &cwd, executable: &executable, socket: &socket },
        cmux_tui_core::user_settings::AgentsCmuxMcp::current(),
        &|name| std::env::var_os(name),
    );
    for setting in settings {
        launch.push(OsString::from("-c"));
        launch.push(setting);
    }
    launch.extend(hoist_session_global_args(args));
    Ok(Some(launch))
}

/// What [`mcp_settings`] needs of the launch: the person's Codex arguments,
/// the launch folder, this build's CLI and the pane's daemon socket.
struct McpLaunch<'a> {
    args: &'a [OsString],
    cwd: &'a Path,
    executable: &'a Path,
    socket: &'a Path,
}

/// The `-c` values that give this launch this build's server as `cmux`
/// (agent_computer_use.rs) when the person said yes to cmux's tools in agents
/// started in cmux (`choice`), unless a config Codex may load has the
/// person's own HTTP server named `cmux`, which this build's command cannot
/// merge into (acpmux codex_cmux_entry.rs): then none, and nothing is said.
///
/// Without the yes, a stdio `cmux` entry of the person's own that Codex surely
/// loads (`codex_cmux_entry::stdio_cmux_entry`) gets the env key
/// `CMUX_AGENT_TOOLS_ANSWER` = `off`, with its own `command` and `args` as the
/// config layers give them (the same entry where it loads; a whole stdio
/// server where a guess that it loads is wrong, never env alone, which Codex
/// refuses): its `cmux mcp serve` then follows the answer as an agent cmux
/// started (`cli/mcp.rs` `refusal`), not `mcp.enabled` as a caller outside
/// cmux. An HTTP entry has no env: none.
fn mcp_settings(
    launch: &McpLaunch<'_>,
    choice: cmux_tui_core::user_settings::AgentsCmuxMcp,
    getenv: &dyn Fn(&str) -> Option<OsString>,
) -> Vec<OsString> {
    if !choice.injects() {
        let Some(entry) =
            acpmux::codex_cmux_entry::stdio_cmux_entry(launch.args, launch.cwd, getenv)
        else {
            return Vec::new();
        };
        let string = |value: &str| toml::Value::String(value.to_owned());
        let mut values = vec![("command".to_owned(), string(&entry.command))];
        if let Some(args) = &entry.args {
            values.push((
                "args".to_owned(),
                toml::Value::Array(args.iter().map(|arg| string(arg)).collect()),
            ));
        }
        values.push((format!("env.{}", acpmux::agent_tools::TOOLS_ANSWER_ENV), string("off")));
        return values
            .into_iter()
            .map(|(key, value)| OsString::from(format!("mcp_servers.cmux.{key}={value}")))
            .collect();
    }
    if acpmux::codex_cmux_entry::http_cmux_entry(launch.args, launch.cwd, getenv) {
        return Vec::new();
    }
    crate::agent_mcp_choice::codex_settings(
        choice,
        launch.executable,
        launch.socket,
        launch.cwd,
        getenv,
    )
}

fn should_inject(args: &[OsString], getenv: impl Fn(&str) -> Option<OsString>) -> bool {
    let disabled = [HOOKS_DISABLED_ENV, "CMUX_CODEX_HOOKS_DISABLED"]
        .into_iter()
        .any(|name| getenv(name).is_some_and(|value| value == "1"));
    if disabled || getenv("CMUX_TUI_CODEX_WRAPPER_ACTIVE").is_some_and(|value| value == "1") {
        return false;
    }
    !launch_classification::is_non_launch(
        &args.iter().map(|arg| arg.to_string_lossy().into_owned()).collect::<Vec<_>>(),
    )
}

fn find_real_codex(path: &OsStr, shim_dir: Option<&Path>) -> Option<PathBuf> {
    std::env::split_paths(path)
        .filter(|dir| !dir.as_os_str().is_empty() && !is_shim_directory(dir, shim_dir))
        .map(|dir| dir.join("codex"))
        .find(|candidate| {
            candidate.metadata().is_ok_and(|metadata| metadata.is_file())
                && current_process_can_execute(candidate)
                && !is_codex_shim(candidate)
        })
}

fn current_process_can_execute(path: &Path) -> bool {
    let Ok(path) = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()) else {
        return false;
    };
    // SAFETY: `path` is a live NUL-terminated CString for this call.
    unsafe { libc::access(path.as_ptr(), libc::X_OK) == 0 }
}

fn path_without_shims(path: &OsStr, shim_dir: Option<&Path>) -> OsString {
    let kept = std::env::split_paths(path).filter(|dir| {
        !dir.as_os_str().is_empty()
            && !is_shim_directory(dir, shim_dir)
            && !is_codex_shim(&dir.join("codex"))
    });
    std::env::join_paths(kept).unwrap_or_else(|_| path.to_owned())
}

fn is_shim_directory(dir: &Path, shim_dir: Option<&Path>) -> bool {
    let Some(shim_dir) = shim_dir else { return false };
    dir == shim_dir
        || matches!((dir.canonicalize(), shim_dir.canonicalize()), (Ok(dir), Ok(shim_dir)) if dir == shim_dir)
}

fn is_codex_shim(path: &Path) -> bool {
    fs::File::open(path)
        .ok()
        .and_then(|file| {
            let mut bytes = Vec::new();
            file.take(4096).read_to_end(&mut bytes).ok().map(|_| bytes)
        })
        .is_some_and(|bytes| {
            bytes.windows(SHIM_MARKER.len()).any(|window| window == SHIM_MARKER.as_bytes())
        })
}

/// Writes `<dir>/codex` (0700 in a 0700 directory) when its content changed.
pub(crate) fn install_shim(dir: &Path, executable: &Path) -> anyhow::Result<PathBuf> {
    fs::create_dir_all(dir).context("create the shim directory")?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    let path = dir.join("codex");
    let script = shim_script(executable, dir)?;
    let current = fs::symlink_metadata(&path).is_ok_and(|metadata| metadata.is_file())
        && fs::read(&path).is_ok_and(|existing| existing == script.as_bytes());
    if current {
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700))?;
    } else {
        agent_hook_install::replace_rewritable_file(&path, script.as_bytes(), Some(0o700))?;
    }
    Ok(path)
}

fn shim_script(executable: &Path, dir: &Path) -> anyhow::Result<String> {
    let executable =
        agent_hook_install::shell_quote(executable.to_str().context("cmux-tui path is not UTF-8")?);
    let dir = agent_hook_install::shell_quote(dir.to_str().context("shim directory is not UTF-8")?);
    Ok(format!(
        "#!/bin/sh\n{SHIM_MARKER}\nif [ -x {executable} ]; then\n  exec {executable} agent {VERB} \"$@\"\nfi\n\nset -f\nIFS=:\nkept=\nfor entry in $PATH; do\n  [ \"$entry\" = {dir} ] || kept=\"${{kept:+$kept:}}$entry\"\ndone\nunset IFS\nset +f\nPATH=$kept\nexport PATH\nexec codex \"$@\"\n"
    ))
}

/// Codex's clap globals replace the root list when repeated after a
/// subcommand (Codex 0.160.1 keeps only the deepest list). Move session
/// -c/--config and feature flags into the root list so the wrapper's hooks
/// survive `codex exec -c ...`, `review`, `agents`, `resume` and `fork`.
fn hoist_session_global_args(args: &[OsString]) -> Vec<OsString> {
    let mut index = 0;
    while index < args.len() {
        let arg = args[index].to_string_lossy();
        if arg == "--" {
            return args.to_vec();
        }
        if arg.starts_with('-') {
            index += if launch_classification::consumes_value(&arg) { 2 } else { 1 };
        } else if matches!(arg.as_ref(), "exec" | "e" | "review" | "agents" | "resume" | "fork") {
            break;
        } else {
            return args.to_vec();
        }
    }
    if index >= args.len() {
        return args.to_vec();
    }
    let mut head = args[..index].to_vec();
    let mut tail = vec![args[index].clone()];
    index += 1;
    while index < args.len() {
        let arg = args[index].to_string_lossy();
        if arg == "--" {
            tail.extend_from_slice(&args[index..]);
            break;
        }
        let separate = matches!(arg.as_ref(), "-c" | "--config" | "--enable" | "--disable");
        let inline =
            ["--config=", "--enable=", "--disable="].iter().any(|prefix| arg.starts_with(prefix))
                || (arg.starts_with("-c") && arg.len() > 2);
        if separate && index + 1 < args.len() {
            head.extend_from_slice(&args[index..index + 2]);
            index += 2;
        } else if inline {
            head.push(args[index].clone());
            index += 1;
        } else {
            let count = if launch_classification::consumes_value(&arg) && index + 1 < args.len() {
                2
            } else {
                1
            };
            tail.extend_from_slice(&args[index..index + count]);
            index += count;
        }
    }
    head.extend(tail);
    head
}

mod launch_classification {
    const INFORMATIONAL: &[&str] = &["--help", "-h", "--version", "-V"];
    const MANAGEMENT: &[&str] = &[
        "a",
        "apply",
        "app",
        "app-server",
        "archive",
        "cloud",
        "cloud-tasks",
        "completion",
        "debug",
        "delete",
        "doctor",
        "exec-server",
        "execpolicy",
        "features",
        "git-credential",
        "help",
        "login",
        "logout",
        "mcp",
        "migrate-nfs-db",
        "migrate-rollouts",
        "plugin",
        "queue",
        "remote-control",
        "responses-api-proxy",
        "sandbox",
        "stdio-to-uds",
        "tcp-tunnel",
        "unarchive",
        "update",
    ];

    pub(super) fn consumes_value(argument: &str) -> bool {
        matches!(
            argument,
            "-c" | "--config"
                | "-m"
                | "--model"
                | "-p"
                | "--profile"
                | "-C"
                | "--cd"
                | "--remote"
                | "-a"
                | "--ask-for-approval"
                | "-s"
                | "--sandbox"
                | "--output-last-message"
                | "--enable"
                | "--disable"
                | "--add-dir"
                | "-i"
                | "--image"
                | "--local-provider"
                | "--remote-auth-token-env"
                | "--output-schema"
                | "--color"
        )
    }

    pub(super) fn is_non_launch(args: &[String]) -> bool {
        let mut expects_value = false;
        for argument in args {
            if expects_value {
                expects_value = false;
                continue;
            }
            if argument == "--" {
                return false;
            }
            if argument.starts_with('-') {
                if INFORMATIONAL.contains(&argument.as_str()) {
                    return true;
                }
                if consumes_value(argument) {
                    expects_value = true;
                }
                continue;
            }
            return MANAGEMENT.contains(&argument.as_str());
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cmux_tui_core::user_settings::AgentsCmuxMcp;

    fn os(args: &[&str]) -> Vec<OsString> {
        args.iter().map(OsString::from).collect()
    }

    /// The settings one launch in `/work` gets.
    fn launch(choice: AgentsCmuxMcp, args: &[&str]) -> Vec<String> {
        let pane = |name: &str| (name == "CMUX_TUI_TERMINAL_ID").then(|| OsString::from("term_1"));
        let args = os(args);
        let settings = mcp_settings(
            &McpLaunch {
                args: &args,
                cwd: Path::new("/work"),
                executable: Path::new("/A/cmux"),
                socket: Path::new("/tmp/s.sock"),
            },
            choice,
            &pane,
        );
        settings.iter().map(|s| s.to_string_lossy().into_owned()).collect()
    }

    /// The server goes in only with the person's yes, under the name `cmux`, for every kind of
    /// session: interactive, with a prompt, exec, review, resumed, forked, in a worktree.
    #[test]
    fn the_server_goes_in_as_cmux_only_with_the_persons_yes() {
        for choice in [AgentsCmuxMcp::Ask, AgentsCmuxMcp::Off] {
            assert!(launch(choice, &["exec", "hi there"]).is_empty(), "{choice:?}");
        }
        for args in [
            &[][..],
            &["fix the bug"],
            &["exec", "fix the bug"],
            &["review", "--uncommitted"],
            &["resume", "--last"],
            &["fork", "--last"],
            &["--worktree"],
            &["agents"],
        ] {
            let settings = launch(AgentsCmuxMcp::On, args);
            assert!(settings.iter().all(|s| s.starts_with("mcp_servers.cmux.")), "{settings:?}");
            assert!(settings.contains(&"mcp_servers.cmux.command=\"/A/cmux\"".to_owned()));
            assert!(settings.contains(&"mcp_servers.cmux.enabled=true".to_owned()), "{args:?}");
            assert!(settings.contains(&"mcp_servers.cmux.cwd=\"/work\"".to_owned()), "{args:?}");
        }
    }

    /// Without the yes, a person's own stdio `cmux` entry Codex surely loads (here their own
    /// `-c`) gets the answer, with its own command (and args, when set) beside it so the entry is
    /// whole either way; an HTTP one, which has no env, and no entry get nothing.
    #[test]
    fn without_the_yes_a_persons_stdio_entry_gets_the_answer_and_stays_whole() {
        let stdio = ["-c", "mcp_servers.cmux.command=\"/opt/cmux\"", "exec", "hi"];
        for choice in [AgentsCmuxMcp::Ask, AgentsCmuxMcp::Off] {
            assert_eq!(
                launch(choice, &stdio),
                [
                    "mcp_servers.cmux.command=\"/opt/cmux\"",
                    "mcp_servers.cmux.env.CMUX_AGENT_TOOLS_ANSWER=\"off\""
                ],
                "{choice:?}"
            );
            assert_eq!(
                launch(
                    choice,
                    &["-c", "mcp_servers.cmux={command=\"/c\", args=[\"a b\"]}", "exec", "hi"]
                ),
                [
                    "mcp_servers.cmux.command=\"/c\"",
                    "mcp_servers.cmux.args=[\"a b\"]",
                    "mcp_servers.cmux.env.CMUX_AGENT_TOOLS_ANSWER=\"off\""
                ],
            );
            assert!(launch(choice, &["-c", "mcp_servers.cmux.url=\"http://x\""]).is_empty());
            assert!(launch(choice, &["exec", "hi"]).is_empty());
        }
        // With the yes, cmux's own server goes in as before.
        assert!(
            launch(AgentsCmuxMcp::On, &stdio).contains(&"mcp_servers.cmux.enabled=true".to_owned())
        );
    }

    /// Codex 0.160.1 keeps only the deepest list of a clap global (`-c`,
    /// `--enable`, `--disable`): a subcommand's own list replaces the root's.
    /// The shim hoists them to the root after every session subcommand.
    #[test]
    fn global_settings_after_a_session_subcommand_are_hoisted() {
        fn surviving(argv: &[OsString]) -> Vec<String> {
            let argv: Vec<String> =
                argv.iter().map(|arg| arg.to_string_lossy().into_owned()).collect();
            let mut lists = vec![Vec::new()];
            let mut index = 0;
            while index < argv.len() {
                let arg = argv[index].as_str();
                if arg == "--" {
                    break;
                }
                if matches!(arg, "-c" | "--config" | "--enable" | "--disable") {
                    lists.last_mut().unwrap().push(argv[index + 1].clone());
                    index += 2;
                    continue;
                }
                if !arg.starts_with('-') && SUBCOMMANDS.contains(&arg) {
                    lists.push(Vec::new());
                }
                index += if launch_classification::consumes_value(arg) { 2 } else { 1 };
            }
            lists.into_iter().rev().find(|list| !list.is_empty()).unwrap_or_default()
        }
        const SUBCOMMANDS: &[&str] = &["exec", "e", "review", "agents", "resume", "fork"];
        let ours = [OsString::from("-c"), OsString::from("hooks.x=1")];
        for (args, theirs) in [
            (&["review", "-c", "model=o3", "--uncommitted"][..], "model=o3"),
            (&["agents", "-c", "x=1"], "x=1"),
            (&["exec", "-c", "x=1", "hi"], "x=1"),
            (&["resume", "--last", "--config", "x=1"], "x=1"),
        ] {
            let mut argv = ours.to_vec();
            argv.extend(hoist_session_global_args(&os(args)));
            let kept = surviving(&argv);
            assert!(kept.contains(&"hooks.x=1".to_owned()), "{args:?}: {argv:?} keeps {kept:?}");
            assert!(kept.contains(&theirs.to_owned()), "{args:?}: {argv:?} keeps {kept:?}");
        }
    }

    /// `codex agents` (the agent command center) and `codex review` start agent sessions: they get
    /// the hooks and the server; a command that starts no session gets neither.
    #[test]
    fn agents_and_review_get_the_server() {
        let pane = |name: &str| (name == "CMUX_TUI_TERMINAL_ID").then(|| OsString::from("term_1"));
        for args in [&["agents"][..], &["review", "--uncommitted"], &["-m", "o3", "agents"]] {
            assert!(should_inject(&os(args), pane), "{args:?}");
        }
        for args in [&["a"][..], &["apply"], &["mcp", "list"], &["git-credential", "get"]] {
            assert!(!should_inject(&os(args), pane), "{args:?}");
        }
    }
}
