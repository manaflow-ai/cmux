//! The daemon's keybindings.json owner (K-T6, cx-9ce.17): one
//! `cmux_config::KeybindingsStore` per daemon on the file beside the
//! settings file, its watcher, and `keybindings-changed` events. Every apply
//! and every reload runs under the store lock and emits its changes before
//! the lock is released, so events leave in revision order.

use cmux_threads::sync::Mutex;
use std::path::PathBuf;
use std::sync::{Arc, OnceLock, Weak};

use cmux_config::{
    KeybindingsChange, KeybindingsOp, KeybindingsOutcome, KeybindingsRefusal, KeybindingsStore,
    Origin, Watcher,
};

use super::mux_work::Sequence;
use super::settings::post_reload;
use super::{Mux, MuxEvent};

/// The daemon serves `keybindings.*` and emits `keybindings-changed`.
pub const KEYBINDINGS_CAPABILITY: &str = "keybindings-v1";

#[derive(Default)]
pub(crate) struct KeybindingsSlot(OnceLock<KeybindingsOwner>);

pub(crate) struct KeybindingsOwner {
    store: Arc<Mutex<KeybindingsStore>>,
    _watcher: Option<Watcher>,
}

impl Mux {
    /// Starts the owner on keybindings.json beside the settings file
    /// (`CMUX_NEXT_CONFIG_FILE` or `~/.config/cmux/cmux-next.json`).
    pub fn start_default_keybindings_owner(self: &Arc<Self>) -> bool {
        let mut started = false;
        self.keybindings.0.get_or_init(|| {
            started = true;
            open_owner(self)
        });
        started
    }

    fn keybindings_store(self: &Arc<Self>) -> &Arc<Mutex<KeybindingsStore>> {
        &self.keybindings.0.get_or_init(|| open_owner(self)).store
    }

    /// Runs `op` and emits every change it produced, including a hand edit
    /// the write-time refresh found when the op was refused.
    pub(crate) fn keybindings_apply(
        self: &Arc<Self>,
        op: KeybindingsOp,
        origin: Origin,
        idempotency_key: Option<String>,
    ) -> Result<KeybindingsOutcome, KeybindingsRefusal> {
        let mut store =
            self.keybindings_store().lock().unwrap_or_else(|poison| poison.into_inner());
        let applied = store.apply(op, origin, idempotency_key);
        emit_changes(self, applied.changes);
        applied.result
    }

    /// Reads the owner's state.
    pub(crate) fn with_keybindings<T>(
        self: &Arc<Self>,
        read: impl FnOnce(&KeybindingsStore) -> T,
    ) -> T {
        let store = self.keybindings_store().lock().unwrap_or_else(|poison| poison.into_inner());
        read(&store)
    }
}

fn emit_changes(mux: &Mux, changes: impl IntoIterator<Item = KeybindingsChange>) {
    for change in changes {
        mux.emit(MuxEvent::KeybindingsChanged(change));
    }
}

fn keybindings_path(mux: &Mux) -> (PathBuf, bool) {
    if cfg!(test) {
        // Unit tests never touch the user's keys.
        let directory = std::env::temp_dir().join(format!(
            "cmux-keybindings-test-{}-{}",
            std::process::id(),
            mux.session
        ));
        return (directory.join("keybindings.json"), false);
    }
    (cmux_config::keybindings_path(&cmux_config::config_path()), true)
}

fn open_owner(mux: &Arc<Mux>) -> KeybindingsOwner {
    let (path, watch) = keybindings_path(mux);
    let store = Arc::new(Mutex::new(KeybindingsStore::open(path)));
    let watcher = watch.then(|| start_watcher(Arc::downgrade(mux), &store)).flatten();
    KeybindingsOwner { store, _watcher: watcher }
}

/// The watcher holds the mux weakly; each hint reloads under the store lock.
fn start_watcher(mux: Weak<Mux>, store: &Arc<Mutex<KeybindingsStore>>) -> Option<Watcher> {
    let files = store.lock().ok()?.watch_paths();
    let store = Arc::clone(store);
    let reloads = Arc::new(Sequence::default());
    Watcher::start(files, move || {
        let store = Arc::clone(&store);
        // Off the utility watch thread (settings.rs `post_reload`).
        post_reload(&mux, &reloads, move |mux| {
            let mut store = store.lock().unwrap_or_else(|poison| poison.into_inner());
            let change = store.reload();
            emit_changes(mux, change);
        });
    })
    .ok()
}
