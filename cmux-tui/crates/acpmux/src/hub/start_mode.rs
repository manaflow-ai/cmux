//! Part of `Hub`; see `hub/mod.rs`. The permission mode a new chat starts
//! in (cx-wx93i; Lawrence 2026-10-14: "by default all chats should be in
//! skip permission mode, that user can switch back"):
//!
//! 0. the value MDM or the team policy forces for the cmux setting
//!    `agents.defaultPermissionMode`, which the app pushes
//!    (`start_mode_state.rs`): an administrator's choice beats everything
//!    below. A forced value this build does not know is `standard`, never
//!    full access;
//! 1. acpmux config.json `defaultPermissionMode` (acpmux without the app,
//!    tests), else the cmux setting `agents.defaultPermissionMode` (the
//!    settings file, `user_settings.rs`, else the value the app pushed):
//!    `fullAccess` (the default), `standard` (the harness's own start mode:
//!    acpmux sets nothing) or `ask` (the mode that asks before each change,
//!    `web_modes::ASKING_MODES`, else `ask`);
//! 2. full access: the harness's own mode that skips every approval
//!    (`FULL_ACCESS_MODES`: Claude Code `bypassPermissions`, the Codex
//!    bridge `agent-full-access` = approval never + danger-full-access,
//!    `yolo` where a harness names it so). A harness with no such mode keeps
//!    its own start mode.
//!
//! A mode picked in a chat holds for that chat only; new chats keep starting
//! in the default (Leo 2026-10-21: "i think starting in full access is ok cuz
//! the default for new chats != whatever u just temp set in an existing
//! running chat"). The default changes only where it is set: Settings, the
//! settings file, MDM or the team policy, or config.json. A
//! `lastPermissionMode` an older build saved in config.json is ignored.
//!
//! acpmux sets it with `session/set_mode` once the harness is up. Like the
//! start model it is soft: a refusal is logged (`start_default_skipped`)
//! and the chat runs the harness's own mode. Not for: a remote-origin
//! (Web) session (the remote guard settles its mode,
//! `server/remote_guard.rs`), a preset's chat, a folder profile's chat, an
//! adopted conversation, and a profile that pins its mode in its argv
//! (`profile_sets_mode`).
//!
//! Only the person widens a mode later (`hub/person.rs`).
//!
//! Inherit (Leo 2026-10-25: "shouldn't sub-agents just inherit the bypass
//! permission situation?"): a chat an agent starts, by `session/new` from
//! its shell (`acpmux new|run`, a local `_acpmux/dispatch`) or as its
//! sub-session (`start_session`, `acpmux new --parent`), runs at its
//! starter's level, not at the person's start level. The starter is the
//! session the connection proved with its caller token (`Conn::caller`,
//! `start_gate.rs`), never the person, a peer, a Web connection or a request
//! value, and never a session a remote connection started (`remote_origin`:
//! its chats keep the rule below, a caller that asks keeps the harness's own
//! mode); a start with none is unchanged. Each field the start leaves out is
//! inherited on its own:
//!
//! - no policy: the defaults' (family or preset) when no wider than the
//!   starter's effective policy, else the starter's own. A starter with no
//!   policy of its own gives none (the daemon default it runs too): the
//!   daemon default as the child's own would move its mode to an asking one
//!   (`policy_mode.rs`);
//! - no mode: a policy narrower than approve-all chooses it (`policy_mode.rs`);
//!   else, on the starter's own family, the starter's exact mode (not a
//!   toggle such as `plan`, and not full access while
//!   `sessions.allowFullAccess` is off); on another family, the starter's
//!   level mapped onto the child's modes: full access to its full-access
//!   mode, a starter that asks (or reports no mode) to its asking mode, and
//!   any other to the harness's own mode (the asking one when the person's
//!   level is `ask`).
//!
//! Its harness never asks less than its starter: once its mode is set it is
//! held to the starter as the starter is then (`Hub::hold_mode`): moved to an
//! asking mode, else refused and closed (a family with no mode that asks
//! under a starter that asks). A mode the start names is held by
//! `start_gate.rs` (a mode that does not ask needs the starter's exact mode
//! or the person), and a sub-session by `subsession_guard.rs`. A policy the
//! start names is not held to the starter (`hub/person.rs`: open to the unix
//! socket since before this).

