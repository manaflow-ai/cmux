//! `session/new` with `_meta.acpmux.worktree: {"name": NAME, "base"?: REF}`:
//! the session starts in the named git worktree of `cwd`'s repository,
//! made when missing and reused when there (`subsession_worktree.rs`
//! `ensure_worktree`). `acpmux new --worktree` sends it. Only over the
//! local unix socket, like a session env or route: a WebSocket client or
//! peer is held to its folder roots, and the worktree folder is outside
//! them; another machine runs `acpmux new` on this one over ssh. The answer's
//! `_meta.acpmux.worktree` says what was found or made.

use std::path::PathBuf;

use serde_json::{Value, json};

use super::Origin;
use crate::rpc::RpcError;

/// Makes or finds the worktree `meta` asks for and points `cwd` into it;
/// None when it asks for none.
pub(super) async fn ensure(
    origin: Origin,
    meta: Option<&Value>,
    cwd: &mut Option<PathBuf>,
) -> Result<Option<Value>, RpcError> {
    let Some(asked) = meta.and_then(|m| m.get("worktree")).filter(|w| !w.is_null()) else {
        return Ok(None);
    };
    if origin != Origin::Local {
        return Err(RpcError::invalid_params(
            "a worktree is made only over the local unix socket: run acpmux new on that machine",
        )
        .with_data(json!({"reason": "worktree.origin_refused"})));
    }
    let name = asked
        .get("name")
        .and_then(Value::as_str)
        .filter(|n| !n.is_empty())
        .ok_or_else(|| RpcError::invalid_params("worktree.name must be a non-empty string"))?
        .to_owned();
    let base = match asked.get("base") {
        None | Some(Value::Null) => None,
        Some(Value::String(b)) => Some(b.clone()),
        Some(_) => return Err(RpcError::invalid_params("worktree.base must be a string")),
    };
    let folder = match cwd.clone().filter(|c| c.is_absolute()) {
        Some(c) if tokio::fs::metadata(&c).await.is_ok_and(|m| m.is_dir()) => c,
        _ => {
            return Err(RpcError::invalid_params(
                "a worktree needs cwd: an absolute folder of the repository",
            ));
        }
    };
    let ensured = cmux_blocking::spawn_blocking(move || {
        crate::subsession_worktree::ensure_worktree(&folder, &name, base.as_deref())
    })
    .await
    .map_err(|e| RpcError::internal(e.to_string()))?
    .map_err(|e| RpcError::invalid_params(format!("no worktree: {e}")))?;
    let w = &ensured.worktree;
    *cwd = Some(w.cwd.clone());
    Ok(Some(json!({
        "root": w.root,
        "branch": w.branch,
        "base": w.base,
        "cwd": w.cwd,
        "reused": ensured.reused,
    })))
}
