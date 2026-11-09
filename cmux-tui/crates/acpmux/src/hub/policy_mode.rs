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
//! The policy is held wherever it could slip:
//! - every agent start (`hold_policy_mode`, after `cap_full_access`): a
//!   preset's, a folder profile's or a profile-pinned chat, a handoff target
//!   that keeps its harness's mode, a resumed or forked chat;
//! - every policy change, acpmux's own included (an aside's deny-all, a
//!   handoff target narrowed to its source): `Hub::set_policy` follows it;
//! - deny-all or review as the default policy (`_acpmux/set_default_policy`),
//!   a lockdown: every chat without a policy of its own follows it. The
//!   defaults `ask`, `approve-reads` and `approve-edits` are not narrowing:
//!   chats start in full access by design (Lawrence 2026-10-14);
//! - a switch into a mode that does not ask is refused (`policy_mode`) while
//!   the harness has one that does (`refuse_wider_mode`), except the person's
//!   own pick, which first widens the chat's policy to approve-all
//!   (`person_widens_policy_for`; not under deny-all);
//! - the start mode preview (`_acpmux/start_mode`) answers the policy's mode.
//!
//! Claude Code asks in `default`, and acpmux's own Claude Code backend holds
//! the policy in any mode with its PreToolUse gate (`policy_gate.rs`). An ACP
//! agent can say it asks before every tool call (`agentCapabilities._meta.
//! acpmux.asksBeforeTools`, [`asks_before_tools`]), which acpmux believes only
//! from an agent it started from a harness entry of its own config
//! ([`claim_distrust`]; lead, 2026-11-09), and logs (`asks_before_tools_claim`).
//! A harness that keeps the
//! policy none of these ways (pi; an ACP agent with no modes that says
//! nothing) does not run under it (lead, 2026-11-08: a policy that silently
//! does not hold is a security bug): its start fails with
//! `policy_unenforceable` (`require_enforced`), however the chat got the
//! policy (asked for, a preset's or profile's, inherited, a lockdown), and a
//! live chat narrowed to it has its agent stopped (`policy_refused`).
//!
//! OpenCode is asked to ask instead (`opencode_ask.rs`): its agent starts
//! with `OPENCODE_CONFIG_CONTENT` whose `permission` is `{"*": "ask"}`, merged
//! into the config the profile or the environment already passes, so every
//! tool call reaches the policy as a `session/request_permission`. That holds
//! in the common case, not always: the user's agent files, the org or managed
//! config and the MDM plist come after it, and a later rule (an agent's own
//! `permission`, a key the global config lists after `"*"`) still wins
//! (`web_modes::REFUSED_FAMILIES`), so the chat still logs `policy_unenforced`.
//! The config is read at spawn: the marker that asks for it is part of the
//! session pool's key (no pooled agent started without it serves such a chat),
//! and a policy narrowed on a live chat whose agent was started without it
//! restarts that agent in the same conversation, as a route switch does
//! (`ask_opencode`): now when it is idle, else when its turn ends.

use super::*;

/// The policy `meta` holds when it is narrower than approve-all: its own, else the default policy
/// (`default`) when that is a lockdown, deny-all or review (module docs).
pub(super) fn narrow_policy(
    meta: &SessionMeta,
    default: PermissionPolicy,
) -> Option<PermissionPolicy> {
    narrower(meta.permission_policy.as_deref().and_then(|p| p.parse().ok()), default)
}

/// A chat's policy (`own`, else `default`) when it is narrower than approve-all (module docs).
pub(super) fn narrower(
    own: Option<PermissionPolicy>,
    default: PermissionPolicy,
) -> Option<PermissionPolicy> {
    let lockdown = matches!(default, PermissionPolicy::DenyAll | PermissionPolicy::Review);
    own.or(lockdown.then_some(default)).filter(|p| *p != PermissionPolicy::ApproveAll)
}

/// Whether `meta`'s agent, spawned from `profile`, is OpenCode asked to ask before every tool
/// (`opencode_ask.rs`): its policy is narrower than approve-all (module docs).
pub(super) fn asks_opencode(
    meta: &SessionMeta,
    profile: &HarnessProfile,
    default: PermissionPolicy,
) -> bool {
    is_opencode(meta, profile) && narrow_policy(meta, default).is_some()
}

