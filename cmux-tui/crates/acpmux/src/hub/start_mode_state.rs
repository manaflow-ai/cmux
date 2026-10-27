//! Part of `Hub`; see `hub/mod.rs`. What `hub/start_mode.rs` needs beyond
//! config.json and the settings file, from the app's chat settings push
//! (`_acpmux/chat_settings` `permissionMode`, `permissionModeManaged`,
//! `server/chats.rs`). Only the app reads the MDM and team policy layers:
//!
//! - the value of `agents.defaultPermissionMode` that MDM or the team policy
//!   forces. It beats config.json and the settings file. A
//!   forced value that is not a short string is a value acpmux does not
//!   know, which is `standard`, never full access. Best effort, not a
//!   security boundary: any process of the same user can push or edit these
//!   files, and a harness profile that pins its own mode still applies.
//! - the effective value when nothing forces it, for a file with no key: a
//!   team default or an MDM recommended value, so new chats start in what
//!   Settings shows. With the app closed it is the last value pushed.
//! - the `sessions.allowFullAccess` that MDM or the team policy forces
//!   (`allowFullAccess` with `allowFullAccessManaged`): a forced off is an
//!   upper bound the settings file cannot raise (`full_access_bound::full_access_allowed_by`);
//!   a forced on adds nothing. acpmux reads only the file, so without the
//!   push a managed off never reached it.
//! - the setting as acpmux last saw it (the pushed values and the file's
//!   value) and a count of the changes it saw, so a push that changes what a
//!   new chat starts in tells the watchers (`apply_permission_push`). acpmux
//!   looks at each push (the app pushes after each settings change it writes)
//!   and each time a new chat's start mode is decided. A mode picked in a
//!   chat is not kept here: it holds for that chat only (`start_mode.rs`).
//!   A file an older build wrote, with its `epoch`, still loads.
//!
//! Kept in `start-mode.json` beside config.json (owner-only, written through
//! `config::write_atomic`), so a forced value holds across a daemon restart
//! before the app pushes again. A daemon with no config file keeps it in
//! memory. Lock order: the config lock, then the state's mutex.

use super::*;
use serde::{Deserialize, Serialize};

/// The state file's name, beside config.json.
const FILE: &str = "start-mode.json";

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct StartModeState {
    /// The forced `agents.defaultPermissionMode`, as the app pushed it
    /// (`""` for a forced value acpmux could not read).
    pub managed: Option<String>,
    /// The effective setting the app pushed when nothing forces it.
    pub pushed: Option<String>,
    /// The setting as acpmux last saw it (the pushed values and the settings
    /// file's value); `None` before the first look.
    pub seen: Option<String>,
    /// Changes to the setting counted so far.
    pub changes: u64,
    /// The `sessions.allowFullAccess` MDM or the team policy forces, as the app pushed it
    /// (`false` for a forced value that is not `true`). Only `false` acts: an upper bound.
    pub full_access_managed: Option<bool>,
}

impl StartModeState {
    /// Whether MDM or the team policy forces `sessions.allowFullAccess` off.
    fn full_access_off(&self) -> bool {
        self.full_access_managed == Some(false)
    }

    /// The saved state, or a new one when there is none or it cannot be read.
    fn load(path: Option<&Path>) -> Self {
        path.and_then(Self::read).unwrap_or_default()
    }

    fn read(path: &Path) -> Option<Self> {
        use std::io::Read;
        let mut file = match crate::config::private_state_file(path) {
            Ok(file) => file,
            Err(e)
                if e.downcast_ref::<std::io::Error>()
                    .is_some_and(|e| e.kind() == std::io::ErrorKind::NotFound) =>
            {
                return None;
            }
            Err(e) => {
                tracing::warn!("{FILE} not read; the change count starts again: {e:#}");
                return None;
            }
        };
        let mut bytes = Vec::new();
        let parsed = file
            .read_to_end(&mut bytes)
            .map_err(anyhow::Error::from)
            .and_then(|_| serde_json::from_slice(&bytes).map_err(anyhow::Error::from));
        parsed
            .inspect_err(|e| {
                tracing::warn!("{FILE} not read; the change count starts again: {e:#}")
            })
            .ok()
    }

    fn save(&self, path: &Path) -> anyhow::Result<()> {
        let bytes = serde_json::to_vec_pretty(self)?;
        crate::config::write_atomic(path, &bytes)
    }

    /// Counts a change when the setting is not what it was at the last look.
    /// The first look counts nothing.
    fn observe(&mut self) {
        let now =
            json!([self.managed, self.pushed, super::start_mode::setting_snapshot()]).to_string();
        match &self.seen {
            Some(seen) if *seen == now => {}
            Some(_) => {
                self.changes += 1;
                self.seen = Some(now);
            }
            None => self.seen = Some(now),
        }
    }
}

