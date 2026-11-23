//! File and command actions this machine runs for another of the person's machines: an agent
//! whose loop runs elsewhere (a VM, say) reads, edits and runs commands on the machine the
//! person sits at, one call at a time, each where its data lives. The actions and their policy
//! are the hand's (`hand/requests.rs`, `hand/policy.rs`); this module is the door to them from
//! the hub carrier's machine-call service (`machine_call_service.rs`), in the daemon: no process
//! is started per call except the command an `exec` names.
//!
//! What a call may do here, default deny:
//!
//! - Only the actions of [`ACTIONS`]: files and one command. No agent sessions, nothing else.
//! - The caller is one of the person's own machines and the person here granted "control for my
//!   other machines signed in to this account" (the service's gate); that grant and this
//!   machine's control consent are read again for every call, before and after its policy
//!   decision, so a grant taken back stops the next call.
//! - The hand's policy for a person's machine decides each call ([`config`]): paths inside the
//!   home folder or the temp folders only; never this machine's cmux, hand or agent-daemon
//!   files; never the destructive commands and paths the hand refuses at every level. The policy
//!   inputs a Cloud sets for a hand (`_level`, `_verdict`) are set here and refused in a request.
//! - A call that touches credentials, startup files or a folder holding them is the owner's to
//!   answer on this machine. Nothing here can ask them yet, so it is refused with that reason
//!   ([`NEEDS_OWNER`]) and never run. For a command this is a filter on what its command line
//!   names, not a sandbox: a command that builds such a path at run time is not caught, and the
//!   control grant already lets its holder run commands here.
//!
//! The asking side's own permission prompt (the agent's harness asking the person in their chat
//! before the tool runs) is separate and comes first.

use serde_json::{Value, json};

use crate::hand::HandError;
use crate::hand::agent::Agents;
use crate::hand::config::{HandConfig, Profile};
use crate::hand::requests::{Ctx, handle_with_consent};
use crate::rpc::RpcError;

/// Every action a call may name: the hand's file actions and its one-command run.
pub const ACTIONS: &[&str] =
    &["fs.read", "fs.list", "fs.glob", "fs.grep", "fs.write", "fs.edit", "fs.patch", "exec"];

/// The refusal for a call only the owner of this machine may allow.
pub const NEEDS_OWNER: &str = "policy.needs_owner";

fn refused(code: &str, message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"code": code}))
}

/// The checked parts of a call `{"action": A, "params": {..}}`: an action of [`ACTIONS`] and
/// object params that set none of the policy's own inputs (any `_` key).
pub fn parse(params: &Value) -> Result<(String, Value), RpcError> {
    let action = params.get("action").and_then(Value::as_str).unwrap_or_default();
    if !ACTIONS.contains(&action) {
        return Err(refused("unknown_action", format!("unknown action {action:?}")));
    }
    let inner = match params.get("params") {
        None | Some(Value::Null) => serde_json::Map::new(),
        Some(Value::Object(map)) => map.clone(),
        Some(_) => return Err(refused("invalid_arguments", "params must be an object")),
    };
    if let Some(key) = inner.keys().find(|key| key.starts_with('_')) {
        return Err(refused(
            "machine_call_denied",
            format!("a call never sets the policy's own inputs ({key})"),
        ));
    }
    Ok((action.to_owned(), Value::Object(inner)))
}

/// The policy a call runs under here: the hand's rules for a person's machine, over the home
/// folder and the temp folders, with no allow rules and no agent sessions.
#[cfg_attr(not(feature = "hub-carrier"), allow(dead_code))]
pub(crate) fn config() -> HandConfig {
    let mut roots = vec![std::env::temp_dir(), "/tmp".into()];
    roots.extend(dirs::home_dir());
    HandConfig {
        api: String::new(),
        hand: String::new(),
        key: String::new(),
        profile: Profile::Mac,
        roots,
        allow: Vec::new(),
        agent_policy: "deny-all".into(),
    }
}

fn hand_error(e: HandError) -> RpcError {
    RpcError::invalid_params(e.message).with_data(json!({"code": e.code, "detail": e.detail}))
}

/// Run one checked call under `cfg`; `consent` is read before and after the policy's decision.
/// The policy runs at the hand's `auto` level with the asking side's allow, so its hard denies
/// and its asks still hold; an ask is refused ([`NEEDS_OWNER`]).
#[cfg_attr(not(feature = "hub-carrier"), allow(dead_code))]
pub(crate) async fn run_with<C>(
    cfg: &HandConfig,
    action: &str,
    mut params: Value,
    consent: C,
) -> Result<Value, RpcError>
where
    C: Fn() -> Result<(), HandError>,
{
    let Some(fields) = params.as_object_mut().filter(|_| ACTIONS.contains(&action)) else {
        return Err(refused("unknown_action", format!("unknown action {action:?}")));
    };
    fields.insert("_level".to_owned(), json!("auto"));
    fields.insert("_verdict".to_owned(), json!("allow"));
    let agents = Agents::default();
    // No action of ACTIONS sends an event.
    let (sink, _events) = tokio::sync::mpsc::channel(1);
    let ctx = Ctx { cfg, agents: &agents, sink };
    let owner = |_summary: Value| async {
        Err(HandError::new(
            NEEDS_OWNER,
            "this touches credentials, startup files or a folder that holds them: only the \
             person at that machine may allow it, and it cannot be asked for from another \
             machine yet",
        ))
    };
    handle_with_consent(&ctx, action, &params, owner, consent).await.map_err(hand_error)
}

/// A call from another of the person's machines, as the machine-call service admitted it.
#[cfg(feature = "hub-carrier")]
pub(crate) async fn run_from(params: &Value) -> Result<Value, RpcError> {
    let (action, inner) = parse(params)?;
    run_with(&config(), &action, inner, || {
        crate::machine_record::require_joined_consent("control")
            .map_err(|_| HandError::new("consent_required", "local control consent is required"))?;
        let consent = crate::cli::cloud_join::consent_status_for(&json!({}));
        let account = crate::cli::cloud_join::machine_user_id();
        crate::machine_call_service::decide(&consent, account.as_deref())
            .map_err(|(refusal, _)| HandError::new(&refusal.reason, refusal.message))
    })
    .await
}

#[cfg(test)]
#[path = "machine_files_tests.rs"]
mod tests;
