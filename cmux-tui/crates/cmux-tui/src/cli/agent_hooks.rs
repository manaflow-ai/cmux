use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};

use serde_json::json;

use super::{GlobalArgs, UsageError};

const PI_EXTENSION: &str = include_str!("../../assets/cmux-pi-session.ts");
const MANAGED_MARKER: &str = "// cmux-tui-pi-session-extension v1";

pub(super) struct AgentHooksPlan {
    pub force: bool,
}

pub(super) fn run(global: GlobalArgs, plan: AgentHooksPlan) -> i32 {
    match install_pi_extension(plan.force) {
        Ok((path, changed)) => super::wire::print_local_success(
            &json!({"installed": true, "changed": changed, "path": path}),
            global.output,
        ),
        Err(error) => super::wire::print_local_error(
            &json!({
                "code": "agent_hooks.install_failed",
                "message": error.to_string(),
                "details": {},
                "retryable": false,
            }),
            global.output,
            1,
        ),
    }
}

fn install_pi_extension(force: bool) -> Result<(PathBuf, bool), UsageError> {
    let root = pi_agent_root()?;
    install_pi_extension_at(&root, force)
}

fn pi_agent_root() -> Result<PathBuf, UsageError> {
    if let Some(path) = std::env::var_os("PI_CODING_AGENT_DIR").filter(|value| !value.is_empty()) {
        return Ok(PathBuf::from(path));
    }
    cmux_tui_core::platform::home_dir()
        .map(|home| home.join(".pi").join("agent"))
        .ok_or_else(|| UsageError::new("cannot determine Pi agent directory"))
}

fn install_pi_extension_at(root: &Path, force: bool) -> Result<(PathBuf, bool), UsageError> {
    let directory = root.join("extensions");
    fs::create_dir_all(&directory).map_err(|error| {
        UsageError::new(format!("cannot create {}: {error}", directory.display()))
    })?;
    let path = directory.join("cmux-tui-session.ts");
    match fs::read_to_string(&path) {
        Ok(current) if current == PI_EXTENSION => return Ok((path, false)),
        Ok(current) if !force && !current.starts_with(MANAGED_MARKER) => {
            return Err(UsageError::new(format!(
                "{} is not managed by cmux; pass --force to replace it",
                path.display()
            )));
        }
        Ok(_) => {}
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(UsageError::new(format!("cannot read {}: {error}", path.display())));
        }
    }

    let mut temporary = None;
    for attempt in 0..16 {
        let candidate =
            directory.join(format!(".cmux-tui-session.{}.{}.tmp", std::process::id(), attempt));
        let mut options = OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        match options.open(&candidate) {
            Ok(mut file) => {
                file.write_all(PI_EXTENSION.as_bytes()).map_err(|error| {
                    UsageError::new(format!("cannot write {}: {error}", candidate.display()))
                })?;
                file.sync_all().map_err(|error| {
                    UsageError::new(format!("cannot sync {}: {error}", candidate.display()))
                })?;
                temporary = Some(candidate);
                break;
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(UsageError::new(format!(
                    "cannot create extension beside {}: {error}",
                    path.display()
                )));
            }
        }
    }
    let temporary = temporary.ok_or_else(|| UsageError::new("cannot allocate extension file"))?;
    if let Err(error) = fs::rename(&temporary, &path) {
        let _ = fs::remove_file(&temporary);
        return Err(UsageError::new(format!("cannot install {}: {error}", path.display())));
    }
    Ok((path, true))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn install_is_idempotent_and_does_not_replace_unmanaged_files() {
        let directory = tempfile::tempdir().unwrap();
        let (path, changed) = install_pi_extension_at(directory.path(), false).unwrap();
        assert!(changed);
        assert_eq!(fs::read_to_string(&path).unwrap(), PI_EXTENSION);
        assert!(!install_pi_extension_at(directory.path(), false).unwrap().1);

        fs::write(&path, "user extension\n").unwrap();
        assert!(install_pi_extension_at(directory.path(), false).is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), "user extension\n");
        assert!(install_pi_extension_at(directory.path(), true).unwrap().1);
    }
}
