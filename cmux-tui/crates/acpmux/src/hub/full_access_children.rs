//! Part of `Hub`; see `hub/mod.rs`. A chat an agent in full access starts runs in full access
//! wherever it is placed, with no new prompt; a chat a starter below full access starts never
//! names more than its starter has (Leo, 2026-11-07: "if you're already starting one in that, it
//! doesn't make sense to suddenly start gating. if you're on auto, sure, these can be perms
//! checks").
//!
//! The starter is the session the connection proved with its caller token (`Conn::caller`,
//! `start_gate.rs`), read here from its record: never a request value, so a client cannot claim
//! full access. It runs in full access when its harness does ([`Hub::caller_access`] is
//! `Access::Full`: its mode, its argv) and `sessions.allowFullAccess` allows it here.
//!
//! - This machine: a start that names a full-access mode of another family is granted to such a
//!   starter (`start_gate.rs` `start_mode_check`), as a start that names none already inherits it
//!   (`start_mode.rs` "Inherit").
//! - Another machine, a Cloud machine included: this daemon forwards the start with
//!   `policy: approve-all` when it names no policy ([`Hub::forward_starter_policy`]); before
//!   this the peer's remote guard started it under `ask` and the chat prompted. A peer refuses
//!   approve-all for reasons of its own (it serves this machine as a remote client, its owner
//!   turned full access off): the refusal stands and says so ([`refused_by`]), never a quiet
//!   asking chat.
//! - A starter below full access that names a policy wider than its own effective one is refused
//!   ([`Hub::named_policy_check`]). Before this a `session/new` policy was open to any unix
//!   socket client (`person.rs`); a start with no proven caller (the CLI outside any chat, the
//!   app) still is.

use super::*;
use cmux_json::JsonSet as _;

/// A peer's `error.data.reason` for a policy it takes only from a peer (`remote_guard/hint.rs`).
const POLICY_REFUSED: &str = "remote.policy_refused";

impl Hub {
    /// Whether proven caller session `caller` runs in full access now (module docs).
    pub(crate) fn starter_runs_full_access(&self, caller: Option<&str>) -> bool {
        let Some(s) = caller.and_then(|id| self.resolve(id).ok().filter(|s| s.id == id)) else {
            return false;
        };
        self.full_access_allowed()
            && self.caller_access(&s.meta()) == super::subsession_guard::Access::Full
    }

    /// A `session/new` from proven caller `caller` that names a policy wider than the caller's
    /// effective one (its own, else the daemon default), while the caller is not in full
    /// access, needs the person (module docs). A start with no proven caller, or that names no
    /// policy, passes.
    pub(super) async fn named_policy_check(
        &self,
        caller: Option<&str>,
        params: &Value,
    ) -> Result<(), RpcError> {
        let Some(named) = named_policy(params) else { return Ok(()) };
        let Some(s) = caller.and_then(|id| self.resolve(id).ok().filter(|s| s.id == id)) else {
            return Ok(());
        };
        if self.starter_runs_full_access(caller) {
            return Ok(());
        }
        let own = self.effective_policy(&s.meta()).await;
        if super::person::breadth(named) <= super::person::breadth(own) {
            return Ok(());
        }
        Err(RpcError::new(
            -32000,
            format!(
                "policy {named} is wider than this session's own ({own}), which is not in full access: start the chat with --policy {own} or narrower, or ask the person to raise it in cmux NEXT"
            ),
        )
        .with_data(json!({"reason": super::person::REASON, "policy": named.to_string(),
            "starterPolicy": own.to_string()})))
    }

    /// The `session/new` `p` this daemon forwards to a peer for proven caller `caller`: when the
    /// caller runs in full access and `p` names no policy, `p` asks for approve-all.
    pub(crate) fn forward_starter_policy(&self, caller: Option<&str>, p: &mut Value) {
        if !named_policy_value(p) && self.starter_runs_full_access(caller) {
            let all = PermissionPolicy::ApproveAll.to_string();
            p.set_path(&["_meta", "acpmux", "policy"], json!(all));
        }
    }
}

/// Whether `session/new` params name a policy (`policy` or `_meta.acpmux.policy`), parsed or not.
fn named_policy_value(params: &Value) -> bool {
    params.get("policy").is_some_and(|v| !v.is_null())
        || params.pointer("/_meta/acpmux/policy").is_some_and(|v| !v.is_null())
}

/// The policy `session/new` params name, when it parses (the handler refuses one that does not).
fn named_policy(params: &Value) -> Option<PermissionPolicy> {
    params
        .pointer("/_meta/acpmux/policy")
        .and_then(Value::as_str)
        .or_else(|| params.get("policy").and_then(Value::as_str))
        .and_then(|p| p.parse().ok())
}

/// Peer `host`'s refusal `e` of a forwarded `session/new` `p` that asks for approve-all
/// ([`Hub::forward_starter_policy`], or the caller's own `--policy`), said plainly: the host's
/// own rule refused full access, and nothing started asking instead. `data.reason` stays the
/// peer's; `data.fullAccessRefusedBy` names the host. Any other error is `e` unchanged.
pub(crate) fn refused_by(host: &str, p: &Value, e: RpcError) -> RpcError {
    if named_policy(p) != Some(PermissionPolicy::ApproveAll) {
        return e;
    }
    let reason = e.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str);
    let why = match reason {
        Some(POLICY_REFUSED) => "it serves this machine as a remote client, not as a peer",
        Some("full_access_off") => {
            "its owner turned full access off there (sessions.allowFullAccess)"
        }
        _ => return e,
    };
    let message = format!(
        "{host} does not start chats in full access for this machine: {why}. Nothing was started there; to run the chat asking, start it with --policy ask ({})",
        e.message
    );
    let mut data = match e.data {
        Some(Value::Object(o)) => Value::Object(o),
        _ => json!({}),
    };
    data.set("fullAccessRefusedBy", json!(host));
    RpcError::new(e.code, message).with_data(data)
}
