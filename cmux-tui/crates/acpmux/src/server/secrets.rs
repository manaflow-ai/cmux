//! The secret methods (`hub/secrets.rs`) and the sudo card's ask (`hub/elevation.rs`), routed before every other method
//! (`chats.rs`), so before peer forwarding: a secret never travels to another
//! daemon, and only a session of this one asks. Each method checks its own
//! caller: the unix socket asks and spends, the person answers.
//!
//! A chat that lives on a peer is refused here with the way its machine does
//! get a value: the person's own delivery from the Mac's Keychain to that
//! machine's file (`cmux cloud deliver-secrets`, which writes it over ssh
//! through the same receiver as a Cloud machine's). A `secretRef` stays with
//! the daemon that issued it; no value or ref crosses the peer link.

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
    if !matches!(
        m,
        method::MUX_SECRET_REQUEST
            | method::MUX_SECRET_SUBMIT
            | method::MUX_SECRET_RUN
            | method::MUX_ELEVATION_REQUEST
    ) {
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
    let session = match hub.resolve(key) {
        Ok(session) => session,
        Err(e) => {
            return Err(match hub.resolve_remote(key) {
                Some((peer, _, _)) if m == method::MUX_ELEVATION_REQUEST => {
                    RpcError::invalid_params(format!(
                        "this chat runs on {}: a password never travels to another daemon, so \
                         ask from a chat on the machine whose acpmux runs it",
                        peer.name
                    ))
                }
                Some((peer, _, _)) => on_peer(&peer.name),
                None => e,
            });
        }
    };
    match m {
        method::MUX_SECRET_REQUEST => {
            refuse_unless_unix(conn, "asking for a secret")?;
            let name = str_param(params, "name").unwrap_or_default();
            let reason = str_param(params, "reason").unwrap_or_default();
            hub.request_secret(&session, name, reason).await
        }
        // A sudo card (`hub/elevation.rs`): the agent asks over the unix socket, and the person
        // answers it with `secret_submit` like any private card.
        method::MUX_ELEVATION_REQUEST => {
            refuse_unless_unix(conn, "asking to run a command as root")?;
            hub.request_elevation(&session, params).await
        }
        method::MUX_SECRET_SUBMIT => {
            let id = str_param(params, "secretId")
                .ok_or_else(|| RpcError::invalid_params("secretId is required"))?;
            let value = str_param(params, "value").map(|v| Zeroizing::new(v.to_owned()));
            // The card is the person's: never the agent that asked. A phone answers a sudo card
            // with its approver signature (`Hub::card_answer_signed`).
            // The value is checked first: a refused one must not spend the phone's signature.
            hub.check_card_value(&session, id, value.as_deref().map(String::as_str))?;
            // A card this daemon no longer holds answers no one: the refusal closes it on every
            // client (`Hub::submit_secret`), whoever sent it, and grants nothing.
            if !hub.card_open(&session, id) {
                hub.submit_secret(&session, id, value)?;
                return Ok(json!({}));
            }
            if !conn.is_person() && !hub.card_answer_signed(&session, id, value.is_some(), params) {
                return Err(crate::hub::person::person_required("filling a secret card"));
            }
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

/// A secret method for a chat on peer `peer` (this daemon's name for it): never forwarded.
fn on_peer(peer: &str) -> RpcError {
    RpcError::invalid_params(format!(
        "this chat runs on {peer}, and a secret never travels to another daemon: store it on this \
         Mac (cmux cloud secret set NAME) and deliver it to that machine (cmux cloud \
         deliver-secrets --target machine:{peer} --names NAME); its shells then read it from \
         ~/.config/cmux/machine-secrets.env"
    ))
}

/// The agent's own tools reach the daemon over the unix socket only.
fn refuse_unless_unix(conn: &Conn, what: &str) -> Result<(), RpcError> {
    if conn.origin == Origin::Local {
        return Ok(());
    }
    Err(RpcError::invalid_params(format!("{what} is accepted only over the local unix socket")))
}
