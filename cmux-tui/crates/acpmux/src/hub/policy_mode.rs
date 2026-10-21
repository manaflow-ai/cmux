//! Part of `Hub`; see `hub/mod.rs`. The harness mode a chat runs in while it
//! has its own acpmux permission policy (`session/new` `policy`, a harness
//! default's `policy`, `_acpmux/set_policy`) narrower than approve-all.
//!
//! acpmux's policy answers only the questions a harness asks
//! (`permissions.rs`). A harness in a mode that never asks (Codex
//! `agent-full-access` = approval never + danger-full-access, Claude Code
//! `bypassPermissions`) runs every tool with no question, so ask,
//! approve-reads, approve-edits and deny-all would hold nothing. Such a chat
//! starts in the harness's mode that asks before each change, never in the
//! start level (`start_mode.rs`), and a narrower policy set on a live chat
//! moves it there. The Codex bridge (cmux-codex-acp `config.rs` `MODES`):
//!
//! | policy | Codex mode | approval, sandbox |
//! | --- | --- | --- |
//! | ask, approve-reads, approve-edits | `ask` | untrusted, workspace-write: Codex asks before every command that is not a known-safe read and before every edit, and the policy answers each |
//! | deny-all | `read-only` | on-request, read-only: the sandbox refuses every write, and what it asks for the policy refuses |
//! | approve-all | the start level | |
//!
//! Claude Code asks in `default`. A harness with no mode that asks (opencode,
//! whose own settings on this machine decide what it asks, `web_modes.rs`;
//! pi; an ACP agent with no modes) cannot keep the policy: the chat logs
//! `policy_unenforced` so a client can say so.

use super::*;

/// The policy `meta` holds when it is narrower than approve-all.
pub(super) fn narrow_policy(meta: &SessionMeta) -> Option<PermissionPolicy> {
    meta.permission_policy
        .as_deref()
        .and_then(|p| p.parse().ok())
        .filter(|p| *p != PermissionPolicy::ApproveAll)
}

/// The mode a chat with `policy` (narrower than approve-all) runs in on a harness of `family`
/// offering `available` (module docs), or `None` when it offers no mode that asks.
pub(crate) fn policy_mode(
    policy: PermissionPolicy,
    family: &str,
    available: &[String],
) -> Option<String> {
    if family == "opencode" {
        return None;
    }
    if policy == PermissionPolicy::DenyAll && available.iter().any(|m| m == "read-only") {
        return Some("read-only".to_owned());
    }
    super::start_mode::asking_mode(family, available)
}

/// `meta`'s config options with the `mode` option set to `mode`, or `None` when it has none.
fn with_mode_option(meta: &SessionMeta, mode: &str) -> Option<Value> {
    let mut options = meta.config_options.clone()?;
    let option = options
        .as_array_mut()?
        .iter_mut()
        .find(|o| o.get("id").and_then(Value::as_str) == Some("mode"))?;
    option["currentValue"] = json!(mode);
    Some(options)
}

impl Hub {
    /// `session`'s policy mode when its policy is narrower than approve-all (module docs):
    /// `Some(None)` when the harness offers no mode that asks, `None` when the policy does not
    /// choose the mode.
    pub(super) fn mode_for_policy(
        meta: &SessionMeta,
        offered: &[String],
    ) -> Option<Option<String>> {
        let policy = narrow_policy(meta)?;
        Some(policy_mode(policy, &crate::web_modes::family_of(meta), offered))
    }

    /// After a chat's start mode is set: a policy narrower than approve-all that its harness's
    /// mode cannot keep is logged (`policy_unenforced`), with the mode it runs in.
    pub(super) fn note_unenforced_policy(&self, session: &Arc<Session>) {
        let meta = session.meta();
        let Some(policy) = narrow_policy(&meta) else { return };
        let family = crate::web_modes::family_of(&meta);
        let offered = super::start_mode::offered_ids(&meta);
        let current = crate::web_modes::mode_of(&meta);
        let wanted = policy_mode(policy, &family, &offered);
        if wanted.is_some() && wanted == current {
            return;
        }
        let reason = if family == "opencode" {
            crate::web_modes::OPENCODE_REFUSAL
        } else {
            crate::web_modes::NO_ASKING_MODE
        };
        tracing::warn!(session = %session.id, %policy, ?current, "the harness cannot keep this policy: {reason}");
        self.append(
            session,
            "mux",
            "policy_unenforced",
            json!({"policy": policy.to_string(), "modeId": current, "reason": reason}),
        );
    }

