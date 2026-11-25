//! `_acpmux/mail/*` durable inter-session mailbox RPCs.
//!
//! Mailbox identities are server-derived. A caller must present the receipt it
//! received for the attached session, including this daemon generation; bare
//! names and caller metadata never establish ownership. Web/Peer bearer paths
//! stay denied until a separately authorized relay exists.

use super::*;
use crate::mailbox::{MailboxError, SendInput};
use crate::session_identity::{LOCAL_HOST_ID, SessionReceipt};
use serde_json::Value;
use std::collections::BTreeMap;

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    method: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    require_local_origin(conn.origin)?;
    match method {
        crate::rpc::method::MUX_MAIL_SEND
            if params.get("target").is_some_and(|target| !target.is_null()) =>
        {
            if params.get("recipient").is_some_and(|recipient| !recipient.is_null()) {
                return Err(RpcError::invalid_params(
                    "mailbox send accepts either recipient or target, not both",
                ));
            }
            let id = required_string(params, "id")?;
            let (sender_id, sender_receipt) = identity_params_or_bound(conn, params, "sender")?;
            let sender_bound =
                conn.mailbox_receipt(&sender_id).ok_or_else(|| detached("deliver", &sender_id))?;
            let sender = validate_binding("sender", &sender_id, &sender_receipt, &sender_bound)?;
            let target = required_string(params, "target")?;
            validate_report_recipient(&target)?;
            let body = params
                .get("body")
                .and_then(Value::as_str)
                .ok_or_else(|| RpcError::invalid_params("body is required"))?;
            let metadata = parse_metadata(params)?;
            let result = hub
                .mailbox()
                .deliver_quiet(SendInput {
                    id,
                    sender,
                    recipient: target,
                    body: body.to_owned(),
                    metadata,
                })
                .map_err(map_error)?;
            Ok(json!({
                "message": result.message,
                "delivery": result.receipt,
                "created": matches!(result.outcome, crate::mailbox::SendOutcome::Created),
                "duplicate": matches!(result.outcome, crate::mailbox::SendOutcome::Duplicate),
                "woke": false,
            }))
        }
        crate::rpc::method::MUX_MAIL_SEND => {
            let id = required_string(params, "id")?;
            let (sender_id, sender_receipt) = identity_params(params, "sender")?;
            let sender_bound =
                conn.mailbox_receipt(&sender_id).ok_or_else(|| detached("send", &sender_id))?;
            let sender = validate_binding("sender", &sender_id, &sender_receipt, &sender_bound)?;
            let (recipient_id, recipient_receipt) = identity_params(params, "recipient")?;
            let recipient_bound = current_identity(hub, &recipient_id)?;
            let recipient =
                validate_binding("recipient", &recipient_id, &recipient_receipt, &recipient_bound)?;
            let body = params
                .get("body")
                .and_then(Value::as_str)
                .ok_or_else(|| RpcError::invalid_params("body is required"))?;
            let metadata = parse_metadata(params)?;
            let result = hub
                .mailbox()
                .send(SendInput { id, sender, recipient, body: body.to_owned(), metadata })
                .map_err(map_error)?;
            Ok(
                json!({"message": result.message, "delivery": result.receipt, "created": matches!(result.outcome, crate::mailbox::SendOutcome::Created), "duplicate": matches!(result.outcome, crate::mailbox::SendOutcome::Duplicate)}),
            )
        }
        crate::rpc::method::MUX_MAIL_READ | crate::rpc::method::MUX_MAIL_WAIT => {
            // The app reads the human reports alias. It is local-only and has
            // no session receipt because it is not an agent mailbox.
            let recipient = if let Some(report_recipient) = report_recipient(params) {
                validate_report_recipient(report_recipient)?;
                report_recipient.to_owned()
            } else {
                let (recipient_id, recipient_receipt) = identity_params(params, "recipient")?;
                let bound = conn.mailbox_receipt(&recipient_id).ok_or_else(|| {
                    detached(
                        if method == crate::rpc::method::MUX_MAIL_WAIT { "wait" } else { "read" },
                        &recipient_id,
                    )
                })?;
                validate_binding("recipient", &recipient_id, &recipient_receipt, &bound)?
            };
            let after = params.get("after").and_then(Value::as_u64).unwrap_or(0);
            let limit = params.get("limit").and_then(Value::as_u64).unwrap_or(50) as usize;
            let page = if method == crate::rpc::method::MUX_MAIL_WAIT {
                let timeout_ms = params.get("timeoutMs").and_then(Value::as_u64).unwrap_or(10_000);
                hub.mailbox().wait(&recipient, after, limit, timeout_ms).await.map_err(map_error)?
            } else {
                hub.mailbox().page(&recipient, after, limit).map_err(map_error)?
            };
            Ok(
                json!({"cursor": page.cursor, "messages": page.rows.into_iter().map(|row| json!({"message": row.message, "delivery": row.delivery})).collect::<Vec<_>>(), "nextCursor": page.next_cursor}),
            )
        }
        crate::rpc::method::MUX_MAIL_ACK => {
            let (recipient_id, recipient_receipt) = identity_params(params, "recipient")?;
            let bound = conn
                .mailbox_receipt(&recipient_id)
                .ok_or_else(|| detached("ack", &recipient_id))?;
            let recipient =
                validate_binding("recipient", &recipient_id, &recipient_receipt, &bound)?;
            let message_id = required_string(params, "messageId")?;
            let delivery = hub.mailbox().acknowledge(&recipient, &message_id).map_err(map_error)?;
            Ok(json!({"delivery": delivery}))
        }
        _ => Err(RpcError::method_not_found(method)),
    }
}

