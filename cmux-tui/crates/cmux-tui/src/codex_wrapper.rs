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
    let shim_dir = shim_directory();
    let Some(codex) = find_real_codex(&path, shim_dir.as_deref()) else {
        eprintln!("{}", messages.agent_not_found);
        return 127;
    };

    let mut command = Command::new(&codex);
    command.env("PATH", path_without_shims(&path, shim_dir.as_deref()));
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

fn prepare_hooks(args: &[OsString]) -> anyhow::Result<Option<Vec<OsString>>> {
    let Some((socket, Some(terminal))) = crate::hook_helper::session_route() else {
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
    launch.extend(hoist_session_global_args(args));
    Ok(Some(launch))
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

    fn os(args: &[&str]) -> Vec<OsString> {
        args.iter().map(OsString::from).collect()
    }

    #[test]
    fn codex_wrapper_injects_session_entrypoints_only() {
        let env = |overrides: &'static [(&'static str, &'static str)]| {
            move |name: &str| {
                overrides.iter().find(|(key, _)| *key == name).map(|(_, value)| (*value).into())
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
    fn codex_wrapper_preserves_session_config_and_prompt_arguments() {
        assert_eq!(
            hoist_session_global_args(&os(&[
                "-c",
                "model=\"root\"",
                "exec",
                "--image",
                "--config=picture",
                "--enable",
                "foo",
                "-cmodel=\"child\"",
                "--",
                "-c",
                "prompt"
            ])),
            os(&[
                "-c",
                "model=\"root\"",
                "--enable",
                "foo",
                "-cmodel=\"child\"",
                "exec",
                "--image",
                "--config=picture",
                "--",
                "-c",
                "prompt"
            ]),
        );
        for args in [
            os(&["a", "diff"]),
            os(&["--", "exec", "-c", "prompt"]),
            os(&["a prompt", "--config=x"]),
        ] {
            assert_eq!(hoist_session_global_args(&args), args);
        }
    }

    #[test]
    fn codex_wrapper_shim_selects_only_the_hidden_verb() {
        let args = os(&["agent", "codex-wrapper", "exec"]);
        assert_eq!(invocation(&args), Some(&args[2..]));
        assert_eq!(invocation(&os(&["agent", "list"])), None);
    }
}
