//! The worktree cleanup methods (`hub/worktree_care.rs`):
//! `_acpmux/worktree/report {staleOnly?}` (a pass that only decides and
//! measures, and the last pass's report), `_acpmux/worktree/clean {only?,
//! staleOnly?}` (the machine view's Clean up now: a pass that acts; with
//! `staleOnly`, Session Info's Storage section, which frees only clean,
//! finished worktrees nothing live uses) and
//! `_acpmux/worktree/restore {key, path?}` (a reclaimed worktree back, by
//! its folder, branch or archive id).
//!
//! Only this machine's clients get them, like the process methods: they
//! read and remove folders on this machine.

use super::{Conn, Origin, str_param};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::Arc;

/// The reply to a worktree method, or None for any other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(
        m,
        method::MUX_WORKTREE_REPORT | method::MUX_WORKTREE_CLEAN | method::MUX_WORKTREE_RESTORE
    ) {
        return None;
    }
    if conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found(&format!(
            "{m} (not served to a remote WebSocket connection or a peer)"
        ))));
    }
    if conn.origin == Origin::LocalApp
        && let Err(error) = pane_scope(m, params)
    {
        return Some(Err(error));
    }
    Some(handle(hub, m, params).await)
}

/// The app's agent pane (`Origin::LocalApp`) frees only what Session
/// Info's Storage offers: `clean` must say `staleOnly: true` and name the
/// folders, so a page that went wrong cannot run an unrestricted pass, and
/// it never restores. The Unix socket (the CLI, the app's machine view)
/// keeps every form.
fn pane_scope(m: &str, params: &Value) -> Result<(), RpcError> {
    match m {
        method::MUX_WORKTREE_REPORT => Ok(()),
        method::MUX_WORKTREE_CLEAN => {
            let named = params
                .get("only")
                .and_then(Value::as_array)
                .is_some_and(|paths| !paths.is_empty());
            if stale_only(params) && named {
                Ok(())
            } else {
                Err(RpcError::invalid_params(
                    "the agent pane frees only named stale worktrees (staleOnly: true, only: [...])",
                ))
            }
        }
        _ => Err(RpcError::method_not_found(&format!("{m} (not served to the agent pane)"))),
    }
}

/// `_acpmux/retention` (`hub/retention.rs`), to this machine's clients only: it rewrites and
/// archives files on this machine. None for any other method.
pub(super) async fn retention(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if m != method::MUX_RETENTION {
        return None;
    }
    if conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found(&format!(
            "{m} (not served to a remote WebSocket connection or a peer)"
        ))));
    }
    let days = match params.get("olderThanDays") {
        None | Some(Value::Null) => None,
        Some(v) => match v.as_u64().and_then(|d| u32::try_from(d).ok()) {
            Some(days) => Some(days),
            None => {
                return Some(Err(RpcError::invalid_params(
                    "olderThanDays must be a number of days",
                )));
            }
        },
    };
    let archive = str_param(params, "archive").map(PathBuf::from);
    if archive.as_ref().is_some_and(|a| !a.is_absolute()) {
        return Some(Err(RpcError::invalid_params("archive must be an absolute folder")));
    }
    let req = crate::hub::RetentionRequest {
        dry_run: params.get("dryRun").and_then(Value::as_bool).unwrap_or(false),
        archive,
        older_than_days: days,
        only: str_param(params, "only").map(str::to_owned),
    };
    Some(hub.retention_pass(req).await)
}

async fn handle(hub: &Arc<Hub>, m: &str, params: &Value) -> Result<Value, RpcError> {
    match m {
        method::MUX_WORKTREE_REPORT => {
            let report = hub.care_pass(false, Vec::new(), stale_only(params)).await?;
            Ok(json!({"report": report, "last": hub.care_last_report()}))
        }
        method::MUX_WORKTREE_CLEAN => {
            let only = match params.get("only") {
                None | Some(Value::Null) => Vec::new(),
                Some(Value::Array(paths)) => paths
                    .iter()
                    .map(|p| p.as_str().map(PathBuf::from))
                    .collect::<Option<Vec<_>>>()
                    .ok_or_else(|| RpcError::invalid_params("only must be a list of folders"))?,
                Some(_) => return Err(RpcError::invalid_params("only must be a list of folders")),
            };
            hub.care_pass(true, only, stale_only(params)).await
        }
        _ => {
            let key = str_param(params, "key")
                .ok_or_else(|| RpcError::invalid_params("key is required"))?;
            let path = str_param(params, "path").map(PathBuf::from);
            hub.care_restore(key.to_string(), path).await
        }
    }
}

/// `staleOnly`: act on and measure only stale worktrees (`policy::stale`).
fn stale_only(params: &Value) -> bool {
    params.get("staleOnly").and_then(Value::as_bool).unwrap_or(false)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_pane_frees_only_named_stale_worktrees() {
        let clean = method::MUX_WORKTREE_CLEAN;
        assert!(pane_scope(clean, &json!({"only": ["/w/a"], "staleOnly": true})).is_ok());
        assert!(pane_scope(clean, &json!({})).is_err(), "an unrestricted pass");
        assert!(pane_scope(clean, &json!({"staleOnly": true})).is_err(), "every stale worktree");
        assert!(pane_scope(clean, &json!({"only": [], "staleOnly": true})).is_err());
        assert!(pane_scope(clean, &json!({"only": ["/w/a"]})).is_err(), "not stale-only");
        assert!(pane_scope(clean, &json!({"only": ["/w/a"], "staleOnly": false})).is_err());
        assert!(pane_scope(method::MUX_WORKTREE_REPORT, &json!({})).is_ok());
        assert!(pane_scope(method::MUX_WORKTREE_RESTORE, &json!({"key": "x"})).is_err());
    }
}
