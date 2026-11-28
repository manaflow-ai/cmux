//! Part of `Hub`; see `hub/mod.rs`. RFD 0170 phase 4: the team and person customization and the
//! `Open in cmux` Slack bindings (`cmux_team_messaging::settings`), kept beside the session store
//! in `team-settings.json` and answered by `server/team_settings.rs`.
//!
//! The file is read on first use, not at start. A write changes the store under its lock and then
//! saves it off the runtime; saves take turns and each writes the store as it is then, so the file
//! always ends at the newest state. A memory store (tests) keeps it in memory only.

use super::*;
use crate::no_panic::LockExt;
use cmux_team_messaging::settings::SettingsStore;
use std::io::Write;
use std::path::PathBuf;

/// The file's name in the daemon's home.
pub const FILE: &str = "team-settings.json";
/// The largest file read back; a larger one is left as it is and the store starts empty.
const MAX_FILE: u64 = 8 << 20;

pub(crate) struct TeamSettingsCell {
    path: Option<PathBuf>,
    store: StdMutex<Option<SettingsStore>>,
    saves: StdMutex<()>,
}

impl TeamSettingsCell {
    pub(crate) fn new(path: Option<PathBuf>) -> Self {
        Self { path, store: StdMutex::new(None), saves: StdMutex::new(()) }
    }

    fn load(&self) -> SettingsStore {
        let Some(path) = &self.path else { return SettingsStore::default() };
        let small = std::fs::metadata(path).is_ok_and(|m| m.len() <= MAX_FILE);
        let read = small.then(|| std::fs::read(path).ok()).flatten();
        read.and_then(|b| serde_json::from_slice::<SettingsStore>(&b).ok())
            .map(SettingsStore::restored)
            .unwrap_or_default()
    }

    /// Run `f` over the store, reading it first if this is its first use.
    pub(crate) fn with<T>(&self, f: impl FnOnce(&mut SettingsStore) -> T) -> T {
        let mut slot = self.store.lock_or_recover();
        let store = slot.get_or_insert_with(|| self.load());
        f(store)
    }

    /// Save the store as it is now. Blocking: call it off the runtime.
    pub(crate) fn save(&self) -> std::io::Result<()> {
        let Some(path) = &self.path else { return Ok(()) };
        let _turn = self.saves.lock_or_recover();
        let bytes = {
            let slot = self.store.lock_or_recover();
            let Some(store) = slot.as_ref() else { return Ok(()) };
            serde_json::to_vec(store).map_err(std::io::Error::other)?
        };
        crate::config::refuse_lost_home(path).map_err(std::io::Error::other)?;
        let dir = path.parent().ok_or_else(|| std::io::Error::other("no parent folder"))?;
        crate::home_fs::create_dir_all(dir, 0o700)?;
        let tmp = path.with_extension(format!("json.{}.tmp", std::process::id()));
        let written = crate::home_fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)
            .and_then(|mut out| {
                out.write_all(&bytes)?;
                out.sync_all()?;
                crate::home_fs::rename(&tmp, path)
            });
        if written.is_err() {
            let _ = crate::home_fs::remove_file(&tmp);
        }
        written
    }
}

impl Hub {
    pub(crate) fn team_settings(&self) -> &TeamSettingsCell {
        &self.team_settings
    }
}
