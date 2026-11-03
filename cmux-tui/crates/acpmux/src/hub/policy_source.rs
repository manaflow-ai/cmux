//! Part of `Hub`; see `hub/mod.rs`. Setting a chat's own permission policy, with who set it
//! (`SessionMeta::policy_source`), and the approve-all an older daemon gave on a `vmHost` machine,
//! turned back to ask.
//!
//! From 2026-10-20 until #26227, a session the owner's peer daemon started with no policy on a
//! `vmHost` machine (not a Mac) got approve-all (`requests.rs`, `vm_host_peer_approves`) with
//! nobody asking for it. #26227 made `Hub::vm_host` false, so no new session gets it, but a
//! session that got it kept that saved policy: it respawns inside the sandbox and still approves
//! everything. Chats taken from it kept it too: a fork, a sub-session and a side chat stay
//! remote-origin, but a handoff asked for on this machine's socket is local, and a chat an agent
//! started inherits its starter's policy (`lifecycle.rs`) with no link back when it asked for
//! no parent.
//!
//! The store kept no record of who set a policy. Its log is no proof either: the vmHost path and
//! an owner's own `_acpmux/set_policy` write the same `policy` record, and an older peer could
//! name approve-all in its session/new request, which leaves none. claude-sr2, 2026-10-27: "Fail
//! closed: if a grant could be either, clear it. The owner can re-grant with one click; a silent
//! approve-all inside a team VM can't be undone."
//!
//! So the rule ([`settle_grant`]): an approve-all with no `policySource` asks
//! (`policySource: cleared`) when it could be vmHost's:
//! - every one, on a machine whose daemon could have given it ([`Hub::could_have_had_vm_host`]:
//!   not a Mac, and its config.json names `vmHost`, is missing (it may have named it), or cmux
//!   created it as a VM): there a chat with no link back can still have inherited it;
//! - every one a chat imported from another machine carries (`transfer.rs` `import_into`, and
//!   the guarded receive in `transfer_guard.rs`), and a `vmHost` one too: that machine's VM was
//!   its sandbox, this one is not;
//! - elsewhere, one a remote connection started, a handoff target's (its tag or a handoff
//!   record), or one taken from another chat (`parentId`, `subsession`, `lineage`) that could
//!   have it or is not here to tell.
//!
//! Any other is kept, as `policySource: set`. The rule runs as the session list loads
//! (`Hub::load_from_store`), before any permission request is answered, and as a chat is
//! imported. Every policy this daemon writes says who set it ([`SET`], [`VM_HOST`]), and the
//! rule settles every approve-all it reads, so it never matches twice: an approve-all the owner
//! sets after the upgrade is never cleared. A cleared chat also loses the mode acpmux set
//! (`mode_set_by_cmux`), which approved by itself in a mode that never asks.
//!
//! A cleared chat whose agent host survived the restart ([`CLEARED_HOST`]) may run in a mode
//! that never asks, or hold requests the old grant would answer: that host is ended before this
//! daemon reaches it, and is never adopted ([`Hub::end_cleared_host`], at adoption
//! ([`Hub::ends_before_adoption`]) and before any start ([`Hub::refuse_cleared_host`])). The chat goes idle; its next
//! start asks, in its policy's mode (`hold_policy_mode`, and OpenCode's ask config at spawn). A
//! host whose end is not proven (it did not end, or the host records cannot be read) is not
//! adopted, and the chat is refused until it is. Once it ended, the chat is [`CLEARED`]; a daemon
//! that died before that ends it at its next start.

use super::*;
use std::collections::{HashMap, HashSet};

/// `policySource`: a request named the policy (session/new, `_acpmux/set_policy`), or a default,
/// a preset or acpmux from another chat's (a fork, a handoff target, a side chat), on a daemon
/// that gives no chat approve-all on its own; or an older daemon's approve-all the rule kept. A
/// string, so a daemon that knows fewer values still reads the session.
pub(super) const SET: &str = "set";
/// `policySource`: the approve-all a vmHost machine gives its owner's peer chats
/// (`vm_host_peer_approves`, off until an attested source exists).
pub(super) const VM_HOST: &str = "vmHost";
/// `policySource`: an older daemon's approve-all, turned back to ask ([`settle_grant`]).
pub(super) const CLEARED: &str = "cleared";
/// `policySource`: [`CLEARED`], with the agent host that ran under the grant still to end.
pub(super) const CLEARED_HOST: &str = "clearedHost";

