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
use std::os::unix::fs::PermissionsExt as _;
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
    let path = std::env::var_os("PATH").unwrap_or_default();
    let shim_dir = shim_directory();
    let Some(codex) = find_real_codex(&path, shim_dir.as_deref()) else {
        eprintln!("codex: command not found");
        return 127;
    };

    let mut command = Command::new(&codex);
    command.env("PATH", path_without_shims(&path, shim_dir.as_deref()));
    let mut launch_args = args.to_vec();
    if should_inject(args, |name| std::env::var_os(name)) {
        if let Some((injected, helper)) = prepare_hooks(args) {
            launch_args = injected;
            command.env("CMUX_TUI_CODEX_WRAPPER_ACTIVE", "1");
            command.env("CMUX_TUI_HOOK", helper);
        }
    }
    let _error = command.args(&launch_args).exec();
    eprintln!("codex: failed to start");
    126
}

/// PATH for pane processes: the Codex shim directory first, then the server's
/// PATH. The Claude shim uses the same directory, so both are available from
/// one environment entry.
pub(crate) fn pane_path() -> Option<String> {
    let dir = shim_directory()?;
    let executable = current_executable().ok()?;
    install_shim(&dir, &executable).ok()?;
    path_with_shim_first(&std::env::var_os("PATH").unwrap_or_default(), &dir)?.into_string().ok()
}

fn shim_directory() -> Option<PathBuf> {
    agent_hook_install::runtime_cmux_tui_data_home().map(|home| home.join("shims"))
}

fn current_executable() -> anyhow::Result<PathBuf> {
    let executable = std::env::current_exe().context("resolve the cmux-tui executable")?;
    Ok(executable.canonicalize().unwrap_or(executable))
}

fn hook_helper(executable: &Path) -> Option<PathBuf> {
    agent_hook_install::runtime_helper_path()
        .filter(|path| agent_hook_install::is_executable_file(path))
        .or_else(|| agent_hook_install::locate_helper_source(Some(executable)))
        .filter(|path| path.is_absolute())
}

fn prepare_hooks(args: &[OsString]) -> Option<(Vec<OsString>, PathBuf)> {
    let executable = current_executable().ok()?;
    let helper = hook_helper(&executable)?;
    let socket = std::env::var_os("CMUX_TUI_SOCKET").filter(|value| !value.is_empty())?;
    let terminal = std::env::var("CMUX_TUI_TERMINAL_ID").ok().filter(|value| !value.is_empty())?;
    let socket = PathBuf::from(socket);
    let mut launch = vec![OsString::from("--enable"), OsString::from("hooks")];
    launch.push(OsString::from("--dangerously-bypass-hook-trust"));
    for event in agent_hook_install::CODEX_EVENTS {
        launch.push(OsString::from("-c"));
        launch.push(OsString::from(agent_hook_install::codex_contextual_hook_setting(
            event, &socket, &terminal, &helper,
        )));
    }
    launch.extend_from_slice(args);
    Some((launch, helper))
}

