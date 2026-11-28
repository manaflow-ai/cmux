//! The daemon's settings owner (plans/cmux-next/settings-react.md): one
//! `cmux_config::ConfigStore` per daemon, the watcher of the settings file
//! and the managed files, and `settings-changed` events. Every apply and
//! every reload runs under the store lock and emits its changes before the
//! lock is released, so events leave in revision order.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak};

use cmux_config::{Change, ConfigStore, ManagedReader, Op, Outcome, Refusal, State, Watcher};

use super::agent_notification_delivery::{AgentEvent, AgentNotificationLevels, Delivery};
use super::terminal_sizing::host_policy::{
    HostSizePolicy, host_policy_from_state, touches_host_policy,
};
use super::{Mux, MuxEvent};

/// The daemon serves `settings.*` and emits `settings-changed`.
pub const SETTINGS_CAPABILITY: &str = "settings-v1";

/// The daemon serves `settings.edit`: several edits in one publish, the
/// conditional `set_unset` and `reset_unchanged` edits
/// (plans/cmux-next/settings-react.md section 7, items 2 and 3), the
/// `set_exact` edit (a default stays) and the `file` check
/// (`settings.file_mismatch`). v2: v1 had neither.
pub const SETTINGS_EDIT_CAPABILITY: &str = "settings-edit-v2";

/// The daemon records every published change of the settings file and serves
/// `settings.history`, `settings.undo`, `settings.restore` and
/// `settings.reset_group`, for every writer (page, palette, CLI, MCP, hand edit).
pub const SETTINGS_HISTORY_CAPABILITY: &str = "settings-history-v1";

