//! `_acpmux/app_launch {app, args?, activate?, hidden?, new?, waitMs?, machine?}` and
//! `_acpmux/app_list {machine?}` (`app_launch.rs`). Without `machine` (or with this machine's
//! own name) it is this machine; with `machine`, that connected peer, asked over its link, the
//! one `acpmux new --machine` starts a chat over: no ssh. A peer's request is never relayed on
//! to another peer.
//!
//! Admission is a chat start's: this machine's own socket and app, the person's own other
//! machines (a proven peer: peer token, the hub carrier, which admits only the same person's
//! machines), and a paired machine with a `client` credential (the grant another person's
//! machine needs). A Web client, a teammate on the Cloud carrier, a read-only machine and a
//! peer forwarding for a Web client are refused (`remote_guard::control_of`). A chat can
//! already run any command there, so this adds reach, not power (Z6).
//!
//! Every launch, done or refused, is one line of the machine's audit log, `app-audit.jsonl`
//! under the acpmux home: who asked (the connection's kind and client, and the machine and chat
//! the request says it came from), the app, how many arguments (never their text), when, and
//! how it went.

use super::{Conn, Origin};
use crate::app_launch::{LaunchRequest, Refusal};
use crate::hub::{Control, Hub};
use crate::rpc::RpcError;
use serde_json::{Value, json};
use std::sync::Arc;
use std::time::Duration;

pub(super) const LAUNCH: &str = "_acpmux/app_launch";
pub(super) const LIST: &str = "_acpmux/app_list";

/// The audit log's file name under the acpmux home.
pub const AUDIT_FILE: &str = "app-audit.jsonl";

/// How long a peer may take beyond the launch's own wait: its link, its folder scan.
const PEER_SLACK: Duration = Duration::from_secs(15);
/// How long a peer's list may take.
const LIST_BUDGET: Duration = Duration::from_secs(20);

pub(super) async fn handle(
    hub: &Arc<Hub>,
    conn: &Conn,
    m: &str,
    params: &Value,
) -> Result<Value, RpcError> {
    let own = crate::pairing::machine_name();
    let machine = params
        .get("machine")
        .and_then(Value::as_str)
        .filter(|name| !name.is_empty() && !name.eq_ignore_ascii_case(&own) && *name != "local");
    if super::remote_guard::control_of(conn.origin, conn.auth, params) == Control::Web {
        if m == LAUNCH {
            audit(conn, params, &own, Err("app.not_allowed"));
        }
        return Err(refused(
            "app.not_allowed",
            format!("this connection may not open apps on {own}"),
            "ask the machine's owner to add your machine (the same grant a chat there needs)",
            &own,
        ));
    }
    match machine {
        Some(name) => forward(hub, conn, m, params, name).await,
        None => here(conn, m, params, &own).await,
    }
}

/// On this machine.
async fn here(conn: &Conn, m: &str, params: &Value, own: &str) -> Result<Value, RpcError> {
    if m == LIST {
        let mut list = tokio::task::spawn_blocking(crate::app_launch::list)
            .await
            .map_err(|e| RpcError::internal(e.to_string()))?;
        list["machine"] = json!(own);
        return Ok(list);
    }
    let request = match LaunchRequest::from_params(params) {
        Ok(request) => request,
        Err(refusal) => {
            audit(conn, params, own, Err(refusal.reason()));
            return Err(refusal_error(&refusal, params, own));
        }
    };
    let launched = tokio::task::spawn_blocking(move || crate::app_launch::launch(&request))
        .await
        .map_err(|e| RpcError::internal(e.to_string()))?;
    match launched {
        Ok(launched) => {
            audit(conn, params, own, Ok(&launched.app.path.to_string_lossy()));
            let mut reply = launched.json();
            reply["machine"] = json!(own);
            Ok(reply)
        }
        Err(refusal) => {
            audit(conn, params, own, Err(refusal.reason()));
            Err(refusal_error(&refusal, params, own))
        }
    }
}