use super::*;

/// The mark on a watchers' harness-feed payload that is a start-mode notice.
pub(crate) const START_MODE_NOTE: &str = "startModeChanged";

/// The cmux setting that chooses the start mode of a new chat.
pub const SETTING: &str = "agents.defaultPermissionMode";

/// Harness mode ids that skip every approval, in preference order.
pub(crate) const FULL_ACCESS_MODES: [&str; 4] =
    ["bypassPermissions", "agent-full-access", "full-access", "yolo"];

/// Mode ids that are a temporary toggle, never inherited by a sub-session.
const TOGGLE_MODES: [&str; 1] = ["plan"];

/// `agents.defaultPermissionMode`.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum DefaultMode {
    /// The harness mode that skips every approval (the default).
    FullAccess,
    /// The harness's own start mode.
    Standard,
    /// The mode that asks before each change.
    Ask,
}

impl DefaultMode {
    fn parse(value: &str) -> Option<Self> {
        match value {
            "fullAccess" => Some(Self::FullAccess),
            "standard" => Some(Self::Standard),
            "ask" => Some(Self::Ask),
            _ => None,
        }
    }

    /// acpmux config.json's `defaultPermissionMode` when it names one, else
    /// the setting as the settings file holds it now, and which of them
    /// chose. No file or no key is the value the app pushed for it (a team
    /// default or an MDM recommended value, `pushed`), else full access
    /// (Lawrence's default). A file
    /// that does not parse, or a value this build does not know, is
    /// `Standard`: a person's opt-out that acpmux cannot read never becomes
    /// full access.
    pub(crate) fn resolve(configured: Option<&str>, pushed: Option<&str>) -> (Self, Source) {
        if let Some(value) = configured {
            let level = Self::parse(value).unwrap_or_else(|| {
                tracing::warn!(value, "config.json defaultPermissionMode: unknown value; new chats keep the harness's own mode");
                Self::Standard
            });
            return (level, Source::Config);
        }
        let unset = || match pushed {
            None => (Self::FullAccess, Source::Default),
            Some(value) => {
                let level = Self::parse(value).unwrap_or_else(|| {
                    tracing::warn!(
                        value,
                        "{SETTING}: unknown pushed value; new chats keep the harness's own mode"
                    );
                    Self::Standard
                });
                (level, Source::Settings)
            }
        };
        match crate::user_settings::read() {
            crate::user_settings::Settings::Missing => unset(),
            crate::user_settings::Settings::Unreadable(why) => {
                tracing::warn!(
                    "{SETTING}: the settings file cannot be read ({why}); new chats keep the harness's own mode"
                );
                (Self::Standard, Source::Settings)
            }
            crate::user_settings::Settings::Parsed(doc) => {
                match crate::user_settings::value(&doc, SETTING) {
                    None | Some(Value::Null) => unset(),
                    Some(v) => {
                        let level = v.as_str().and_then(Self::parse).unwrap_or_else(|| {
                            tracing::warn!(
                                "{SETTING}: unknown value {v}; new chats keep the harness's own mode"
                            );
                            Self::Standard
                        });
                        (level, Source::Settings)
                    }
                }
            }
        }
    }
}

/// What chose a start level: a value policy forces, config.json, the cmux
/// setting, or nothing (full access).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Source {
    Managed,
    Config,
    Settings,
    Default,
}

impl Source {
    fn as_str(self) -> &'static str {
        match self {
            Self::Managed => "managed",
            Self::Config => "config",
            Self::Settings => "settings",
            Self::Default => "default",
        }
    }
}

