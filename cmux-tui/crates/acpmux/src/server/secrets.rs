//! The secret methods (`hub/secrets.rs`), routed before every other method
//! (`chats.rs`), so before peer forwarding: a secret never travels to another
//! daemon, and only a session of this one asks. Each method checks its own
//! caller: the unix socket asks and spends, the person answers.

use super::{Conn, Origin, str_param};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use serde_json::{Value, json};
use std::sync::Arc;
use zeroize::Zeroizing;

/// The reply to a secret method, or None for any other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(m, method::MUX_SECRET_REQUEST | method::MUX_SECRET_SUBMIT | method::MUX_SECRET_RUN)
    {
        return None;
    }
    Some(handle(hub, conn, m, params).await)
}

async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    // `name` is the secret's name here, never a session key.
    let key = str_param(params, "sessionId")
        .ok_or_else(|| RpcError::invalid_params("sessionId is required"))?;
    let session = hub.resolve(key)?;
    match m {
        method::MUX_SECRET_REQUEST => {
            refuse_unless_unix(conn, "asking for a secret")?;
            let name = str_param(params, "name").unwrap_or_default();
            let reason = str_param(params, "reason").unwrap_or_default();
            hub.request_secret(&session, name, reason).await
        }
        method::MUX_SECRET_SUBMIT => {
            // The card is the person's: never the agent that asked.
            if !conn.is_person() {
                return Err(crate::hub::person::person_required("filling a secret card"));
            }
            let id = str_param(params, "secretId")
                .ok_or_else(|| RpcError::invalid_params("secretId is required"))?;
            let value = str_param(params, "value").map(|v| Zeroizing::new(v.to_owned()));
            hub.submit_secret(&session, id, value)?;
            Ok(json!({}))
        }
        _ => {
            refuse_unless_unix(conn, "spending a secretRef")?;
            let secret_ref = str_param(params, "secretRef")
                .ok_or_else(|| RpcError::invalid_params("secretRef is required"))?;
            let env = str_param(params, "env").unwrap_or_default();
            let argv: Vec<String> = params
                .get("argv")
                .and_then(Value::as_array)
                .map(|a| a.iter().filter_map(Value::as_str).map(str::to_owned).collect())
                .unwrap_or_default();
            hub.run_with_secret(&session, secret_ref, env, &argv).await
        }
    }
}

/// The agent's own tools reach the daemon over the unix socket only.
fn refuse_unless_unix(conn: &Conn, what: &str) -> Result<(), RpcError> {
    if conn.origin == Origin::Local {
        return Ok(());
    }
    Err(RpcError::invalid_params(format!("{what} is accepted only over the local unix socket")))
}