/// Whether `meta`'s agent, spawned from `profile` (as configured, before it is resolved), is
/// OpenCode.
pub(super) fn is_opencode(meta: &SessionMeta, profile: &HarnessProfile) -> bool {
    crate::web_modes::family_of(meta) == "opencode"
        || crate::config::derive_family(&meta.harness, profile) == "opencode"
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
    // Codex names its read-only mode `read-only`, Muse Code (muse-acp) `readOnly`: either
    // refuses every write and shell command, so deny-all holds there.
    if policy == PermissionPolicy::DenyAll
        && let Some(mode) = available.iter().find(|m| *m == "read-only" || *m == "readOnly")
    {
        return Some(mode.clone());
    }
    super::start_mode::asking_mode(family, available)
}

/// The mode a Claude Code chat whose policy is narrower than approve-all spawns in when its saved
/// `mode` never asks: the policy's (module docs), else `None` to keep `mode`.
pub(super) fn claude_spawn_mode(
    meta: &SessionMeta,
    default: PermissionPolicy,
    mode: &str,
) -> Option<String> {
    let policy = narrow_policy(meta, default)?;
    if super::start_mode::asks(mode, "claude") {
        return None;
    }
    let offered: Vec<String> =
        crate::claude_stdio::MODES.iter().map(|(id, ..)| (*id).to_owned()).collect();
    policy_mode(policy, "claude", &offered)
}

/// The modes a new chat a remote connection started on the Codex bridge settles in, the start
/// first (`server/remote_guard.rs` `settle_web_session_mode`). A chat an enrolled peer of this
/// host started (`peer`) under deny-all (`policy`: the chat's narrower policy) settles in the
/// policy's own `read-only` (`policy_mode`) when the harness offers it: its sandbox refuses every
/// write and the network, and deny-all refuses every escalation out of it, where in `ask`
/// deny-all refuses every command Codex asks about, reads included. Anything else, the Web and
/// a paired device included, settles in the bridge's asking modes
/// (`web_modes::BRIDGE_ASKING_MODES`).
pub(crate) fn bridge_settle_modes(
    peer: bool,
    policy: Option<PermissionPolicy>,
    offered: &[String],
) -> Vec<String> {
    const READ_ONLY: &str = "read-only";
    if peer && policy == Some(PermissionPolicy::DenyAll) && offered.iter().any(|m| m == READ_ONLY) {
        return vec![READ_ONLY.to_owned()];
    }
    crate::web_modes::BRIDGE_ASKING_MODES.iter().map(|m| (*m).to_owned()).collect()
}

/// `meta`'s config options with the `mode` option set to `mode`, or `None` when it has none.
fn with_mode_option(meta: &SessionMeta, mode: &str) -> Option<Value> {
    let mut options = meta.config_options.as_deref()?.clone();
    let option = options
        .as_array_mut()?
        .iter_mut()
        .find(|o| o.get("id").and_then(Value::as_str) == Some("mode"))?;
    option["currentValue"] = json!(mode);
    Some(options)
}

impl Hub {
    /// [`bridge_settle_modes`] for `session`, which an enrolled peer started when `peer`: its
    /// narrower policy (its own, else a deny-all default) and the modes its harness offers.
    pub(crate) async fn bridge_settle_modes(&self, session: &Session, peer: bool) -> Vec<String> {
        let default = self.config.read().await.permission_policy;
        let meta = session.meta();
        let offered = super::start_mode::offered_ids(&meta);
        bridge_settle_modes(peer, narrow_policy(&meta, default), &offered)
    }

    /// `session`'s policy mode when its policy is narrower than approve-all (module docs):
    /// `Some(None)` when the harness offers no mode that asks, `None` when the policy does not
    /// choose the mode.
    pub(super) fn mode_for_policy(
        meta: &SessionMeta,
        offered: &[String],
        default: PermissionPolicy,
    ) -> Option<Option<String>> {
        let policy = narrow_policy(meta, default)?;
        Some(policy_mode(policy, &crate::web_modes::mode_family(meta), offered))
    }

