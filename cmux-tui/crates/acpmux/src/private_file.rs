//! A file this user writes made owner-only: mode 0600 on Unix, an owner-only access list on
//! Windows.

/// Owner-only (mode 0600 on Unix, an owner-only access list on Windows)
/// for a file this user writes.
pub(crate) fn owner_only(path: &std::path::Path) {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = crate::home_fs::set_permissions(path, std::fs::Permissions::from_mode(0o600));
    }
    #[cfg(windows)]
    if let Err(e) = crate::owner_only::restrict(path) {
        tracing::warn!("could not make {} owner-only: {e}", path.display());
    }
}
