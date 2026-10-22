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