/// The cmux setting as the settings file holds it now, to see a change
/// (`start_mode_state.rs`): its value as compact JSON, `None` with no file or
/// no key, and a marker for a file that cannot be read.
pub(crate) fn setting_snapshot() -> Option<String> {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Missing => None,
        crate::user_settings::Settings::Unreadable(_) => Some("\u{0}unreadable".to_owned()),
        crate::user_settings::Settings::Parsed(doc) => {
            match crate::user_settings::value(&doc, SETTING) {
                None | Some(Value::Null) => None,
                Some(value) => Some(value.to_string()),
            }
        }
    }
}

/// The level a new chat starts at (module docs): the forced value
/// (`managed`), else `DefaultMode::resolve` (with `pushed`). With
/// `sessions.allowFullAccess` off, full access starts as Standard, whatever
/// chose it.
fn start_level(
    managed: Option<&str>,
    configured: Option<&str>,
    pushed: Option<&str>,
) -> (DefaultMode, Source) {
    let (level, source) = if let Some(value) = managed {
        let level = DefaultMode::parse(value).unwrap_or_else(|| {
            tracing::warn!(
                value,
                "{SETTING}: unknown managed value; new chats keep the harness's own mode"
            );
            DefaultMode::Standard
        });
        (level, Source::Managed)
    } else {
        DefaultMode::resolve(configured, pushed)
    };
    // `sessions.allowFullAccess` off: no chat starts in a mode that skips every approval.
    if level == DefaultMode::FullAccess && !full_access_allowed() {
        return (DefaultMode::Standard, source);
    }
    (level, source)
}

/// The cmux setting that allows the modes that skip every approval (Settings > Agents > Agent
/// Sessions, "Allow Full-Access Modes").
pub const ALLOW_FULL_ACCESS: &str = "sessions.allowFullAccess";

/// Whether a mode that skips every approval may run now: yes unless the settings file turns
/// `sessions.allowFullAccess` off. A settings file that cannot be read fails closed (no).
pub fn full_access_allowed() -> bool {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Missing => true,
        crate::user_settings::Settings::Unreadable(_) => false,
        crate::user_settings::Settings::Parsed(doc) => !matches!(
            crate::user_settings::value(&doc, ALLOW_FULL_ACCESS),
            Some(Value::Bool(false))
        ),
    }
}

/// The markers of a mode id or option value that skips every approval, shared with the cmux NEXT
/// app (`spec/full-access-modes.json`).
const FULL_ACCESS_RULE: &str = include_str!("../../../../spec/full-access-modes.json");

fn full_access_markers() -> Option<&'static [String]> {
    static MARKERS: std::sync::OnceLock<Option<Vec<String>>> = std::sync::OnceLock::new();
    MARKERS
        .get_or_init(|| {
            let rule: Value = serde_json::from_str(FULL_ACCESS_RULE).ok()?;
            Some(
                rule.get("markers")?
                    .as_array()?
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_owned)
                    .collect(),
            )
        })
        .as_deref()
}

/// Whether a mode id or option value skips every approval, by the shared rule
/// (`spec/full-access-modes.json`): lowercased, without `-`, `_` or spaces, it contains a
/// marker. Wider than `FULL_ACCESS_MODES` (the modes acpmux itself picks), so a harness's
/// `danger-full-access` or `auto-approve` is refused too.
pub(crate) fn is_full_access(mode: &str) -> bool {
    let folded: String = mode
        .chars()
        .filter(|c| !matches!(c, '-' | '_' | ' '))
        .flat_map(char::to_lowercase)
        .collect();
    // A rule that does not parse names every mode full access: refused while the setting is off.
    full_access_markers().is_none_or(|markers| markers.iter().any(|m| folded.contains(m.as_str())))
}

/// The mode a resumed chat runs in: its saved mode, or the harness default (`fallback`) when the
/// saved one skips every approval and `sessions.allowFullAccess` is off.
pub(crate) fn resumable_mode(saved: String, fallback: &str) -> String {
    if is_full_access(&saved) && !full_access_allowed() { fallback.to_owned() } else { saved }
}

