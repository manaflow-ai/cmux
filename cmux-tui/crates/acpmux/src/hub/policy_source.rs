//! Part of `Hub`; see `hub/mod.rs`. Setting a chat's own permission policy, with who set it
//! (`SessionMeta::policy_source`), and the approve-all an older daemon gave on a `vmHost` machine,
//! turned back to ask.
//!
//! From 2026-10-20 until #26227, a session the owner's peer daemon started with no policy on a
//! `vmHost` machine (not a Mac) got approve-all (`requests.rs`, `vm_host_peer_approves`) with
//! nobody asking for it. #26227 made `Hub::vm_host` false, so no new session gets it, but a
//! session that got it kept that saved policy: it respawns inside the sandbox and still approves
//! everything. Chats taken from it kept it too: a fork, a sub-session and a side chat stay
//! remote-origin, but a handoff asked for on this machine's socket, and a chat an agent started
//! (its policy inherited from its starter, `start_mode.rs`), are local.
//!
//! The store kept no record of who set a policy. Its log is no proof either: the vmHost path and
//! an owner's own `_acpmux/set_policy` write the same `policy` record, and an older peer could
//! name approve-all in its session/new request, which leaves none. claude-sr2, 2026-10-27: "Fail
//! closed: if a grant could be either, clear it. The owner can re-grant with one click; a silent
//! approve-all inside a team VM can't be undone."
//!
//! So the rule ([`settle_grant`]): an approve-all with no `policySource` asks
//! (`policySource: cleared`) when it could be vmHost's: the chat was started by a remote
//! connection, it is a handoff target (its tag or a handoff record), or it was taken from another
//! chat (`parentId`, `subsession`, `lineage`) that could have it or is not here to tell. Any other
//! is a chat this machine started for its person: it is kept, as `policySource: set`.
//!
//! When: as the session list loads (`Hub::load_from_store`), before any permission request is
//! answered, and as a chat is imported (`transfer.rs` `import_into`, and the guarded receive in
//! `transfer_guard.rs`, before either changes its origin, links or tags; a chat from another
//! machine has no parent here to tell). Every policy this daemon writes says who set it ([`SET`],
//! [`VM_HOST`]), and the rule settles every approve-all it reads, so it never matches twice: an
//! approve-all the owner sets after the upgrade is never cleared. A cleared chat whose agent
//! survived the restart in a mode that never asks is moved to its policy's mode before any
//! prompt reaches it, and its agent is stopped when that fails ([`Hub::hold_cleared_grants`]).

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
/// none of the chats it was taken from is here to tell.
pub(super) fn settle_imported_grant(meta: &mut SessionMeta) -> bool {
    let could_be = meta.remote_origin
        || meta.tags.contains_key(super::handoff::TARGET_TAG)
        || taken_from(meta).next().is_some();
    settle_grant(meta, could_be)
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

    /// [`settle_grant`] on every session the store lists, each saved when it changed.
    pub(super) fn settle_legacy_grants(&self, metas: &mut [SessionMeta]) {
        if !metas.iter().any(|m| m.policy_source.is_none() && m.permission_policy.is_some()) {
            return;
        }
        let could_be = could_be_vm_host(metas, &self.handoffs.target_ids());
        for meta in metas.iter_mut() {
            if settle_grant(meta, could_be.contains(&meta.id))
                && let Err(e) = self.store.save(meta)
            {
                tracing::warn!(session = %meta.id, "save the settled grant failed: {e}");
            }
        }
    }

    /// Every chat whose grant was cleared and that is in a mode wider than its policy's (an agent
    /// that survived the restart, or a saved mode): its turn is cancelled and it moves to its
    /// policy's mode. A running agent that does not move in [`HOLD_WAIT`], or one this daemon did
    /// not reach, is stopped; a chat with no agent saves its policy's mode for its next start. At
    /// daemon start, after adoption and before any prompt to an adopted chat (`daemon.rs`).
    /// Returns how many agents it stopped.
    pub(crate) async fn hold_cleared_grants(self: &Arc<Self>) -> usize {
        let default = self.config.read().await.permission_policy;
        let mut stopped = 0;
        for s in self.sessions() {
            if s.meta().policy_source.as_deref() != Some(CLEARED) || !wider_than_policy(&s, default)
            {
                continue;
            }
            if s.turn().is_some()
                && let Err(e) = self.cancel(&s).await
            {
                tracing::warn!(session = %s.id, "the turn was not cancelled: {}", e.message);
            }
            let alive = match s.child.lock().await.clone() {
                Some(child) => child.is_alive().await,
                None => false,
            };
            if alive && tokio::time::timeout(HOLD_WAIT, self.follow_policy(&s)).await.is_err() {
                tracing::warn!(session = %s.id, "a cleared grant's agent did not change its mode in time");
            }
            if (alive || Self::host_record_live(&s.id)) && wider_than_policy(&s, default) {
                tracing::warn!(session = %s.id, "a cleared grant's agent stays in a mode that does not ask: stopped");
                self.append(&s, "mux", "grant_cleared", json!({"stopped": true}));
                self.stop_full_access_agent(&s).await;
                stopped += 1;
            }
            // No agent runs it now: its policy's mode is saved for the next start.
            if wider_than_policy(&s, default) {
                self.follow_policy(&s).await;
            }
        }
        stopped
    }
}

/// How long [`Hub::hold_cleared_grants`] waits for a running agent to change its mode.
const HOLD_WAIT: std::time::Duration =
    std::time::Duration::from_secs(if cfg!(test) { 1 } else { 10 });

/// Whether `session` runs in a mode that does not ask while its narrower policy has one that
/// does (`policy_mode.rs`).
fn wider_than_policy(session: &Session, default: PermissionPolicy) -> bool {
    let meta = session.meta();
    let Some(policy) = super::policy_mode::narrow_policy(&meta, default) else { return false };
    let family = crate::web_modes::family_of(&meta);
    let offered = super::start_mode::offered_ids(&meta);
    super::policy_mode::policy_mode(policy, &family, &offered).is_some()
        && crate::web_modes::mode_of(&meta)
            .is_some_and(|mode| !super::start_mode::asks(&mode, &family))
}

#[cfg(test)]
#[path = "policy_source_tests.rs"]
mod tests;
