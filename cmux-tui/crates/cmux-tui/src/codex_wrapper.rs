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
        let resolver_path = path_without_shims(&path, shim_dir.as_deref());
        match prepare_hooks(args, &codex, &resolver_path) {
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

fn prepare_hooks(
    args: &[OsString],
    codex: &Path,
    path: &OsStr,
) -> anyhow::Result<Option<Vec<OsString>>> {
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
    // cmux Computer Use, with no setup (agent_computer_use.rs), unless the
    // person said no to cmux's tools in their agents (agent_mcp_choice.rs).
    let cwd = std::env::current_dir().unwrap_or_default();
    let resolve = |codex: &Path, path: &OsStr, cwd: &Path, config: &ConfigArgs| {
        crate::codex_mcp_entry::resolve(codex, path, cwd, config, crate::codex_mcp_entry::TIMEOUT)
    };
    let settings = mcp_settings(
        &McpLaunch { args, codex, path, cwd: &cwd, executable: &executable, socket: &socket },
        cmux_tui_core::user_settings::AgentsCmuxMcp::current(),
        &resolve,
        &|name| std::env::var_os(name),
        &mut |line| eprintln!("{line}"),
    );
    for setting in settings {
        launch.push(OsString::from("-c"));
        launch.push(setting);
    }
    launch.extend(hoist_session_global_args(args));
    Ok(Some(launch))
}

use crate::agent_computer_use::CodexEntry;
use crate::codex_mcp_entry::ConfigArgs;

/// What [`mcp_settings`] needs of the launch: the person's Codex arguments,
/// the real Codex, the shim-free `PATH`, the launch folder, this build's CLI
/// and the pane's daemon socket.
struct McpLaunch<'a> {
    args: &'a [OsString],
    codex: &'a Path,
    path: &'a OsStr,
    cwd: &'a Path,
    executable: &'a Path,
    socket: &'a Path,
}

