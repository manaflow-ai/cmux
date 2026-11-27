//! Undo of cookie clears in incognito stores (decision D2, issue 13742):
//! an incognito store keeps nothing on disk, so the cookies a clear deletes
//! there stay in memory, under a `host:` restore id like a disk backup's,
//! only while the store lives. Disposing the store drops them; a host exit
//! loses them. Bound: [`crate::cookie_backups::MAX_BACKUPS`] per store; a
//! clear past it is refused before any cookie is deleted.

use serde_json::Value;
use std::collections::{HashMap, HashSet};
use std::sync::{LazyLock, Mutex, MutexGuard, PoisonError};

#[derive(Default)]
struct Memory {
    /// Browser contexts made as incognito stores.
    stores: HashSet<String>,
    /// Restore id -> (store, `{site, store, createdAt, cookies}`).
    backups: HashMap<String, (String, Value)>,
}

static MEMORY: LazyLock<Mutex<Memory>> = LazyLock::new(Mutex::default);

fn memory() -> MutexGuard<'static, Memory> {
    MEMORY.lock().unwrap_or_else(PoisonError::into_inner)
}

/// `context` is an incognito store.
pub(super) fn mark(context: &str) {
    memory().stores.insert(context.to_owned());
}

pub(super) fn is_incognito(context: &str) -> bool {
    memory().stores.contains(context)
}

/// Keeps `record` for `context`; answers its restore id.
pub(super) fn save(context: &str, record: Value) -> Result<String, String> {
    let id = crate::cookie_backups::new_restore_id()?;
    let mut memory = memory();
    let held = memory.backups.values().filter(|(store, _)| store == context).count();
    if held >= crate::cookie_backups::MAX_BACKUPS {
        return Err(format!(
            "this incognito store already holds {held} undo backups; restore one with restoreCookies() first"
        ));
    }
    memory.backups.insert(id.clone(), (context.to_owned(), record));
    Ok(id)
}

/// The store and record of `restore_id`, if it is an incognito backup.
pub(super) fn get(restore_id: &str) -> Option<(String, Value)> {
    memory().backups.get(restore_id).cloned()
}

pub(super) fn remove(restore_id: &str) {
    memory().backups.remove(restore_id);
}

/// The store closed: its backups go with it.
pub(super) fn forget(context: &str) {
    let mut memory = memory();
    memory.stores.remove(context);
    memory.backups.retain(|_, (store, _)| store != context);
}
