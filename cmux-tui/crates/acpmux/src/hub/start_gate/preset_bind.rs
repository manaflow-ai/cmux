//! A preset's approval bound to what a session actually runs (`hub/person.rs`
//! (b)). The approval is checked when a request comes in, but the contents
//! are read again when the session resolves (model, effort, env) and at
//! every spawn (args, env, system prompt): each read records the
//! [`crate::config::Preset::approval_digest`] of the contents it used, and
//! the start counts the approval only when every read matches it. A later
//! respawn from contents the person did not approve does not get the mode
//! the approval gave back.

use super::*;

/// Why a `session/new` may start in its mode (`Hub::start_mode_check`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum StartGrant {
    /// The connection is the person.
    Person,
    /// The mode asks.
    Asks,
    /// A preset the person approved, as the session runs it.
    Preset,
    /// The caller session's own mode.
    Inherit,
}

impl Hub {
    /// The approval digest of the preset contents `session/new` resolved
    /// with (model, effort, policy, env), before its first spawn.
    pub(in crate::hub) fn note_preset_resolved(&self, s: &Session, digest: Option<String>) {
        s.applied.lock().unwrap_or_else(|e| e.into_inner()).preset_resolved = digest;
    }

    /// At a spawn: the approval digest of the preset contents this spawn
    /// used (`spawn.rs`, read under the same config lock as the contents).
    /// A session that got its mode from a preset approval and now spawns
    /// from other contents leaves that mode for the harness's own (module
    /// docs): the saved mode is not replayed.
    pub(in crate::hub) fn note_preset_spawned(&self, s: &Session, digest: Option<String>) {
        s.applied.lock().unwrap_or_else(|e| e.into_inner()).preset_spawned = digest.clone();
        let dropped = {
            let mut m = s.meta.lock().unwrap_or_else(|e| e.into_inner());
            let kept = match (m.preset_mode_approval.as_deref(), digest.as_deref()) {
                (None, _) => true,
                (Some(approved), Some(now)) => cmux_local_auth::tokens_match(now, approved),
                (Some(_), None) => false,
            };
            if !kept {
                m.preset_mode_approval = None;
                let family = crate::web_modes::family_of(&m);
                let mode = crate::web_modes::mode_of(&m);
                if !self.web_modes().config_value_asks(&family, None, mode.as_deref()) {
                    forget_mode(&mut m);
                }
            }
            !kept
        };
        if dropped {
            self.append(s, "mux", "preset_mode_dropped", json!({"preset": s.meta().preset}));
            self.save_meta(s);
        }
    }

    /// `session/new`'s start mode, with the preset approval held against
    /// the contents session `s` resolved and spawned with: the approved
    /// digest when both match it (`StartMode::preset_approved` is then
    /// `preset_fits` and that). None when the request asks for no mode.
    pub(in crate::hub) async fn bound_start(
        &self,
        params: &Value,
        s: &Session,
    ) -> Option<(StartMode, Option<String>)> {
        let cfg = self.config.read().await;
        let mut start = StartMode::of(params, &cfg)?;
        let approval = start
            .preset
            .as_deref()
            .and_then(|n| cfg.presets.get(n))
            .filter(|p| p.mode.is_some())
            .and_then(|p| p.mode_approval.clone());
        let bound = {
            let a = s.applied.lock().unwrap_or_else(|e| e.into_inner());
            let same = |d: &Option<String>, approved: &str| {
                d.as_deref().is_some_and(|d| cmux_local_auth::tokens_match(d, approved))
            };
            approval.filter(|d| same(&a.preset_resolved, d) && same(&a.preset_spawned, d))
        };
        start.preset_approved = start.preset_fits && bound.is_some();
        Some((start, bound))
    }

    /// After the start mode is set: a mode a preset approval gave is
    /// recorded with the approved digest, so a respawn from other contents
    /// leaves it (`note_preset_spawned`).
    pub(in crate::hub) fn note_start_grant(
        &self,
        s: &Session,
        grant: StartGrant,
        bound: Option<String>,
    ) {
        if grant == StartGrant::Preset {
            s.meta.lock().unwrap_or_else(|e| e.into_inner()).preset_mode_approval = bound;
            self.save_meta(s);
        }
    }
}

/// A fresh agent for `s` (`Hub::ensure_child`): nothing acpmux set on the last
/// one is assumed, but the preset digests stay, since `spawn_profile` noted
/// them for this spawn's contents just before.
pub(in crate::hub) fn fresh_applied(s: &Session) {
    let mut a = s.applied.lock().unwrap_or_else(|e| e.into_inner());
    *a = crate::hub::session::Applied {
        preset_resolved: a.preset_resolved.take(),
        preset_spawned: a.preset_spawned.take(),
        ..Default::default()
    };
}

/// Forget a session's saved mode (its ACP mode and its `mode` option), so a
/// spawn starts in the harness's own and replays none.
fn forget_mode(m: &mut crate::store::SessionMeta) {
    if let Some(modes) = m.modes.as_mut().and_then(Value::as_object_mut) {
        modes.remove("currentModeId");
    }
    if let Some(opts) = m.config_options.as_mut().and_then(Value::as_array_mut) {
        for o in opts.iter_mut().filter(|o| o.get("id").and_then(Value::as_str) == Some("mode")) {
            o["currentValue"] = Value::Null;
        }
    }
}
