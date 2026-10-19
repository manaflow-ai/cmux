//! The host's read replica publisher on this daemon (`cloud-host-replica-v1`,
//! plans/cmux-next/object-sync/DESIGN.md phase 3). The cloud keeps a
//! read-only copy of `host:<host>/session` (the workspace tree) and forwards
//! the owner's ops while the host is online; [`HostReplica`] does the wire,
//! this module supplies the state, runs forwarded ops through the daemon's
//! own command path, and serves the app's lease commands.
//!
//! Remote relay policy (CLAUDE.md "Remote CLI relay"): a forwarded op is
//! denied unless it is in [`FORWARDED_OPS`], and only the fields listed there
//! pass (no command-bearing params, no selector of another machine or
//! session: `machine` and `session` are always `current`). The cloud
//! authenticated the caller as the host's owner; the publisher checks the
//! principal's user against its own install token again.

use std::sync::{Arc, Weak};

use serde::Deserialize;
use serde_json::{Map, Value};

use super::{Mux, list_workspaces_reply};
use crate::cloud_conversations::{
    CloudError, HostOpRefusal, HostReplica, HostReplicaParams, HostSource,
};
use crate::workspace_registry::Actor;

pub(super) use crate::cloud_conversations::CLOUD_HOST_REPLICA_CAPABILITY as CAPABILITY;

/// The ops the cloud may forward, each with the params fields that pass.
const FORWARDED_OPS: &[(&str, &[&str])] = &[(
    "workspace.rename",
    &["workspace", "name", "expected_name_revision", "expected_generation"],
)];

/// `cloud-host-replica-set`: the app's install token lease for the publisher.
#[derive(Deserialize)]
pub(super) struct HostReplicaSetParams {
    api_base_url: String,
    install_token: String,
    expires_at: u64,
    #[serde(default)]
    client_version: Option<String>,
    host_name: String,
}

/// `cloud-host-replica-clear`.
#[derive(Deserialize)]
pub(super) struct HostReplicaClearParams {
    /// The host's off switch: the cloud copy is deleted before the lease goes.
    #[serde(default)]
    purge: bool,
}

/// Only the verified cmux app holds the install token.
fn replica(mux: &Mux, client: u64) -> anyhow::Result<&HostReplica> {
    let replica = mux
        .host_replica()
        .ok_or_else(|| anyhow::anyhow!("cloud host replica is not available on this daemon"))?;
    if !matches!(super::origin_gate::connection_actor(mux, client), Actor::Frontend { .. }) {
        return Err(CloudError::Rejected {
            code: "forbidden".into(),
            message: "the host replica belongs to the verified cmux app connection".into(),
            retryable: false,
        }
        .into());
    }
    Ok(replica)
}

pub(super) fn set(mux: &Mux, client: u64, params: HostReplicaSetParams) -> anyhow::Result<Value> {
    let HostReplicaSetParams { api_base_url, install_token, expires_at, client_version, host_name } =
        params;
    let lease =
        HostReplicaParams { api_base_url, install_token, expires_at, client_version, host_name };
    Ok(replica(mux, client)?.set_lease(lease)?)
}

pub(super) fn clear(
    mux: &Mux,
    client: u64,
    params: HostReplicaClearParams,
) -> anyhow::Result<Value> {
    Ok(replica(mux, client)?.clear(params.purge))
}

pub(super) fn status(mux: &Mux, client: u64) -> anyhow::Result<Value> {
    Ok(replica(mux, client)?.status())
}

/// The cloud's key in the daemon's idempotency store: namespaced by user, so
/// it never meets a local client's key, and inside the 128-byte key limit.
fn cloud_key(user: &str, key: &str) -> String {
    use sha2::{Digest, Sha256};
    let digest = Sha256::digest(format!("{user}\n{key}").as_bytes());
    let hex: String = digest.iter().map(|byte| format!("{byte:02x}")).collect();
    format!("cloud:{hex}")
}

/// The daemon side of the publisher.
struct MuxHostSource {
    mux: Weak<Mux>,
}

fn refusal(code: &str, message: impl Into<String>, retryable: bool) -> HostOpRefusal {
    HostOpRefusal { code: code.to_string(), message: message.into(), retryable }
}

fn refusal_of(error: &Value) -> HostOpRefusal {
    refusal(
        error["code"].as_str().unwrap_or("operation.failed"),
        error["message"].as_str().unwrap_or("operation failed"),
        error["retryable"].as_bool().unwrap_or(false),
    )
}

/// The workspace fields the cloud copy keeps: what a reader lists and what
/// `workspace.rename` needs. Screens, tab and screen titles, the app and the
/// kind stay on this Mac (a title can name a folder or a command).
const PUBLISHED_WORKSPACE_FIELDS: &[&str] = &[
    "id",
    "resource_id",
    "short_id",
    "name",
    "name_revision",
    "group",
    "color",
    "icon",
    "pinned",
    "marked_unread",
    "unread_count",
    "active",
];

