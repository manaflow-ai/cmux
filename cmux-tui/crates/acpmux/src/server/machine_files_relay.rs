//! `_acpmux/machine_files_call`: one file or command action on another of the person's machines,
//! sent on from this machine's own socket (an agent's `machine_read`, `machine_edit` or
//! `machine_exec` tool, `acpmux_mcp_machine.rs`) to that machine's machine-call service over the
//! hub carrier (`machine_call_service.rs`), where `machine_files.rs` decides and runs it.
//!
//! Default deny: only the local unix socket may send one. A peer, a paired device, the web or
//! the app's own connection is refused, so nothing reaches a third machine through this one, and
//! this method never runs anything here.

use std::sync::Arc;

use serde_json::{Value, json};

use super::Conn;
use super::computer_use_relay::{Admission, admit};
use crate::hub::Hub;
use crate::machine_files;
use crate::rpc::RpcError;

/// How long a call may take: the longest command the far machine runs (ten minutes), and the way.
#[cfg(feature = "hub-carrier")]
const CALL_WAIT: std::time::Duration = std::time::Duration::from_secs(630);

fn refused(code: &str, message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"code": code}))
}

/// The machine a call names, and its checked action and params.
pub(super) fn parse(params: &Value) -> Result<(String, String, Value), RpcError> {
    let machine = params.get("machine").and_then(Value::as_str).unwrap_or_default().trim();
    if machine.is_empty() || machine.len() > 256 || machine.chars().any(char::is_control) {
        return Err(refused("invalid_arguments", "name a machine"));
    }
    let (action, inner) = machine_files::parse(params)?;
    Ok((machine.to_owned(), action, inner))
}

pub(super) async fn call(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    if !matches!(admit(conn.origin, conn.auth, None), Admission::Forward) {
        return Err(refused(
            "machine_call_denied",
            "only an agent on this machine may send a call to another machine",
        ));
    }
    let (machine, action, inner) = parse(params)?;
    #[cfg(feature = "hub-carrier")]
    if let Some(key) = crate::machine_call_service::machine_key(&hub.mesh_book_machines(), &machine)
    {
        return crate::machine_call_service::request(
            hub,
            &key,
            crate::machine_call_service::FILES_CALL,
            json!({"action": action, "params": inner}),
            CALL_WAIT,
        )
        .await;
    }
    let _ = (hub, action, inner);
    Err(refused(
        "unknown_machine",
        format!("no signed-in machine named {machine:?}; `cmux machines` lists them"),
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::server::Origin;
    use crate::server::conn_auth::ConnAuth;

    #[test]
    fn machine_files_call_names_one_machine_and_a_listed_action() {
        let (machine, action, inner) =
            parse(&json!({"machine": "studio", "action": "exec", "params": {"argv": ["uname"]}}))
                .unwrap();
        assert_eq!((machine.as_str(), action.as_str()), ("studio", "exec"));
        assert_eq!(inner, json!({"argv": ["uname"]}));
        let code = |v: Value| parse(&v).unwrap_err().data.unwrap()["code"].clone();
        assert_eq!(code(json!({"action": "exec"})), "invalid_arguments");
        assert_eq!(code(json!({"machine": " ", "action": "exec"})), "invalid_arguments");
        assert_eq!(code(json!({"machine": "studio", "action": "agent.start"})), "unknown_action");
        assert_eq!(
            code(json!({"machine": "studio", "action": "exec", "params": {"_level": "full"}})),
            "machine_call_denied"
        );
    }

    #[test]
    fn machine_files_call_is_sent_on_from_the_local_socket_only() {
        assert!(matches!(admit(Origin::Local, ConnAuth::LocalSocket, None), Admission::Forward));
        for (origin, auth) in [
            (Origin::Peer, ConnAuth::PeerToken),
            (Origin::Peer, ConnAuth::Device),
            (Origin::Web, ConnAuth::LocalSocket),
            (Origin::LocalApp, ConnAuth::LocalSocket),
        ] {
            assert!(
                !matches!(admit(origin, auth, None), Admission::Forward),
                "{origin:?} {auth:?}"
            );
        }
    }
}
