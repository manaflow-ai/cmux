//! Part of `Hub`; see `hub/mod.rs`. The permission mode a new chat starts
//! in (cx-wx93i; Lawrence 2026-10-14: "by default all chats should be in
//! skip permission mode, that user can switch back"):
//!
//! 1. the person's last mode pick in a chat of this harness profile
//!    (config.json `defaults.<profile>.mode`, written by `note_mode_pick`
//!    from the app pane only), when the harness still offers it;
//! 2. acpmux config.json `defaultPermissionMode` (acpmux without the app,
//!    tests), else the cmux setting `agents.defaultPermissionMode` (the
//!    settings file, `user_settings.rs`): `fullAccess` (the default), `standard` (the
//!    harness's own start mode: acpmux sets nothing) or `ask` (the mode
//!    that asks before each change, `web_modes::ASKING_MODES`, else `ask`);
//! 3. full access: the harness's own mode that skips every approval
//!    (`FULL_ACCESS_MODES`: Claude Code `bypassPermissions`, the Codex
//!    bridge `agent-full-access` = approval never + danger-full-access,
//!    `yolo` where a harness names it so). A harness with no such mode keeps
//!    its own start mode.
//!
//! acpmux sets it with `session/set_mode` once the harness is up. Like the
//! start model it is soft: a refusal is logged (`start_default_skipped`)
//! and the chat runs the harness's own mode. Not for: a remote-origin
//! (Web) session (the remote guard settles its mode,
//! `server/remote_guard.rs`), a preset's chat, a folder profile's chat, an
//! adopted conversation, and a profile that pins its mode in its argv
//! (`profile_sets_mode`).
//!
//! Only the person widens a mode later (`hub/person.rs`). A pick that only
//! repeats what the setting gives saves nothing, so a later setting change
//! still reaches that harness.

use super::*;

/// The cmux setting that chooses the start mode of a new chat.
pub const SETTING: &str = "agents.defaultPermissionMode";

/// Harness mode ids that skip every approval, in preference order.
pub(crate) const FULL_ACCESS_MODES: [&str; 4] =
    ["bypassPermissions", "agent-full-access", "full-access", "yolo"];

/// Mode ids that are a temporary toggle, never a saved pick.
const TOGGLE_MODES: [&str; 1] = ["plan"];

/// The longest mode id a pick saves.
const MAX_MODE: usize = 128;

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
    /// the setting as the settings file holds it now; a missing file, key or
    /// unknown value is full access (Lawrence's default).
    pub(crate) fn resolve(configured: Option<&str>) -> Self {
        if let Some(access) = configured.and_then(Self::parse) {
            return access;
        }
        crate::user_settings::text()
            .and_then(|text| crate::user_settings::document(&text))
            .and_then(|doc| crate::user_settings::value(&doc, SETTING))
            .and_then(|v| v.as_str().and_then(Self::parse))
            .unwrap_or(Self::FullAccess)
    }
}

/// The mode ids a session's harness offers.
fn available(meta: &crate::store::SessionMeta) -> Vec<String> {
    meta.modes
        .as_ref()
        .and_then(|m| m.get("availableModes"))
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|m| m.get("id").and_then(Value::as_str))
        .map(str::to_owned)
        .collect()
}

/// The full-access mode among `available`, if the harness has one.
pub(crate) fn full_access_mode(available: &[String]) -> Option<String> {
    FULL_ACCESS_MODES.iter().find(|m| available.iter().any(|a| a == *m)).map(|m| (*m).to_owned())
}

/// The mode that asks before each change among `available`: the family's
/// asking default (`web_modes::ASKING_MODES`), else a mode named `ask`.
fn asking_mode(family: &str, available: &[String]) -> Option<String> {
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

impl Hub {
    /// The mode a new chat on `session` starts in (module docs), or `None`
    /// to keep the harness's own. `saved`: the profile's saved pick.
    pub(super) async fn start_mode(
        &self,
        session: &Session,
        saved: Option<&str>,
    ) -> Option<String> {
        let meta = session.meta();
        let offered = available(&meta);
        if offered.is_empty() {
            return None;
        }
        let wanted = match saved.filter(|m| offered.iter().any(|a| a == m)) {
            Some(m) => Some(m.to_owned()),
            None => {
                let configured = self.config.read().await.default_permission_mode.clone();
                mode_for(
                    DefaultMode::resolve(configured.as_deref()),
                    &crate::web_modes::family_of(&meta),
                    &offered,
                )
            }
        };
        wanted.filter(|m| crate::web_modes::mode_of(&meta).as_deref() != Some(m.as_str()))
    }

    /// `session/set_mode` from a client. From the app pane (`pick`), once
    /// the harness takes it, the mode is the person's saved pick for the
    /// profile's next new chat.
    pub async fn client_set_mode(
        self: &Arc<Self>,
        session: &Arc<Session>,
        mode: &str,
        pick: bool,
    ) -> Result<Value, RpcError> {
        let r = self.set_mode(session, mode).await?;
        if pick {
            self.note_mode_pick(session, mode).await;
        }
        Ok(r)
    }

    /// Saves a mode pick on `session` as its harness profile's start mode
    /// (config.json `defaults.<profile>.mode`). Not for a preset's or a
    /// folder profile's chat, a remote-origin chat, a toggle such as Plan,
    /// or a profile that pins its mode. A pick equal to what the setting
    /// gives removes the saved mode instead, so the setting decides again.
    pub(super) async fn note_mode_pick(&self, session: &Session, mode: &str) {
        let meta = session.meta();
        if meta.preset.is_some()
            || meta.harness.is_empty()
            || meta.remote_origin
            || mode.is_empty()
            || mode.len() > MAX_MODE
            || TOGGLE_MODES.contains(&mode)
        {
            return;
        }
        let offered = available(&meta);
        let mut cfg = self.config.write().await;
        let from_setting = mode_for(
            DefaultMode::resolve(cfg.default_permission_mode.as_deref()),
            &crate::web_modes::family_of(&meta),
            &offered,
        );
        let Some(profile) = cfg.harnesses.get(&meta.harness) else { return };
        if profile_sets_mode(profile) {
            return;
        }
        let keep = (from_setting.as_deref() != Some(mode)).then(|| mode.to_owned());
        let before = cfg.defaults.get(&meta.harness).and_then(|d| d.mode.clone());
        if before == keep {
            return;
        }
        match keep {
            Some(m) => cfg.defaults.entry(meta.harness.clone()).or_default().mode = Some(m),
            None => {
                if let Some(entry) = cfg.defaults.get_mut(&meta.harness) {
                    entry.mode = None;
                    if entry.is_empty() {
                        cfg.defaults.remove(&meta.harness);
                    }
                }
            }
        }
        if let Err(e) = cfg.save() {
            tracing::warn!(harness = %meta.harness, "mode pick not saved to config.json: {e}");
        }
    }
}
