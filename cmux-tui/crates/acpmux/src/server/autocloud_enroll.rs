//! `_acpmux/autocloud_enroll {name?, enabled?, teams?, agents?, hours?, idleSecs?}`: read or set
//! whether this machine lets AutoCloud place work on it, and on what terms
//! (`crate::autocloud_enroll`). Without `name` it is this machine; with `name`, that connected
//! peer, asked over its link, so the Mac's Settings switch sets a Remote machine. With none of
//! the setting fields it only reads. The answer is the machine's `autoCloud` health block plus
//! `configured`, the saved value (null: the settings key `cloud.autoCloudEnroll` decides).
//!
//! The same shape as `_acpmux/vm_host`: never from a Web client, or a peer forwarding for one,
//! and turned on or widened only by the person's own clients (`vm_boundary::owner`), never a
//! paired machine's credential. Turning it off only narrows. A peer's request is not relayed on.

use super::{Conn, Origin};
use crate::autocloud_enroll::{Enrollment, report_now};
use crate::hub::{Control, Hub};
use crate::rpc::RpcError;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};
use std::sync::Arc;

/// The method name.
pub(super) const METHOD: &str = "_acpmux/autocloud_enroll";
/// The refusal's `data.reason`.
pub(super) const REMOTE_REFUSED: &str = "autocloud-enroll-remote";
/// The fields that change the enrollment; a request with none of them only reads.
const FIELDS: [&str; 5] = ["enabled", "teams", "agents", "hours", "idleSecs"];

/// Whether `params` changes anything.
fn writes(params: &Value) -> bool {
    FIELDS.iter().any(|f| params.get(*f).is_some())
}

/// Whether going from `from` to `to` only narrows: off, or on with nothing new let in. A
/// narrowing change is allowed from any non-Web client; anything else needs the owner's own.
pub(crate) fn only_narrows(from: &Enrollment, to: &Enrollment) -> bool {
    if !to.enabled {
        return true;
    }
    from.enabled
        && to.policy.teams.iter().all(|t| from.policy.teams.contains(t))
        && (from.policy.agents.is_empty()
            || (!to.policy.agents.is_empty()
                && to.policy.agents.iter().all(|a| from.policy.agents.contains(a))))
        && to.idle_secs >= from.idle_secs
        && to.policy.hours == from.policy.hours
}

fn refused(what: &str) -> RpcError {
    RpcError::new(
        -32000,
        format!("AutoCloud enrollment is {what} only from this machine, its cmux app, or its owner's own machine"),
    )
    .with_data(json!({"reason": REMOTE_REFUSED}))
}

async fn view(hub: &Hub) -> Value {
    let saved = hub.config.read().await.auto_cloud_enroll.clone();
    let mut v = json!(report_now(saved.as_ref()));
    v.set("configured", saved.unwrap_or(Value::Null));
    v
}

pub(super) async fn handle(hub: &Arc<Hub>, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    let control = super::remote_guard::control_of(conn.origin, conn.auth, params);
    if control == Control::Web {
        return Err(refused("changed"));
    }
    if let Some(name) = params.get("name").and_then(Value::as_str) {
        if conn.origin == Origin::Peer {
            return Err(RpcError::invalid_params(
                "a peer's request is not relayed to another peer",
            ));
        }
        let Some(peer) = hub.connected_peers().into_iter().find(|p| p.name == name) else {
            return Err(RpcError::invalid_params(format!(
                "no connected peer named {name:?}: `acpmux machine ls` lists the peers"
            )));
        };
        let mut fwd = json!({});
        for f in FIELDS {
            if let Some(v) = params.get(f) {
                fwd.set(f, v.clone());
            }
        }
        let mut reply = peer.request(METHOD, fwd).await?;
        reply.set("name", json!(name));
        return Ok(reply);
    }
    if !writes(params) {
        return Ok(view(hub).await);
    }
    {
        let mut cfg = hub.config.write().await;
        let current = Enrollment::resolve(cfg.auto_cloud_enroll.as_ref());
        let next = current.with(params).map_err(RpcError::invalid_params)?;
        if !only_narrows(&current, &next)
            && !crate::hub::vm_boundary::owner(conn.auth, control, params)
        {
            return Err(refused("turned on or widened"));
        }
        cfg.auto_cloud_enroll = Some(next.to_value());
        cfg.save().map_err(|e| RpcError::internal(format!("save autoCloudEnroll: {e}")))?;
    }
    Ok(view(hub).await)
}

#[cfg(test)]
#[path = "autocloud_enroll_tests.rs"]
mod tests;