/// Whether a session request switches into a full-access mode: `session/set_mode` to one, or
/// `session/set_config_option` of any option whose value is one (not only the `mode` option).
pub(crate) fn requests_full_access(m: &str, params: &Value) -> bool {
    let value = match m {
        method::SESSION_SET_MODE => params.get("modeId"),
        method::SESSION_SET_CONFIG_OPTION => params.get("value"),
        _ => None,
    };
    value.and_then(Value::as_str).is_some_and(is_full_access)
}

/// The refusal of a full-access mode while `sessions.allowFullAccess` is off.
pub(crate) fn full_access_off() -> RpcError {
    RpcError::new(
        -32000,
        "full-access modes are turned off in cmux Settings (sessions.allowFullAccess)",
    )
    .with_data(json!({"reason": "full_access_off"}))
}

/// Whether acpmux sets a start mode on a new chat at all (module docs):
/// `plain` is a chat that is not an adopted conversation, a preset's or a
/// folder profile's; never a remote-origin chat, a handoff that keeps the
/// harness's mode, or a profile that pins its mode. `session/new` and
/// `_acpmux/start_mode` both decide with this.
pub(super) fn mode_eligible(
    plain: bool,
    remote: bool,
    keep_harness_mode: bool,
    profile: &HarnessProfile,
) -> bool {
    plain && !remote && !keep_harness_mode && !profile_sets_mode(profile)
}

/// The mode ids a session's harness offers, for the policy modes (`policy_mode.rs`).
pub(super) fn offered_ids(meta: &crate::store::SessionMeta) -> Vec<String> {
    available(meta)
}

/// The mode ids a session's harness offers.
fn available(meta: &crate::store::SessionMeta) -> Vec<String> {
    offered(meta).into_iter().map(|(id, _)| id).collect()
}

