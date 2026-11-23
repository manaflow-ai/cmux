//! Part of `Hub`; see `hub/mod.rs`. A restricted chat: read-only work in a folder the person
//! chose not to trust.
//!
//! Leo: "even if you don't trust something, like you should still be able to use it". Don't
//! trust used to end the chat's work in that folder (`server/trust_gate.rs` refuses every
//! prompt with `trust.untrusted`); the pane's only way on was a chat with no folder. A restricted
//! chat is the other way on: the same folder, with what Don't trust is about kept off.
//!
//! `session/new` takes `_meta.acpmux.restricted: true` (`requested`). The chat then:
//! - runs Claude Code with `--setting-sources user` and `--strict-mcp-config` at every start, a
//!   resume or respawn too (`claude_args`): the folder's own `.claude/settings*.json` (its hooks,
//!   its permission rules, its env) and its `.mcp.json` servers never load, so nothing the
//!   folder ships runs as code;
//! - holds the `review` policy (`POLICY`): reads, searches and read-only shell commands run,
//!   every edit and every other command is denied by the PreToolUse gate (`policy_gate.rs`), in
//!   every mode;
//! - keeps that policy: `_acpmux/set_policy` refuses anything wider (`refuse_widening`).
//!
//! Only on acpmux's own Claude Code backend (`HarnessKind::ClaudeStdio`, `kept_by`): it is the
//! one whose project config acpmux can keep from loading. Codex reads its project config by its
//! own trust record, which acpmux's Don't trust does not change, so a restricted Codex chat
//! would not be what it says; its start is refused with `restricted.unsupported`, and the pane
//! offers the folder-free chat instead.
//!
//! The trust gate lets a restricted chat's `session/new` and `session/prompt` through a folder
//! answered Don't trust (`trust.untrusted`), from the app's pane only (a Web client's folder
//! still needs a person's Trust). A fork, a side session, a handoff, a mode, tool, folder or
//! MCP change start or widen an agent beyond this chat and stay refused there.

use super::*;
use crate::config::PermissionPolicy;

/// The `_meta.acpmux` field, and the session/new answer's `_meta.acpmux` flag that it was kept.
pub(crate) const FIELD: &str = "restricted";

/// The policy a restricted chat holds: the read-only preset.
pub(crate) const POLICY: PermissionPolicy = PermissionPolicy::Review;

/// Whether `meta` (the request's `_meta.acpmux`) asks for a restricted chat. Absent, null or
/// false: no; anything but a boolean is refused.
pub(crate) fn requested(meta: Option<&Value>) -> Result<bool, RpcError> {
    match meta.and_then(|m| m.get(FIELD)) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(b)) => Ok(*b),
        Some(_) => Err(RpcError::invalid_params(format!("{FIELD}: must be true or false"))
            .with_data(json!({"reason": "restricted.invalid"}))),
    }
}

/// The policy a restricted start runs under: `POLICY`, or a narrower one it named (deny-all).
/// Any other policy it names is refused, so a caller cannot widen it at the start.
pub(crate) fn start_policy(
    asked: Option<PermissionPolicy>,
) -> Result<Option<PermissionPolicy>, RpcError> {
    match asked {
        None => Ok(Some(POLICY)),
        Some(p) if narrow(p) => Ok(Some(p)),
        Some(p) => Err(widening(p)),
    }
}

/// A policy at most as wide as `POLICY`.
fn narrow(policy: PermissionPolicy) -> bool {
    matches!(policy, PermissionPolicy::Review | PermissionPolicy::DenyAll)
}

fn widening(policy: PermissionPolicy) -> RpcError {
    RpcError::invalid_params(format!(
        "restricted.policy: a restricted chat keeps the {POLICY} policy, not {policy}; trust the \
         folder to work in it fully"
    ))
    .with_data(json!({"reason": "restricted.policy", "policy": policy.to_string()}))
}

/// `_acpmux/set_policy` on `meta`'s chat: a restricted chat refuses a policy wider than `POLICY`.
pub(crate) fn refuse_widening(
    meta: &crate::store::SessionMeta,
    policy: PermissionPolicy,
) -> Result<(), RpcError> {
    if meta.restricted && !narrow(policy) { Err(widening(policy)) } else { Ok(()) }
}

/// Whether a chat on harness `profile` can be restricted: acpmux's Claude Code backend only.
pub(crate) fn kept_by(profile: &HarnessProfile) -> bool {
    profile.kind == crate::config::HarnessKind::ClaudeStdio
}

/// The refusal for a restricted start on a harness that cannot keep it.
pub(crate) fn unsupported(harness: &str) -> RpcError {
    RpcError::invalid_params(format!(
        "restricted.unsupported: {harness} cannot run read-only in a folder you did not trust; \
         continue without the folder, or trust it"
    ))
    .with_data(json!({"reason": "restricted.unsupported", "harness": harness}))
}

/// The Claude Code args a restricted chat's every start gets; none for any other chat.
pub(crate) fn claude_args(meta: &crate::store::SessionMeta) -> Vec<String> {
    if !meta.restricted {
        return Vec::new();
    }
    ["--setting-sources", "user", "--strict-mcp-config"].map(str::to_owned).into()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn requested_reads_a_boolean_only() {
        assert!(!requested(None).unwrap());
        assert!(!requested(Some(&json!({}))).unwrap());
        assert!(!requested(Some(&json!({"restricted": null}))).unwrap());
        assert!(!requested(Some(&json!({"restricted": false}))).unwrap());
        assert!(requested(Some(&json!({"restricted": true}))).unwrap());
        let e = requested(Some(&json!({"restricted": "yes"}))).unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], "restricted.invalid");
    }

    #[test]
    fn a_restricted_start_holds_review_or_narrower() {
        assert_eq!(start_policy(None).unwrap(), Some(PermissionPolicy::Review));
        assert_eq!(
            start_policy(Some(PermissionPolicy::DenyAll)).unwrap(),
            Some(PermissionPolicy::DenyAll)
        );
        for wide in [
            PermissionPolicy::Ask,
            PermissionPolicy::ApproveReads,
            PermissionPolicy::ApproveEdits,
            PermissionPolicy::ApproveAll,
        ] {
            let e = start_policy(Some(wide)).unwrap_err();
            assert_eq!(e.data.unwrap()["reason"], "restricted.policy", "{wide}");
        }
    }

    fn meta() -> crate::store::SessionMeta {
        serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "r", "name": "r", "harness": "claude",
            "cwd": "/tmp", "status": "idle", "createdAt": 1, "updatedAt": 2
        }))
        .unwrap()
    }

    #[test]
    fn a_restricted_chat_refuses_a_wider_policy() {
        let mut meta = meta();
        assert!(refuse_widening(&meta, PermissionPolicy::ApproveAll).is_ok());
        meta.restricted = true;
        assert!(refuse_widening(&meta, PermissionPolicy::ApproveAll).is_err());
        assert!(refuse_widening(&meta, PermissionPolicy::Ask).is_err());
        assert!(refuse_widening(&meta, PermissionPolicy::Review).is_ok());
        assert!(refuse_widening(&meta, PermissionPolicy::DenyAll).is_ok());
    }

    #[test]
    fn only_a_restricted_chat_gets_the_args() {
        let mut meta = meta();
        assert!(claude_args(&meta).is_empty());
        meta.restricted = true;
        assert_eq!(claude_args(&meta), ["--setting-sources", "user", "--strict-mcp-config"]);
    }
}