/// The state, loaded from `start-mode.json` when the hub is built (`StartModeCell::load`), so a
/// forced `sessions.allowFullAccess` off holds from the first request after a daemon restart;
/// a daemon with no config file loads it at first use. Beside it, the times that off began,
/// counted with the state under its lock: what runs outside any session watches it (`probe_bound`).
pub(crate) struct StartModeCell(StdMutex<Option<StartModeState>>, tokio::sync::watch::Sender<u64>);

impl StartModeCell {
    /// The state saved beside config.json (`state_file`), read now. Nothing is written until the
    /// first update.
    pub(super) fn load(path: Option<&Path>) -> Self {
        let state = path.map(|p| StartModeState::load(Some(p)));
        Self(StdMutex::new(state), tokio::sync::watch::channel(0).0)
    }
}

/// Where the state is kept: beside config.json, if the daemon has one.
pub(super) fn state_file(cfg: &Config) -> Option<PathBuf> {
    cfg.path.as_ref().and_then(|p| p.parent()).map(|dir| dir.join(FILE))
}

impl Hub {
    /// Applies `change` to the state kept at `path` (`state_file`), looks at
    /// the setting, and saves what changed. Answers the state before and
    /// after. Callers may hold the config lock (never the other way round).
    pub(super) fn update_start_mode_state(
        &self,
        path: Option<&Path>,
        change: impl FnOnce(&mut StartModeState),
    ) -> (StartModeState, StartModeState) {
        let mut cell = self.start_mode_state.0.lock().unwrap_or_else(|e| e.into_inner());
        let loaded = cell.is_none();
        let state = cell.get_or_insert_with(|| StartModeState::load(path));
        let before = state.clone();
        change(state);
        state.observe();
        if state.full_access_off() && !before.full_access_off() {
            self.start_mode_state.1.send_modify(|n| *n += 1);
        }
        if (loaded || *state != before)
            && let Some(path) = path
            && let Err(e) = state.save(path)
        {
            tracing::warn!("{FILE} not saved: {e:#}");
        }
        (before, state.clone())
    }

    /// The times MDM or the team policy forced `sessions.allowFullAccess` off (a count, so an
    /// unset after an off does not hide it from a watcher that has not looked yet; review 46 of
    /// #23322), marked seen, and whether it forces it off now: read together under the state lock,
    /// which both change under (review 75), so an unset between two reads cannot hide an off.
    pub(super) fn full_access_off_now(&self) -> (tokio::sync::watch::Receiver<u64>, u64, bool) {
        let cell = self.start_mode_state.0.lock().unwrap_or_else(|e| e.into_inner());
        let mut offs = self.start_mode_state.1.subscribe();
        let seen = *offs.borrow_and_update();
        let off = cell.as_ref().is_some_and(|s| s.full_access_managed == Some(false));
        (offs, seen, off)
    }

    /// The `sessions.allowFullAccess` MDM or the team policy forces, as last pushed.
    pub(super) fn full_access_managed(&self) -> Option<bool> {
        let cell = self.start_mode_state.0.lock().unwrap_or_else(|e| e.into_inner());
        cell.as_ref().and_then(|s| s.full_access_managed)
    }

    /// The app's push of `sessions.allowFullAccess` (`_acpmux/chat_settings`): the value MDM or
    /// the team policy forces, `None` when nothing forces it. Tells watchers (the pane's mode
    /// menu, `_acpmux/start_mode`) when it changed.
    pub async fn apply_full_access_push(&self, managed: Option<bool>) {
        let path = state_file(&*self.config.read().await);
        let (before, after) = self.update_start_mode_state(path.as_deref(), |state| {
            state.full_access_managed = managed;
        });
        if before.full_access_managed != after.full_access_managed {
            tracing::info!(
                managed = ?after.full_access_managed,
                "{}: MDM or the team policy pushed a new value",
                super::start_mode::ALLOW_FULL_ACCESS
            );
            self.start_mode_changed();
        }
        // Every push of the off crosses the permission barrier, not only the one that changed
        // it: a second push may otherwise return while an ask still decides under the old bound.
        if after.full_access_managed == Some(false) {
            self.full_access_turned_off(before.full_access_managed != Some(false)).await;
        }
    }

    /// The app's push (`_acpmux/chat_settings`): the effective setting and
    /// whether policy forces it. Forced with no value is a forced value
    /// acpmux does not know. Tells watchers when what a new chat starts in
    /// may have changed.
    pub async fn apply_permission_push(&self, effective: Option<String>, managed: bool) {
        let (forced, pushed) =
            if managed { (Some(effective.unwrap_or_default()), None) } else { (None, effective) };
        let path = state_file(&*self.config.read().await);
        let (before, after) = self.update_start_mode_state(path.as_deref(), |state| {
            state.managed = forced;
            state.pushed = pushed;
        });
        if before.managed != after.managed
            || before.pushed != after.pushed
            || before.changes != after.changes
        {
            self.start_mode_changed();
        }
    }
}