/// The modes a session's harness offers: id and name.
fn offered(meta: &crate::store::SessionMeta) -> Vec<(String, Option<String>)> {
    meta.modes
        .as_ref()
        .and_then(|m| m.get("availableModes"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|m| {
            let id = m.get("id").and_then(Value::as_str)?;
            Some((id.to_owned(), m.get("name").and_then(Value::as_str).map(str::to_owned)))
        })
        .collect()
}

/// The full-access mode among `available`, if the harness has one.
pub(crate) fn full_access_mode(available: &[String]) -> Option<String> {
    FULL_ACCESS_MODES.iter().find(|m| available.iter().any(|a| a == *m)).map(|m| (*m).to_owned())
}

/// The mode that asks before each change among `available`: the family's
/// asking default (`web_modes::ASKING_MODES`), else a mode named `ask`.
pub(super) fn asking_mode(family: &str, available: &[String]) -> Option<String> {
    let row = crate::web_modes::ASKING_MODES
        .iter()
        .find(|(f, _)| *f == family)
        .map(|(_, modes)| *modes)
        .unwrap_or(&[]);
    row.iter()
        .chain(std::iter::once(&"ask"))
        .find(|m| available.iter().any(|a| a == *m))
        .map(|m| (*m).to_owned())
}

/// The mode a chat that must leave full access moves to: the family's asking mode, else the first
/// offered mode that does not skip approvals.
pub(crate) fn mode_below_full_access(family: &str, available: &[String]) -> Option<String> {
    asking_mode(family, available)
        .or_else(|| available.iter().find(|m| !is_full_access(m)).cloned())
}

/// What `access` gives a harness of `family` offering `available`.
fn mode_for(access: DefaultMode, family: &str, available: &[String]) -> Option<String> {
    match access {
        DefaultMode::FullAccess => full_access_mode(available),
        DefaultMode::Standard => None,
        DefaultMode::Ask => asking_mode(family, available),
    }
}

/// Whether a profile chooses its permission mode in its own argv (Claude
/// Code `--permission-mode` or a skip flag, Codex `--sandbox`, `-s`,
/// `--ask-for-approval`, `-a`, a full-auto or bypass flag, or `-c
/// approval_policy=` / `sandbox_mode=`). Then no start mode is set over it.
pub(super) fn profile_sets_mode(profile: &HarnessProfile) -> bool {
    const FLAGS: [&str; 9] = [
        "--permission-mode",
        "--dangerously-skip-permissions",
        "--dangerously-bypass-approvals-and-sandbox",
        "--yolo",
        "--full-auto",
        "--sandbox",
        "-s",
        "--ask-for-approval",
        "-a",
    ];
    let argv = &profile.argv;
    argv.iter().enumerate().any(|(i, a)| {
        FLAGS.iter().any(|f| a == f || a.starts_with(&format!("{f}=")))
            || ((a == "-c" || a == "--config")
                && argv.get(i + 1).is_some_and(|v| {
                    let v = v.trim_start();
                    v.starts_with("approval_policy") || v.starts_with("sandbox_mode")
                }))
    })
}

/// Modes that ask (or only read) on harnesses the asking table leaves out:
/// the Codex bridge's `ask` and `read-only`. The start gate takes them on the
/// bridge alone (`start_gate.rs`): the codex-acp adapter's `read-only` writes
/// in the workspace without asking (`web_modes::NON_ASKING_MODES`).
pub(super) const NARROW_MODES: [&str; 2] = ["ask", "read-only"];

/// The level of mode `mode` on a harness of `family`: a full-access mode,
/// a mode that asks before each change (`asking`: the merged asking table's
/// row for the family), or any other (the harness's own).
fn level_of(mode: &str, family: &str, asking: &[String]) -> DefaultMode {
    if FULL_ACCESS_MODES.contains(&mode) {
        return DefaultMode::FullAccess;
    }
    let reviewed = crate::web_modes::ASKING_MODES
        .iter()
        .find(|(f, _)| *f == family)
        .is_some_and(|(_, modes)| modes.contains(&mode));
    if reviewed || asking.iter().any(|m| m == mode) || NARROW_MODES.contains(&mode) {
        DefaultMode::Ask
    } else {
        DefaultMode::Standard
    }
}

/// Whether mode `mode` of a harness of `family` asks before each change (or only reads).
pub(super) fn asks(mode: &str, family: &str) -> bool {
    asks_in(mode, family, &[])
}

/// `asks`, also counting `asking`: the configured asking modes of `family` (`webAskingModes`).
pub(super) fn asks_in(mode: &str, family: &str, asking: &[String]) -> bool {
    level_of(mode, family, asking) == DefaultMode::Ask
}

/// The policy a chat that names none inherits from its starter (module docs, "Inherit"):
/// `defaults` (its family's or preset's) when no wider than the starter's effective policy (its
/// own, else `daemon`), else the starter's own (none: the daemon default, as the starter runs).
pub(super) fn inherited_policy(
    defaults: Option<PermissionPolicy>,
    own: Option<PermissionPolicy>,
    daemon: PermissionPolicy,
) -> Option<PermissionPolicy> {
    let theirs = own.unwrap_or(daemon);
    match defaults {
        Some(d) if super::person::breadth(d) <= super::person::breadth(theirs) => Some(d),
        _ => own,
    }
}

impl DefaultMode {
    fn as_str(self) -> &'static str {
        match self {
            Self::FullAccess => "fullAccess",
            Self::Standard => "standard",
            Self::Ask => "ask",
        }
    }
}

impl Hub {
    /// The mode a new chat on `session` starts in (module docs), or `None`
    /// to keep the harness's own.
    pub(super) async fn start_mode(&self, session: &Session) -> Option<String> {
        let meta = session.meta();
        let offered = available(&meta);
        if offered.is_empty() {
            return None;
        }
        // A chat with its own policy narrower than approve-all runs in the mode that keeps it
        // (`policy_mode.rs`), never in the start level.
        let default = self.config.read().await.permission_policy;
        let mode = match Self::mode_for_policy(&meta, &offered, default) {
            Some(mode) => mode,
            None => {
                let (level, _) = self.start_level().await;
                mode_for(level, &crate::web_modes::family_of(&meta), &offered)
            }
        };
        mode.filter(|m| crate::web_modes::mode_of(&meta).as_deref() != Some(m.as_str()))
    }

