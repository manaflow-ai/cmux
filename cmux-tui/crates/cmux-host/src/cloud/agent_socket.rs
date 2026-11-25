//! The Cloud agent's listening sockets (the agent socket and the carrier
//! ticket socket): root and group cmux, 0660, so the work user's tools can
//! ask and no other user can.

use std::fs;
use std::io;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::UnixListener;

use crate::config::Paths;

/// A fresh nonblocking listener at `socket` under `paths`, replacing any
/// stale socket file left there.
pub(super) fn listen(paths: &Paths, socket: &str) -> io::Result<UnixListener> {
    let path = paths.at(socket);
    if let Some(dir) = path.parent() {
        fs::create_dir_all(dir)?;
        fs::set_permissions(dir, fs::Permissions::from_mode(0o755))?;
    }
    let _ = fs::remove_file(&path);
    let listener = UnixListener::bind(&path)?;
    listener.set_nonblocking(true)?;
    if paths.is_system_root()
        && let Some(gid) = group_id("cmux")
    {
        std::os::unix::fs::chown(&path, Some(0), Some(gid))?;
    }
    fs::set_permissions(&path, fs::Permissions::from_mode(0o660))?;
    Ok(listener)
}

fn group_id(name: &str) -> Option<u32> {
    let cname = std::ffi::CString::new(name).ok()?;
    // SAFETY: getgrnam returns a pointer to static storage or null.
    let group = unsafe { libc::getgrnam(cname.as_ptr()) };
    if group.is_null() {
        return None;
    }
    // SAFETY: non-null result from getgrnam.
    Some(unsafe { (*group).gr_gid })
}
