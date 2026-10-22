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
}

impl StartModeState {
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

/// The state, loaded from `start-mode.json` at first use.
#[derive(Default)]
pub(crate) struct StartModeCell(StdMutex<Option<StartModeState>>);

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
        if (loaded || *state != before)
            && let Some(path) = path
            && let Err(e) = state.save(path)
        {
            tracing::warn!("{FILE} not saved: {e:#}");
        }
        (before, state.clone())
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