/// The published projection of the daemon's workspace list.
fn published_state(listed: &Value) -> Value {
    let workspaces: Vec<Value> = listed["workspaces"]
        .as_array()
        .map(|all| {
            all.iter()
                .map(|workspace| {
                    let kept: Map<String, Value> = PUBLISHED_WORKSPACE_FIELDS
                        .iter()
                        .filter_map(|field| {
                            workspace.get(*field).map(|v| (field.to_string(), v.clone()))
                        })
                        .collect();
                    Value::Object(kept)
                })
                .collect()
        })
        .unwrap_or_default();
    serde_json::json!({
        "workspaces": workspaces,
        "registry_id": listed["registry_id"],
        "generation": listed["generation"],
    })
}

impl HostSource for MuxHostSource {
    fn session_state(&self) -> Value {
        let Some(mux) = self.mux.upgrade() else { return Value::Null };
        list_workspaces_reply(&mux).map_or(Value::Null, |listed| published_state(&listed))
    }

    fn apply(
        &self,
        op: &str,
        params: &Value,
        idempotency_key: &str,
        user: &str,
    ) -> Result<Value, HostOpRefusal> {
        let Some((_, fields)) = FORWARDED_OPS.iter().find(|(name, _)| *name == op) else {
            return Err(refusal(
                "operation.unsupported",
                format!("{op} is not open to the cloud"),
                false,
            ));
        };
        let mux = self
            .mux
            .upgrade()
            .ok_or_else(|| refusal("operation.failed", "the daemon is shutting down", true))?;
        let Value::Object(given) = params else {
            return Err(refusal("validation.invalid", "params must be an object", false));
        };
        if let Some(extra) = given.keys().find(|key| !fields.contains(&key.as_str())) {
            return Err(refusal(
                "validation.invalid",
                format!("{op} does not take {extra} from the cloud"),
                false,
            ));
        }
        let allowed: Map<String, Value> = given.clone();
        let message = crate::apps::envelope::request(
            op,
            Value::Object(allowed),
            Some(cloud_key(user, idempotency_key)),
        )
        .map_err(|error| refusal_of(&error))?;
        let parsed = crate::resource_router::parse_resource_request_as(
            &message,
            Actor::Peer { id: format!("cloud:{user}") },
        )
        .map_err(|error| refusal(&error.code, error.message.clone(), error.retryable))?;
        if crate::resource_router::requires_connection_context(parsed.envelope.operation) {
            return Err(refusal(
                "operation.unsupported",
                format!("{op} needs a client connection"),
                false,
            ));
        }
        let response = crate::resource_router::handle_parsed_resource_request(&mux, parsed)
            .map_err(|error| refusal(&error.code, error.message.clone(), error.retryable))?;
        crate::apps::envelope::answer(op, response).map_err(|error| refusal_of(&error))
    }
}

/// Installs the publisher once, starts it with this daemon's state and
/// marks every tree change for publishing. A second install is refused.
pub fn install_host_replica(mux: &Arc<Mux>, replica: HostReplica) -> bool {
    let source = Arc::new(MuxHostSource { mux: Arc::downgrade(mux) });
    let weak = Arc::downgrade(mux);
    replica.set_sink(Arc::new(move |event| {
        if let Some(mux) = weak.upgrade() {
            mux.emit(crate::MuxEvent::CloudConversation(Arc::new(event)));
        }
    }));
    if mux.set_host_replica(replica).is_err() {
        return false;
    }
    let Some(replica) = mux.host_replica() else { return false };
    if let Err(error) = replica.start(source) {
        eprintln!("cmux-tui: host replica unavailable: {error}");
        return false;
    }
    let weak = Arc::downgrade(mux);
    let mut events = mux.subscribe_launch_snapshot();
    let spawned =
        std::thread::Builder::new().name("mux-host-replica-changes".into()).spawn(move || {
            loop {
                match events.recv() {
                    Ok(_) => while events.try_recv().is_ok() {},
                    // The mailbox overflowed (or the daemon stops): resubscribe and publish again.
                    Err(_) => {
                        let Some(mux) = weak.upgrade() else { return };
                        events = mux.subscribe_launch_snapshot();
                    }
                }
                let Some(mux) = weak.upgrade() else { return };
                if let Some(replica) = mux.host_replica() {
                    replica.mark_changed();
                }
            }
        });
    if let Err(error) = spawned {
        eprintln!("cmux-tui: host replica change watcher unavailable: {error}");
    }
    true
}

#[cfg(test)]
#[path = "cloud_host_replica_tests.rs"]
mod tests;