    /// `start_mode` for a chat an agent started: at its starter's level (module docs, "Inherit"),
    /// read now. `starter`: the proven caller session; none (or one that is gone) is `start_mode`.
    pub(super) async fn start_mode_for(
        &self,
        session: &Session,
        starter: Option<&str>,
    ) -> Option<String> {
        let theirs = starter.and_then(|id| self.resolve(id).ok().filter(|s| s.id == id));
        let Some(theirs) = theirs.map(|s| s.meta()) else { return self.start_mode(session).await };
        let meta = session.meta();
        let offered = available(&meta);
        if offered.is_empty() {
            return None;
        }
        let default = self.config.read().await.permission_policy;
        let mode = match Self::mode_for_policy(&meta, &offered, default) {
            Some(mode) => mode,
            None => self.inherited_mode(&theirs, &meta, &offered).await,
        };
        mode.filter(|m| crate::web_modes::mode_of(&meta).as_deref() != Some(m.as_str()))
    }

    /// The mode chat `meta` (offering `offered`) inherits from starter `theirs` (module docs).
    async fn inherited_mode(
        &self,
        theirs: &crate::store::SessionMeta,
        meta: &crate::store::SessionMeta,
        offered: &[String],
    ) -> Option<String> {
        let family = crate::web_modes::family_of(meta);
        let allowed = full_access_allowed();
        if crate::web_modes::family_of(theirs) == family
            && let Some(mode) = crate::web_modes::mode_of(theirs)
            && offered.contains(&mode)
            && !TOGGLE_MODES.contains(&mode.as_str())
            && (allowed || !is_full_access(&mode))
        {
            return Some(mode);
        }
        let access = self.caller_access(theirs);
        if access == super::subsession_guard::Access::Full && allowed {
            return full_access_mode(offered);
        }
        let asks = access == super::subsession_guard::Access::Asks
            || self.start_level().await.0 == DefaultMode::Ask;
        if !asks {
            return None;
        }
        // The family's reviewed asking mode, else one the person's `webAskingModes` names.
        let table = self.web_modes();
        asking_mode(&family, offered)
            .or_else(|| table.modes(&family).iter().find(|m| offered.contains(m)).cloned())
    }

    /// A chat that inherited full access from `starter` (`start_mode_for`) holds it as cmux's own
    /// (`trust_wait.rs` `full_access_by_cmux`) only when the starter's is cmux's own too.
    pub(super) fn inherited_full_access_is_cmux_only_if_theirs(
        &self,
        session: &Session,
        starter: Option<&str>,
    ) {
        let Some(theirs) = starter.and_then(|id| self.resolve(id).ok().filter(|s| s.id == id))
        else {
            return;
        };
        if super::trust_wait::full_access_by_cmux(&theirs.meta()) {
            return;
        }
        {
            let mut m = session.meta.lock().unwrap_or_else(|e| e.into_inner());
            if !m.mode_set_by_cmux.as_deref().is_some_and(is_full_access) {
                return;
            }
            m.mode_set_by_cmux = None;
        }
        self.save_meta(session);
    }

    /// Session `id`'s own policy (none: it runs the daemon default); one acpmux cannot parse
    /// counts as `ask`.
    pub(super) fn own_policy(&self, id: &str) -> Option<PermissionPolicy> {
        let s = self.resolve(id).ok().filter(|s| s.id == id)?;
        let own = s.meta().permission_policy?;
        Some(own.parse().unwrap_or(PermissionPolicy::Ask))
    }