/// The `-c` values that add cmux's server to this launch
/// (agent_computer_use.rs), when the person said yes to cmux's tools in their
/// agents (`choice`; nothing otherwise). Only then is Codex asked for its
/// `cmux` entry (`resolve`, codex_mcp_entry.rs), with the shim-free `PATH`
/// and the person's config arguments; an answer it could not get is said on
/// `warn`, and nothing is turned off.
fn mcp_settings(
    launch: &McpLaunch<'_>,
    choice: cmux_tui_core::user_settings::AgentsCmuxMcp,
    resolve: &dyn Fn(&Path, &OsStr, &Path, &ConfigArgs) -> CodexEntry,
    getenv: &dyn Fn(&str) -> Option<OsString>,
    warn: &mut dyn FnMut(&str),
) -> Vec<OsString> {
    if !choice.injects() {
        return Vec::new();
    }
    // A resumed or forked session, a new worktree, a remote server: Codex's
    // answer here is not the launch's, so nothing is turned off (asked or said).
    let existing = if crate::codex_mcp_entry::probe_matches_launch(launch.args) {
        let config = crate::codex_mcp_entry::config_args(launch.args);
        let existing = resolve(launch.codex, launch.path, launch.cwd, &config);
        if existing == CodexEntry::Unknown {
            warn(crate::localization::catalog().agent_wrapper.codex_mcp_unknown);
        }
        existing
    } else {
        CodexEntry::Unknown
    };
    crate::agent_mcp_choice::codex_settings(
        choice,
        launch.executable,
        launch.socket,
        &existing,
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
/// subcommand. Move session -c/--config and feature flags into the root list
/// so the wrapper's hooks survive `codex exec -c ...` and resume/fork.
fn hoist_session_global_args(args: &[OsString]) -> Vec<OsString> {
    let mut index = 0;
    while index < args.len() {
        let arg = args[index].to_string_lossy();
        if arg == "--" {
            return args.to_vec();
        }
        if arg.starts_with('-') {
            index += if launch_classification::consumes_value(&arg) { 2 } else { 1 };
        } else if matches!(arg.as_ref(), "exec" | "e" | "resume" | "fork") {
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
        "completion",
        "debug",
        "delete",
        "doctor",
        "exec-server",
        "features",
        "help",
        "login",
        "logout",
        "mcp",
        "mcp-server",
        "plugin",
        "remote-control",
        "review",
        "sandbox",
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
    use std::cell::RefCell;

    fn os(args: &[&str]) -> Vec<OsString> {
        args.iter().map(OsString::from).collect()
    }

    /// One resolver call: the Codex, PATH, folder and config arguments.
    type Call = (PathBuf, OsString, PathBuf, Vec<OsString>);

    /// The settings one launch gets, the resolver's calls, and what was said.
    fn launch(
        choice: AgentsCmuxMcp,
        args: &[&str],
        answer: CodexEntry,
    ) -> (Vec<String>, Vec<Call>, Vec<String>) {
        let calls = RefCell::new(Vec::new());
        let resolve = |codex: &Path, path: &OsStr, cwd: &Path, config: &ConfigArgs| {
            calls.borrow_mut().push((
                codex.to_owned(),
                path.to_owned(),
                cwd.to_owned(),
                config.args.clone(),
            ));
            answer.clone()
        };
        let pane = |name: &str| (name == "CMUX_TUI_TERMINAL_ID").then(|| OsString::from("term_1"));
        let mut said = Vec::new();
        let args = os(args);
        let settings = mcp_settings(
            &McpLaunch {
                args: &args,
                codex: Path::new("/real/codex"),
                path: OsStr::new("/usr/bin:/bin"),
                cwd: Path::new("/work"),
                executable: Path::new("/A/cmux"),
                socket: Path::new("/tmp/s.sock"),
            },
            choice,
            &resolve,
            &pane,
            &mut |line| said.push(line.to_owned()),
        );
        let settings = settings.iter().map(|s| s.to_string_lossy().into_owned()).collect();
        (settings, calls.into_inner(), said)
    }

    fn found(command: &str) -> CodexEntry {
        CodexEntry::Found(serde_json::json!({
            "name": "cmux", "enabled": true,
            "transport": {"type": "stdio", "command": command, "args": ["mcp", "serve"]},
        }))
    }

    /// Codex is asked only when the server goes in, with the shim-free PATH,
    /// the launch folder and the person's config arguments.
    #[test]
    fn codex_is_asked_only_when_the_server_goes_in() {
        for choice in [AgentsCmuxMcp::Ask, AgentsCmuxMcp::Off] {
            let (settings, calls, said) = launch(choice, &["-p", "work"], found("/opt/cmux"));
            assert!(settings.is_empty() && calls.is_empty() && said.is_empty(), "{choice:?}");
        }
        let (settings, calls, said) = launch(
            AgentsCmuxMcp::On,
            &["-pwork", "-c", "x=1", "exec", "say hi"],
            CodexEntry::Absent,
        );
        assert_eq!(calls.len(), 1);
        let (codex, path, cwd, config) = &calls[0];
        assert_eq!(
            (codex.as_path(), path.as_os_str(), cwd.as_path()),
            (Path::new("/real/codex"), OsStr::new("/usr/bin:/bin"), Path::new("/work"))
        );
        assert_eq!(config, &os(&["--profile", "work", "-c", "x=1"]));
        assert!(said.is_empty());
        assert!(
            settings.iter().all(|s| s.starts_with("mcp_servers.cmux_terminal.")),
            "{settings:?}"
        );
    }

    /// A launch whose session Codex's answer does not describe (a new
    /// worktree: untrusted, no project layer; a resumed or forked session):
    /// Codex is not asked and nothing is turned off, which would otherwise
    /// fail Codex with "invalid transport".
    #[test]
    fn a_worktree_or_resumed_session_turns_nothing_off() {
        for args in [
            &["--worktree"][..],
            &["exec", "--worktree", "hi"],
            &["resume", "--last"],
            &["exec", "resume", "--last"],
            &["fork", "--last"],
            // A skip flag after the prompt (reproduced with Codex 0.169).
            &["exec", "hi", "--worktree"],
            &["exec", "hi", "--ignore-user-config"],
            &["hi", "--remote", "ws://127.0.0.1:1"],
        ] {
            let (settings, calls, said) = launch(AgentsCmuxMcp::On, args, found("/opt/cmux"));
            assert!(calls.is_empty(), "{args:?}");
            // Said once: the person's own cmux server stays on for this launch.
            assert_eq!(said.len(), 1, "{args:?}: {said:?}");
            assert!(said[0].starts_with("cmux: "), "{said:?}");
            assert!(
                !settings.iter().any(|s| s.contains("enabled=false")),
                "{args:?}: {settings:?}"
            );
            assert!(settings.iter().any(|s| s.starts_with("mcp_servers.cmux_terminal.command=")));
        }
    }

    /// An entry with a url is never turned off, and the person is told.
    #[test]
    fn a_url_entry_is_kept_and_said() {
        let http = CodexEntry::Found(serde_json::json!({
            "name": "cmux", "enabled": true,
            "transport": {"type": "streamable_http", "url": "http://127.0.0.1:1/mcp"},
        }));
        let (settings, _, said) = launch(AgentsCmuxMcp::On, &[], http);
        assert!(!settings.iter().any(|s| s.starts_with("mcp_servers.cmux.")), "{settings:?}");
        assert_eq!(said.len(), 1, "{said:?}");
        assert!(said[0].starts_with("cmux: "), "{said:?}");
    }

    /// `enabled=false` only for another cmux's entry Codex reported; an
    /// answer it could not get is said once, and nothing is turned off.
    #[test]
    fn only_another_cmuxs_entry_is_turned_off() {
        let off = "mcp_servers.cmux.enabled=false".to_owned();
        let (settings, _, said) = launch(AgentsCmuxMcp::On, &[], found("/opt/cmux"));
        assert!(settings.contains(&off) && said.is_empty(), "{settings:?}");
        let (settings, _, _) = launch(AgentsCmuxMcp::On, &[], found("/usr/bin/my-tool"));
        assert!(!settings.contains(&off), "{settings:?}");
        let (settings, _, said) = launch(AgentsCmuxMcp::On, &[], CodexEntry::Unknown);
        assert!(!settings.contains(&off), "{settings:?}");
        // One line, the shim's own (structure, not wording).
        assert_eq!(said.len(), 1, "{said:?}");
        assert!(said[0].starts_with("cmux: ") && said[0].contains("Codex"), "{said:?}");
        assert!(settings.iter().any(|s| s.starts_with("mcp_servers.cmux_terminal.command=")));
    }
}