/// Settles an approve-all an older daemon saved with no source: ask when it `could_be_vm_host`,
/// else kept as [`SET`]. Returns whether it changed `meta`.
pub(super) fn settle_grant(meta: &mut SessionMeta, could_be_vm_host: bool) -> bool {
    let approve_all = meta.permission_policy.as_deref().and_then(|p| p.parse().ok())
        == Some(PermissionPolicy::ApproveAll);
    if !approve_all || meta.policy_source.is_some() {
        return false;
    }
    let source = if could_be_vm_host {
        tracing::warn!(session = %meta.id, "an older daemon's approve-all that could be vmHost's is now ask");
        meta.permission_policy = Some(PermissionPolicy::Ask.to_string());
        meta.mode_set_by_cmux = None;
        CLEARED
    } else {
        SET
    };
    meta.policy_source = Some(source.to_owned());
    true
}

/// The chats `meta` was taken from: its fork parent, the chat that started it as a sub-session,
/// and the agent's chat that started it.
fn taken_from(meta: &SessionMeta) -> impl Iterator<Item = &str> {
    let parent = meta.parent_id.as_deref();
    let started_by = meta.subsession.as_ref().map(|s| s.started_by.as_str());
    parent.into_iter().chain(started_by).chain(meta.lineage.as_ref().map(|l| l.parent.as_str()))
}

/// [`settle_grant`] for a chat imported from another machine, before the import changes it:
/// none of the chats it was taken from is here to tell, nor what set an approve-all of an older
/// daemon; and a vmHost grant was for that machine's VM.
pub(super) fn settle_imported_grant(meta: &mut SessionMeta) -> bool {
    if meta.policy_source.as_deref() == Some(VM_HOST) {
        meta.policy_source = None;
    }
    settle_grant(meta, true)
}

/// The ids among `metas` whose approve-all could be vmHost's (module docs). A chat taken from
/// one that is not listed, or from a loop of chats, could be.
fn could_be_vm_host(metas: &[SessionMeta], targets: &HashSet<String>) -> HashSet<String> {
    let by_id: HashMap<&str, &SessionMeta> = metas.iter().map(|m| (m.id.as_str(), m)).collect();
    let mut known: HashMap<&str, bool> = HashMap::new();
    fn visit<'a>(
        id: &'a str,
        by_id: &HashMap<&'a str, &'a SessionMeta>,
        targets: &HashSet<String>,
        known: &mut HashMap<&'a str, bool>,
    ) -> bool {
        if let Some(&could) = known.get(id) {
            return could;
        }
        let Some(meta) = by_id.get(id) else { return true };
        // On the path now: a loop back to it could be.
        known.insert(id, true);
        let could = meta.remote_origin
            || targets.contains(id)
            || meta.tags.contains_key(super::handoff::TARGET_TAG)
            || taken_from(meta).any(|p| visit(p, by_id, targets, known));
        known.insert(id, could);
        could
    }
    metas
        .iter()
        .filter(|m| visit(&m.id, &by_id, targets, &mut known))
        .map(|m| m.id.clone())
        .collect()
}

impl Hub {
    /// Sets `session`'s own policy; its mode follows (`follow_policy`), so a policy acpmux sets
    /// itself (an aside's, a handoff target's) holds as one a client sets does.
    pub async fn set_policy(self: &Arc<Self>, session: &Arc<Session>, policy: PermissionPolicy) {
        // A failed save is logged there; no request waits for this one.
        let _ = self.set_policy_from(session, policy, SET).await;
    }

    /// [`Hub::set_policy`] for `_acpmux/set_policy`: answered only once the policy is saved
    /// (`meta_save.rs`).
    pub(crate) async fn set_policy_answered(
        self: &Arc<Self>,
        session: &Arc<Session>,
        policy: PermissionPolicy,
    ) -> Result<(), RpcError> {
        self.set_policy_from(session, policy, SET).await
    }

    /// The approve-all a vmHost machine gives a chat its owner's peer daemon starts with no
    /// policy (`requests.rs`).
    pub(crate) async fn grant_vm_host_approve_all(self: &Arc<Self>, session: &Arc<Session>) {
        // A failed save is logged there.
        let _ = self.set_policy_from(session, PermissionPolicy::ApproveAll, VM_HOST).await;
    }

    /// A [`CLEARED_HOST`] chat keeps that source through a policy write: its old host still has to
    /// end before anything reaches it. Any source, `cleared` included, keeps an approve-all from
    /// [`settle_grant`], so the owner's grant made meanwhile holds once that host has ended.
    async fn set_policy_from(
        self: &Arc<Self>,
        session: &Arc<Session>,
        policy: PermissionPolicy,
        source: &str,
    ) -> Result<(), RpcError> {
        self.permission_policy_changed(session, |m| {
            m.permission_policy = Some(policy.to_string());
            if m.policy_source.as_deref() != Some(CLEARED_HOST) {
                m.policy_source = Some(source.to_owned());
            }
        });
        self.append(session, "mux", "policy", json!({"policy": policy.to_string()}));
        let saved = self.save_meta_answered(session);
        self.follow_policy(session).await;
        if policy == PermissionPolicy::ApproveAll {
            self.approve_pending_tools(session).await;
        }
        saved
    }

