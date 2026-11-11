//! The daemon's settings owner (plans/cmux-next/settings-react.md): one
//! `cmux_config::ConfigStore` per daemon, the watcher of the settings file
//! and the managed files, and `settings-changed` events. Every apply and
//! every reload runs under the store lock and emits its changes before the
//! lock is released, so events leave in revision order.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock, Weak};

use cmux_config::{Change, ConfigStore, ManagedReader, Op, Outcome, Refusal, State, Watcher};

use super::terminal_sizing::host_policy::{
    HostSizePolicy, host_policy_from_state, touches_host_policy,
};
use super::{Mux, MuxEvent};

/// The daemon serves `settings.*` and emits `settings-changed`.
pub const SETTINGS_CAPABILITY: &str = "settings-v1";

#[derive(Default)]
pub(crate) struct SettingsSlot(OnceLock<SettingsOwner>);

pub(crate) struct SettingsOwner {
    store: Arc<Mutex<ConfigStore>>,
    _watcher: Option<Watcher>,
}

/// Where the owner reads and writes.
pub struct SettingsPaths {
    pub config: PathBuf,
    /// Read while `config` does not exist (classic `cmux.json`).
    pub seed: Option<PathBuf>,
    /// The cold-start cache goes to `<state_dir>/settings/effective.json`.
    pub state_dir: Option<PathBuf>,
    pub reader: Box<dyn ManagedReader>,
    /// Start the file watcher.
    pub watch: bool,
}

impl Mux {
    /// Starts the settings owner with `paths`. False when one already runs.
    pub fn start_settings_owner(self: &Arc<Self>, paths: SettingsPaths) -> bool {
        let mut started = false;
        self.settings.0.get_or_init(|| {
            started = true;
            open_owner(self, paths)
        });
        started
    }

    /// Starts the owner on `CMUX_NEXT_CONFIG_FILE` or
    /// `~/.config/cmux/cmux-next.json`, with this session's state directory
    /// for the cache. The variable is the launch input for the settings
    /// file: the Mac app sets it on the `server ensure` that starts its
    /// daemon, the detached owner inherits it, and a `server restart`
    /// carries it to the next owner (`CarriedLaunch` in cmux-tui).
    pub fn start_default_settings_owner(self: &Arc<Self>) -> bool {
        self.start_settings_owner(self.default_settings_paths())
    }

    fn default_settings_paths(self: &Arc<Self>) -> SettingsPaths {
        if cfg!(test) {
            // Unit tests never touch the user's settings file.
            let directory = std::env::temp_dir().join(format!(
                "cmux-settings-test-{}-{}",
                std::process::id(),
                self.session
            ));
            return SettingsPaths {
                config: directory.join("cmux-next.json"),
                seed: None,
                state_dir: Some(directory),
                reader: Box::new(cmux_config::managed::FixedManagedReader::default()),
                watch: false,
            };
        }
        SettingsPaths {
            config: cmux_config::config_path(),
            seed: cmux_config::seed_path(),
            state_dir: self.session_state_directory(),
            reader: cmux_config::managed::default_reader(|name| std::env::var(name).ok()),
            watch: true,
        }
    }

    fn settings_store(self: &Arc<Self>) -> &Arc<Mutex<ConfigStore>> {
        &self.settings.0.get_or_init(|| open_owner(self, self.default_settings_paths())).store
    }

    /// Runs `op` on the owner and emits every change it produced, including
    /// a hand edit the write-time refresh found when the op was refused.
    pub(crate) fn settings_apply(self: &Arc<Self>, op: Op) -> Result<Outcome, Refusal> {
        let mut store = self.settings_store().lock().unwrap_or_else(|poison| poison.into_inner());
        let applied = store.apply(op);
        let host_policy = host_policy_after(&store, &applied.changes);
        adopt_freeing(self, &store, &applied.changes);
        emit_changes(self, applied.changes);
        drop(store);
        if let Some((policy, revision)) = host_policy {
            self.adopt_host_size_policy(policy, revision);
        }
        applied.result
    }