    /// After a chat's start mode is set: a policy narrower than approve-all that its harness's
    /// mode cannot keep is logged (`policy_unenforced`), with the mode it runs in.
    pub(super) fn note_unenforced_policy(&self, session: &Arc<Session>, cfg: &Config) {
        let meta = session.meta();
        let Some(policy) = narrow_policy(&meta, cfg.permission_policy) else { return };
        // Its PreToolUse gate holds the policy in any mode (`policy_gate.rs`), and so does an agent
        // that asks before every tool call.
        if super::policy_gate::has_gate(&meta) || asks_before_tools(&meta, cfg) {
            return;
        }
        let family = crate::web_modes::mode_family(&meta);
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
    /// Code `plan`) stays. A chat whose agent is not running keeps the mode for its next start. An
    /// agent that cannot keep the policy then is stopped (`stop_unheld`).
    pub(crate) async fn follow_policy(self: &Arc<Self>, session: &Arc<Session>) {
        self.follow_policy_mode(session).await;
        // Then the policy holds, or the agent stops (module docs).
        self.stop_unheld(session).await;
    }

    /// `follow_policy`'s move of the chat's mode.
    async fn follow_policy_mode(self: &Arc<Self>, session: &Arc<Session>) {
        let default = self.config.read().await.permission_policy;
        let meta = session.meta();
        let Some(policy) = narrow_policy(&meta, default) else { return };
        let family = crate::web_modes::mode_family(&meta);
        if family == "opencode" {
            self.ask_opencode(session).await;
            self.note_unenforced_policy(session, &*self.config.read().await);
            return;
        }
        let Some(current) = crate::web_modes::mode_of(&meta) else { return };
        let offered = super::start_mode::offered_ids(&meta);
        let Some(wanted) = policy_mode(policy, &family, &offered) else {
            self.note_unenforced_policy(session, &*self.config.read().await);
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
        // Not a chat being closed (`kill`), whose host only removes its record once it ends:
        // reaching it would start the chat again.
        let running = match child {
            Some(child) => child.is_alive().await,
            None => false,
        } || (Self::host_record_live(&session.id)
            && !session.closing.load(Ordering::SeqCst));
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
        self.note_unenforced_policy(session, &*self.config.read().await);
    }

    /// A paired machine's Full-access setting ended (turned off, or the machine revoked;
    /// `crate::pairing`): every chat a remote connection started whose mode its narrower policy
    /// does not hold (which only that setting lets happen) moves back to its policy's mode, as
    /// `follow_policy` moves it, and the turn it runs then stops, before the change is answered.
    /// Every such chat, whichever machine moved it; another machine that still has the setting
    /// may move its chat again. Also once at daemon start (`daemon.rs`), after the agent hosts
    /// are adopted: which machine moved a chat is not kept, so a restart puts every such chat
    /// back (fail closed). Returns how many chats it put back.
    pub(crate) async fn hold_policies_again(self: &Arc<Self>) -> usize {
        let default = self.config.read().await.permission_policy;
        let table = self.web_modes();
        let held: Vec<Arc<Session>> = self
            .sessions()
            .into_iter()
            .filter(|s| out_of_policy(&s.meta(), default, &table))
            .collect();
        for s in &held {
            tracing::warn!(session = %s.id, "a machine's Full access ended: the chat goes back to its policy's mode");
            self.append(s, "mux", "full_access_ended", json!({}));
            // First: a Web turn past its dispatch check sends no prompt now (`remote_floor_breach`),
            // and one whose prompt went out is cancelled.
            if s.turn().is_some_and(|t| t.control == Control::Web) {
                self.remote_floor_cancel(s, "remote.full_access_ended");
            }
        }
        futures::future::join_all(held.iter().map(|s| self.follow_policy(s))).await;
        // After the move: a turn that began before it ran in the wider mode.
        for s in &held {
            if s.turn().is_some()
                && let Err(e) = self.cancel(s).await
            {
                tracing::warn!(session = %s.id, "the turn was not cancelled: {}", e.message);
            }
        }
        held.len()
    }

    /// `session/set_mode` or `session/set_config_option` from a paired machine whose Full-access
    /// setting covers it (`server/remote_guard.rs` `full_access_device`): the policy of a chat a
    /// remote connection started holds the mode only when it is deny-all
    /// (`refuse_wider_mode_as`). The setting is read again once the switch is done:
    /// turned off in between, the chat is put back at once and the request fails.
    pub(crate) async fn set_for_full_access_device(
        self: &Arc<Self>,
        session: &Arc<Session>,
        device: &str,
        set: SetRequest,
    ) -> Result<Value, RpcError> {
        let r = match set {
            SetRequest::Mode(mode) => self.set_mode_as(session, &mode, true).await?,
            SetRequest::Config(id, value) => self.set_config_as(session, &id, value, true).await?,
        };
        if self.pairing.full_access(device) {
            return Ok(r);
        }
        self.hold_policies_again().await;
        Err(full_access_ended())
    }

    /// An OpenCode chat whose policy became narrower than approve-all while its agent runs without
    /// OpenCode asked to ask (module docs): the agent restarts and resumes the conversation, as a
    /// route switch does (`route_switch.rs`), now when the chat is idle, else when its turn ends
    /// (`turns.rs`). An agent host not reached since a daemon restart is reached first. A chat
    /// whose agent is not running asks from its next start (`spawn.rs`).
    async fn ask_opencode(self: &Arc<Self>, session: &Arc<Session>) {
        let asks = || session.applied.lock().unwrap_or_else(|e| e.into_inner()).opencode_asks;
        if asks() {
            return;
        }
        // Under the spawn lock, as `follow_policy`: a start in flight either ends first and its
        // child is seen here, or starts after and reads the policy (`spawn.rs` sets the marker).
        let spawning = session.spawn_lock.lock().await;
        let child = session.child.lock().await.clone();
        let running = match child {
            Some(child) => child.is_alive().await,
            None => false,
        } || (Self::host_record_live(&session.id)
            && !session.closing.load(Ordering::SeqCst));
        if !running {
            return;
        }
        // `child_for` takes the spawn lock.
        drop(spawning);
        // A turn runs, or one recovered from an agent host has not taken its lock yet
        // (`transfer_out.rs`): the agent restarts when it ends.
        let idle = if session.turn().is_none() { session.turn_lock.try_lock().ok() } else { None };
        let Some(_turn) = idle else {
            session.route_switch.store(true, Ordering::SeqCst);
            return;
        };
        // An unreached host is reached (`ensure_child`): a fresh start there already asks.
        let restarted = match self.child_for(session).await {
            Ok(_) if asks() => Ok(()),
            Ok(_) => self.restart_on_route(session).await,
            Err(e) => Err(e),
        };
        if let Err(e) = restarted {
            tracing::warn!(session = %session.id, "OpenCode not restarted to ask: {}", e.message);
        }
    }

    /// deny-all became the default policy: every chat without a policy of its own follows it
    /// (module docs).
    pub(crate) async fn follow_default_policy(self: &Arc<Self>) {
        let sessions: Vec<Arc<Session>> =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        // All at once: one agent that never answers its mode change holds no other chat back.
        let follows = sessions
            .iter()
            .filter(|s| s.meta().permission_policy.is_none() && s.moving().is_none())
            .map(|s| self.follow_policy(s));
        futures::future::join_all(follows).await;
    }

    /// A chat whose agent just started (cold, or from the pool) runs in its policy's mode
    /// (module docs). Sent to the agent itself: the start holds `spawn_lock`, so `set_mode` would
    /// wait on it. `pinned`: the profile pins its mode in argv, which the chat does not record
    /// yet. Then the policy must hold (`require_enforced`): an agent that cannot keep it is an
    /// error, and the caller stops it.
    pub(super) async fn hold_policy_mode(
        &self,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        pinned: bool,
    ) -> Result<(), RpcError> {
        let default = self.config.read().await.permission_policy;
        self.move_to_policy_mode(session, child, pinned, default).await;
        require_enforced(&session.meta(), &*self.config.read().await)
    }

    /// `hold_policy_mode`'s move: the agent to its policy's mode, when it runs in a wider one.
    async fn move_to_policy_mode(
        &self,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        pinned: bool,
        default: PermissionPolicy,
    ) {
        let meta = session.meta();
        let Some(policy) = narrow_policy(&meta, default) else { return };
        let (Some(current), Some(sid)) =
            (crate::web_modes::mode_of(&meta), meta.agent_session_id.clone())
        else {
            return;
        };
        let family = crate::web_modes::mode_family(&meta);
        let offered = super::start_mode::offered_ids(&meta);
        let Some(wanted) = policy_mode(policy, &family, &offered) else { return };
        let asks = super::start_mode::asks(&current, &family);
        let narrower = wanted == "read-only" && policy == PermissionPolicy::DenyAll;
        // A mode pinned in argv is not what the chat records until its first turn: always moved.
        if !pinned && (current == wanted || (asks && !narrower)) {
            return;
        }
        match child
            .request(method::SESSION_SET_MODE, json!({"sessionId": sid, "modeId": wanted}))
            .await
        {
            Ok(_) => {
                session.meta.lock().unwrap_or_else(|e| e.into_inner()).mode_set_by_cmux =
                    Some(wanted.clone());
                let mut writes = vec![ModeWrite::CurrentMode(json!(wanted))];
                if let Some(options) = with_mode_option(&session.meta(), &wanted) {
                    writes.push(ModeWrite::ConfigOptions(options));
                }
                self.write_mode_state(session, writes);
                self.append(session, "mux", "mode", json!({"modeId": wanted}));
            }
            Err(e) => {
                tracing::warn!(session = %session.id, mode = %wanted, "policy mode not set at start: {}", e.message);
            }
        }
    }

    /// After a live chat's policy changed (`follow_policy`): an agent that runs and cannot keep
    /// the chat's policy has its turn cancelled and is stopped (`refuse_unheld`); its next start
    /// fails with `policy_unenforceable` (module docs). An agent in a host this daemon has not
    /// reached yet (adoption after a restart) counts as running.
    async fn stop_unheld(self: &Arc<Self>, session: &Arc<Session>) {
        if require_enforced(&session.meta(), &*self.config.read().await).is_ok() {
            return;
        }
        let child = session.child.lock().await.clone();
        let running = match child {
            Some(child) => child.is_alive().await,
            None => false,
        } || (Self::host_record_live(&session.id)
            && !session.closing.load(Ordering::SeqCst));
        if !running {
            return;
        }
        if session.turn().is_some()
            && let Err(e) = self.cancel(session).await
        {
            tracing::warn!(session = %session.id, "the turn of an agent that cannot keep its policy was not cancelled: {}", e.message);
        }
        self.refuse_unheld(session).await;
    }

    /// An agent of `session` that runs now (started, adopted after a restart, reached again) must
    /// keep the chat's policy: when it cannot, it is stopped and `policy_refused` says why. Returns
    /// whether it was stopped.
    pub(super) async fn refuse_unheld(&self, session: &Arc<Session>) -> bool {
        let held = require_enforced(&session.meta(), &*self.config.read().await);
        let Err(e) = held else { return false };
        tracing::warn!(session = %session.id, "the agent cannot keep the chat's policy: stopped: {}", e.message);
        self.stop_started_agent(session, false, "policy_refused", refusal_record(&e)).await;
        true
    }

    /// At its agent's `initialize` (a cold start, or a pooled agent taken): the agent's
    /// `asksBeforeTools` claim, when it makes one, is logged as `asks_before_tools_claim`, with
    /// whether acpmux believes it and, when not, why ([`claim_distrust`]).
    pub(super) async fn note_asks_claim(&self, session: &Arc<Session>) {
        let meta = session.meta();
        if !claims_asks(&meta) {
            return;
        }
        let distrust = claim_distrust(&meta, &*self.config.read().await);
        if let Some(why) = distrust {
            tracing::warn!(session = %session.id, harness = %meta.harness, "the agent says it asks before every tool call; not believed: {why}");
        }
        self.append(
            session,
            "mux",
            "asks_before_tools_claim",
            json!({"harness": meta.harness, "trusted": distrust.is_none(), "reason": distrust}),
        );
    }

    /// The person picked a mode that does not ask (`session/set_mode`, or the `mode` config
    /// option) on `session`, whose own policy is narrower than approve-all and keeps it in an
    /// asking mode (`refuse_wider_mode` would refuse it): the pick means "stop asking", so the
    /// chat's policy becomes approve-all first and the switch then takes (user 20336: "it was in
    /// edits, then i changed to bypass, and it was still asking me"). Not under deny-all (a
    /// lockdown), and not while `sessions.allowFullAccess` is off. Callers pass only a person's
    /// connection; an agent or script still gets the refusal.
    pub(crate) async fn person_widens_policy_for(
        self: &Arc<Self>,
        session: &Arc<Session>,
        m: &str,
        params: &Value,
    ) {
        if self.refuse_wider_mode(session, m, params).await.is_ok() {
            return;
        }
        let default = self.config.read().await.permission_policy;
        let meta = session.meta();
        let narrow = narrow_policy(&meta, default);
        // Not under a lockdown default, which the person's pick does not lift (module docs).
        let lockdown = meta.permission_policy.is_none() && narrow.is_some();
        if narrow.is_none_or(|p| p == PermissionPolicy::DenyAll)
            || lockdown
            || !self.full_access_allowed()
        {
            return;
        }
        self.set_policy(session, PermissionPolicy::ApproveAll).await;
    }

    /// A switch of `session` into a mode that does not ask (`session/set_mode`, or the `mode`
    /// config option), from any client, while its policy is narrower than approve-all and its
    /// harness has a mode that keeps it: refused, as the policy would no longer hold.
    pub(super) async fn refuse_wider_mode(
        &self,
        session: &Session,
        m: &str,
        params: &Value,
    ) -> Result<(), RpcError> {
        self.refuse_wider_mode_as(session, m, params, false).await
    }

    /// `refuse_wider_mode`; `granted`: a paired machine's Full-access setting
    /// covers the request (`crate::pairing`), so the policy of a chat a remote
    /// connection started (the `ask` the remote guard gives it) no longer
    /// holds its mode, unless it is deny-all (its own or the default's
    /// lockdown). A chat started on this machine keeps its policy's mode.
    pub(super) async fn refuse_wider_mode_as(
        &self,
        session: &Session,
        m: &str,
        params: &Value,
        granted: bool,
    ) -> Result<(), RpcError> {
        let mode = match m {
            method::SESSION_SET_MODE => params.get("modeId"),
            method::SESSION_SET_CONFIG_OPTION
                if params.get("configId").and_then(Value::as_str) == Some("mode") =>
            {
                params.get("value")
            }
            _ => None,
        };
        let Some(mode) = mode.and_then(Value::as_str) else { return Ok(()) };
        let default = self.config.read().await.permission_policy;
        let meta = session.meta();
        let Some(policy) = narrow_policy(&meta, default) else { return Ok(()) };
        if granted && meta.remote_origin && policy != PermissionPolicy::DenyAll {
            return Ok(());
        }
        let family = crate::web_modes::mode_family(&meta);
        let offered = super::start_mode::offered_ids(&meta);
        let table = self.web_modes();
        if policy_mode(policy, &family, &offered).is_none()
            || super::start_mode::asks_in(mode, &family, table.modes(&family))
        {
            return Ok(());
        }
        Err(RpcError::invalid_params(format!(
            "mode {mode:?} does not ask before it acts, and this chat's permission policy is {policy}: set the policy to approve-all first"
        ))
        .with_data(json!({"reason": "policy_mode", "policy": policy.to_string()})))
    }
}

/// Fails chat `meta` whose policy is narrower than approve-all and that its agent cannot keep
/// (module docs): `Ok` when the agent has the PreToolUse gate (`policy_gate.rs`), says it asks
/// before every tool call ([`asks_before_tools`]), is OpenCode asked to ask before every tool
/// (`opencode_ask.rs`), or runs in a mode that keeps the policy (the policy's own, or another
/// that asks; for deny-all on a harness with `read-only`, that one). Every agent start
/// (`hold_policy_mode`), every creation (`lifecycle.rs`) and every policy change on a live chat
/// (`stop_unheld`) calls it. `cfg`: the daemon's config now, its default policy and the harness
/// entries an `asksBeforeTools` claim is judged against ([`claim_distrust`]).
pub(super) fn require_enforced(meta: &SessionMeta, cfg: &Config) -> Result<(), RpcError> {
    let Some(policy) = narrow_policy(meta, cfg.permission_policy) else { return Ok(()) };
    if super::policy_gate::has_gate(meta)
        || asks_before_tools(meta, cfg)
        || crate::web_modes::family_of(meta) == "opencode"
    {
        return Ok(());
    }
    let family = crate::web_modes::mode_family(meta);
    let offered = super::start_mode::offered_ids(meta);
    let current = crate::web_modes::mode_of(meta);
    let held = match (policy_mode(policy, &family, &offered), current) {
        (Some(wanted), Some(current)) => {
            let narrower = wanted == "read-only" && policy == PermissionPolicy::DenyAll;
            current == wanted || (super::start_mode::asks(&current, &family) && !narrower)
        }
        _ => false,
    };
    if held {
        return Ok(());
    }
    let mut why = match policy_mode(policy, &family, &offered) {
        Some(wanted) => format!("it does not run in its mode that asks ({wanted})"),
        None => crate::web_modes::NO_ASKING_MODE.to_owned(),
    };
    if claims_asks(meta)
        && let Some(distrust) = claim_distrust(meta, cfg)
    {
        why.push_str(&format!(
            "; it says it asks before every tool call, which acpmux believes only from an agent it started from a harness entry of its own config ({distrust})"
        ));
    }
    Err(unenforceable(policy, &meta.harness, &why))
}

/// Whether `meta`'s agent said at `initialize` that it asks the client
/// (`session/request_permission`) before every tool call it makes, and acpmux believes it: the
/// claim ([`claims_asks`]) comes from an agent acpmux started from a harness entry of its own
/// config (`cfg`, [`claim_distrust`]), and it does not run in a mode that skips approvals
/// (`start_mode::is_full_access`). The policy then answers each call, so it holds.
pub(super) fn asks_before_tools(meta: &SessionMeta, cfg: &Config) -> bool {
    // A mode that skips approvals overrides the claim.
    claims_asks(meta)
        && claim_distrust(meta, cfg).is_none()
        && crate::web_modes::mode_of(meta).is_none_or(|m| !super::start_mode::is_full_access(&m))
}

/// Whether `meta`'s agent says it asks before every tool call:
/// `agentCapabilities._meta.acpmux.asksBeforeTools` is `true`. Believed only as
/// [`claim_distrust`] says.
fn claims_asks(meta: &SessionMeta) -> bool {
    meta.agent_capabilities
        .as_ref()
        .and_then(|c| c.pointer("/_meta/acpmux/asksBeforeTools"))
        .and_then(Value::as_bool)
        == Some(true)
}

/// Why acpmux does not believe `meta`'s `asksBeforeTools` claim, or None when it does (lead,
/// 2026-11-09). Any program can say it asks; acpmux believes the agent it started from a harness
/// entry of its own config (`config.json`, a discovered harness: `Config::profile`), and only while
/// that entry still launches what the agent started from (its `launch_digest`, argv and env, as
/// `profile_respawn.rs` judges it):
/// - `not_started_here`: no launch is recorded (a forked chat before its own start, a chat moved
///   from another machine, a start by an older build): the claim was copied, not made to acpmux;
/// - `not_a_config_entry`: the harness is no entry of the config (a folder profile, the
///   repository's `.cmux/harnesses`, or an entry removed since the start);
/// - `entry_changed`: the entry launches something else now (changed since the start, such as an
///   agent host adopted after a restart).
pub(super) fn claim_distrust(meta: &SessionMeta, cfg: &Config) -> Option<&'static str> {
    let Some(started) = meta.launch_digest.as_deref() else { return Some("not_started_here") };
    let Some(entry) = cfg.profile(&meta.harness) else { return Some("not_a_config_entry") };
    (entry.launch_digest() != started).then_some("entry_changed")
}

/// The `policy_refused` record of refusal `e` (`unenforceable`): its data and its message.
pub(super) fn refusal_record(e: &RpcError) -> Value {
    let mut record = e.data.clone().unwrap_or_else(|| json!({}));
    if let Some(fields) = record.as_object_mut() {
        fields.insert("message".to_owned(), json!(e.message));
    }
    record
}

/// The typed error of a start under a policy that harness `harness` cannot keep
/// (`require_enforced`): `data.reason` is `policy_unenforceable`, with the policy, the harness
/// and a hint.
pub(super) fn unenforceable(policy: PermissionPolicy, harness: &str, why: &str) -> RpcError {
    let hint = format!(
        "start it with --policy approve-all, or on a harness that keeps {policy} (Claude Code, the Codex bridge)"
    );
    RpcError::invalid_params(format!(
        "permission policy {policy} cannot be enforced on harness {harness}: {why}. The chat did not start; {hint}"
    ))
    .with_data(json!({
        "reason": "policy_unenforceable",
        "policy": policy.to_string(),
        "harness": harness,
        "why": why,
        "hint": hint,
    }))
}

/// Whether a chat a remote connection started runs in a mode its narrower policy does not hold:
/// what `refuse_wider_mode` refuses (a mode that does not ask, under a policy whose harness has
/// a mode that keeps it), so only a paired machine's Full-access setting moves a chat there.
pub(super) fn out_of_policy(
    meta: &SessionMeta,
    default: PermissionPolicy,
    table: &crate::web_modes::WebModeTable,
) -> bool {
    if !meta.remote_origin {
        return false;
    }
    let family = crate::web_modes::mode_family(meta);
    let offered = super::start_mode::offered_ids(meta);
    narrow_policy(meta, default)
        .is_some_and(|policy| policy_mode(policy, &family, &offered).is_some())
        && crate::web_modes::mode_of(meta)
            .is_some_and(|mode| !super::start_mode::asks_in(&mode, &family, table.modes(&family)))
}

/// What `Hub::set_for_full_access_device` sets.
pub(crate) enum SetRequest {
    Mode(String),
    Config(String, Value),
}

fn full_access_ended() -> RpcError {
    RpcError::invalid_params(
        "this machine's Full access was turned off on the Mac: the chat is back in its policy's mode",
    )
    .with_data(json!({"reason": "full_access_ended"}))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An `asksBeforeTools` claim is believed only from an agent started from a harness entry of
    /// the config that still launches what it started from (`claim_distrust`).
    #[test]
    fn a_policy_claim_is_believed_only_from_an_unchanged_config_entry() {
        let mut cfg: Config =
            serde_json::from_value(json!({"harnesses": {"lane": {"argv": ["lane-acp"]}}})).unwrap();
        let mut meta: SessionMeta = serde_json::from_value(json!({
            "schema": crate::store::META_SCHEMA, "id": "s", "name": "s", "harness": "lane",
            "cwd": "/w", "status": "ready", "createdAt": 0, "updatedAt": 0,
            "agentCapabilities": {"_meta": {"acpmux": {"asksBeforeTools": true}}},
        }))
        .unwrap();
        // A copy of the claim (a fork before its start, a moved chat): no launch recorded.
        assert_eq!(claim_distrust(&meta, &cfg), Some("not_started_here"));
        assert!(!asks_before_tools(&meta, &cfg));
        meta.launch_digest = Some(cfg.harnesses["lane"].launch_digest());
        assert_eq!(claim_distrust(&meta, &cfg), None);
        assert!(asks_before_tools(&meta, &cfg));
        // In a mode that skips approvals, a believed claim still does not hold.
        meta.modes = Some(json!({"currentModeId": "bypassPermissions"}));
        assert!(!asks_before_tools(&meta, &cfg));
        meta.modes = None;
        let lane = cfg.harnesses.get_mut("lane").unwrap();
        lane.env.insert("LANE_FLAG".to_owned(), "1".to_owned());
        assert_eq!(claim_distrust(&meta, &cfg), Some("entry_changed"));
        assert!(!asks_before_tools(&meta, &cfg));
        // A folder profile, or an entry removed since.
        meta.harness = "acme".to_owned();
        assert_eq!(claim_distrust(&meta, &cfg), Some("not_a_config_entry"));
        // No claim at all: nothing to believe.
        meta.harness = "lane".to_owned();
        meta.agent_capabilities = Some(json!({}));
        assert!(!claims_asks(&meta));
    }

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

    /// A remote start on the bridge settles in `read-only` only for an enrolled peer under
    /// deny-all, and in `ask` from anyone else, under any other policy, or when the harness offers
    /// no `read-only`.
    #[test]
    fn a_remote_bridge_start_settles_in_read_only_only_for_a_peer_under_deny_all() {
        let codex = ids(&["ask", "read-only", "agent", "agent-full-access"]);
        let deny_all = Some(PermissionPolicy::DenyAll);
        assert_eq!(bridge_settle_modes(true, deny_all, &codex), ids(&["read-only"]));
        assert_eq!(bridge_settle_modes(false, deny_all, &codex), ids(&["ask"]));
        assert_eq!(bridge_settle_modes(true, deny_all, &ids(&["ask", "agent"])), ids(&["ask"]));
        assert_eq!(bridge_settle_modes(true, deny_all, &[]), ids(&["ask"]));
        for policy in [
            None,
            Some(PermissionPolicy::Ask),
            Some(PermissionPolicy::ApproveReads),
            Some(PermissionPolicy::ApproveEdits),
        ] {
            assert_eq!(bridge_settle_modes(true, policy, &codex), ids(&["ask"]), "{policy:?}");
        }
    }

    /// Muse Code through muse-acp offers `default`, `readOnly` and `plan`, and asks through its
    /// approval option, not a mode: deny-all holds in `readOnly`; the asking policies have no
    /// mode that keeps them.
    #[test]
    fn muse_deny_all_runs_read_only() {
        let muse = ids(&["default", "readOnly", "plan"]);
        assert_eq!(
            policy_mode(PermissionPolicy::DenyAll, "muse", &muse).as_deref(),
            Some("readOnly")
        );
        assert_eq!(policy_mode(PermissionPolicy::Ask, "muse", &muse), None);
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
