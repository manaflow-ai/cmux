//! The worktree cleanup methods (`hub/worktree_care.rs`):
//! `_acpmux/worktree/report {}` (a pass that only decides and measures,
//! and the last pass's report), `_acpmux/worktree/clean {only?}` (the
//! machine view's Clean up now: a pass that acts) and
//! `_acpmux/worktree/restore {key, path?}` (a reclaimed worktree back, by
//! its folder, branch or archive id).
//!
//! Only this machine's clients get them, like the process methods: they
//! read and remove folders on this machine.

use super::{Conn, str_param};
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
    Some(handle(hub, m, params).await)
}

/// `_acpmux/retention` (`hub/retention.rs`), to this machine's clients only: it rewrites and
/// archives files on this machine. None for any other method.
pub(super) async fn retention(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if m != method::MUX_RETENTION
        && m != method::MUX_HISTORY_DELETE
        && m != method::MUX_HISTORY_OFFLOAD
        && m != method::MUX_LIFECYCLE
        && m != method::MUX_TRANSCRIPT_OFFLOAD
    {
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
    let dry_run = params.get("dryRun").and_then(Value::as_bool).unwrap_or(false);
    if m == method::MUX_LIFECYCLE {
        if let Some(id) = str_param(params, "restore") {
            return Some(match hub.resolve(id) {
                Ok(session) => hub.lifecycle_restore(session).await,
                Err(e) => Err(e),
            });
        }
        return Some(hub.lifecycle_now(crate::hub::LifecycleRequest { dry_run }).await);
    }
    if m == method::MUX_HISTORY_OFFLOAD {
        let req = crate::hub::HistoryOffloadRequest { dry_run, older_than_days: days };
        return Some(hub.history_offload_now(req).await);
    }
    if m == method::MUX_HISTORY_DELETE {
        // Recently deleted, and its undo (`hub/history_delete.rs`).
        if params.get("deleted").and_then(Value::as_bool).unwrap_or(false) {
            return Some(Ok(hub.history_deleted()));
        }
        if let Some(id) = str_param(params, "restore") {
            let restored = hub.resolve(id).and_then(|session| {
                let restored = hub.history_restore(&session)?;
                Ok(json!({"sessionId": session.id, "restored": restored}))
            });
            return Some(restored);
        }
        let export = str_param(params, "export").map(PathBuf::from);
        if export.as_ref().is_some_and(|a| !a.is_absolute()) {
            return Some(Err(RpcError::invalid_params("export must be an absolute folder")));
        }
        let req = crate::hub::HistoryDeleteRequest {
            dry_run,
            older_than_days: days,
            export,
            ..Default::default()
        };
        return Some(hub.history_delete_now(req).await);
    }
    if m == method::MUX_TRANSCRIPT_OFFLOAD {
        let req = crate::hub::TranscriptOffloadRequest {
            dry_run,
            older_than_days: days,
            restore_all: params.get("restoreAll").and_then(Value::as_bool).unwrap_or(false),
        };
        return Some(hub.transcript_offload_now(req).await);
    }
    let archive = str_param(params, "archive").map(PathBuf::from);
    if archive.as_ref().is_some_and(|a| !a.is_absolute()) {
        return Some(Err(RpcError::invalid_params("archive must be an absolute folder")));
    }
    let req = crate::hub::RetentionRequest {
        dry_run,
        archive,
        older_than_days: days,
        only: str_param(params, "only").map(str::to_owned),
        unread_only: params.get("unreadOnly").and_then(Value::as_bool).unwrap_or(false),
    };
    Some(hub.retention_pass(req).await)
}

async fn handle(hub: &Arc<Hub>, m: &str, params: &Value) -> Result<Value, RpcError> {
    match m {
        method::MUX_WORKTREE_REPORT => {
            let report = hub.care_pass(false, Vec::new()).await?;
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
            hub.care_pass(true, only).await
        }
        _ => {
            let key = str_param(params, "key")
                .ok_or_else(|| RpcError::invalid_params("key is required"))?;
            let path = str_param(params, "path").map(PathBuf::from);
            hub.care_restore(key.to_string(), path).await
        }
    }
}
