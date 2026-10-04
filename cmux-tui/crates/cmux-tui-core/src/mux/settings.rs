//! The daemon's settings owner (plans/cmux-next/settings-react.md): one
//! `cmux_config::ConfigStore` per daemon, the watcher of cmux.json and the
//! managed files, and `settings-changed` events. Every apply and every
//! reload runs under the store lock and emits its changes before the lock
//! is released, so events leave in revision order.

use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock, Weak};

use cmux_config::{Change, ConfigStore, ManagedReader, Op, Outcome, Refusal, State, Watcher};
use serde_json::json;

use super::{Mux, MuxEvent};
use crate::resource::{ResourceError, ResourceOperation};

/// The daemon serves `settings.*` and emits `settings-changed`.
pub const SETTINGS_CAPABILITY: &str = "settings-v1";
/// A client capability only the hosting app sends in `set-client-info`. A
/// trusted local connection that sent it may publish value domains and the
/// team policy; every other connection is refused.
pub const SETTINGS_HOST_CAPABILITY: &str = "settings-host-v1";

#[derive(Default)]
pub(crate) struct SettingsSlot(OnceLock<SettingsOwner>);

pub(crate) struct SettingsOwner {
    store: Arc<Mutex<ConfigStore>>,
    _watcher: Option<Watcher>,
}

/// Where the owner reads and writes.
pub struct SettingsPaths {
    pub config: PathBuf,
    /// The cold-start cache goes to `<state_dir>/settings/effective.json`.
    pub state_dir: Option<PathBuf>,
    pub reader: Box<dyn ManagedReader>,
    /// Start the file watcher (off in tests that drive reloads themselves).
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

    /// Starts the owner on `CMUX_NEXT_CONFIG_FILE` or `~/.config/cmux/cmux.json`,
    /// with this session's state directory for the cache.
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
                config: directory.join("cmux.json"),
                state_dir: Some(directory),
                reader: Box::new(cmux_config::managed::FixedManagedReader::default()),
                watch: false,
            };
        }
        SettingsPaths {
            config: cmux_config::config_path(),
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
        emit_changes(self, applied.changes);
        applied.result
    }

    /// Reads the owner's state.
    pub(crate) fn with_settings<T>(self: &Arc<Self>, read: impl FnOnce(&State) -> T) -> T {
        let store = self.settings_store().lock().unwrap_or_else(|poison| poison.into_inner());
        read(store.state())
    }

    /// Re-reads cmux.json and the managed values (the watcher's hint).
    pub fn reload_settings(self: &Arc<Self>) -> Option<Change> {
        let mut store = self.settings_store().lock().unwrap_or_else(|poison| poison.into_inner());
        let change = store.reload();
        emit_changes(self, change.clone());
        change
    }
}

fn emit_changes(mux: &Mux, changes: impl IntoIterator<Item = Change>) {
    for change in changes {
        mux.emit(MuxEvent::SettingsChanged(change));
    }
}

fn open_owner(mux: &Arc<Mux>, paths: SettingsPaths) -> SettingsOwner {
    let watch = paths.watch;
    let store =
        Arc::new(Mutex::new(ConfigStore::open(paths.config, paths.state_dir, paths.reader)));
    let watcher = watch.then(|| start_watcher(Arc::downgrade(mux), &store)).flatten();
    SettingsOwner { store, _watcher: watcher }
}

/// The watcher holds the mux weakly; each hint reloads under the store lock.
fn start_watcher(mux: Weak<Mux>, store: &Arc<Mutex<ConfigStore>>) -> Option<Watcher> {
    let files = store.lock().ok()?.watch_paths();
    let store = Arc::clone(store);
    Watcher::start(files, move || {
        let Some(mux) = mux.upgrade() else { return };
        let mut store = store.lock().unwrap_or_else(|poison| poison.into_inner());
        let change = store.reload();
        emit_changes(&mux, change);
    })
    .ok()
}

/// `settings.domains.publish` and `settings.team_policy.set` come only from
/// the hosting app: a trusted local connection that sent
/// `settings-host-v1` in `set-client-info`.
pub(crate) fn require_hosting_app(
    mux: &Mux,
    client: u64,
    operation: ResourceOperation,
) -> Result<(), ResourceError> {
    if mux.control_clients.is_unix(client)
        && mux.control_clients.supports_capability(client, SETTINGS_HOST_CAPABILITY)
    {
        return Ok(());
    }
    Err(ResourceError::operation_failed(
        operation.wire_name().to_owned(),
        "only the hosting app may send this operation",
        json!({"required_authority":"hosting_app","client_capability":SETTINGS_HOST_CAPABILITY}),
    ))
}