    /// A respawned ACP chat that came back in full access (its harness restored the mode on
    /// load) while `sessions.allowFullAccess` is off: moved to a mode that asks
    /// (`mode_below_full_access`). A resumed chat never runs above the setting: when the harness
    /// offers no lower mode or refuses the switch, the answer is `full_access_off` and the caller
    /// stops the agent.
    pub(super) async fn leave_full_access_if_off(
        &self,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
    ) -> Result<(), RpcError> {
        let meta = session.meta();
        let Some(current) = crate::web_modes::mode_of(&meta) else { return Ok(()) };
        if !is_full_access(&current) || full_access_allowed() {
            return Ok(());
        }
        let family = crate::web_modes::family_of(&meta);
        let (Some(sid), Some(mode)) =
            (meta.agent_session_id.clone(), mode_below_full_access(&family, &available(&meta)))
        else {
            tracing::warn!(session = %session.id, "resume: full access is off and {current} offers no other mode");
            return Err(full_access_off());
        };
        if let Err(e) =
            child.request(method::SESSION_SET_MODE, json!({"sessionId": sid, "modeId": mode})).await
        {
            tracing::warn!(session = %session.id, "resume: leaving {current}: {}", e.message);
            return Err(full_access_off());
        }
        tracing::info!(session = %session.id, "resume: full access is off; {current} runs as {mode}");
        session.meta.lock().unwrap_or_else(|e| e.into_inner()).mode_set_by_cmux =
            Some(mode.clone());
        self.write_mode_state(session, [ModeWrite::CurrentMode(json!(mode))]);
        Ok(())
    }

    /// `leave_full_access_if_off` for a chat just started (cold or from the pool): when it would
    /// run in full access, the agent stops and the chat stays open and idle. A profile that pins
    /// its mode in its argv (`--yolo`) is left alone, as acpmux sets no mode over it anywhere else,
    /// except for a narrower policy, which the chat's mode then keeps (`hold_policy_mode`).
    pub(super) async fn cap_full_access(
        &self,
        session: &Arc<Session>,
        child: &Arc<ChildAgent>,
        profile: &HarnessProfile,
    ) -> Result<(), RpcError> {
        if !profile_sets_mode(profile)
            && let Err(e) = self.leave_full_access_if_off(session, child).await
        {
            if let Some(started) = session.child.lock().await.take() {
                started.terminate(super::shutdown::SHUTDOWN_GRACE).await;
            }
            // A host that outlived the grace would be re-adopted, still in full access.
            if Self::host_record_live(&session.id) {
                self.end_unadopted_host(session).await;
            }
            self.set_status(session, SessionStatus::Idle);
            self.append(session, "mux", "full_access_refused", json!({}));
            return Err(e);
        }
        // A narrower policy holds over a pinned mode too (`policy_mode.rs`).
        self.hold_policy_mode(session, child, profile_sets_mode(profile)).await;
        Ok(())
    }

    /// The level new chats start at now, and what chose it.
    async fn start_level(&self) -> (DefaultMode, Source) {
        let (state, configured) = {
            let cfg = self.config.read().await;
            let path = super::start_mode_state::state_file(&cfg);
            (
                self.update_start_mode_state(path.as_deref(), |_| {}).1,
                cfg.default_permission_mode.clone(),
            )
        };
        start_level(state.managed.as_deref(), configured.as_deref(), state.pushed.as_deref())
    }

