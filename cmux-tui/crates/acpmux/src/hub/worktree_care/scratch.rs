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
    use std::os::unix::fs::MetadataExt as _;
    match crate::home_fs::create_dir(dir, 0o700) {
        Ok(()) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => {
            let meta = crate::home_fs::symlink_metadata(dir)?;
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
    if crate::home_fs::symlink_metadata(cwd).is_ok() || !is_peer_scratch_in(cwd, temp, uid) {
        return Ok(false);
    }
    own_dir(root, uid)?;
    own_dir(cwd, uid)?;
    match crate::home_fs::OpenOptions::new()
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

/// Whether `rel` (a chat's folder below a temp dir) is `claude-<uid>/<slug>/<uuid>/scratchpad`, the
/// scratch folder Claude Code makes for a session of a project (`<slug>` is the project path with
/// its slashes as dashes). Returns the three parent names to make, in order.
fn claude_scratchpad_parts(rel: &Path, uid: u32) -> Option<[String; 3]> {
    let mut names = Vec::new();
    for c in rel.components() {
        match c {
            std::path::Component::Normal(s) => names.push(s.to_str()?.to_owned()),
            _ => return None,
        }
    }
    let [root, slug, id, leaf] = <[String; 4]>::try_from(names).ok()?;
    (root == format!("claude-{uid}")
        && leaf == "scratchpad"
        && uuid::Uuid::parse_str(&id).is_ok()
        && leaf_name_ok(&slug))
    .then_some([root, slug, id])
}

/// Makes the missing Claude Code scratchpad `cwd` below one of `bases` again (module text of
/// `revive_peer_scratch_in`, same rules): `Ok(true)` when it made it, `Ok(false)` when `cwd` is
/// not one or is there. It is an empty per-session scratch folder under the temp dir, which a
/// temp cleaner (macOS's, a reboot) empties; the agent's own history for that path resumes there.
/// 2026-11-28, cosmic-gray: the coordinator chat's folder was such a scratchpad, gone, so every
/// deadline wake was refused `session.folder_missing` and its held messages sat 23 h overdue until
/// they expired unread.
#[cfg(unix)]
pub(crate) fn revive_claude_scratchpad_in(
    cwd: &Path,
    bases: &[&Path],
    uid: u32,
) -> std::io::Result<bool> {
    if crate::home_fs::symlink_metadata(cwd).is_ok() {
        return Ok(false);
    }
    for base in bases {
        let Some(parts) = cwd.strip_prefix(base).ok().and_then(|r| claude_scratchpad_parts(r, uid))
        else {
            continue;
        };
        let mut dir = base.to_path_buf();
        for part in &parts {
            dir.push(part);
            own_dir(&dir, uid)?;
        }
        own_dir(cwd, uid)?;
        return Ok(true);
    }
    Ok(false)
}

/// `revive_claude_scratchpad_in` for this process's user, below `/private/tmp` and `/tmp`.
#[cfg(unix)]
pub(crate) fn revive_claude_scratchpad(cwd: &Path) -> std::io::Result<bool> {
    revive_claude_scratchpad_in(cwd, &[Path::new("/private/tmp"), Path::new("/tmp")], unsafe {
        libc::geteuid()
    })
}

#[cfg(all(test, unix))]
mod claude_scratchpad_tests {
    use super::*;
    use std::os::unix::fs::MetadataExt as _;

    const ID: &str = "6fcbbd31-ac86-40d4-9bd9-373079591ec2";

    fn base() -> (std::path::PathBuf, u32) {
        let t = std::env::temp_dir().join(format!("acpmux-claude-pad-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&t).unwrap();
        (t, unsafe { libc::geteuid() })
    }

    #[test]
    fn a_gone_claude_scratchpad_is_made_again_owner_only() {
        let (t, uid) = base();
        let cwd =
            t.join(format!("claude-{uid}")).join("-Users-x-Projects").join(ID).join("scratchpad");
        assert!(revive_claude_scratchpad_in(&cwd, &[t.as_path()], uid).unwrap());
        assert_eq!(std::fs::metadata(&cwd).unwrap().mode() & 0o777, 0o700);
        assert!(!revive_claude_scratchpad_in(&cwd, &[t.as_path()], uid).unwrap());
        std::fs::remove_dir_all(&t).unwrap();
    }

    #[test]
    fn only_the_scratchpad_shape_is_made() {
        let (t, uid) = base();
        let root = format!("claude-{uid}");
        for cwd in [
            t.join(&root).join("-p").join(ID),
            t.join(&root).join("-p").join(ID).join("work"),
            t.join(&root).join("-p").join("not-a-uuid").join("scratchpad"),
            t.join(format!("claude-{}", uid + 1)).join("-p").join(ID).join("scratchpad"),
            t.join(&root).join("..").join("x").join(ID).join("scratchpad"),
            t.join("project").join("-p").join(ID).join("scratchpad"),
        ] {
            assert!(
                !revive_claude_scratchpad_in(&cwd, &[t.as_path()], uid).unwrap(),
                "{}",
                cwd.display()
            );
            assert!(!cwd.exists(), "{}", cwd.display());
        }
        std::fs::remove_dir_all(&t).unwrap();
    }
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

    /// A configured temp folder may sit below the home: reads and writes stay in its held tree.
    #[test]
    fn scratch_revival_stays_in_the_held_home() {
        crate::lost_home_race_tests::isolated(
            module_path!(),
            "scratch_revival_stays_in_the_held_home",
            |home| {
                // SAFETY: geteuid takes no arguments and has no caller preconditions.
                let uid = unsafe { libc::geteuid() };
                let temp = home.join("tmp");
                std::fs::create_dir(&temp).unwrap();
                let existing = temp.join(format!("acpmux-peer-scratch-{uid}-{ID}"));
                own_dir(&existing, uid).unwrap();
                crate::config::hold_home();
                crate::lost_home_race_tests::replace(home);
                let new_root = temp.join(format!("acpmux-peer-scratch-{uid}-{}", "0".repeat(32)));
                for root in [existing, new_root] {
                    let cwd = root.join("chat");
                    assert!(revive_peer_scratch_in(&cwd, &temp, uid).unwrap());
                    assert!(!revive_peer_scratch_in(&cwd, &temp, uid).unwrap());
                    let saved = home.with_extension("old").join(cwd.strip_prefix(home).unwrap());
                    assert!(saved.join(crate::trust::AGENT_HOME_MARKER).is_file());
                    assert_eq!(std::fs::metadata(saved).unwrap().mode() & 0o777, 0o700);
                }
                assert!(!home.join("tmp").exists(), "the replacement home stays untouched");
            },
            |_, _| {},
        );
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
