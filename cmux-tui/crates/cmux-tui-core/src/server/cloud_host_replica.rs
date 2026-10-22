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
//!
//! The Chief stream (a450, cmux-prompts logs/iphone-chief-DESIGN.md): the
//! Home Chief conversation (the oldest one of `user_local` and `agent_mux`)
//! and its newest messages are published on `host:<h>/chief`, so the phone
//! reads it while the Mac is offline. `conversation.message.send` with only
//! `text` is the one op open on it: it becomes the person's (`user_local`)
//! message, keyed by the cloud key, so a resend from HostDO's mailbox never
//! makes a second message.

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

/// The one Chief op the cloud may forward, and its only field.
const CHIEF_SEND_OP: &str = "conversation.message.send";
/// The newest Chief messages read for the copy (then trimmed to the budget).
const CHIEF_TAIL: u32 = 100;
/// The copy stays below the publisher's 200 KiB state limit.
const CHIEF_STATE_BUDGET: usize = 180 * 1024;
/// The prefix of a phone message's key and client id in the Chief conversation.
const CHIEF_KEY_PREFIX: &str = "cloud-";
/// One phone message, in characters.
const CHIEF_TEXT_MAX: usize = 20_000;

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

/// The Home Chief conversation: the oldest one with the local person and `agent_mux`.
fn chief_conversation(summaries: &[cmux_conversation::Summary]) -> Option<String> {
    summaries
        .iter()
        .filter(|s| {
            s.participants.iter().any(|p| p.id == crate::conversation_store::LOCAL_USER)
                && s.participants.iter().any(|p| p.id == crate::chief_registry::DEFAULT_CHIEF)
        })
        .min_by(|a, b| (&a.created_at, &a.id).cmp(&(&b.created_at, &b.id)))
        .map(|s| s.id.clone())
}

impl MuxHostSource {
    /// Runs the phone's Chief message as the person's message.
    fn send_to_chief(&self, params: &Value, idempotency_key: &str) -> Result<Value, HostOpRefusal> {
        let Value::Object(given) = params else {
            return Err(refusal("validation.invalid", "params must be an object", false));
        };
        if let Some(extra) = given.keys().find(|key| key.as_str() != "text") {
            return Err(refusal(
                "validation.invalid",
                format!("{CHIEF_SEND_OP} does not take {extra} from the cloud"),
                false,
            ));
        }
        let text = given.get("text").and_then(Value::as_str).unwrap_or("");
        if text.trim().is_empty() || text.chars().count() > CHIEF_TEXT_MAX {
            return Err(refusal(
                "validation.invalid",
                format!("text must be 1-{CHIEF_TEXT_MAX} characters"),
                false,
            ));
        }
        let mux = self
            .mux
            .upgrade()
            .ok_or_else(|| refusal("operation.failed", "the daemon is shutting down", true))?;
        let conversation = mux
            .with_conversations(|store| Ok(chief_conversation(&store.list()?)))
            .map_err(|error| refusal("operation.failed", error.to_string(), true))?
            .ok_or_else(|| refusal("not_found", "this Mac has no Chief conversation", false))?;
        // One key for the op ledger and the message (the store requires both equal):
        // the phone's own key under `cloud-`, so a resend replays and the phone knows
        // its message (it strips the prefix). Only the host's owner reaches this.
        let key = format!("{CHIEF_KEY_PREFIX}{idempotency_key}");
        if !cmux_conversation::valid_token(&key) {
            return Err(refusal("validation.invalid", "idempotency_key is too long", false));
        }
        let op: cmux_conversation::Op = serde_json::from_value(serde_json::json!({
            "kind": "message.send", "client_msg_id": key,
            "parts": [{"type": "text", "text": text}],
        }))
        .map_err(|error| refusal("validation.invalid", error.to_string(), false))?;
        let outcome = super::conversations::commit_op(
            &mux,
            &conversation,
            &key,
            crate::conversation_store::LOCAL_USER,
            &op,
            &None,
        )
        .map_err(|error| refusal("operation.failed", error.to_string(), true))?;
        Ok(super::conversations::op_reply(&outcome, outcome.result.change.clone(), None))
    }
}

impl HostSource for MuxHostSource {
    fn chief_state(&self) -> Option<Value> {
        let mux = self.mux.upgrade()?;
        let (summary, mut messages) = mux
            .with_conversations(|store| {
                let Some(id) = chief_conversation(&store.list()?) else { return Ok(None) };
                Ok(Some(store.snapshot(&id, CHIEF_TAIL)?))
            })
            .ok()
            .flatten()?;
        let summary = serde_json::to_value(&summary).ok()?;
        loop {
            let state = serde_json::json!({ "conversation": summary, "messages": messages });
            if state.to_string().len() <= CHIEF_STATE_BUDGET || messages.is_empty() {
                return Some(state);
            }
            // Oldest first: drop from the front until the copy fits.
            let drop = messages.len().div_ceil(8);
            messages.drain(..drop);
        }
    }

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
        if op == CHIEF_SEND_OP {
            return self.send_to_chief(params, idempotency_key);
        }
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
    let weak = Arc::downgrade(mux);
    let mut chats = mux.subscribe_conversations();
    let spawned =
        std::thread::Builder::new().name("mux-host-replica-chief".into()).spawn(move || {
            loop {
                match chats.recv() {
                    Ok(_) => while chats.try_recv().is_ok() {},
                    Err(_) => {
                        let Some(mux) = weak.upgrade() else { return };
                        chats = mux.subscribe_conversations();
                    }
                }
                let Some(mux) = weak.upgrade() else { return };
                if let Some(replica) = mux.host_replica() {
                    replica.mark_changed();
                }
            }
        });
    if let Err(error) = spawned {
        eprintln!("cmux-tui: host replica chief watcher unavailable: {error}");
    }
    true
}

#[cfg(test)]
#[path = "cloud_host_replica_tests.rs"]
mod tests;
