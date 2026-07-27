use std::ffi::{OsStr, OsString};
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode, Stdio};

use anyhow::{Context, Result};

use crate::localization::Catalog;

const CODEX_PATH_OVERRIDE: &str = "CMUX_TREE_CODEX_PATH";
const HOOK_DEBUG: &str = "CMUX_TREE_HOOK_DEBUG";

pub fn run(arguments: Vec<OsString>, catalog: Catalog) -> Result<ExitCode> {
    let current_executable = std::env::current_exe().ok();
    let codex_home = codex_home();
    let codex = resolve_codex(
        std::env::var_os(CODEX_PATH_OVERRIDE).as_deref(),
        &codex_home,
        std::env::var_os("PATH").as_deref(),
        current_executable.as_deref(),
        catalog,
    )
    .context(catalog.codex_binary_not_found())?;

    if invocation_can_use_local_daemon(&arguments) {
        ensure_local_daemon(&codex, &codex_home, catalog);
    }

    replace_with_codex(&codex, &arguments, catalog)
}

fn codex_home() -> PathBuf {
    std::env::var_os("CODEX_HOME").map_or_else(
        || {
            std::env::var_os("HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("."))
                .join(".codex")
        },
        PathBuf::from,
    )
}

fn resolve_codex(
    explicit: Option<&OsStr>,
    codex_home: &Path,
    search_path: Option<&OsStr>,
    current_executable: Option<&Path>,
    catalog: Catalog,
) -> Result<PathBuf> {
    if let Some(explicit) = explicit.filter(|value| !value.is_empty()) {
        let candidate = PathBuf::from(explicit);
        if executable_candidate(&candidate, current_executable) {
            return Ok(candidate);
        }
        anyhow::bail!(catalog.invalid_codex_binary(&candidate.display().to_string()));
    }

    let managed = codex_home.join("packages/standalone/current/codex");
    if executable_candidate(&managed, current_executable) {
        return Ok(managed);
    }

    for directory in search_path.into_iter().flat_map(std::env::split_paths) {
        let candidate = directory.join("codex");
        if executable_candidate(&candidate, current_executable) {
            return Ok(candidate);
        }
    }

    anyhow::bail!(catalog.no_codex_binary())
}

fn executable_candidate(candidate: &Path, current_executable: Option<&Path>) -> bool {
    if same_file(candidate, current_executable) {
        return false;
    }
    let Ok(metadata) = fs::metadata(candidate) else { return false };
    if !metadata.is_file() {
        return false;
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;

        metadata.permissions().mode() & 0o111 != 0
    }
    #[cfg(not(unix))]
    {
        true
    }
}

fn same_file(candidate: &Path, current_executable: Option<&Path>) -> bool {
    let Some(current_executable) = current_executable else { return false };
    let (Ok(candidate), Ok(current)) = (fs::metadata(candidate), fs::metadata(current_executable))
    else {
        return false;
    };
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;

        candidate.dev() == current.dev() && candidate.ino() == current.ino()
    }
    #[cfg(not(unix))]
    {
        fs::canonicalize(candidate).ok() == fs::canonicalize(current_executable).ok()
    }
}

fn invocation_can_use_local_daemon(arguments: &[OsString]) -> bool {
    let mut first_positional = None;
    let mut consume_next = false;

    for argument in arguments {
        if consume_next {
            consume_next = false;
            continue;
        }
        let Some(argument) = argument.to_str() else {
            first_positional.get_or_insert("");
            continue;
        };
        if argument == "--" {
            first_positional.get_or_insert("");
            break;
        }
        if is_non_replayable_option(argument) {
            return false;
        }
        if argument.starts_with('-') {
            if matches!(argument, "-h" | "--help" | "-V" | "--version") {
                return false;
            }
            consume_next = option_consumes_value(argument);
            continue;
        }
        if first_positional.is_none() {
            first_positional = Some(argument);
        }
    }

    match first_positional {
        None | Some("") => true,
        Some("resume" | "fork" | "archive" | "delete" | "unarchive") => true,
        Some(command) if known_non_session_subcommand(command) => false,
        Some(_) => true,
    }
}

fn is_non_replayable_option(argument: &str) -> bool {
    matches!(
        argument,
        "-c" | "--config"
            | "-p"
            | "--profile"
            | "--enable"
            | "--disable"
            | "--search"
            | "--strict-config"
            | "--dangerously-bypass-hook-trust"
            | "--remote"
            | "--remote-auth-token-env"
    ) || [
        "--config=",
        "--profile=",
        "--enable=",
        "--disable=",
        "--remote=",
        "--remote-auth-token-env=",
    ]
    .iter()
    .any(|prefix| argument.starts_with(prefix))
}

