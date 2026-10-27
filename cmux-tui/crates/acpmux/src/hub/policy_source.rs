//! Part of `Hub`; see `hub/mod.rs`. Setting a chat's own permission policy, with who set it
//! (`SessionMeta::policy_source`), and the approve-all an older daemon gave on a `vmHost` machine,
//! turned back to ask.
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
//! answered, and as a moved-in chat is imported (`transfer_guard.rs`, by the source's
//! `remoteOrigin`, before the import marks it remote-origin). Every policy this daemon
//! writes says who set it ([`SET`], [`VM_HOST`]), so the rule matches only what an older daemon
//! saved: running it again changes nothing, and an approve-all the owner sets after the upgrade
//! is never cleared. A chat the rule cleared whose agent still runs in a mode that never asks is
//! moved back to its policy's mode once its host is adopted (`hold_policies_again`, `daemon.rs`),
//! or at its next start (`hold_policy_mode`).

use super::*;

/// `policySource`: a request named the policy (session/new, `_acpmux/set_policy`), or a default,
/// a preset or acpmux from another chat's (a fork, a handoff target, a side chat), on a daemon
/// that gives no chat approve-all on its own. A string, so a daemon that knows fewer values still
/// reads the session.
pub(super) const SET: &str = "set";
/// `policySource`: the approve-all a vmHost machine gives its owner's peer chats
/// (`vm_host_peer_approves`, off until an attested source exists).
pub(super) const VM_HOST: &str = "vmHost";
/// `policySource`: an older daemon's approve-all, turned back to ask ([`clear_legacy_grant`]).
pub(super) const CLEARED: &str = "cleared";

/// Turns `meta`'s approve-all to ask when an older daemon could have given it on a vmHost
/// machine (module docs). Returns whether it changed `meta`.
pub(super) fn clear_legacy_grant(meta: &mut SessionMeta) -> bool {
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

impl Hub {
    /// Sets `session`'s own policy; its mode follows (`follow_policy`), so a policy acpmux sets
    /// itself (an aside's, a handoff target's) holds as one a client sets does.
    pub async fn set_policy(self: &Arc<Self>, session: &Arc<Session>, policy: PermissionPolicy) {
        self.set_policy_from(session, policy, SET).await;
    }

    /// The approve-all a vmHost machine gives a chat its owner's peer daemon starts with no
    /// policy (`requests.rs`).
    pub(crate) async fn grant_vm_host_approve_all(self: &Arc<Self>, session: &Arc<Session>) {
        self.set_policy_from(session, PermissionPolicy::ApproveAll, VM_HOST).await;
    }

    async fn set_policy_from(
        self: &Arc<Self>,
        session: &Arc<Session>,
        policy: PermissionPolicy,
        source: &str,
    ) {
        self.permission_policy_changed(session, |m| {
            m.permission_policy = Some(policy.to_string());
            m.policy_source = Some(source.to_owned());
        });
        self.append(session, "mux", "policy", json!({"policy": policy.to_string()}));
        self.save_meta(session);
        self.follow_policy(session).await;
    }

    /// [`clear_legacy_grant`] on a session the store lists, saved when it changed.
    pub(super) fn clear_legacy_grant_at_load(&self, meta: &mut SessionMeta) {
        if clear_legacy_grant(meta)
            && let Err(e) = self.store.save(meta)
        {
            tracing::warn!(session = %meta.id, "save the cleared grant failed: {e}");
        }
    }
}

#[cfg(test)]
#[path = "policy_source_tests.rs"]
mod tests;