    /// Reads the owner's state.
    pub(crate) fn with_settings<T>(self: &Arc<Self>, read: impl FnOnce(&State) -> T) -> T {
        let store = self.settings_store().lock().unwrap_or_else(|poison| poison.into_inner());
        read(store.state())
    }

    /// The `settings.snapshot` answer, with the owner's settings file path.
    pub(crate) fn settings_snapshot(self: &Arc<Self>) -> serde_json::Value {
        self.settings_store().lock().unwrap_or_else(|poison| poison.into_inner()).snapshot_json()
    }
}

/// The host sizing policy the store now holds, when `changes` touched it.
/// With the store revision it was read at (adopted in revision order).
fn host_policy_after(store: &ConfigStore, changes: &[Change]) -> Option<(HostSizePolicy, u64)> {
    changes
        .iter()
        .any(|change| touches_host_policy(&change.keys))
        .then(|| (host_policy_from_state(store.state()), store.state().revision()))
}

/// The app setting that frees idle terminals; while on, each terminal keeps
/// its last command for its parked tab (`shell_history::Recording`).
const FREEING_ENABLED_SETTING: &str = "workspaces.freeing.enabled";

fn freeing_enabled(state: &State) -> bool {
    state
        .get(&cmux_config::Target::Key(FREEING_ENABLED_SETTING.to_string()))
        .row
        .and_then(|row| row.value)
        .and_then(|value| value.as_bool())
        .unwrap_or(false)
}

/// Adopts `workspaces.freeing.enabled` when `changes` touched it.
fn adopt_freeing(mux: &Mux, store: &ConfigStore, changes: &[Change]) {
    if changes.iter().any(|change| change.keys.iter().any(|key| key == FREEING_ENABLED_SETTING)) {
        mux.set_terminal_last_command(freeing_enabled(store.state()));
    }
}

fn emit_changes(mux: &Mux, changes: impl IntoIterator<Item = Change>) {
    let mut changed = false;
    for change in changes {
        changed |= change.keys.iter().any(|key| {
            key == "notifications.agentIdleTimers"
                || key.starts_with("notifications.agentIdleTimers.")
        });
        mux.emit(MuxEvent::SettingsChanged(change));
    }
    // The idle reminders live in agent_chat_notices, which is unix only.
    #[cfg(unix)]
    if changed {
        mux.reload_cache_ttl_timers();
    }
    #[cfg(not(unix))]
    let _ = changed;
}

fn open_owner(mux: &Arc<Mux>, paths: SettingsPaths) -> SettingsOwner {
    let watch = paths.watch;
    let store = Arc::new(Mutex::new(ConfigStore::open(
        paths.config,
        paths.seed,
        paths.state_dir,
        paths.reader,
    )));
    let watcher = watch.then(|| start_watcher(Arc::downgrade(mux), &store)).flatten();
    // The host sizing policy follows the file from its first read.
    let host_policy = store
        .lock()
        .ok()
        .map(|store| (host_policy_from_state(store.state()), store.state().revision()));
    if let Some((policy, revision)) = host_policy {
        mux.adopt_host_size_policy(policy, revision);
    }
    if let Ok(store) = store.lock() {
        mux.set_terminal_last_command(freeing_enabled(store.state()));
    }
    SettingsOwner { store, _watcher: watcher }
}

/// The watcher holds the mux weakly; each hint reloads under the store lock.
fn start_watcher(mux: Weak<Mux>, store: &Arc<Mutex<ConfigStore>>) -> Option<Watcher> {
    let files = store.lock().ok()?.watch_paths();
    let store = Arc::clone(store);
    Watcher::start(files, move || {
        let Some(mux) = mux.upgrade() else { return };
        let mut store = store.lock().unwrap_or_else(|poison| poison.into_inner());
        let change: Vec<Change> = store.reload().into_iter().collect();
        let host_policy = host_policy_after(&store, &change);
        adopt_freeing(&mux, &store, &change);
        emit_changes(&mux, change);
        drop(store);
        if let Some((policy, revision)) = host_policy {
            mux.adopt_host_size_policy(policy, revision);
        }
    })
    .ok()
}