    /// `_acpmux/set_policy` made a live chat's policy narrower: a mode wider than the policy's
    /// (full access, or another mode that does not ask) moves to it. A mode as narrow (Claude
    /// Code `plan`) stays. Soft: a refusal is logged as `policy_unenforced`. A chat whose agent is
    /// not running keeps the mode for its next start.
    pub(crate) async fn follow_policy(self: &Arc<Self>, session: &Arc<Session>) {
        let meta = session.meta();
        let Some(policy) = narrow_policy(&meta) else { return };
        let Some(current) = crate::web_modes::mode_of(&meta) else { return };
        let family = crate::web_modes::family_of(&meta);
        let offered = super::start_mode::offered_ids(&meta);
        let Some(wanted) = policy_mode(policy, &family, &offered) else {
            self.note_unenforced_policy(session);
            return;
        };
        let asks = super::start_mode::asks(&current, &family);
        let narrower = wanted == "read-only" && policy == PermissionPolicy::DenyAll;
        if current == wanted || (asks && !narrower) {
            return;
        }
        // Under the spawn lock: a start in flight (`ensure_child`) either ends first and its
        // child is seen here, or starts after and reads the mode written here.
        let spawning = session.spawn_lock.lock().await;
        let child = session.child.lock().await.clone();
        // An agent in a host this daemon has not reached yet (adoption after a restart, a broken
        // link) runs too: `set_mode` reaches the host again (`readopt`), which replays nothing.
        let running = match child {
            Some(child) => child.is_alive().await,
            None => false,
        } || Self::host_record_live(&session.id);
        // A chat whose agent is not running starts none: its saved mode becomes the policy's,
        // which the agent's next start restores (`replay_config`, Claude's `--permission-mode`).
        // The Codex bridge also reports the mode as its `mode` config option, which
        // `replay_config` replays after the mode: it gets the policy's mode too.
        if !running {
            let mut writes = vec![ModeWrite::CurrentMode(json!(wanted))];
            if let Some(options) = with_mode_option(&session.meta(), &wanted) {
                writes.push(ModeWrite::ConfigOptions(options));
            }
            self.write_mode_state(session, writes);
            self.append(session, "mux", "mode", json!({"modeId": wanted}));
            self.save_meta(session);
            return;
        }
        // `set_mode` reaches the agent through `ensure_child`, which takes the spawn lock.
        drop(spawning);
        if let Err(e) = self.set_mode(session, &wanted).await {
            tracing::warn!(session = %session.id, mode = %wanted, "policy mode not set: {}", e.message);
        }
        self.note_unenforced_policy(session);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ids(modes: &[&str]) -> Vec<String> {
        modes.iter().map(|m| (*m).to_owned()).collect()
    }

    #[test]
    fn each_policy_maps_onto_a_codex_mode_that_keeps_it() {
        let codex = ids(&["ask", "read-only", "agent", "agent-full-access"]);
        for (policy, mode) in [
            (PermissionPolicy::Ask, "ask"),
            (PermissionPolicy::ApproveReads, "ask"),
            (PermissionPolicy::ApproveEdits, "ask"),
            (PermissionPolicy::DenyAll, "read-only"),
        ] {
            assert_eq!(policy_mode(policy, "codex", &codex).as_deref(), Some(mode), "{policy}");
        }
    }

    #[test]
    fn claude_asks_in_default_and_opencode_and_a_modeless_harness_cannot_keep_a_policy() {
        let claude = ids(&["default", "acceptEdits", "plan", "bypassPermissions"]);
        for policy in [
            PermissionPolicy::Ask,
            PermissionPolicy::ApproveReads,
            PermissionPolicy::ApproveEdits,
            PermissionPolicy::DenyAll,
        ] {
            assert_eq!(policy_mode(policy, "claude", &claude).as_deref(), Some("default"));
            assert_eq!(policy_mode(policy, "opencode", &ids(&["build", "plan", "ask"])), None);
            assert_eq!(policy_mode(policy, "pi", &[]), None);
        }
    }
}
