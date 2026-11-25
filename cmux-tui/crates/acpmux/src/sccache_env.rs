//! The compiler cache on a person's Cloud machine (RFD 0068 item 6): the variables that point
//! `cargo` at sccache, added to the environment of every agent this daemon spawns there, and so
//! to every shell and command the agent runs.
//!
//! The cloud service names the cache in the bind file's `sccache` section only when it is on;
//! cmux-host keeps it and copies it to [`ENV_FILE`] for the work user (cmux-host
//! `sccache_env.rs`). This daemon reads that file at each agent spawn and adds its variables
//! when all of these hold; otherwise the environment is exactly what it was without it:
//!
//! - this is a Cloud VM (`cloud_host::is_cloud_vm`) and the file is there, this user's, and valid;
//! - every name in it is `RUSTC_WRAPPER` or `SCCACHE_*` (any other name refuses the whole file);
//! - an `sccache` binary is on the PATH the agent gets;
//! - the agent's environment (the profile's, the login shell's, this daemon's) has no
//!   `RUSTC_WRAPPER`: a wrapper the person set wins, and then none of these are added.
//!
//! A variable the person set is never replaced. Logs carry names only, never values.

use std::ffi::OsStr;
use std::path::Path;

/// The work user's copy of the bind's `sccache` section (cmux-host `sccache_env::ENV_FILE`).
pub const ENV_FILE: &str = "/run/cmux/sccache-env.json";

/// The variable whose presence means the person chose their own compiler wrapper.
pub const WRAPPER: &str = "RUSTC_WRAPPER";

const MAX_FILE: u64 = 64 * 1024;
const MAX_VARS: usize = 32;
const MAX_VALUE: usize = 4096;

/// A name the file may set: `RUSTC_WRAPPER`, or `SCCACHE_` and upper-case letters, digits or
/// underscores.
pub fn allowed_name(name: &str) -> bool {
    name == WRAPPER
        || name.strip_prefix("SCCACHE_").is_some_and(|rest| {
            !rest.is_empty()
                && rest.bytes().all(|b| b.is_ascii_uppercase() || b.is_ascii_digit() || b == b'_')
        })
}

/// [`ENV_FILE`]'s text, `{"env": {NAME: value}}`: its variables, or why it is refused (a name,
/// never a value).
pub fn parse(text: &str) -> Result<Vec<(String, String)>, String> {
    let value: serde_json::Value = serde_json::from_str(text).map_err(|_| "not JSON".to_owned())?;
    let serde_json::Value::Object(root) = value else { return Err("not an object".to_owned()) };
    if let Some(key) = root.keys().find(|k| k.as_str() != "env") {
        return Err(format!("unknown key {key:?}"));
    }
    let Some(serde_json::Value::Object(env)) = root.get("env") else {
        return Err("`env` is not an object".to_owned());
    };
    if env.is_empty() || env.len() > MAX_VARS {
        return Err(format!("{} variables", env.len()));
    }
    let mut out = Vec::with_capacity(env.len());
    for (name, value) in env {
        if !allowed_name(name) {
            return Err(format!("{name:?} is not an allowed name"));
        }
        let serde_json::Value::String(value) = value else {
            return Err(format!("{name} is not a string"));
        };
        if value.is_empty() || value.len() > MAX_VALUE || value.chars().any(char::is_control) {
            return Err(format!("{name} is not a short single-line value"));
        }
        out.push((name.clone(), value.clone()));
    }
    out.sort();
    Ok(out)
}

/// The variables to add to an agent's environment: none without `sccache` on its PATH or when
/// `is_set(RUSTC_WRAPPER)`; else each of `vars` that `is_set` does not already name.
pub fn plan(
    vars: &[(String, String)],
    is_set: impl Fn(&str) -> bool,
    sccache_on_path: bool,
) -> Vec<(String, String)> {
    if !sccache_on_path || is_set(WRAPPER) {
        return Vec::new();
    }
    vars.iter().filter(|(name, _)| !is_set(name)).cloned().collect()
}

/// An executable `sccache` in one of `path`'s directories.
pub fn on_path(path: Option<&OsStr>) -> bool {
    let Some(path) = path else { return false };
    std::env::split_paths(path).any(|dir| is_executable(&dir.join("sccache")))
}

#[cfg(unix)]
fn is_executable(file: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(file).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

#[cfg(not(unix))]
fn is_executable(file: &Path) -> bool {
    file.is_file()
}

/// [`ENV_FILE`]'s variables: `Ok(None)` when there is no file; refused unless it is a regular
/// file of this user, small, and valid.
#[cfg(unix)]
fn read(file: &Path) -> Result<Option<Vec<(String, String)>>, String> {
    use std::os::unix::fs::MetadataExt;
    let meta = match std::fs::symlink_metadata(file) {
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(e) => return Err(format!("cannot stat: {e}")),
        Ok(meta) => meta,
    };
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    if !meta.file_type().is_file() || meta.uid() != uid || meta.len() > MAX_FILE {
        return Err("not a small regular file of this user".to_owned());
    }
    let text = std::fs::read_to_string(file).map_err(|e| format!("cannot read: {e}"))?;
    parse(&text).map(Some)
}

/// What [`apply`] did last, so a log line is written when it changes, not at every spawn.
#[cfg(unix)]
static LAST: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

#[cfg(unix)]
fn note(outcome: String) {
    let mut last = LAST.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    if last.as_deref() != Some(outcome.as_str()) {
        tracing::info!("compiler cache: {outcome}");
        *last = Some(outcome);
    }
}

/// Adds the compiler cache's variables to `cmd`, whose full environment is `env` (inherited,
/// then changed: `agent::command`), when [`plan`] says so. Nothing off a Cloud VM.
#[cfg(unix)]
pub fn apply(cmd: &mut tokio::process::Command, env: &[(String, String)]) {
    apply_at(cmd, env, crate::cloud_host::is_cloud_vm(), Path::new(ENV_FILE));
}

/// [`apply`] with whether this is a Cloud VM and the file to read.
#[cfg(unix)]
fn apply_at(cmd: &mut tokio::process::Command, env: &[(String, String)], cloud: bool, file: &Path) {
    if !cloud {
        return;
    }
    let vars = match read(file) {
        Ok(Some(vars)) => vars,
        Ok(None) => return,
        Err(why) => return note(format!("{} refused ({why}); off", file.display())),
    };
    // Set even when empty: an empty RUSTC_WRAPPER is the person turning wrappers off.
    let is_set = |name: &str| env.iter().any(|(k, _)| k == name);
    let path = env.iter().find(|(k, _)| k == "PATH").map(|(_, v)| OsStr::new(v.as_str()));
    let sccache = on_path(path);
    let add = plan(&vars, is_set, sccache);
    if add.is_empty() {
        let why = if !sccache { "no sccache on PATH" } else { "RUSTC_WRAPPER is already set" };
        return note(format!("off for this agent: {why}"));
    }
    let names: Vec<&str> = add.iter().map(|(k, _)| k.as_str()).collect();
    note(format!("on, adding {}", names.join(",")));
    cmd.envs(add);
}

#[cfg(test)]
#[path = "sccache_env_tests.rs"]
mod tests;