/// On the connected peer `name`.
async fn forward(
    hub: &Arc<Hub>,
    conn: &Conn,
    m: &str,
    params: &Value,
    name: &str,
) -> Result<Value, RpcError> {
    if conn.origin == Origin::Peer {
        return Err(RpcError::invalid_params("a peer's request is not relayed to another peer"));
    }
    let Some(peer) = hub.connected_peers().into_iter().find(|p| p.name.eq_ignore_ascii_case(name))
    else {
        return Err(refused(
            "app.unreachable",
            format!("{name} is not a connected machine"),
            &format!(
                "`acpmux machine ls` lists the machines; `acpmux machine add {name}` links it"
            ),
            name,
        ));
    };
    let mut forwarded = params.clone();
    if let Some(object) = forwarded.as_object_mut() {
        object.remove("machine");
        // What the far end's audit says this came from (claimed: the link is the proof).
        object.insert(
            "from".into(),
            json!({"machine": crate::pairing::machine_name(), "session": conn.caller()}),
        );
    }
    let budget = if m == LAUNCH {
        LaunchRequest::from_params(params).map_or(crate::app_launch::DEFAULT_WAIT, |r| r.wait)
            + PEER_SLACK
    } else {
        LIST_BUDGET
    };
    let answer = match tokio::time::timeout(budget, peer.request(m, forwarded)).await {
        Ok(answer) => answer,
        Err(_) => {
            return Err(refused(
                "app.unreachable",
                format!("{name} did not answer within {} s", budget.as_secs()),
                &format!("`acpmux machine status {name}`"),
                name,
            ));
        }
    };
    match answer {
        Ok(mut reply) => {
            reply["machine"] = json!(peer.name);
            Ok(reply)
        }
        // An acpmux from before app launch.
        Err(error) if error.code == -32601 => Err(refused(
            "app.daemon_too_old",
            format!("{name}'s acpmux is older than app launch"),
            &format!("`acpmux machine update {name}`, then run it again"),
            name,
        )),
        Err(error) => Err(error),
    }
}

fn refusal_error(refusal: &Refusal, params: &Value, machine: &str) -> RpcError {
    let app = params.get("app").and_then(Value::as_str).unwrap_or("APP");
    let on = params
        .get("from")
        .and_then(|from| from.get("machine"))
        .and_then(Value::as_str)
        .map_or_else(String::new, |_| format!(" --on {machine}"));
    refused(refusal.reason(), refusal.message(machine), &refusal.next(app, &on), machine)
}

fn refused(reason: &str, message: String, next: &str, machine: &str) -> RpcError {
    RpcError::new(-32000, message).with_data(json!({
        "reason": reason, "next": next, "machine": machine,
    }))
}

/// One audit line for a launch: `Ok(path)` it opened, `Err(reason)` it was refused.
fn audit(conn: &Conn, params: &Value, own: &str, outcome: Result<&str, &str>) {
    let origin = match conn.origin {
        Origin::Local => "local",
        Origin::LocalApp => "app",
        Origin::Web => "web",
        Origin::Peer => "peer",
    };
    let mut line = json!({
        "at": crate::store::now_ms(),
        "kind": "app_launch",
        "host": own,
        "origin": origin,
        "auth": format!("{:?}", conn.auth),
        "client": conn.client_name(),
        "caller": conn.caller(),
        "from": params.get("from").cloned().unwrap_or(Value::Null),
        "app": params.get("app").cloned().unwrap_or(Value::Null),
        "args": params.get("args").and_then(Value::as_array).map_or(0, Vec::len),
        "activate": params.get("activate").and_then(Value::as_bool).unwrap_or(false),
    });
    match outcome {
        Ok(path) => {
            line["ok"] = json!(true);
            line["path"] = json!(path);
        }
        Err(reason) => {
            line["ok"] = json!(false);
            line["reason"] = json!(reason);
        }
    }
    crate::xhost_audit::append_line(&crate::config::home().join(AUDIT_FILE), &line);
}
