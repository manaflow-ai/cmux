//! Part of `Hub`; see `hub/mod.rs`. A chat's Sources: folders it sees beside its own folder.
//!
//! `session/new` takes them as ACP's `additionalDirectories` (the field ACP agents advertise
//! with `sessionCapabilities.additionalDirectories`). They are kept in the chat's meta
//! (`SessionMeta::additional_directories`) and given to every start of its harness: Claude Code
//! as `--add-dir DIR` (`claude_args`), an ACP harness in its `session/new` and `session/load`
//! (`spawn.rs` `acp_params`). A chat needs no project to have them: one started with nothing runs in
//! its empty agent-home folder (Leo, 2026-11-03: "and you can also just start with nothing").
//!
//! A folder is an absolute path to a directory that exists, kept canonical (symlinks resolved,
//! no `..`), each once, and never the chat's own folder. A WebSocket caller's folders must also
//! sit inside the web roots (`server/remote_guard.rs`), which checks them before this does.

use super::*;

use std::path::{Path, PathBuf};

/// The request field, as ACP names it.
pub(crate) const FIELD: &str = "additionalDirectories";

/// Most folders one chat takes: a list longer than this is a mistake, not a choice.
pub(crate) const MAX_DIRS: usize = 64;

fn refused(why: &str) -> RpcError {
    RpcError::invalid_params(format!("{FIELD}: {why}"))
        .with_data(json!({"reason": "additionalDirectories.invalid"}))
}

/// The folders `params` asks for (`additionalDirectories`), checked and canonical, each once.
/// Absent or null: none.
pub(crate) async fn requested(params: &Value) -> Result<Vec<PathBuf>, RpcError> {
    let Some(list) = params.get(FIELD).filter(|v| !v.is_null()) else { return Ok(Vec::new()) };
    let list = list.as_array().ok_or_else(|| refused("must be a list of absolute folder paths"))?;
    if list.len() > MAX_DIRS {
        return Err(refused(&format!("at most {MAX_DIRS} folders")));
    }
    let mut out: Vec<PathBuf> = Vec::with_capacity(list.len());
    for item in list {
        let path = item.as_str().ok_or_else(|| refused("each entry must be a path string"))?;
        if !Path::new(path).is_absolute() {
            return Err(refused(&format!("{path:?} is not an absolute path")));
        }
        let canonical = tokio::fs::canonicalize(path)
            .await
            .map_err(|_| refused(&format!("{path:?} does not exist")))?;
        let is_dir = tokio::fs::metadata(&canonical).await.is_ok_and(|m| m.is_dir());
        if !is_dir {
            return Err(refused(&format!("{path:?} is not a folder")));
        }
        if !out.contains(&canonical) {
            out.push(canonical);
        }
    }
    Ok(out)
}

/// The compare-and-set token comes from the persisted session info. Validate its shape without
/// requiring paths to still exist, so a deleted source folder can still be removed.
fn expected_directories(value: &Value, cwd: &Path) -> Result<Vec<PathBuf>, RpcError> {
    let list =
        value.as_array().ok_or_else(|| refused("must be a list of absolute folder paths"))?;
    if list.len() > MAX_DIRS {
        return Err(refused(&format!("at most {MAX_DIRS} folders")));
    }
    let own = std::fs::canonicalize(cwd).unwrap_or_else(|_| cwd.to_path_buf());
    let mut out = Vec::with_capacity(list.len());
    for item in list {
        let path = item.as_str().ok_or_else(|| refused("each entry must be a path string"))?;
        let path = PathBuf::from(path);
        if !path.is_absolute() {
            return Err(refused("expected folders must be absolute paths"));
        }
        if path != own && path != cwd && !out.contains(&path) {
            out.push(path);
        }
    }
    Ok(out)
}