    /// Whether this machine's daemon could have given vmHost's approve-all (module docs): never
    /// on a Mac; elsewhere when its config names `vmHost` (a `false` may have followed a `true`),
    /// or there is no config.json (one may have named it), or cmux created it as a VM (on by
    /// default there). A config this cannot read could.
    fn could_have_had_vm_host(&self) -> bool {
        let configured =
            self.config.try_read().map_or(true, |c| c.vm_host.is_some() || c.file_missing);
        !cfg!(target_os = "macos") && (configured || self.cmux_vm())
    }

    /// [`settle_grant`] on every session the store lists, each saved when it changed. A cleared
    /// chat whose agent host may run (or when the host records cannot be read) is
    /// [`CLEARED_HOST`].
    pub(super) fn settle_legacy_grants(&self, metas: &mut [SessionMeta]) {
        if !metas.iter().any(|m| m.policy_source.is_none() && m.permission_policy.is_some()) {
            return;
        }
        let everyone = self.could_have_had_vm_host();
        let could_be = could_be_vm_host(metas, &self.handoffs.target_ids());
        let hosted = Self::read_live_host_sessions();
        for meta in metas.iter_mut() {
            if !settle_grant(meta, everyone || could_be.contains(&meta.id)) {
                continue;
            }
            if meta.policy_source.as_deref() == Some(CLEARED)
                && hosted.as_ref().is_none_or(|h| h.contains(&meta.id))
            {
                meta.policy_source = Some(CLEARED_HOST.to_owned());
            }
            if let Err(e) = self.store.save(meta) {
                tracing::warn!(session = %meta.id, "save the settled grant failed: {e}");
            }
        }
    }

    /// A [`CLEARED_HOST`] chat's agent host is ended, never adopted (module docs). Called before a
    /// host is adopted and before an agent starts, under the chat's spawn lock. Returns whether the
    /// chat was one: its host has then ended, or is marked unadoptable.
    pub(super) async fn end_cleared_host(&self, session: &Arc<Session>) -> bool {
        if session.meta().policy_source.as_deref() != Some(CLEARED_HOST) {
            return false;
        }
        self.end_unadopted_host(session).await;
        if Self::host_record_gone(&session.id) {
            session.meta.lock().unwrap_or_else(|e| e.into_inner()).policy_source =
                Some(CLEARED.to_owned());
            self.append(session, "mux", "grant_cleared", json!({"hostEnded": true}));
            self.save_meta(session);
        } else {
            tracing::warn!(session = %session.id, "the agent host of a cleared grant did not end; it is not adopted");
            self.mark_unadoptable(session, json!({"reason": "grant_cleared"}));
        }
        true
    }

    /// Whether adoption skips `session`'s host (`hosts.rs` `adopt_agent_hosts`): a
    /// [`CLEARED_HOST`] chat's, which is ended, or one MDM's off ends (`end_if_runs_full_access`).
    /// A chat a prompt reaches first is never adopted with it either ([`Hub::refuse_cleared_host`]
    /// runs before `readopt`).
    pub(super) async fn ends_before_adoption(&self, session: &Arc<Session>, off: bool) -> bool {
        use super::full_access_bound::FullAccessEnd;
        self.end_cleared_host(session).await
            || self.end_if_runs_full_access(session, off).await != FullAccessEnd::NotInFullAccess
    }

    /// Before any agent start, cold or pooled (`reach_or_start`): a [`CLEARED_HOST`] chat's old
    /// host is ended first ([`Hub::end_cleared_host`]), and the chat is refused while its end is
    /// not proven (host records that cannot be read prove nothing). No start runs beside it, and
    /// none leaves the chat `clearedHost`, so a later restart adopts the host it starts.
    pub(super) async fn refuse_cleared_host(&self, session: &Arc<Session>) -> Result<(), RpcError> {
        if !self.end_cleared_host(session).await
            || session.meta().policy_source.as_deref() != Some(CLEARED_HOST)
        {
            return Ok(());
        }
        Err(RpcError::internal(
            "this chat's agent host ran under an approve-all that is now cleared and is not proven ended; the chat starts again once it is",
        ))
    }
}

#[cfg(test)]
#[path = "policy_source_tests.rs"]
mod tests;