fn require_local_origin(origin: Origin) -> Result<(), RpcError> {
    if origin.web_class() {
        return Err(RpcError::invalid_params(
            "mailbox RPCs are available only on the local daemon",
        )
        .with_data(json!({"reason": "mailbox_remote_refused"})));
    }
    Ok(())
}

fn detached(operation: &str, session_id: &str) -> RpcError {
    RpcError::new(-32002, format!("mailbox {operation} requires an attached session"))
        .with_data(json!({"reason": "session_not_attached", "sessionId": session_id}))
}

fn required_string(params: &Value, name: &str) -> Result<String, RpcError> {
    params
        .get(name)
        .and_then(Value::as_str)
        .map(str::to_owned)
        .filter(|s| !s.trim().is_empty())
        .ok_or_else(|| RpcError::invalid_params(format!("{name} is required")))
}

fn report_recipient(params: &Value) -> Option<&str> {
    params
        .get("recipient")
        .and_then(Value::as_str)
        .filter(|recipient| recipient.starts_with("reports:"))
}

fn validate_report_recipient(recipient: &str) -> Result<(), RpcError> {
    if recipient.strip_prefix("reports:").is_some_and(|person| !person.trim().is_empty()) {
        Ok(())
    } else {
        Err(RpcError::invalid_params("mailbox reports recipient must be reports:<person>"))
    }
}

fn parse_metadata(params: &Value) -> Result<BTreeMap<String, Value>, RpcError> {
    match params.get("metadata") {
        None | Some(Value::Null) => Ok(BTreeMap::new()),
        Some(metadata) => serde_json::from_value(metadata.clone())
            .map_err(|e| RpcError::invalid_params(format!("metadata must be an object: {e}"))),
    }
}

