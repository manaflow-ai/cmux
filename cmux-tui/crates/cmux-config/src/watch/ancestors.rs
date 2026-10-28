//! macOS: a kqueue vnode watch on each nearest existing ancestor of a missing
//! directory. FSEvents reports every change below a watched directory, so an
//! ancestor such as /Library (while /Library/Managed Preferences is missing)
//! or the home folder (before ~/.config/cmux exists) woke the daemon for each
//! write anywhere under it. A vnode watch on the directory fires only when its
//! own entries change (the missing directory appearing) or it goes away, like
//! the Linux backend's ancestor mask.
//!
//! One thread waits in `kevent` with no timeout; dropping [`Ancestors`]
//! triggers a user event that ends it. Closing a directory's descriptor
//! removes its watch.

use std::collections::{BTreeMap, BTreeSet};
use std::ffi::{c_int, c_void};
use std::fs::{File, OpenOptions};
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::os::unix::fs::OpenOptionsExt;
use std::path::PathBuf;
use std::sync::Mutex;
use std::thread::JoinHandle;

// <sys/event.h> and <fcntl.h> (Darwin).
const EVFILT_VNODE: i16 = -4;
const EVFILT_USER: i16 = -10;
const EV_ADD: u16 = 0x0001;
const EV_CLEAR: u16 = 0x0020;
const NOTE_DELETE: u32 = 0x0000_0001;
const NOTE_WRITE: u32 = 0x0000_0002;
const NOTE_RENAME: u32 = 0x0000_0020;
const NOTE_REVOKE: u32 = 0x0000_0040;
const NOTE_TRIGGER: u32 = 0x0100_0000;
const O_EVTONLY: c_int = 0x0000_8000;
/// The user event's identifier (any value; only one user event exists).
const STOP: usize = 1;

#[repr(C)]
struct KEvent {
    ident: usize,
    filter: i16,
    flags: u16,
    fflags: u32,
    data: isize,
    udata: *mut c_void,
}

impl KEvent {
    fn new(ident: usize, filter: i16, flags: u16, fflags: u32) -> Self {
        Self { ident, filter, flags, fflags, data: 0, udata: std::ptr::null_mut() }
    }
}

unsafe extern "C" {
    safe fn kqueue() -> c_int;
    fn kevent(
        kq: c_int,
        changelist: *const KEvent,
        nchanges: c_int,
        eventlist: *mut KEvent,
        nevents: c_int,
        timeout: *const c_void,
    ) -> c_int;
}

fn change(kq: RawFd, event: &KEvent) -> io::Result<()> {
    // SAFETY: one valid change, no event list, no timeout.
    let result = unsafe { kevent(kq, event, 1, std::ptr::null_mut(), 0, std::ptr::null()) };
    if result < 0 { Err(io::Error::last_os_error()) } else { Ok(()) }
}

pub(super) struct Ancestors {
    kq: OwnedFd,
    dirs: Mutex<BTreeMap<PathBuf, File>>,
    thread: Option<JoinHandle<()>>,
}

impl Ancestors {
    /// Calls `on_event` on its own thread whenever a watched directory's
    /// entries change or it goes away.
    pub(super) fn start(on_event: impl Fn() + Send + 'static) -> io::Result<Self> {
        let raw = kqueue();
        if raw < 0 {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: kqueue returned a new descriptor that nothing else owns.
        let kq = unsafe { OwnedFd::from_raw_fd(raw) };
        change(raw, &KEvent::new(STOP, EVFILT_USER, EV_ADD | EV_CLEAR, 0))?;
        // supervise-allow: owned by Ancestors, which keeps the handle and joins it at drop; a panic ends parent-directory change hints only, and the loaded config stays in effect.
        let thread = cmux_threads::spawn(
            "cmux-config-ancestors",
            cmux_threads::ThreadQos::UserInitiated,
            move || {
                let mut event = KEvent::new(0, 0, 0, 0);
                loop {
                    // SAFETY: room for one event; a null timeout waits until one arrives.
                    let count = unsafe {
                        kevent(raw, std::ptr::null(), 0, &mut event, 1, std::ptr::null())
                    };
                    if count < 0 {
                        if io::Error::last_os_error().kind() == io::ErrorKind::Interrupted {
                            continue;
                        }
                        return;
                    }
                    if count == 0 {
                        continue;
                    }
                    if event.filter == EVFILT_USER {
                        return;
                    }
                    on_event();
                }
            },
        )?;
        Ok(Self { kq, dirs: Mutex::default(), thread: Some(thread) })
    }

    /// Watches exactly `wanted`; returns how many directories are watched.
    /// A directory that cannot be opened (no permission, gone) is skipped.
    pub(super) fn set(&self, wanted: &BTreeSet<PathBuf>) -> usize {
        let Ok(mut dirs) = self.dirs.lock() else { return 0 };
        dirs.retain(|path, _| wanted.contains(path));
        for path in wanted {
            if dirs.contains_key(path) {
                continue;
            }
            let Ok(file) = OpenOptions::new().read(true).custom_flags(O_EVTONLY).open(path) else {
                continue;
            };
            let fflags = NOTE_WRITE | NOTE_DELETE | NOTE_RENAME | NOTE_REVOKE;
            let watch =
                KEvent::new(file.as_raw_fd() as usize, EVFILT_VNODE, EV_ADD | EV_CLEAR, fflags);
            if change(self.kq.as_raw_fd(), &watch).is_ok() {
                dirs.insert(path.clone(), file);
            }
        }
        dirs.len()
    }
}

impl Drop for Ancestors {
    fn drop(&mut self) {
        let _ = change(self.kq.as_raw_fd(), &KEvent::new(STOP, EVFILT_USER, 0, NOTE_TRIGGER));
        if let Some(thread) = self.thread.take() {
            // The last owner may drop the watch from its own callback.
            if thread.thread().id() != std::thread::current().id() {
                let _ = thread.join();
            }
        }
    }
}
