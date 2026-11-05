//! A host's watch on its discovery record directory (#36625).
//!
//! A terminal host outlives its app and daemon on purpose: the next daemon
//! adopts it from its record. A host whose record directory is removed (a
//! throwaway `HOME` deleted after a run, a wiped state directory) can never
//! be discovered again, so it would hold its PTY and shell until reboot. One
//! thread blocks on a kernel event for the directory's removal (kqueue
//! `EVFILT_VNODE` `NOTE_DELETE` on macOS, inotify `IN_DELETE_SELF` on Linux)
//! and reports it once. Nothing polls; the thread ends with the event or
//! with the process.

use std::io;
use std::os::unix::fs::MetadataExt;
use std::path::{Path, PathBuf};

/// Runs `on_removed` once, on a thread of its own, when the directory `dir`
/// is removed (at once when it is already gone or replaced by the time the
/// watch is armed). An error when the watch cannot start; the host then
/// keeps today's behavior.
pub(crate) fn follow_record_root_removal(
    dir: &Path,
    on_removed: impl FnOnce() + Send + 'static,
) -> io::Result<()> {
    let watch = Watch::arm(dir)?;
    std::thread::Builder::new().name("terminal-host-record-root".into()).spawn(
        move || match watch.wait() {
            Ok(()) => on_removed(),
            Err(error) => eprintln!("terminal-host: the record directory watch ended: {error}"),
        },
    )?;
    Ok(())
}

fn identity(path: &Path) -> Option<(u64, u64)> {
    std::fs::metadata(path).ok().filter(|meta| meta.is_dir()).map(|meta| (meta.dev(), meta.ino()))
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
    /// The directory was gone or replaced when the watch was armed.
    gone_at_arm: bool,
    #[allow(dead_code)]
    path: PathBuf,
}

impl Watch {
    #[cfg(target_vendor = "apple")]
    fn arm(dir: &Path) -> io::Result<Self> {
        use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
        let before = identity(dir).ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))?;
        let path = cstring(dir)?;
        // SAFETY: open with a NUL-terminated path; O_EVTONLY keeps the
        // volume unmountable and grants no read access.
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
        change.fflags = libc::NOTE_DELETE | libc::NOTE_REVOKE;
        // SAFETY: one change on a descriptor this function owns; no events out.
        if unsafe {
            libc::kevent(queue.as_raw_fd(), &change, 1, std::ptr::null_mut(), 0, std::ptr::null())
        } < 0
        {
            return Err(io::Error::last_os_error());
        }
        // The descriptor names the directory that was there at `before`: a
        // removal between the stat and the open shows as a new identity.
        // SAFETY: fstat on a descriptor this function owns.
        let mut stat: libc::stat = unsafe { std::mem::zeroed() };
        let opened = (unsafe { libc::fstat(dir_fd.as_raw_fd(), &mut stat) } == 0)
            .then(|| (stat.st_dev as u64, stat.st_ino as u64));
        let gone_at_arm = opened != Some(before) || identity(dir) != Some(before);
        Ok(Self { queue, _dir: dir_fd, gone_at_arm, path: dir.to_path_buf() })
    }

    #[cfg(target_os = "linux")]
    fn arm(dir: &Path) -> io::Result<Self> {
        use std::os::fd::{FromRawFd, OwnedFd};
        let before = identity(dir).ok_or_else(|| io::Error::from(io::ErrorKind::NotFound))?;
        let path = cstring(dir)?;
        // SAFETY: inotify_init1 takes flags only.
        let fd = unsafe { libc::inotify_init1(libc::IN_CLOEXEC) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: inotify_init1 returned a fresh descriptor this process owns.
        let queue = unsafe { OwnedFd::from_raw_fd(fd) };
        // SAFETY: a valid inotify descriptor and a NUL-terminated path.
        let watch = unsafe {
            libc::inotify_add_watch(fd, path.as_ptr(), libc::IN_DELETE_SELF | libc::IN_ONLYDIR)
        };
        if watch < 0 {
            let error = io::Error::last_os_error();
            if error.raw_os_error() == Some(libc::ENOENT) {
                return Ok(Self { queue, gone_at_arm: true, path: dir.to_path_buf() });
            }
            return Err(error);
        }
        // The watch is on whatever directory the path named at the call: a
        // removal after the stat shows as a new or missing identity.
        let gone_at_arm = identity(dir) != Some(before);
        Ok(Self { queue, gone_at_arm, path: dir.to_path_buf() })
    }

    /// Block until the directory is removed.
    fn wait(self) -> io::Result<()> {
        use std::os::fd::AsRawFd;
        if self.gone_at_arm {
            return Ok(());
        }
        loop {
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
                let mut buffer = [0_u8; 1024];
                // SAFETY: the buffer outlives the call and its length is
                // passed. The only event watched is IN_DELETE_SELF (and the
                // IN_IGNORED that follows it).
                unsafe {
                    libc::read(self.queue.as_raw_fd(), buffer.as_mut_ptr().cast(), buffer.len())
                }
            };
            if ready > 0 {
                return Ok(());
            }
            let error = io::Error::last_os_error();
            if ready < 0 && error.kind() != io::ErrorKind::Interrupted {
                return Err(error);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::mpsc;
    use std::time::Duration;

    use super::*;

    fn scratch(name: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!(
            "cmux-record-root-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |elapsed| elapsed.as_nanos())
        ));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn removing_the_directory_reports_once_and_a_write_in_it_does_not() {
        let dir = scratch("removed");
        let (tx, rx) = mpsc::channel();
        follow_record_root_removal(&dir, move || tx.send(()).unwrap()).unwrap();
        // Records are written and replaced inside the directory all the time.
        std::fs::write(dir.join("a.json.tmp"), b"{}").unwrap();
        std::fs::rename(dir.join("a.json.tmp"), dir.join("a.json")).unwrap();
        std::fs::remove_file(dir.join("a.json")).unwrap();
        assert!(rx.recv_timeout(Duration::from_millis(300)).is_err(), "a write reported removal");
        std::fs::remove_dir_all(&dir).unwrap();
        rx.recv_timeout(Duration::from_secs(5)).expect("the removal was not reported");
    }

    #[test]
    fn a_directory_gone_before_the_watch_cannot_be_watched() {
        let dir = scratch("gone");
        std::fs::remove_dir_all(&dir).unwrap();
        assert!(follow_record_root_removal(&dir, || {}).is_err());
    }
}
