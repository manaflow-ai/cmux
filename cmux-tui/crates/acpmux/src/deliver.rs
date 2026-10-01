//! Prompts that another program hands to a session, for `cmux agent
//! message`, and the session list for `cmux agent list`. The caller's
//! message id is the prompt id, so the daemon runs a message once even when
//! the caller sends it again after a crash or a daemon restart (the id is
//! also looked up in the session's log).

use crate::cli::output::{PromptId, queue_prompt};
use crate::client::Client;
use crate::rpc::method;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::sync::Arc;

/// A running daemon, or an error: delivering a message never starts one.
pub async fn connect() -> Result<Arc<Client>> {
    crate::daemon::connect(false).await
}

/// The id and name of the session `key` names (an id, a name, or a unique
/// prefix of either).
pub async fn resolve_session(client: &Client, key: &str) -> Result<(String, String)> {
    let detail = client.request(method::MUX_INFO, json!({"sessionId": key})).await?;
    let id = detail
        .get("sessionId")
        .and_then(Value::as_str)
        .ok_or_else(|| anyhow!("acpmux returned no session id for {key:?}"))?;
    let name = detail.get("name").and_then(Value::as_str).unwrap_or(id);
    Ok((id.to_owned(), name.to_owned()))
}

/// The running daemon's sessions (`_acpmux/sessions` summaries).
pub async fn sessions(client: &Client) -> Result<Vec<Value>> {
    let listed = client.request(method::MUX_SESSIONS, json!({})).await?;
    Ok(listed.get("sessions").and_then(Value::as_array).cloned().unwrap_or_default())
}

/// Queue `text` as a prompt of `session` under `prompt_id` and return once
/// the daemon accepted it: started now, or queued behind a running turn.
pub async fn deliver(
    client: Arc<Client>,
    session: &str,
    text: &str,
    prompt_id: &str,
) -> Result<Value> {
    let prompt = PromptId { id: prompt_id.to_owned(), resend: true };
    queue_prompt(client, session, text, false, &prompt).await
}
