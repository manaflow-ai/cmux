//! The approve-all an older daemon gave on a `vmHost` machine, turned back to ask.
//!
//! From 2026-10-20 until #26227, a session the owner's peer daemon started with no policy on a
//! `vmHost` machine (not a Mac) got approve-all (`requests.rs`, `vm_host_peer_approves`) with
//! nobody asking for it. #26227 made `Hub::vm_host` false, so no new session gets it, but a
//! session that got it kept that saved policy: it respawns inside the sandbox and still approves
//! everything.
//!
//! The store kept no record of who set a policy, only the policy and `remoteOrigin` (the chat was
//! started over the WebSocket listener, which the vmHost path required; a fork, a side chat, a
//! sub-session and a moved-in chat keep it). Its log is no proof: the vmHost path and an owner's
//! own `_acpmux/set_policy` write the same `policy` record, and an older peer could name
//! approve-all in its session/new request, which leaves none. claude-sr2, 2026-10-27: "Fail
//! closed: if a grant could be either, clear it. The owner can re-grant with one click; a silent
//! approve-all inside a team VM can't be undone."
//!
//! So the rule ([`clear_legacy_grant`]): a remote-origin chat whose own policy is approve-all and
//! whose `policySource` is absent is set to `ask` (`policySource: cleared`). On every platform: a
//! chat moved in from a vmHost machine carries its grant to a Mac too. A chat started on this
//! machine (not remote-origin) is kept: the vmHost path never touched one.
//!
//! When: as the session list loads (`Hub::load_from_store`), before any permission request is
//! answered, and as a moved-in chat is imported (`transfer_guard.rs`). Every policy this daemon
//! writes says who set it (`policySource`: `set` for a request, a default or acpmux, `vmHost` for
//! the vmHost path), so the rule matches only what an older daemon saved: running it again
//! changes nothing, and an approve-all the owner sets after the upgrade is never cleared. A chat
//! the rule cleared whose agent still runs in a mode that never asks is moved back to its
//! policy's mode once its host is adopted (`hold_policies_again`, `daemon.rs`), or at its next
//! start (`hold_policy_mode`).

use crate::config::PermissionPolicy;
use crate::store::SessionMeta;

/// `policySource` values (`SessionMeta::policy_source`). `set`: a request named the policy
/// (session/new, `_acpmux/set_policy`), or a default, a preset or acpmux from another chat's (a
/// fork, a handoff target, a side chat), on a daemon that gives no chat approve-all on its own.
pub(crate) const SET: &str = "set";
/// The approve-all a vmHost machine gives its owner's peer chats (`vm_host_peer_approves`, off
/// until an attested source exists).
pub(crate) const VM_HOST: &str = "vmHost";
/// An older daemon's approve-all with no source, turned back to ask ([`clear_legacy_grant`]).
pub(crate) const CLEARED: &str = "cleared";

/// Turns `meta`'s approve-all to ask when an older daemon could have given it on a vmHost
/// machine (module docs). Returns whether it changed `meta`.
pub(crate) fn clear_legacy_grant(meta: &mut SessionMeta) -> bool {
    let approve_all = meta.permission_policy.as_deref().and_then(|p| p.parse().ok())
        == Some(PermissionPolicy::ApproveAll);
    if !meta.remote_origin || !approve_all || meta.policy_source.is_some() {
        return false;
    }
    meta.permission_policy = Some(PermissionPolicy::Ask.to_string());
    meta.policy_source = Some(CLEARED.to_owned());
    tracing::warn!(
        session = %meta.id,
        "an approve-all an older daemon saved with no source (it could be vmHost's) is now ask"
    );
    true
}

#[cfg(test)]
#[path = "vm_host_grants_tests.rs"]
mod tests;