fn option_consumes_value(argument: &str) -> bool {
    !argument.contains('=')
        && matches!(
            argument,
            "-m" | "--model"
                | "-C"
                | "--cd"
                | "-a"
                | "--ask-for-approval"
                | "-s"
                | "--sandbox"
                | "--output-last-message"
                | "-i"
                | "--image"
                | "--oss-provider"
        )
}

fn known_non_session_subcommand(argument: &str) -> bool {
    matches!(
        argument,
        "exec"
            | "e"
            | "review"
            | "login"
            | "logout"
            | "mcp"
            | "plugin"
            | "mcp-server"
            | "app-server"
            | "remote-control"
            | "app"
            | "completion"
            | "update"
            | "doctor"
            | "sandbox"
            | "debug"
            | "apply"
            | "a"
            | "cloud"
            | "exec-server"
            | "features"
            | "help"
    )
}

fn ensure_local_daemon(codex: &Path, codex_home: &Path, catalog: Catalog) {
    let socket = codex_home.join("app-server-control/app-server-control.sock");
    if is_unix_socket(&socket) {
        return;
    }

    let result = Command::new(codex)
        .args(["app-server", "daemon", "start"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
    if std::env::var_os(HOOK_DEBUG).as_deref() == Some(OsStr::new("1"))
        && result.as_ref().map_or(true, |status| !status.success())
    {
        eprintln!("cmux-tree-hook: {}", catalog.daemon_start_failed());
    }
}

#[cfg(unix)]
fn is_unix_socket(path: &Path) -> bool {
    use std::os::unix::fs::FileTypeExt;

    fs::metadata(path).is_ok_and(|metadata| metadata.file_type().is_socket())
}

#[cfg(not(unix))]
fn is_unix_socket(_path: &Path) -> bool {
    false
}

#[cfg(unix)]
fn replace_with_codex(codex: &Path, arguments: &[OsString], catalog: Catalog) -> Result<ExitCode> {
    use std::os::unix::process::CommandExt;

    let error = Command::new(codex).args(arguments).exec();
    Err(error).with_context(|| catalog.launch_codex(&codex.display().to_string()))
}

#[cfg(not(unix))]
fn replace_with_codex(codex: &Path, arguments: &[OsString], catalog: Catalog) -> Result<ExitCode> {
    let status = Command::new(codex)
        .args(arguments)
        .status()
        .with_context(|| catalog.launch_codex(&codex.display().to_string()))?;
    Ok(if status.success() { ExitCode::SUCCESS } else { ExitCode::FAILURE })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(values: &[&str]) -> Vec<OsString> {
        values.iter().map(OsString::from).collect()
    }

    #[test]
    fn interactive_and_session_tui_invocations_prepare_the_daemon() {
        for arguments in [
            args(&[]),
            args(&["hello"]),
            args(&["--model", "gpt-test"]),
            args(&["resume", "--last"]),
            args(&["fork", "session-id"]),
            args(&["delete", "session-id"]),
        ] {
            assert!(invocation_can_use_local_daemon(&arguments), "{arguments:?}");
        }
    }

    #[test]
    fn non_replayable_and_non_session_invocations_do_not_prepare_the_daemon() {
        for arguments in [
            args(&["--version"]),
            args(&["exec", "hello"]),
            args(&["app-server", "--listen", "stdio://"]),
            args(&["-c", "model_reasoning_effort=high"]),
            args(&["resume", "--remote", "unix://"]),
            args(&["resume", "--enable=hooks"]),
            args(&["--dangerously-bypass-hook-trust"]),
        ] {
            assert!(!invocation_can_use_local_daemon(&arguments), "{arguments:?}");
        }
    }

    #[test]
    fn explicit_codex_path_is_authoritative() {
        let root = std::env::temp_dir().join(format!("cmux-tree-hook-path-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(&root).unwrap();
        let explicit = root.join("codex");
        fs::write(&explicit, b"codex").unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;

            fs::set_permissions(&explicit, fs::Permissions::from_mode(0o700)).unwrap();
        }

        let resolved = resolve_codex(
            Some(explicit.as_os_str()),
            &root,
            None,
            None,
            Catalog::new(crate::localization::Locale::English),
        )
        .unwrap();
        assert_eq!(resolved, explicit);
        fs::remove_dir_all(root).unwrap();
    }
}
