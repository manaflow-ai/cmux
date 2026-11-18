//! `_acpmux/pr_feedback {sessionId, pr, repo?, kind}`: a pull request's own failing checks
//! (`kind: checks`) or its unresolved review threads (`kind: comments`) as a message for the
//! chat's agent (`crate::pr_feedback`). The answer's `draft` is for the composer; nothing is
//! sent. It reads GitHub with this machine's `gh`, in the chat's folder, so a peer's chat is
//! answered on its own machine (`peer_forward.rs`); a Web connection is refused in
//! `remote_guard.rs`.

use super::str_param;
use crate::hub::Hub;
use crate::pr_feedback::{self, Kind};
use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::sync::Arc;

/// The reply to `pr_feedback`, or None for any other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if m != method::MUX_PR_FEEDBACK {
        return None;
    }
    Some(handle(hub, params).await)
}

async fn handle(hub: &Arc<Hub>, params: &Value) -> Result<Value, RpcError> {
    let key = str_param(params, "sessionId")
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let session = hub.resolve(key)?;
    let pr = str_param(params, "pr")
        .ok_or_else(|| {
            RpcError::invalid_params("pr is required: a number, #number or a pull request URL")
        })?
        .to_owned();
    let repo = str_param(params, "repo").map(str::to_owned);
    let kind = str_param(params, "kind")
        .and_then(Kind::parse)
        .ok_or_else(|| RpcError::invalid_params("kind must be checks or comments"))?;
    let cwd = session.meta().cwd.clone();
    // gh runs and waits here: off the runtime, bounded by the read's own deadline.
    tokio::task::spawn_blocking(move || {
        let ctx = pr_feedback::ctx()?;
        pr_feedback::fetch(&ctx, Some(&cwd), &pr, repo.as_deref(), kind)
    })
    .await
    .map_err(|e| RpcError::internal(format!("pr feedback stopped: {e}")))?
    .map_err(|e| RpcError::new(-32000, e))
}