#[derive(Default)]
pub(crate) struct SettingsSlot {
    owner: OnceLock<SettingsOwner>,
    // Hook folds may already hold the lifecycle fence. Read this small snapshot
    // independently of the store, which takes daemon locks when applying edits.
    agent_notifications: Mutex<AgentNotificationLevels>,
    /// `agents.appControl` is `read`: agents in cmux may read the app but
    /// not change it (server/agent_app_control.rs). One load per line.
    agents_read_only: AtomicBool,
}

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
    pub(super) fn agent_notification_delivery(&self, event: Option<AgentEvent>) -> Delivery {
        event.map_or(Delivery::Banner, |event| {
            self.settings
                .agent_notifications
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .for_event(event)
        })
    }

    fn adopt_agent_notification_levels(&self, state: &State) {
        *self.settings.agent_notifications.lock().unwrap_or_else(|e| e.into_inner()) =
            AgentNotificationLevels::from_settings(&state.effective().root);
    }

    /// Whether `agents.appControl` is `read` (server/agent_app_control.rs).
    /// False until the settings owner has read the file.
    pub(crate) fn agents_read_only(&self) -> bool {
        self.settings.agents_read_only.load(Ordering::Relaxed)
    }

    fn adopt_agents_app_control(&self, state: &State) {
        self.settings.agents_read_only.store(agents_read_only(state), Ordering::Relaxed);
    }

    /// Starts the settings owner with `paths`. False when one already runs.
    pub fn start_settings_owner(self: &Arc<Self>, paths: SettingsPaths) -> bool {
        let mut started = false;
        self.settings.owner.get_or_init(|| {
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
        &self.settings.owner.get_or_init(|| open_owner(self, self.default_settings_paths())).store
    }

    /// Runs `op` on the owner and emits every change it produced, including
    /// a hand edit the write-time refresh found when the op was refused.
    pub(crate) fn settings_apply(self: &Arc<Self>, op: Op) -> Result<Outcome, Refusal> {
        let mut store = self.settings_store().lock().unwrap_or_else(|poison| poison.into_inner());
        let applied = store.apply(op);
        let host_policy = host_policy_after(&store, &applied.changes);
        let computer_use = touches_computer_use(&applied.changes);
        adopt_preferences(self, &store, &applied.changes);
        emit_changes(self, applied.changes);
        drop(store);
        if computer_use {
            self.computer_use_policy_changed();
        }
        if let Some((policy, revision)) = host_policy {
            self.adopt_host_size_policy(policy, revision);
        }
        applied.result
    }

    /// The effective settings (every layer merged), as JSON.
    pub(crate) fn settings_effective_root(self: &Arc<Self>) -> serde_json::Value {
        self.with_settings(|state| state.effective().root.clone())
    }

    /// Reads the owner's state.
    pub(crate) fn with_settings<T>(self: &Arc<Self>, read: impl FnOnce(&State) -> T) -> T {
        let store = self.settings_store().lock().unwrap_or_else(|poison| poison.into_inner());
        read(store.state())
    }

    /// The owner's settings file path when it is not `file` (`settings.edit`'s
    /// `file`, `ConfigStore::serves`), else None.
    pub(crate) fn settings_file_mismatch(self: &Arc<Self>, file: &Path) -> Option<PathBuf> {
        let store = self.settings_store().lock().unwrap_or_else(|poison| poison.into_inner());
        (!store.serves(file)).then(|| store.config_path().to_path_buf())
    }

    /// The settings history (`settings.history`), newest first.
    pub(crate) fn settings_history(self: &Arc<Self>) -> Vec<cmux_config::HistoryEntry> {
        self.settings_store().lock().unwrap_or_else(|poison| poison.into_inner()).history()
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

/// Whether `changes` touched a `computerUse.*` key (read after the store
/// lock is released: the Computer Use host reads the settings again).
fn touches_computer_use(changes: &[Change]) -> bool {
    changes
        .iter()
        .flat_map(|change| &change.keys)
        .any(|key| key == "computerUse" || key.starts_with("computerUse."))
}

/// The app setting that frees idle terminals; while on, each terminal keeps
/// its last command for its parked tab (`shell_history::Recording`), and the
/// daemon's freeing timer parks idle terminals (`idle_freeing.rs`).
const FREEING_ENABLED_SETTING: &str = "workspaces.freeing.enabled";
/// Every `workspaces.freeing.*` key the daemon reads.
const FREEING_PREFIX: &str = "workspaces.freeing.";

fn setting(state: &State, key: &str) -> Option<serde_json::Value> {
    state.get(&cmux_config::Target::Key(key.to_string())).row.and_then(|row| row.value)
}

fn freeing_enabled(state: &State) -> bool {
    setting(state, FREEING_ENABLED_SETTING).and_then(|value| value.as_bool()).unwrap_or(false)
}

/// `workspaces.freeing.*` as the freeing timer and `park-tabs` read them; a missing or
/// malformed key takes the schema default.
fn freeing_settings(state: &State) -> super::idle_freeing::FreeingSettings {
    let defaults = super::idle_freeing::FreeingSettings::default();
    let idle = setting(state, "workspaces.freeing.idleMinutes")
        .and_then(|value| value.as_f64())
        .filter(|minutes| minutes.is_finite() && *minutes >= 1.0)
        .map(|minutes| std::time::Duration::from_secs_f64(minutes.min(1e9) * 60.0))
        .unwrap_or(defaults.idle);
    super::idle_freeing::FreeingSettings {
        enabled: freeing_enabled(state),
        idle,
        agents: setting(state, "workspaces.freeing.agents")
            .and_then(|value| value.as_bool())
            .unwrap_or(defaults.agents),
        relaunch_running_commands: setting(state, "workspaces.freeing.runningCommands")
            .and_then(|value| value.as_str().map(|mode| mode == "relaunch"))
            .unwrap_or(defaults.relaunch_running_commands),
    }
}

/// The app setting that lets agents in cmux change the app (`change`, the
/// default) or only read it (`read`).
pub(crate) const AGENTS_APP_CONTROL_SETTING: &str = "agents.appControl";

fn agents_read_only(state: &State) -> bool {
    state
        .get(&cmux_config::Target::Key(AGENTS_APP_CONTROL_SETTING.to_string()))
        .row
        .and_then(|row| row.value)
        .is_some_and(|value| value.as_str() == Some("read"))
}

/// Whether `key` (a changed key) is the app control setting or holds it.
fn touches_agents_app_control(key: &str) -> bool {
    key == "agents" || key == AGENTS_APP_CONTROL_SETTING
}

/// Refresh daemon-owned preferences while changes are still in revision order.
fn adopt_preferences(mux: &Mux, store: &ConfigStore, changes: &[Change]) {
    if changes.iter().flat_map(|change| &change.keys).any(|key| {
        key == "notifications"
            || key == "notifications.delivery"
            || key.starts_with("notifications.delivery.")
    }) {
        mux.adopt_agent_notification_levels(store.state());
    }
    if changes.iter().flat_map(|change| &change.keys).any(|key| touches_agents_app_control(key)) {
        mux.adopt_agents_app_control(store.state());
    }
    if changes.iter().any(|change| change.keys.iter().any(|key| key.starts_with(FREEING_PREFIX))) {
        adopt_freeing_state(mux, store.state());
    }
}

fn adopt_freeing_state(mux: &Mux, state: &State) {
    mux.set_terminal_last_command(freeing_enabled(state) || mux.freeing_overridden());
    mux.set_freeing_settings(freeing_settings(state));
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
        mux.adopt_agent_notification_levels(store.state());
        mux.adopt_agents_app_control(store.state());
        adopt_freeing_state(mux, store.state());
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
        let computer_use = touches_computer_use(&change);
        adopt_preferences(&mux, &store, &change);
        emit_changes(&mux, change);
        drop(store);
        if computer_use {
            mux.computer_use_policy_changed();
        }
        if let Some((policy, revision)) = host_policy {
            mux.adopt_host_size_policy(policy, revision);
        }
    })
    .ok()
}

#[cfg(test)]
mod freeing_default_tests {
    use super::*;

    fn store_with(file: &str) -> ConfigStore {
        let dir = std::env::temp_dir().join(format!(
            "cmux-freeing-default-{}-{}",
            std::process::id(),
            file.len()
        ));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).expect("dir");
        let config = dir.join("cmux-next.json");
        std::fs::write(&config, file).expect("write");
        ConfigStore::open(
            config,
            None,
            None,
            Box::new(cmux_config::managed::FixedManagedReader::default()),
        )
    }

    /// Leo, 2026-11-19: freeing idle shells in workspaces hidden for a day is on by default. A
    /// settings file that never names it turns the daemon's freeing timer on, after a day.
    #[test]
    fn freeing_is_on_by_default_after_a_day() {
        let store = store_with("{}");
        let settings = freeing_settings(store.state());
        assert!(settings.enabled);
        assert_eq!(settings.idle, std::time::Duration::from_secs(1440 * 60));
        assert!(settings.agents);
        assert!(!settings.relaunch_running_commands);
        assert_eq!(settings, super::super::idle_freeing::FreeingSettings::default());
    }

    #[test]
    fn freeing_off_in_the_file_keeps_it_off() {
        let store = store_with(r#"{"workspaces":{"freeing":{"enabled":false}}}"#);
        assert!(!freeing_settings(store.state()).enabled);
    }
}