fn should_inject(args: &[OsString], getenv: impl Fn(&str) -> Option<OsString>) -> bool {
    let disabled = [HOOKS_DISABLED_ENV, "CMUX_CODEX_HOOKS_DISABLED"]
        .into_iter()
        .any(|name| getenv(name).is_some_and(|value| value == "1"));
    if disabled || getenv("CMUX_TUI_CODEX_WRAPPER_ACTIVE").is_some_and(|value| value == "1") {
        return false;
    }
    let Some(socket) = getenv("CMUX_TUI_SOCKET").filter(|value| !value.is_empty()) else {
        return false;
    };
    if !fs::metadata(socket).is_ok_and(|metadata| metadata.file_type().is_socket()) {
        return false;
    }
    if getenv("CMUX_TUI_TERMINAL_ID").is_none_or(|value| value.is_empty()) {
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

fn path_with_shim_first(path: &OsStr, shim_dir: &Path) -> Option<OsString> {
    let inherited = std::env::split_paths(path).filter(|dir| dir != shim_dir);
    std::env::join_paths(std::iter::once(shim_dir.to_path_buf()).chain(inherited)).ok()
}

fn is_shim_directory(dir: &Path, shim_dir: Option<&Path>) -> bool {
    let Some(shim_dir) = shim_dir else { return false };
    dir == shim_dir
        || matches!((dir.canonicalize(), shim_dir.canonicalize()), (Ok(dir), Ok(shim_dir)) if dir == shim_dir)
}

fn is_codex_shim(path: &Path) -> bool {
    fs::read(path)
        .ok()
        .is_some_and(|bytes| bytes.windows(SHIM_MARKER.len()).any(|window| window == SHIM_MARKER.as_bytes()))
}

fn install_shim(dir: &Path, executable: &Path) -> anyhow::Result<PathBuf> {
    fs::create_dir_all(dir).context("create the shim directory")?;
    fs::set_permissions(dir, fs::Permissions::from_mode(0o700))?;
    let path = dir.join("codex");
    let script = shim_script(executable, dir)?;
    let current = fs::symlink_metadata(&path).is_ok_and(|metadata| metadata.is_file())
        && fs::read(&path).is_ok_and(|existing| existing == script.as_bytes());
    if current {
        fs::set_permissions(&path, fs::Permissions::from_mode(0o700))?;
    } else {
        agent_hook_install::atomic_write(&path, script.as_bytes(), Some(0o700))?;
    }
    Ok(path)
}

fn shim_script(executable: &Path, dir: &Path) -> anyhow::Result<String> {
    let executable = agent_hook_install::shell_quote(executable.to_str().context("cmux-tui path is not UTF-8")?);
    let dir = agent_hook_install::shell_quote(dir.to_str().context("shim directory is not UTF-8")?);
    Ok(format!(
        "#!/bin/sh\n{SHIM_MARKER}\nif [ -x {executable} ]; then\n  exec {executable} agent {VERB} \"$@\"\nfi\n\nset -f\nIFS=:\nkept=\nfor entry in $PATH; do\n  [ \"$entry\" = {dir} ] || kept=\"${{kept:+$kept:}}$entry\"\ndone\nunset IFS\nset +f\nPATH=$kept\nexport PATH\nexec codex \"$@\"\n"
    ))
}

mod launch_classification {
    const INFORMATIONAL: &[&str] = &["--help", "-h", "--version", "-V"];
    const MANAGEMENT: &[&str] = &[
        "apply", "app", "app-server", "archive", "completion", "debug", "delete", "doctor",
        "exec-server", "features", "help", "login", "logout", "mcp", "mcp-server", "plugin",
        "remote-control", "review", "sandbox", "unarchive", "update",
    ];

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
                if matches!(argument.as_str(), "-c" | "--config" | "-m" | "--model" | "-p" | "--profile" | "-C" | "--cd" | "-s" | "--sandbox" | "--enable" | "--disable") && !argument.contains('=') {
                    expects_value = true;
                }
                continue;
            }
            return MANAGEMENT.contains(&argument.as_str()) && !matches!(argument.as_str(), "exec" | "resume" | "fork");
        }
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    fn os(args: &[&str]) -> Vec<OsString> {
        args.iter().map(OsString::from).collect()
    }

    #[test]
    fn codex_wrapper_injects_session_entrypoints_only() {
        let root = tempfile::tempdir().unwrap();
        let socket = root.path().join("mux.sock");
        let _listener = UnixListener::bind(&socket).unwrap();
        let env = |args: &[(&str, &str)]| {
            let socket = socket.clone();
            move |name: &str| -> Option<OsString> {
                if let Some((_, value)) = args.iter().find(|(key, _)| *key == name) {
                    return Some((*value).into());
                }
                match name {
                    "CMUX_TUI_SOCKET" => Some(socket.clone().into_os_string()),
                    "CMUX_TUI_TERMINAL_ID" => Some("term_1".into()),
                    _ => None,
                }
            }
        };
        assert!(!should_inject(&os(&["--version"]), env(&[])));
        assert!(!should_inject(&os(&["mcp", "list"]), env(&[])));
        assert!(should_inject(&os(&[]), env(&[])));
        assert!(should_inject(&os(&["exec", "hello"]), env(&[])));
        assert!(should_inject(&os(&["resume", "--last"]), env(&[])));
        assert!(!should_inject(&os(&[]), env(&[(HOOKS_DISABLED_ENV, "1")])), "opt-out");
    }

    #[test]
    fn codex_wrapper_shim_selects_only_the_hidden_verb() {
        let args = os(&["agent", "codex-wrapper", "exec"]);
        assert_eq!(invocation(&args), Some(&args[2..]));
        assert_eq!(invocation(&os(&["agent", "list"])), None);
    }
}
