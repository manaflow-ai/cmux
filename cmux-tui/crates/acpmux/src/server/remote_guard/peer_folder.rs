//! A proven peer's (the owner's own daemon's) `session/new` folder (`remote_guard.rs`): a
//! missing one inside a root is made without ever following a link, and a refused one says
//! what `mkdir -p` would make of it and which folder inside the roots to use instead.

use super::{canonical_dir, folder_refused, fs_spelling};
use crate::rpc::RpcError;
use serde_json::Value;
use std::path::{Component, Path, PathBuf};

/// A proven peer's missing `cwd` that lies inside a root once its nearest existing folder is
/// resolved: made (owner-only) when `make`, and returned canonical; `Ok(None)` when it would
/// be made but `make` is off. `Err(None)`: it would lie outside every root, so nothing is
/// made; `Err(Some(_))`: it is no absolute path, or the make failed.
pub(super) async fn make_inside_root(
    cwd: &str,
    roots: &[PathBuf],
    make: bool,
) -> Result<Option<String>, Option<RpcError>> {
    let path = Path::new(cwd);
    if !path.is_absolute() {
        return Err(Some(folder_refused("cwd")));
    }
    let inside = |p: &Path| roots.iter().any(|root| p.starts_with(root));
    let mut base = None;
    for ancestor in path.ancestors().skip(1) {
        if let Some(found) = fs_spelling(&ancestor.to_string_lossy()).await
            && found.is_dir()
        {
            base = Some((ancestor, found));
            break;
        }
    }
    let Some((ancestor, found)) = base else { return Err(None) };
    let rest = path.strip_prefix(ancestor).map_err(|_| None)?.to_path_buf();
    // Only plain names below the folder that exists: a `..` or `.` there is not followed.
    if !rest.components().all(|c| matches!(c, std::path::Component::Normal(_))) {
        return Err(None);
    }
    let target = found.join(&rest);
    if !inside(&target) {
        return Err(None);
    }
    if !make {
        return Ok(None);
    }
    let made = tokio::task::spawn_blocking(move || make_below(&found, &rest)).await;
    if !matches!(made, Ok(Ok(()))) {
        return Err(Some(folder_refused("cwd")));
    }
    // Resolved again: the folder made is the one checked.
    let canonical =
        canonical_dir(&target.to_string_lossy()).await.ok_or(Some(folder_refused("cwd")))?;
    if inside(Path::new(&canonical)) { Ok(Some(canonical)) } else { Err(None) }
}

/// Make each name of `rest` below `base` (canonical), one folder at a time through
/// descriptors that never follow a link, from `/` down: a link (dangling or not) or a file
/// anywhere on the way, `base`'s own folders included, fails the make, so no folder is ever
/// made outside `base` even when one of them is swapped for a link meanwhile.
#[cfg(unix)]
fn make_below(base: &Path, rest: &Path) -> std::io::Result<()> {
    use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
    use std::os::unix::ffi::OsStrExt;
    let open = |at: libc::c_int, name: &std::ffi::CStr| {
        let flags = libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC;
        // SAFETY: `name` is a NUL-terminated path and `at` a descriptor this function holds
        // (or AT_FDCWD); the returned descriptor is owned by the OwnedFd below.
        let fd = unsafe { libc::openat(at, name.as_ptr(), flags) };
        if fd < 0 {
            Err(std::io::Error::last_os_error())
        } else {
            // SAFETY: `fd` was just opened and nothing else owns it.
            Ok(unsafe { OwnedFd::from_raw_fd(fd) })
        }
    };
    let c = |bytes: &[u8]| {
        std::ffi::CString::new(bytes).map_err(|_| std::io::Error::other("a NUL in the path"))
    };
    let mut dir = open(libc::AT_FDCWD, &c(b"/")?)?;
    for part in base.components().filter(|p| matches!(p, std::path::Component::Normal(_))) {
        dir = open(dir.as_raw_fd(), &c(part.as_os_str().as_bytes())?)?;
    }
    for part in rest.components() {
        let name = c(part.as_os_str().as_bytes())?;
        // SAFETY: as above; mkdirat never follows a link in the last component.
        if unsafe { libc::mkdirat(dir.as_raw_fd(), name.as_ptr(), 0o700) } != 0 {
            let e = std::io::Error::last_os_error();
            if e.kind() != std::io::ErrorKind::AlreadyExists {
                return Err(e);
            }
        }
        dir = open(dir.as_raw_fd(), &name)?;
    }
    Ok(())
}

#[cfg(not(unix))]
fn make_below(_base: &Path, _rest: &Path) -> std::io::Result<()> {
    Err(std::io::Error::other("folders are made for a peer on unix only"))
}

