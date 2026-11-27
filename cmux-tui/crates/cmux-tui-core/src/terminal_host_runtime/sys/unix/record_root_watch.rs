//! A host's watch on its discovery record directory (#36625).
//!
//! A terminal host outlives its app and daemon on purpose: the next daemon
//! adopts it from its record. A host whose record directory is removed (a
//! throwaway `HOME` deleted after a run, a wiped state directory) can never
//! be discovered again, so it would hold its PTY and shell until reboot. One
//! thread blocks on kernel events for the directory's removal or rename and
//! reports it once. Nothing polls: after every event the directory's
//! identity is read again (event order is not trusted), and the thread ends
//! with the removal or with the process.
//!
//! - macOS: kqueue `EVFILT_VNODE` (`NOTE_DELETE`, `NOTE_RENAME`,
//!   `NOTE_REVOKE`) on the directory, posted at the `rmdir` itself.
//! - Linux: inotify `IN_DELETE` / `IN_MOVED_FROM` on the parent for the
//!   directory's name, plus `IN_DELETE_SELF` / `IN_MOVE_SELF` on the
//!   directory. The parent's event is the one that matters: the host keeps
//!   files open inside the directory (its PTY lock, its lease), and an open
//!   child pins the directory's dentry, so the kernel holds the directory's
//!   own `IN_DELETE_SELF` back until the host exits.

use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::Path;

/// Runs `on_removed` once, on a thread of its own, when the directory `dir`
/// is removed or renamed away (at once when it is already gone or replaced
/// by the time the watch is armed). An error only when the watch cannot
/// start for another reason; the host then keeps today's behavior.
pub(crate) fn follow_record_root_removal(
    dir: &Path,
    on_removed: impl FnOnce() + Send + 'static,
) -> io::Result<()> {
    let watch = match identity(dir) {
        // Gone between publication and here: it is already removed.
        None => None,
        Some(before) => match Watch::arm(dir, before) {
            Ok(watch) => Some(watch),
            // Removed between the identity read and the arm (macOS `open`
            // fails with ENOENT): also already removed.
            Err(_) if identity(dir) != Some(before) => None,
            Err(error) => return Err(error),
        },
    };
    std::thread::Builder::new().name("terminal-host-record-root".into()).spawn(move || {
        let Some(watch) = watch else { return on_removed() };
        match watch.wait() {
            Ok(()) => on_removed(),
            Err(error) => eprintln!("terminal-host: the record directory watch ended: {error}"),
        }
    })?;
    Ok(())
}

/// The directory's (device, inode), or `None` when no directory is there.
fn identity(path: &Path) -> Option<(u64, u64)> {
    std::fs::symlink_metadata(path)
        .ok()
        .filter(|meta| meta.is_dir())
        .map(|meta| (meta.dev(), meta.ino()))
}

fn cstring(path: &Path) -> io::Result<std::ffi::CString> {
    use std::os::unix::ffi::OsStrExt;
    std::ffi::CString::new(path.as_os_str().as_bytes())
        .map_err(|_| io::Error::from(io::ErrorKind::InvalidInput))
}

struct Watch {
    queue: std::os::fd::OwnedFd,
    /// The directory's descriptor the kqueue filter watches (macOS only).
    #[cfg(target_vendor = "apple")]
    _dir: std::os::fd::OwnedFd,
    path: std::path::PathBuf,
    before: (u64, u64),
}

impl Watch {
    #[cfg(target_vendor = "apple")]
    fn arm(dir: &Path, before: (u64, u64)) -> io::Result<Self> {
        use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
        let path = cstring(dir)?;
        // SAFETY: open with a NUL-terminated path; O_EVTONLY grants no read
        // access and does not keep the volume from unmounting.
        let fd = unsafe {
            libc::open(path.as_ptr(), libc::O_EVTONLY | libc::O_DIRECTORY | libc::O_CLOEXEC)
        };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: open returned a fresh descriptor this process owns.
        let dir_fd = unsafe { OwnedFd::from_raw_fd(fd) };
        // SAFETY: kqueue takes no arguments.
        let queue = unsafe { libc::kqueue() };
        if queue < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: kqueue returned a fresh descriptor this process owns.
        let queue = unsafe { OwnedFd::from_raw_fd(queue) };
        // SAFETY: a zeroed kevent is a valid value; its fields are set below.
        let mut change: libc::kevent = unsafe { std::mem::zeroed() };
        change.ident = dir_fd.as_raw_fd() as libc::uintptr_t;
        change.filter = libc::EVFILT_VNODE;
        change.flags = libc::EV_ADD | libc::EV_CLEAR;
        change.fflags = libc::NOTE_DELETE | libc::NOTE_RENAME | libc::NOTE_REVOKE;
        // SAFETY: one change on descriptors this function owns; no events out.
        if unsafe {
            libc::kevent(queue.as_raw_fd(), &change, 1, std::ptr::null_mut(), 0, std::ptr::null())
        } < 0
        {
            return Err(io::Error::last_os_error());
        }
        Ok(Self { queue, _dir: dir_fd, path: dir.to_path_buf(), before })
    }

