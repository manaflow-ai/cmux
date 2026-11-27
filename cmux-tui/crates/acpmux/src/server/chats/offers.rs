//! The session offer methods (`hub/offers.rs`). The agent's tool offers over
//! the unix socket; the person answers. A chat this daemon does not host is
//! left to the usual routing, but its peer sees the answer as a peer's, not
//! the person's, and refuses it: only the app of the daemon that hosts the
//! chat answers its offers.

use super::super::{Conn, Origin, str_param};
use crate::hub::Hub;
use crate::rpc::{RpcError, method};
use serde_json::Value;
use std::sync::Arc;

/// The reply to an offer method for a chat of this daemon, or None.
pub(in crate::server) fn dispatch(
    hub: &Arc<Hub>,
    conn: &Conn,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    if !matches!(m, method::MUX_OFFER_SESSION | method::MUX_OFFER_RESPOND) {
        return None;
    }
    let Some(key) = str_param(params, "sessionId") else {
        return Some(Err(RpcError::invalid_params("sessionId is required")));
    };
    let session = hub.resolve(key).ok()?;
    Some(if m == method::MUX_OFFER_SESSION {
        if conn.origin == Origin::Local {
            hub.offer_session(&session, params)
        } else {
            Err(RpcError::invalid_params(
                "offering a chat is accepted only over the local unix socket",
            ))
        }
    } else if !conn.is_person() {
        // The chip is the person's: never the agent that offered it.
        Err(crate::hub::person::person_required("answering a chat offer"))
    } else {
        let Some(offer_id) = str_param(params, "offerId") else {
            return Some(Err(RpcError::invalid_params("offerId is required")));
        };
        let outcome = str_param(params, "outcome").unwrap_or_default();
        hub.answer_offer(&session, offer_id, outcome, str_param(params, "childSessionId"))
    })
}
