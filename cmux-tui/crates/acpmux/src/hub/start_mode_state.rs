//! Part of `Hub`; see `hub/mod.rs`. What `hub/start_mode.rs` needs beyond
//! config.json and the settings file:
//!
//! - the value of `agents.defaultPermissionMode` that MDM or the team policy
//!   forces. Only the app reads those layers; it pushes the effective value
//!   with every chat settings push (`_acpmux/chat_settings` `permissionMode`,
//!   `permissionModeManaged`, `server/chats.rs`). A forced value beats
//!   config.json, the settings file and every pick.
//! - a count of changes to the setting, for "latest choice wins": a pick
//!   records the count (`lastPermissionModeChange`) and wins only while no
//!   change has been counted since. Counting changes, not comparing values,
//!   means a setting changed and changed back still wins over an older pick.
//!   acpmux counts a change when it sees the setting (the forced value and
//!   the file's value) differ from the last time it looked: at each push
//!   (the app pushes after each settings change it writes) and each time a
//!   new chat's start mode is decided. A change and its undo made while
//!   neither happens (the app closed, the file edited twice by hand) is not
//!   seen.
//!
//! Kept in `start-mode.json` beside config.json (0600, written through a
//! temp file and a rename), so a forced value holds across a daemon restart
//! before the app pushes again. A daemon with no config file keeps it in
//! memory.

use super::*;
use serde::{Deserialize, Serialize};

/// The state file's name, beside config.json.
const FILE: &str = "start-mode.json";

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub(crate) struct StartModeState {
    /// The forced `agents.defaultPermissionMode`, as the app pushed it.
    pub managed: Option<String>,
    /// The setting as acpmux last saw it (the forced value and the settings
    /// file's value); `None` before the first look.
    pub seen: Option<String>,
    /// Changes to the setting counted so far.
    pub changes: u64,
}

impl StartModeState {
    fn load(path: Option<&Path>) -> Self {
        path.and_then(|p| std::fs::read(p).ok())
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    fn save(&self, path: &Path) -> std::io::Result<()> {
        use std::io::Write;
        let bytes = serde_json::to_vec_pretty(self).map_err(std::io::Error::other)?;
        let tmp = path.with_extension("json.tmp");
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create(true).truncate(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let mut file = options.open(&tmp)?;
        file.write_all(&bytes)?;
        file.sync_all()?;
        std::fs::rename(&tmp, path)
    }

    /// Counts a change when the setting is not what it was at the last look.
    /// The first look counts nothing.
    fn observe(&mut self) {
        let now = json!([self.managed, super::start_mode::setting_snapshot()]).to_string();
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

impl Hub {
    /// Where the state is kept: beside config.json, if the daemon has one.
    async fn start_mode_file(&self) -> Option<PathBuf> {
        let cfg = self.config.read().await;
        cfg.path.as_ref().and_then(|p| p.parent()).map(|dir| dir.join(FILE))
    }

    /// Applies `change` to the state, looks at the setting, and saves what
    /// changed. Answers the state before and after.
    async fn with_start_mode_state(
        &self,
        change: impl FnOnce(&mut StartModeState),
    ) -> (StartModeState, StartModeState) {
        let path = self.start_mode_file().await;
        let mut cell = self.start_mode_state.0.lock().unwrap_or_else(|e| e.into_inner());
        let state = cell.get_or_insert_with(|| StartModeState::load(path.as_deref()));
        let before = state.clone();
        change(state);
        state.observe();
        if *state != before
            && let Some(path) = &path
            && let Err(e) = state.save(path)
        {
            tracing::warn!("{FILE} not saved: {e}");
        }
        (before, state.clone())
    }

    /// The forced value and the change count as they are now.
    pub(super) async fn start_mode_state(&self) -> StartModeState {
        self.with_start_mode_state(|_| {}).await.1
    }

    /// The app's push (`_acpmux/chat_settings`): the effective setting and
    /// whether policy forces it. Tells watchers when what a new chat starts
    /// in may have changed.
    pub async fn apply_permission_push(&self, effective: Option<String>, managed: bool) {
        let forced = effective.filter(|_| managed);
        let (before, after) = self.with_start_mode_state(|state| state.managed = forced).await;
        if before.managed != after.managed || before.changes != after.changes {
            self.start_mode_changed();
        }
    }
}
