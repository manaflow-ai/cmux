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

/// The cmux setting whose folders every new chat gets on top of its Sources.
pub(crate) const SETTING: &str = "agents.additionalDirectories";

/// The folders `agents.additionalDirectories` names in `doc`, as [`requested`] keeps them:
/// absolute or `~/` paths to folders that exist, canonical, each once. An entry that is none of
/// these is skipped with a warning (a folder removed since must not stop every chat).
pub(crate) fn from_settings_doc(doc: &Value, home: Option<&Path>) -> Vec<PathBuf> {
    let Some(list) = crate::user_settings::value(doc, SETTING) else { return Vec::new() };
    let mut out: Vec<PathBuf> = Vec::new();
    for item in list.as_array().into_iter().flatten() {
        let Some(raw) = item.as_str().map(str::trim).filter(|s| !s.is_empty()) else { continue };
        let path = match (raw.strip_prefix("~/"), raw == "~", home) {
            (Some(rest), _, Some(home)) => home.join(rest),
            (None, true, Some(home)) => home.to_path_buf(),
            _ => PathBuf::from(raw),
        };
        let kept = path
            .is_absolute()
            .then(|| std::fs::canonicalize(&path).ok())
            .flatten()
            .filter(|c| c.is_dir());
        match kept {
            Some(c) if out.len() < MAX_DIRS => {
                if !out.contains(&c) {
                    out.push(c);
                }
            }
            _ => tracing::warn!(folder = raw, "{SETTING}: skipped a folder that is not there"),
        }
    }
    out
}

/// A new chat's folders: its own (`asked`, from `session/new`), then the setting's, each once.
/// A remote-origin chat gets only its own: the setting is this person's, for their own chats.
pub(crate) fn with_settings(asked: Vec<PathBuf>, remote: bool) -> Vec<PathBuf> {
    if remote {
        return asked;
    }
    let crate::user_settings::Settings::Parsed(doc) = crate::user_settings::read() else {
        return asked;
    };
    merged(asked, from_settings_doc(&doc, dirs::home_dir().as_deref()))
}

fn merged(mut asked: Vec<PathBuf>, extra: Vec<PathBuf>) -> Vec<PathBuf> {
    for dir in extra {
        if asked.len() >= MAX_DIRS {
            break;
        }
        if !asked.contains(&dir) {
            asked.push(dir);
        }
    }
    asked
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
        let changed = {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            let changed = m.additional_directories != dirs;
            m.additional_directories = dirs.clone();
            changed
        };
        let applied = if !changed {
            "unchanged"
        } else {
            self.append(session, "mux", "directories", json!({FIELD: dirs}));
            self.save_meta_answered(session)?;
            if session.child.lock().await.is_none() {
                "nextStart"
            } else {
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
                        "now"
                    }
                    None => "afterTurn",
                }
            }
        };
        Ok(json!({"sessionId": session.id, FIELD: dirs, "applied": applied}))
    }
}

#[cfg(test)]
#[path = "additional_dirs_tests.rs"]
mod tests;