/// `dirs` without the chat's own folder `cwd` (compared canonical when it can be read).
pub(crate) fn without_cwd(dirs: Vec<PathBuf>, cwd: &Path) -> Vec<PathBuf> {
    if dirs.is_empty() {
        return dirs;
    }
    let own = std::fs::canonicalize(cwd).unwrap_or_else(|_| cwd.to_path_buf());
    dirs.into_iter().filter(|d| d != &own && d != cwd).collect()
}

/// Claude Code's words for the chat's folders: `--add-dir DIR` for each.
pub(crate) fn claude_args(meta: &SessionMeta) -> Vec<String> {
    meta.additional_directories
        .iter()
        .flat_map(|d| ["--add-dir".to_owned(), d.to_string_lossy().into_owned()])
        .collect()
}

/// The `additionalDirectories` an ACP `session/new` or `session/load` carries, None for none
/// (the field is left out, as before).
pub(crate) fn acp_value(meta: &SessionMeta) -> Option<Value> {
    (!meta.additional_directories.is_empty()).then(|| {
        Value::Array(
            meta.additional_directories
                .iter()
                .map(|d| Value::String(d.to_string_lossy().into_owned()))
                .collect(),
        )
    })
}

impl Hub {
    /// `_acpmux/set_directories`: the chat's folders become `additionalDirectories` (an empty
    /// list clears them), and its agent restarts on them, resuming the same conversation, as a
    /// tool switch does (`tools.rs` `set_tools`): now between turns, at the end of a running
    /// turn, or at the next start of an agent that is not running. Watchers hear it as a `mux`
    /// record of kind `directories`.
    pub async fn set_directories(
        self: &Arc<Self>,
        session: &Arc<Session>,
        params: &Value,
    ) -> Result<Value, RpcError> {
        if params.get(FIELD).is_none_or(Value::is_null) {
            return Err(refused("is required (an empty list clears them)"));
        }
        let dirs = without_cwd(requested(params).await?, &session.meta().cwd);
        let expected = match params.get("expectedAdditionalDirectories") {
            Some(value) => Some(expected_directories(value, &session.meta().cwd)?),
            None => None,
        };
        let changed = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            if expected.as_ref().is_some_and(|expected| expected != &m.additional_directories) {
                return Err(
                    RpcError::invalid_params("additionalDirectories changed")
                        .with_data(json!({"reason": "additionalDirectories.changed", FIELD: m.additional_directories})),
                );
            }
            let changed = m.additional_directories != dirs;
            m.additional_directories = dirs.clone();
            changed
        };
        let applied = if !changed {
            "unchanged"
        } else {
            self.append(session, "mux", "directories", json!({FIELD: dirs}));
            self.save_meta_answered(session)?;
            self.restart_on_change(session).await?
        };
        Ok(json!({"sessionId": session.id, FIELD: dirs, "applied": applied}))
    }

    /// Restarts the chat's agent on what changed for its start (its folders, its chat secrets,
    /// `chat_secrets.rs`), resuming the same conversation: `now` between turns, `afterTurn` at
    /// the end of a running turn, `nextStart` for an agent that is not running.
    pub(crate) async fn restart_on_change(
        self: &Arc<Self>,
        session: &Arc<Session>,
    ) -> Result<&'static str, RpcError> {
        if session.child.lock().await.is_none() {
            return Ok("nextStart");
        }
        // As `restart_harnesses`: a turn that ended before it saw the flag restarts nothing,
        // so the lock is tried again once the flag is set.
        let mut turn = session.turn_lock.try_lock().ok();
        if turn.is_none() {
            session.route_switch.store(true, Ordering::SeqCst);
            turn = session
                .turn_lock
                .try_lock()
                .ok()
                .filter(|_| session.route_switch.load(Ordering::SeqCst));
        }
        match turn {
            Some(_turn) => {
                self.restart_on_route(session).await?;
                Ok("now")
            }
            None => Ok("afterTurn"),
        }
    }
}

#[cfg(test)]
#[path = "additional_dirs_tests.rs"]
mod tests;