/// `folder_refused` for a `cwd` that names no directory, with `data.cause`: `missing` when
/// `mkdir -p` on this machine would make it (nothing is there, and its nearest existing
/// folder is a directory), else `unusable` (a file, a link, no absolute path).
pub(super) async fn cwd_refused(cwd: &str) -> RpcError {
    let mut e = folder_refused("cwd");
    let path = Path::new(cwd);
    let mut cause = "unusable";
    // `mkdir -p` reads a `..` after a name that is no folder as an error: no `.` or `..`.
    let plain = path.is_absolute()
        && path.components().all(|c| matches!(c, Component::RootDir | Component::Normal(_)));
    for (i, ancestor) in path.ancestors().enumerate().take_while(|_| plain) {
        match tokio::fs::symlink_metadata(ancestor).await {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => continue,
            Ok(_) if i > 0 && tokio::fs::metadata(ancestor).await.is_ok_and(|m| m.is_dir()) => {
                cause = "missing";
            }
            _ => {}
        }
        break;
    }
    if let Some(data) = e.data.as_mut() {
        data["cause"] = Value::from(cause);
    }
    e
}

/// `cwd` outside the roots, refused; for a proven peer (`told`: the configured roots) told the configured roots (`roots`, and
/// in the message) and `tryCwd`, a folder in the first one a start may use: `ROOT/<cwd's last
/// name>` when nothing is there yet or it is a real folder (no link), else `ROOT` itself.
pub(super) async fn outside_told(cwd: &str, told: &Option<Vec<PathBuf>>) -> RpcError {
    let mut e = super::outside_roots("cwd");
    // The Web is not told this machine's folders.
    let Some(roots) = told.as_deref() else { return e };
    let listed: Vec<String> = roots.iter().map(|r| r.to_string_lossy().into_owned()).collect();
    e.message.push_str(&if listed.is_empty() {
        "; this machine has no webRoots".to_owned()
    } else {
        format!("; this machine's webRoots: {}", listed.join(", "))
    });
    e.message.push_str(" (with no folder at all, a scratch folder is made for the session)");
    let mut pick = roots.first().cloned();
    if let (Some(root), Some(leaf)) = (roots.first(), Path::new(cwd).file_name()) {
        let candidate = root.join(leaf);
        let usable = match tokio::fs::symlink_metadata(&candidate).await {
            Ok(m) => m.is_dir(),
            Err(e) => e.kind() == std::io::ErrorKind::NotFound,
        };
        if usable {
            pick = Some(candidate);
        }
    }
    if let Some(data) = e.data.as_mut() {
        data["roots"] = Value::from(listed);
        if let Some(pick) = pick {
            data["tryCwd"] = Value::from(pick.to_string_lossy().into_owned());
        }
    }
    e
}

/// `webRoots` from config.json, under `web_roots`' guards, in config order.
pub(super) async fn configured_web_roots(hub: &std::sync::Arc<crate::hub::Hub>) -> Vec<PathBuf> {
    let raw = hub.config.read().await.web_roots.clone();
    guarded_roots(raw).await
}

/// Each folder of `raw` in the filesystem's own spelling, once, without `/`, the home
/// directory or any ancestor of it.
pub(super) async fn guarded_roots(raw: Vec<String>) -> Vec<PathBuf> {
    let home = match dirs::home_dir() {
        Some(h) => fs_spelling(&h.to_string_lossy()).await.unwrap_or(h),
        None => std::path::PathBuf::from("/"),
    };
    let mut roots = Vec::new();
    for r in raw {
        if let Some(root) = fs_spelling(&r).await
            && !home.starts_with(&root)
            && !roots.contains(&root)
        {
            roots.push(root);
        }
    }
    roots
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;

    #[test]
    fn a_folder_is_made_below_its_base_and_never_through_a_link_on_the_way() {
        let dir = std::env::temp_dir().join(format!("make-below-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let (root, outside) = (dir.join("root"), dir.join("outside"));
        std::fs::create_dir_all(&root).unwrap();
        std::fs::create_dir_all(&outside).unwrap();
        let root = std::fs::canonicalize(&root).unwrap();
        make_below(&root, Path::new("a/b")).unwrap();
        assert!(root.join("a/b").is_dir());
        // A folder inside the base swapped for a link after the base was checked: the walk
        // from `/` does not follow it, so nothing is made in `outside/b`.
        std::fs::create_dir_all(outside.join("b")).unwrap();
        std::fs::remove_dir_all(root.join("a")).unwrap();
        std::os::unix::fs::symlink(&outside, root.join("a")).unwrap();
        assert!(make_below(&root.join("a/b"), Path::new("child")).is_err());
        assert!(make_below(&root, Path::new("a/b/child")).is_err());
        assert!(!outside.join("b/child").exists());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
