use std::ffi::{OsStr, OsString};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};

use crate::cli::Error;

pub fn find_on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path)
        .map(|directory| directory.join(executable_name(name)))
        .find(|candidate| is_executable_file(candidate))
}

pub fn run_attached(
    executable: &Path,
    args: &[OsString],
    removed_env: &[&str],
) -> Result<i32, Error> {
    run_attached_with_env(executable, args, removed_env, &[])
}

pub fn run_attached_with_env(
    executable: &Path,
    args: &[OsString],
    removed_env: &[&str],
    added_env: &[(&str, &str)],
) -> Result<i32, Error> {
    run_attached_with_env_inner(executable, args, removed_env, added_env, false)
}

/// Run a routed child with a clean credential boundary.  This is used for the
/// cmux handoff path: only the newly exchanged route credential is added back
/// after inherited token-like variables are removed.
pub fn run_attached_with_env_isolated(
    executable: &Path,
    args: &[OsString],
    removed_env: &[&str],
    added_env: &[(&str, &str)],
) -> Result<i32, Error> {
    run_attached_with_env_inner(executable, args, removed_env, added_env, true)
}

fn run_attached_with_env_inner(
    executable: &Path,
    args: &[OsString],
    removed_env: &[&str],
    added_env: &[(&str, &str)],
    isolate_credentials: bool,
) -> Result<i32, Error> {
    let mut command = Command::new(executable);
    command
        .args(args)
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());
    for key in removed_env {
        command.env_remove(key);
    }
    // The descriptor marker is not secret, but it must not reach a child that
    // could accidentally consume a one-use lease a second time.
    command.env_remove("CODEROUTER_HANDOFF_FD");
    if isolate_credentials {
        remove_inherited_credentials(&mut command);
    }
    for (key, value) in added_env {
        command.env(key, value);
    }
    let status = command.status().map_err(|source| Error::Spawn {
        executable: executable.to_path_buf(),
        source,
    })?;
    Ok(exit_code(status))
}

fn remove_inherited_credentials(command: &mut Command) {
    for (key, _) in std::env::vars_os() {
        let upper = key.to_string_lossy().to_ascii_uppercase();
        let token_like = upper.contains("TOKEN")
            || upper.contains("SECRET")
            || upper.contains("PASSWORD")
            || upper.contains("CREDENTIAL")
            || upper.contains("API_KEY")
            || upper.ends_with("_KEY");
        if token_like {
            command.env_remove(key);
        }
    }
    // These names are covered by the token matcher, but keep explicit aliases
    // here as a reviewable contract for Stack and CodeRouter handoff values.
    for key in [
        // The routed child receives its trusted base URL through the provider
        // configuration. It does not need the CLI's origin or credential-file
        // location, which could otherwise expose a saved Stack session.
        "CODEROUTER_API_URL",
        "CODEROUTER_DATA_DIR",
        "CODEROUTER_HANDOFF_LEASE",
        "CODEROUTER_ROUTE_TOKEN",
        "STACK_ACCESS_TOKEN",
        "STACK_REFRESH_TOKEN",
        "X_STACK_ACCESS_TOKEN",
        "X_STACK_REFRESH_TOKEN",
        "CMUX_STACK_ACCESS_TOKEN",
        "CMUX_STACK_REFRESH_TOKEN",
    ] {
        command.env_remove(key);
    }
}

pub fn is_same_executable(left: &Path, right: &Path) -> bool {
    let left = std::fs::canonicalize(left).unwrap_or_else(|_| left.to_path_buf());
    let right = std::fs::canonicalize(right).unwrap_or_else(|_| right.to_path_buf());
    left == right
}

fn exit_code(status: ExitStatus) -> i32 {
    status.code().unwrap_or(1)
}

fn executable_name(name: &str) -> OsString {
    #[cfg(windows)]
    {
        if name.ends_with(".exe") {
            OsString::from(name)
        } else {
            OsString::from(format!("{name}.exe"))
        }
    }
    #[cfg(not(windows))]
    {
        OsString::from(name)
    }
}

fn is_executable_file(path: &Path) -> bool {
    let Ok(metadata) = path.metadata() else {
        return false;
    };
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

pub fn os(value: impl AsRef<OsStr>) -> OsString {
    value.as_ref().to_os_string()
}
