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
mod tests {
    use super::*;

    fn on(params: Value) -> Enrollment {
        Enrollment { enabled: true, ..Enrollment::default() }.with(&params).unwrap()
    }

    #[test]
    fn reads_without_fields() {
        assert!(!writes(&json!({})));
        assert!(!writes(&json!({"name": "mini"})));
        assert!(writes(&json!({"enabled": false})));
        assert!(writes(&json!({"hours": null})));
    }

    #[test]
    fn off_always_narrows_on_and_widening_do_not() {
        let off = Enrollment::default();
        let own = on(json!({}));
        assert!(only_narrows(&own, &off));
        assert!(!only_narrows(&off, &own), "turning on lets work in");
        assert!(!only_narrows(&own, &on(json!({"teams": ["t2"]}))), "another team");
        assert!(only_narrows(&on(json!({"teams": ["t2"]})), &own), "dropping a team");
        assert!(!only_narrows(&own, &on(json!({"idleSecs": 60}))), "shorter idle bar");
        assert!(only_narrows(&own, &on(json!({"idleSecs": 900}))), "longer idle bar");
        assert!(only_narrows(&own, &on(json!({"agents": ["claude"]}))), "any agent to one");
        assert!(!only_narrows(&on(json!({"agents": ["claude"]})), &own), "one agent to any");
        assert!(!only_narrows(&own, &on(json!({"hours": {"from": 20, "to": 8}}))), "hours change");
    }

    #[test]
    fn with_replaces_named_fields_and_rejects_bad_types() {
        let e = on(json!({"teams": ["t"], "hours": {"from": 20, "to": 8}, "idleSecs": 120}));
        assert_eq!(e.policy.teams, vec!["t".to_owned()]);
        assert_eq!(e.idle_secs, 120);
        let cleared = e.with(&json!({"hours": null})).unwrap();
        assert_eq!(cleared.policy.hours, None);
        assert_eq!(cleared.policy.teams, e.policy.teams, "unnamed fields stay");
        assert!(e.with(&json!({"enabled": "yes"})).is_err());
        assert!(e.with(&json!({"teams": "t"})).is_err());
        assert!(e.with(&json!({"idleSecs": -1})).is_err());
    }

    #[test]
    fn saved_value_round_trips_and_keeps_policy_when_off() {
        let e = on(json!({"teams": ["t"], "agents": ["codex"], "idleSecs": 300}));
        assert_eq!(Enrollment::from_value(&e.to_value()), e);
        let off = e.with(&json!({"enabled": false})).unwrap();
        let back = Enrollment::from_value(&off.to_value());
        assert!(!back.enabled);
        assert_eq!(back.policy, e.policy, "off keeps the rules for the next on");
        assert_eq!(Enrollment::resolve(Some(&json!(false))), Enrollment::default());
    }
}
