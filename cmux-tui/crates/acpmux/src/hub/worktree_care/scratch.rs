//! Make a proven peer's scratch folder again when it is gone, so its chat goes on.
//!
//! A peer's chat that names no folder runs in `<temp>/acpmux-peer-scratch-<uid>-<id>/<name>`
//! (`server/remote_guard.rs` `peer_scratch`), an empty folder acpmux made for it. The temp dir
//! does not outlive a reboot (macOS empties `/var/folders/.../T`), so after one the daemon's
//! restart continuation of a cut turn (`restart_resume.rs`) was refused as
//! `session.folder_missing` and the chat sat idle with its work undone (3 of the 11 dead
//! sessions on NOW, 2026-11-26). The folder held nothing of the person's: it is made again,
//! owner-only, at the same path, so the agent's own history for that path (Claude Code keys it
//! by folder) resumes there.
//!
//! Only a path of exactly that shape is made, and only in this user's own temp dir. A folder
//! that exists already must be a directory (never a link) this user owns that no one else may
//! write or read, as `peer_scratch_root` makes it; otherwise it is left alone and the prompt is
//! refused as before.

use std::path::Path;

/// The scratch root's name for this user: `acpmux-peer-scratch-<uid>-<32 hex>`.
fn root_name_ok(name: &str, uid: u32) -> bool {
    name.strip_prefix(&format!("acpmux-peer-scratch-{uid}-"))
        .is_some_and(|id| id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// A chat's folder name as `scratch_name` makes it: letters, digits, `.`, `-`, `_`, not all dots.
fn leaf_name_ok(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 80
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'-' | b'_'))
        && !name.bytes().all(|b| b == b'.')
}

/// Whether `cwd` is a peer scratch folder of this user's in `temp`.
pub(crate) fn is_peer_scratch_in(cwd: &Path, temp: &Path, uid: u32) -> bool {
    let (Some(leaf), Some(root)) = (cwd.file_name(), cwd.parent()) else { return false };
    let (Some(root_name), Some(temp_of)) = (root.file_name(), root.parent()) else {
        return false;
    };
    let same_temp = temp_of == temp
        || std::fs::canonicalize(temp_of)
            .ok()
            .zip(std::fs::canonicalize(temp).ok())
            .is_some_and(|(a, b)| a == b);
    same_temp
        && root_name.to_str().is_some_and(|n| root_name_ok(n, uid))
        && leaf.to_str().is_some_and(leaf_name_ok)
}

/// Makes `dir` owner-only, or accepts it when it is already this user's owner-only folder.
#[cfg(unix)]
fn own_dir(dir: &Path, uid: u32) -> std::io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt as _, MetadataExt as _};
    match std::fs::DirBuilder::new().mode(0o700).create(dir) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            let meta = std::fs::symlink_metadata(dir)?;
            if meta.file_type().is_dir() && meta.uid() == uid && meta.mode() & 0o077 == 0 {
                Ok(())
            } else {
                Err(std::io::Error::other(format!(
                    "{} is not this user's own owner-only folder",
                    dir.display()
                )))
            }
        }
        Err(e) => Err(e),
    }
}

/// Makes the missing peer scratch folder `cwd` again (module text): `Ok(true)` when it made it,
/// `Ok(false)` when `cwd` is not one or is there.
#[cfg(unix)]
pub(crate) fn revive_peer_scratch_in(cwd: &Path, temp: &Path, uid: u32) -> std::io::Result<bool> {
    let Some(root) = cwd.parent() else { return Ok(false) };
    if std::fs::symlink_metadata(cwd).is_ok() || !is_peer_scratch_in(cwd, temp, uid) {
        return Ok(false);
    }
    own_dir(root, uid)?;
    own_dir(cwd, uid)?;
    match std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(cwd.join(crate::trust::AGENT_HOME_MARKER))
    {
        Ok(_) => {}
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(e) => return Err(e),
    }
    Ok(true)
}

/// `revive_peer_scratch_in` for this process's user and temp dir.
#[cfg(unix)]
pub(crate) fn revive_peer_scratch(cwd: &Path) -> std::io::Result<bool> {
    revive_peer_scratch_in(cwd, &std::env::temp_dir(), unsafe { libc::geteuid() })
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};

    fn temp() -> (std::path::PathBuf, u32) {
        let t = std::env::temp_dir().join(format!("acpmux-scratch-test-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&t).unwrap();
        (t, unsafe { libc::geteuid() })
    }

    const ID: &str = "01a2106c092f771986ec4df02e98b4eb";

    /// The 11-26 dead chats: their scratch root went with the temp dir; the folder comes back
    /// owner-only, marked as acpmux's, at the same path.
    #[test]
    fn a_gone_peer_scratch_folder_is_made_again_owner_only() {
        let (t, uid) = temp();
        let cwd = t.join(format!("acpmux-peer-scratch-{uid}-{ID}")).join("mac-runners-heal-origin");
        assert!(revive_peer_scratch_in(&cwd, &t, uid).unwrap());
        for dir in [cwd.parent().unwrap(), cwd.as_path()] {
            let meta = std::fs::symlink_metadata(dir).unwrap();
            assert!(meta.is_dir());
            assert_eq!(meta.mode() & 0o777, 0o700, "{}", dir.display());
        }
        assert!(cwd.join(crate::trust::AGENT_HOME_MARKER).is_file());
        // There now: nothing to do.
        assert!(!revive_peer_scratch_in(&cwd, &t, uid).unwrap());
        // A second chat under the same remade root.
        let other = cwd.parent().unwrap().join("cmux24-runner-heal");
        assert!(revive_peer_scratch_in(&other, &t, uid).unwrap());
        std::fs::remove_dir_all(&t).unwrap();
    }

    /// Any other folder stays gone: another shape, another user's root, another temp dir.
    #[test]
    fn only_a_peer_scratch_folder_in_this_users_temp_is_made() {
        let (t, uid) = temp();
        let elsewhere =
            std::env::temp_dir().join(format!("acpmux-elsewhere-{}", uuid::Uuid::now_v7()));
        for cwd in [
            t.join("project"),
            t.join(format!("acpmux-peer-scratch-{uid}-{ID}")),
            t.join(format!("acpmux-peer-scratch-{}-{ID}", uid + 1)).join("x"),
            t.join(format!("acpmux-peer-scratch-{uid}-short")).join("x"),
            t.join(format!("acpmux-peer-scratch-{uid}-{ID}")).join(".."),
            t.join(format!("acpmux-peer-scratch-{uid}-{ID}")).join("a b"),
            elsewhere.join(format!("acpmux-peer-scratch-{uid}-{ID}")).join("x"),
        ] {
            assert!(!revive_peer_scratch_in(&cwd, &t, uid).unwrap(), "{}", cwd.display());
            assert!(!cwd.exists(), "{}", cwd.display());
        }
        std::fs::remove_dir_all(&t).unwrap();
    }

    /// A root someone else could write is not used.
    #[test]
    fn a_root_others_may_write_is_refused() {
        let (t, uid) = temp();
        let root = t.join(format!("acpmux-peer-scratch-{uid}-{ID}"));
        std::fs::create_dir(&root).unwrap();
        std::fs::set_permissions(&root, std::fs::Permissions::from_mode(0o777)).unwrap();
        assert!(revive_peer_scratch_in(&root.join("x"), &t, uid).is_err());
        assert!(!root.join("x").exists());
        std::fs::remove_dir_all(&t).unwrap();
    }
}
