//! `credential.verify`, `credential.mint` and `credential.rotate`
//! (plans/cmux-next/identity.md section 2). The connection gate already
//! refused a non-owner for mint and rotate (`server/origin_gate.rs`); every
//! operation here refuses a connection from another machine.

use std::sync::Arc;

use serde_json::{Value, json};

use super::{ParsedResourceRequest, ensure_session_route, optional_string, required_string};
use crate::resource::{ResourceError, ResourceOperation};
use crate::{Actor, Mux};

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    ensure_session_route(mux, &request.selectors)?;
    if matches!(request.actor, Actor::Peer { .. } | Actor::Legacy | Actor::Daemon) {
        return Err(crate::request_origin::forbidden(
            "launch credentials are checked on this machine only",
            json!({"derived": "agent", "required": "user", "reason": "credential_not_local"}),
        ));
    }
    match request.envelope.operation {
        ResourceOperation::CredentialVerify => {
            Ok(mux.verify_launch_credential(required_string(&request.fields, "credential")?))
        }
        ResourceOperation::CredentialMint => mux.mint_acp_session_credential(
            required_string(&request.fields, "acp_session")?,
            optional_string(&request.fields, "agent")?.as_deref(),
        ),
        ResourceOperation::CredentialRotate => {
            mux.rotate_launch_keys(request.envelope.idempotency_key.as_deref().unwrap_or_default())
        }
        operation => Err(ResourceError::operation_failed(
            operation.wire_name(),
            "credential router received an operation it does not own",
            json!({}),
        )),
    }
}