fn identity_params(params: &Value, role: &str) -> Result<(String, SessionReceipt), RpcError> {
    let value =
        params.get(role).ok_or_else(|| RpcError::invalid_params(format!("{role} is required")))?;
    let (id, nested_receipt) = if let Some(id) = value.as_str() {
        (id.to_owned(), None)
    } else if let Some(object) = value.as_object() {
        let id = object
            .get("qualifiedSessionId")
            .or_else(|| object.get("sessionId"))
            .and_then(Value::as_str)
            .ok_or_else(|| RpcError::invalid_params(format!("{role} must name a session")))?
            .to_owned();
        (id, object.get("sessionReceipt"))
    } else {
        return Err(RpcError::invalid_params(format!(
            "{role} must be a string or identity object"
        )));
    };
    let receipt_name = format!("{role}Receipt");
    let session_receipt_name = format!("{role}SessionReceipt");
    let receipt = params
        .get(&receipt_name)
        .or_else(|| params.get(&session_receipt_name))
        .or(nested_receipt)
        .or_else(|| (role == "recipient").then(|| params.get("receipt")).flatten())
        .ok_or_else(|| {
            RpcError::invalid_params(format!("{role} session receipt is required"))
                .with_data(json!({"reason": "mailbox_identity_receipt_required", "role": role}))
        })?;
    let receipt = serde_json::from_value(receipt.clone()).map_err(|e| {
        RpcError::invalid_params(format!("{role} session receipt is invalid: {e}"))
            .with_data(json!({"reason": "mailbox_identity_receipt_invalid", "role": role}))
    })?;
    Ok((id, receipt))
}

/// The local agent CLI is already attached to one session, so `deliver` may
/// omit the verbose receipt object. Session-to-session mail keeps the explicit
/// receipt requirement; the no-wake reports target only uses this convenience
/// on a local connection with exactly one bound sender.
fn identity_params_or_bound(
    conn: &Arc<Conn>,
    params: &Value,
    role: &str,
) -> Result<(String, SessionReceipt), RpcError> {
    match identity_params(params, role) {
        Ok(value) => Ok(value),
        Err(error) if role == "sender" && error.message.contains("session receipt is required") => {
            let id = params.get(role).and_then(Value::as_str).ok_or(error)?.to_owned();
            let receipt = conn.mailbox_receipt(&id).ok_or_else(|| detached("deliver", &id))?;
            Ok((id, receipt))
        }
        Err(error) => Err(error),
    }
}

fn current_identity(hub: &Hub, requested: &str) -> Result<SessionReceipt, RpcError> {
    let key = requested.strip_prefix("acp:").unwrap_or(requested);
    let session = hub.resolve(key)?;
    Ok(SessionReceipt::new(
        LOCAL_HOST_ID,
        session.id.clone(),
        session.meta().agent_session_id,
        hub.started_at,
    ))
}

fn validate_binding(
    role: &str,
    requested: &str,
    supplied: &SessionReceipt,
    expected: &SessionReceipt,
) -> Result<String, RpcError> {
    if supplied.generation != expected.generation {
        return Err(RpcError::invalid_params(format!("{role} session receipt is stale"))
            .with_data(json!({
                "reason": "mailbox_identity_stale_generation",
                "role": role,
                "expectedGeneration": expected.generation,
                "receivedGeneration": supplied.generation,
            })));
    }
    if supplied != expected {
        return Err(RpcError::invalid_params(format!("{role} session identity does not match"))
            .with_data(json!({"reason": "mailbox_identity_mismatch", "role": role})));
    }
    let key = requested.strip_prefix("acp:").unwrap_or(requested);
    if key != expected.mux_session_id && key != expected.qualified_id() {
        return Err(RpcError::invalid_params(format!("{role} session identity does not match"))
            .with_data(json!({"reason": "mailbox_identity_mismatch", "role": role})));
    }
    Ok(expected.qualified_id())
}

fn map_error(error: MailboxError) -> RpcError {
    match error {
        MailboxError::Storage(error) => RpcError::internal(error.to_string()),
        MailboxError::NotFound(id) => {
            RpcError::not_found(format!("mailbox message {id} was not found"))
        }
        MailboxError::NotRecipient(id) => RpcError::invalid_params(format!(
            "the recipient cannot acknowledge mailbox message {id}"
        )),
        other => RpcError::invalid_params(other.to_string()),
    }
}