    #[cfg(target_os = "linux")]
    fn arm(dir: &Path, before: (u64, u64)) -> io::Result<Self> {
        use std::os::fd::{FromRawFd, OwnedFd};
        // SAFETY: inotify_init1 takes flags only.
        let fd = unsafe { libc::inotify_init1(libc::IN_CLOEXEC) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: inotify_init1 returned a fresh descriptor this process owns.
        let queue = unsafe { OwnedFd::from_raw_fd(fd) };
        let add = |path: &Path, mask: u32| -> io::Result<()> {
            let path = cstring(path)?;
            // SAFETY: a valid inotify descriptor and a NUL-terminated path.
            if unsafe { libc::inotify_add_watch(fd, path.as_ptr(), mask) } < 0 {
                let error = io::Error::last_os_error();
                // Gone already: the identity check after arming reports it.
                if error.raw_os_error() != Some(libc::ENOENT) {
                    return Err(error);
                }
            }
            Ok(())
        };
        if let Some(parent) = dir.parent().filter(|parent| !parent.as_os_str().is_empty()) {
            add(
                parent,
                libc::IN_DELETE
                    | libc::IN_MOVED_FROM
                    | libc::IN_DELETE_SELF
                    | libc::IN_MOVE_SELF
                    | libc::IN_ONLYDIR,
            )?;
        }
        add(dir, libc::IN_DELETE_SELF | libc::IN_MOVE_SELF | libc::IN_ONLYDIR)?;
        Ok(Self { queue, path: dir.to_path_buf(), before })
    }

    fn removed(&self) -> bool {
        identity(&self.path) != Some(self.before)
    }

    /// Block until the directory is removed, renamed away or replaced.
    fn wait(self) -> io::Result<()> {
        use std::os::fd::AsRawFd;
        loop {
            // Watches are armed before this check, so a removal between the
            // caller's identity read and here is never missed.
            if self.removed() {
                return Ok(());
            }
            #[cfg(target_vendor = "apple")]
            let ready = {
                // SAFETY: a zeroed kevent is a valid output buffer.
                let mut event: libc::kevent = unsafe { std::mem::zeroed() };
                // SAFETY: waits on a kqueue this watch owns, one event out.
                unsafe {
                    libc::kevent(
                        self.queue.as_raw_fd(),
                        std::ptr::null(),
                        0,
                        &mut event,
                        1,
                        std::ptr::null(),
                    )
                }
            };
            #[cfg(target_os = "linux")]
            let ready = {
                let mut buffer = [0_u8; 4096];
                // SAFETY: the buffer outlives the call and its length is
                // passed. The events' content is not needed: the identity
                // check above decides.
                unsafe {
                    libc::read(self.queue.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len())
                }
            };
            if ready < 0 {
                let error = io::Error::last_os_error();
                if error.kind() != io::ErrorKind::Interrupted {
                    return Err(error);
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::fs::File;
    use std::sync::mpsc;
    use std::time::Duration;

    use super::*;

    fn scratch(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir()
            .join(format!(
                "cmux-record-root-{name}-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map_or(0, |elapsed| elapsed.as_nanos())
            ))
            .join("records");
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    /// The host keeps files open inside its record directory (its PTY lock,
    /// its lease); the removal is still reported at once (on Linux the
    /// directory's own IN_DELETE_SELF waits until those files close).
    #[test]
    fn removing_the_directory_reports_once_and_a_write_in_it_does_not() {
        let dir = scratch("removed");
        let held = File::create(dir.join("t.pty.lock")).unwrap();
        let (tx, rx) = mpsc::channel();
        follow_record_root_removal(&dir, move || tx.send(()).unwrap()).unwrap();
        // Records are written and replaced inside the directory all the time.
        std::fs::write(dir.join("a.json.tmp"), b"{}").unwrap();
        std::fs::rename(dir.join("a.json.tmp"), dir.join("a.json")).unwrap();
        std::fs::remove_file(dir.join("a.json")).unwrap();
        assert!(rx.recv_timeout(Duration::from_millis(300)).is_err(), "a write reported removal");
        std::fs::remove_dir_all(dir.parent().unwrap()).unwrap();
        rx.recv_timeout(Duration::from_secs(5)).expect("the removal was not reported");
        drop(held);
    }

    #[test]
    fn a_directory_renamed_away_is_reported() {
        let dir = scratch("renamed");
        let _held = File::create(dir.join("t.live")).unwrap();
        let (tx, rx) = mpsc::channel();
        follow_record_root_removal(&dir, move || tx.send(()).unwrap()).unwrap();
        std::fs::rename(&dir, dir.with_file_name("moved")).unwrap();
        rx.recv_timeout(Duration::from_secs(5)).expect("the rename was not reported");
        std::fs::remove_dir_all(dir.parent().unwrap()).unwrap();
    }

    #[test]
    fn a_directory_gone_before_the_watch_is_reported_at_once() {
        let dir = scratch("gone");
        std::fs::remove_dir_all(dir.parent().unwrap()).unwrap();
        let (tx, rx) = mpsc::channel();
        follow_record_root_removal(&dir, move || tx.send(()).unwrap()).unwrap();
        rx.recv_timeout(Duration::from_secs(5)).expect("a gone directory was not reported");
    }
}
