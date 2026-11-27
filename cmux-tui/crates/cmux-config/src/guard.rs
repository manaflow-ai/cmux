//! The managed-key guard every write path passes (Swift `ManagedKeyGuard`
//! and `SettingsController.managedKey(forPath:)`).

use std::collections::BTreeMap;

use crate::keypath::key_path;
use crate::managed::ManagedSource;

/// The managed key a write at `path` would change: the path is the key,
/// inside it, or an ancestor object of it. Keys are checked in sorted order.
pub fn managed_key_for_path<'a>(
    managed: &'a BTreeMap<String, ManagedSource>,
    path: &[String],
) -> Option<(&'a str, &'a ManagedSource)> {
    managed.iter().find_map(|(key, source)| {
        let managed_path = key_path(key);
        (path.starts_with(&managed_path) || managed_path.starts_with(path))
            .then_some((key.as_str(), source))
    })
}

/// The managed key whose own value removing `path` would remove (the path
/// is the key or inside it). Removing an ancestor object is allowed: it only
/// prunes the user's file, and the managed value still applies.
pub fn managed_key_for_removal<'a>(
    managed: &'a BTreeMap<String, ManagedSource>,
    path: &[String],
) -> Option<(&'a str, &'a ManagedSource)> {
    managed.iter().find_map(|(key, source)| {
        path.starts_with(&key_path(key)).then_some((key.as_str(), source))
    })
}