#[cfg(test)]
mod tests {
    use super::{
        parse_metadata, report_recipient, require_local_origin, validate_binding,
        validate_report_recipient,
    };
    use crate::mailbox::{Mailbox, MailboxError, SendInput};
    use crate::server::Origin;
    use crate::session_identity::SessionReceipt;
    use serde_json::json;
    use std::collections::BTreeMap;

    fn receipt(host: &str, mux: &str, generation: u64) -> SessionReceipt {
        SessionReceipt::new(host, mux, Some(format!("agent-{mux}")), generation)
    }

    #[test]
    fn spoofed_sender_identity_is_rejected() {
        let expected = receipt("local", "sender", 7);
        let spoofed = receipt("local", "other", 7);
        let error = validate_binding("sender", "local/other", &spoofed, &expected)
            .expect_err("spoofed sender must fail");
        assert_eq!(error.data.unwrap()["reason"], "mailbox_identity_mismatch");
    }

    #[test]
    fn stale_restart_receipt_is_rejected() {
        let expected = receipt("local", "sender", 8);
        let stale = receipt("local", "sender", 7);
        let error = validate_binding("sender", "local/sender", &stale, &expected)
            .expect_err("stale receipt must fail");
        assert_eq!(error.data.unwrap()["reason"], "mailbox_identity_stale_generation");
    }

    #[test]
    fn duplicate_id_binding_conflict_is_not_hidden_by_a_bare_id() {
        let expected = receipt("local", "sender", 7);
        assert!(validate_binding("sender", "sender", &expected, &expected).is_ok());
        let mailbox = Mailbox::memory();
        let input = |sender: &str| SendInput {
            id: "duplicate".into(),
            sender: sender.into(),
            recipient: "local/recipient".into(),
            body: "body".into(),
            metadata: BTreeMap::new(),
        };
        mailbox.send(input("local/sender")).unwrap();
        assert!(matches!(mailbox.send(input("local/other")), Err(MailboxError::IdConflict(_))));
    }

    #[test]
    fn qualified_routing_returns_the_server_qualified_id() {
        let expected = receipt("local", "recipient", 7);
        assert_eq!(
            validate_binding("recipient", "local/recipient", &expected, &expected).unwrap(),
            "local/recipient"
        );
    }

    #[test]
    fn remote_mailbox_rpc_is_rejected() {
        let error = require_local_origin(Origin::Web).expect_err("remote mailbox must fail closed");
        assert_eq!(error.code, -32602);
        assert_eq!(error.data.unwrap()["reason"], "mailbox_remote_refused");
        assert!(require_local_origin(Origin::Peer).is_err());
    }

    #[test]
    fn local_mailbox_origins_are_allowed() {
        assert!(require_local_origin(Origin::Local).is_ok());
        assert!(require_local_origin(Origin::LocalApp).is_ok());
    }

    #[test]
    fn null_metadata_is_normalized_to_empty_object() {
        let metadata = parse_metadata(&json!({"metadata": null})).expect("null is valid");
        assert!(metadata.is_empty());
    }

    #[test]
    fn non_object_metadata_is_rejected() {
        let error = parse_metadata(&json!({"metadata": "invalid"}))
            .expect_err("metadata must be an object");
        assert!(error.message.contains("metadata must be an object"));
    }

    #[test]
    fn reports_alias_is_detected_and_validated() {
        let params = json!({"recipient": "reports:leo"});
        assert_eq!(report_recipient(&params), Some("reports:leo"));
        assert!(validate_report_recipient("reports:leo").is_ok());
        for invalid in ["reports:", "reports:   ", "agent"] {
            assert!(validate_report_recipient(invalid).is_err(), "{invalid} must be rejected");
        }
        assert_eq!(report_recipient(&json!({"recipient": "agent"})), None);
    }
}
