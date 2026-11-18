//! `_acpmux/rewind` and `_acpmux/rewind_undo` (`hub/turn_rewind.rs`): back to before a turn of a
//! chat on this machine, its conversation, its files or both, and the files back again.
//!
//! Only this machine's clients get them, like the worktree methods: they rewrite files in the
//! chat's folder on this machine. The conversation goes back through the same fork before a prompt
//! as Edit and resend (`session/fork` with `beforePromptId`, `hub/fork_before.rs`), with its
//! admission and checks.

use super::{Conn, str_param};
use crate::hub::Hub;
use crate::hub::turn_rewind::{Fork, PromptKey, RewindRequest};
use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::sync::Arc;

/// The reply to a rewind method, or None for any other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(m, method::MUX_REWIND | method::MUX_REWIND_UNDO) {
        return None;
    }
    if conn.origin.web_class() {
        return Some(Err(RpcError::method_not_found(&format!(
            "{m} (not served to a remote WebSocket connection or a peer)"
        ))));
    }
    Some(Box::pin(handle(hub, conn, m, params)).await)
}

async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    let key = str_param(params, "sessionId")
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let session = hub.resolve(key)?;
    if m == method::MUX_REWIND_UNDO {
        let safety = str_param(params, "safetyCheckpointId")
            .ok_or_else(|| RpcError::invalid_params("safetyCheckpointId is required"))?;
        return hub.rewind_undo(&session, safety).await;
    }
    let request = parse(params)?;
    let who = super::requests::who(conn);
    // Each rewind is a fork of its own: a second click makes a second rewound chat.
    let request_id = format!("rewind-{}", uuid::Uuid::now_v7());
    let fork: Fork<'_> = Box::new(move |source, prompt| {
        Box::pin(async move {
            let ask = super::requests::ask(conn, params, &who);
            let (new, _) = Box::pin(hub.fork_before(&source, &prompt, &request_id, ask)).await?;
            Ok(new)
        })
    });
    hub.rewind(&session, request, fork).await
}

/// `_acpmux/rewind`'s params: the prompt by `promptId` or by its `seq`, what to rewind, and
/// whether this is only a dry run.
pub(crate) fn parse(params: &Value) -> Result<RewindRequest, RpcError> {
    let prompt = match (str_param(params, "promptId"), params.get("seq").and_then(Value::as_u64)) {
        (Some(id), _) => PromptKey::Id(id.to_owned()),
        (None, Some(seq)) => PromptKey::Seq(seq),
        (None, None) => return Err(RpcError::invalid_params("promptId or seq is required")),
    };
    let flag =
        |name: &str, default: bool| params.get(name).and_then(Value::as_bool).unwrap_or(default);
    Ok(RewindRequest {
        prompt,
        conversation: flag("conversation", true),
        files: flag("files", false),
        dry_run: flag("dryRun", false),
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn conversation_only_is_the_default() {
        let request = parse(&json!({"sessionId": "s", "seq": 7})).unwrap();
        assert!(matches!(request.prompt, PromptKey::Seq(7)));
        assert!(request.conversation && !request.files && !request.dry_run);
    }

    #[test]
    fn a_prompt_id_wins_over_a_seq_and_one_is_required() {
        let request =
            parse(&json!({"promptId": "p", "seq": 7, "files": true, "dryRun": true})).unwrap();
        assert!(matches!(request.prompt, PromptKey::Id(ref id) if id == "p"));
        assert!(request.files && request.dry_run);
        assert!(parse(&json!({"sessionId": "s"})).is_err());
    }
}