    /// `_acpmux/start_mode`: the mode a plain new chat on `harness` (or the
    /// preset) in `cwd` would start in, by the rules `new_session` applies
    /// (`mode_eligible`, `start_level`, `mode_for`), for a connection of
    /// this origin (`remote`: a remote-origin chat gets none). Read only.
    /// `modeId` is null when acpmux would set no mode: the chat is not
    /// eligible, the level keeps the harness's own mode, or the harness's
    /// modes are not known yet (no chat of it in this daemon, and not
    /// acpmux's own Claude backend).
    pub async fn start_mode_answer(
        &self,
        harness: Option<String>,
        preset: Option<String>,
        cwd: Option<std::path::PathBuf>,
        remote: bool,
    ) -> Result<Value, RpcError> {
        // A remote-origin connection's chats get no start mode: it is told so
        // before its cwd, preset or harness is resolved, so the answer never
        // reveals this Mac's folders, profiles or settings.
        if remote {
            return Ok(
                json!({"harness": null, "modeId": null, "name": null, "level": null, "source": null}),
            );
        }
        // As session/new: harness discovery and launcher checks finish first.
        self.wait_startup().await;
        let (agent, profile, eligible, policy) = {
            let cfg = self.config.read().await;
            let r = self.resolve_new(&cfg, harness, &preset, None, remote, cwd.as_deref())?;
            let plain = r.preset_name.is_none() && r.folder_root.is_none();
            let terminal = r.profile.kind == crate::config::HarnessKind::Terminal;
            let eligible = !terminal && mode_eligible(plain, remote, false, &r.profile);
            // The policy the new chat would hold (`policy_mode.rs`): its preset's or defaults',
            // else deny-all as the default policy.
            let policy = (!terminal)
                .then(|| super::policy_mode::narrower(r.defaults.policy, cfg.permission_policy))
                .flatten();
            (r.agent, r.profile, eligible, policy)
        };
        let none =
            json!({"harness": agent, "modeId": null, "name": null, "level": null, "source": null});
        let family = crate::config::derive_family(&agent, &profile);
        let modes = self.known_modes(&agent, &profile);
        let ids: Vec<String> = modes.iter().map(|(id, _)| id.clone()).collect();
        let name_of = |mode: &Option<String>| {
            mode.as_ref()
                .and_then(|m| modes.iter().find(|(id, _)| id == m))
                .and_then(|(_, n)| n.clone())
        };
        // A narrower policy chooses the mode on every chat, eligible or not.
        if let Some(policy) = policy {
            let mode = super::policy_mode::policy_mode(policy, &family, &ids);
            if mode.is_none() {
                return Ok(none);
            }
            return Ok(json!({
                "harness": agent,
                "modeId": mode,
                "name": name_of(&mode),
                "level": DefaultMode::Ask.as_str(),
                "source": "policy",
            }));
        }
        if !eligible {
            return Ok(none);
        }
        let (level, source) = self.start_level().await;
        let mode = mode_for(level, &family, &ids);
        Ok(json!({
            "harness": agent,
            "modeId": mode,
            "name": name_of(&mode),
            "level": level.as_str(),
            "source": source.as_str(),
        }))
    }

    /// The modes harness profile `agent` offers, as its newest chat in this
    /// daemon reported them, else acpmux's own Claude backend's list.
    fn known_modes(&self, agent: &str, profile: &HarnessProfile) -> Vec<(String, Option<String>)> {
        let all: Vec<Arc<Session>> =
            self.sessions.lock().unwrap_or_else(|e| e.into_inner()).values().cloned().collect();
        let of_agent: Vec<Arc<Session>> = all
            .into_iter()
            .filter(|s| s.meta.lock().unwrap_or_else(|e| e.into_inner()).harness == agent)
            .collect();
        let reported = newest_first(of_agent)
            .iter()
            .map(|s| offered(&s.meta.lock().unwrap_or_else(|e| e.into_inner())))
            .find(|m| !m.is_empty());
        reported.unwrap_or_else(|| {
            if profile.kind == crate::config::HarnessKind::ClaudeStdio {
                crate::claude_stdio::MODES
                    .iter()
                    .map(|(id, name, _)| ((*id).to_owned(), Some((*name).to_owned())))
                    .collect()
            } else {
                Vec::new()
            }
        })
    }

    /// Tells local watchers a new chat's start mode may have changed
    /// (`_acpmux/start_mode_changed`), so a pending chat asks again. It
    /// rides the watchers' harness feed (`server/harness_admin.rs`
    /// `watch_note`), marked `START_MODE_NOTE`.
    pub(super) fn start_mode_changed(&self) {
        self.send_harness_change(json!({ (START_MODE_NOTE): true }));
    }
}
