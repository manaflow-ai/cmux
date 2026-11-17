//! Leases with `LockFileEx`, the Windows counterpart of the hosts' `flock`
//! leases (liveness `.live`, `.publication.lock` shared and reset
//! exclusive). The kernel releases a byte-range lock when its handle closes
//! or its process ends, so a held exclusive lease proves the holder lives.
//! Locks belong to the file handle: a second handle, even in the same
//! process, conflicts like another process would.

use std::fs::{File, OpenOptions};
use std::io;
use std::os::windows::fs::OpenOptionsExt;
use std::os::windows::io::AsRawHandle;
use std::path::Path;

use windows_sys::Win32::Foundation::{ERROR_LOCK_VIOLATION, HANDLE};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE, LOCKFILE_EXCLUSIVE_LOCK,
    LOCKFILE_FAIL_IMMEDIATELY, LockFileEx, UnlockFileEx,
};
use windows_sys::Win32::System::IO::OVERLAPPED;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LeaseKind {
    Shared,
    Exclusive,
}

/// A held lease: the lock lives as long as this value (or its process).
#[derive(Debug)]
pub struct Lease {
    file: File,
    kind: LeaseKind,
}

impl Lease {
    pub fn kind(&self) -> LeaseKind {
        self.kind
    }
}

impl Drop for Lease {
    fn drop(&mut self) {
        unlock_file(&self.file);
    }
}

/// What a probe saw.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LeaseProbe {
    /// Another handle holds a lock on it: its holder lives.
    Held,
    /// No lock: the holder is gone.
    Free,
    /// No such file.
    Missing,
}

fn open(path: &Path, create: bool) -> io::Result<File> {
    OpenOptions::new()
        .read(true)
        .write(true)
        .create(create)
        // Others may open it to probe; the lock, not the share mode, is the lease.
        .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
        .open(path)
}

/// Locks the whole file (created if missing). `wait`: block until free;
/// else Ok(None) when another handle holds a conflicting lock.
pub fn acquire(path: &Path, kind: LeaseKind, wait: bool) -> io::Result<Option<Lease>> {
    let file = open(path, true)?;
    Ok(if lock_file(&file, kind, wait)? { Some(Lease { file, kind }) } else { None })
}

/// Locks the whole of an open `file` through this handle. `wait`: block
/// until free; else Ok(false) when another handle holds a conflicting lock.
/// The lock lives until [`unlock_file`] or the handle closes.
pub fn lock_file(file: &File, kind: LeaseKind, wait: bool) -> io::Result<bool> {
    let mut flags = 0;
    if kind == LeaseKind::Exclusive {
        flags |= LOCKFILE_EXCLUSIVE_LOCK;
    }
    if !wait {
        flags |= LOCKFILE_FAIL_IMMEDIATELY;
    }
    let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
    // SAFETY: a valid file handle; a synchronous handle, so the zeroed
    // OVERLAPPED only names offset 0.
    let ok = unsafe {
        LockFileEx(file.as_raw_handle() as HANDLE, flags, 0, u32::MAX, u32::MAX, &mut overlapped)
    };
    if ok != 0 {
        return Ok(true);
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(ERROR_LOCK_VIOLATION as i32) {
        return Ok(false);
    }
    Err(error)
}

/// Releases this handle's whole-file lock.
pub fn unlock_file(file: &File) {
    let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
    // SAFETY: a valid handle; the whole range `lock_file` locked.
    unsafe { UnlockFileEx(file.as_raw_handle() as HANDLE, 0, u32::MAX, u32::MAX, &mut overlapped) };
}

/// Whether a lease file's holder lives: tries an exclusive lock without
/// waiting, and releases it at once when it got it.
pub fn probe(path: &Path) -> io::Result<LeaseProbe> {
    if !path.exists() {
        return Ok(LeaseProbe::Missing);
    }
    match open(path, false) {
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(LeaseProbe::Missing),
        Err(e) => return Err(e),
        Ok(_) => {}
    }
    Ok(match acquire(path, LeaseKind::Exclusive, false)? {
        Some(_lease) => LeaseProbe::Free,
        None => LeaseProbe::Held,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;
    use std::time::Duration;
    use windows_sys::Win32::Storage::FileSystem::FILE_FLAG_OVERLAPPED;

    fn lease_path(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("cmux-liveness-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("lease")
    }

    /// A handle opened with `FILE_FLAG_OVERLAPPED`: `LockFileEx` answers `ERROR_IO_PENDING`
    /// while another handle holds the lock and the kernel finishes the call later, writing
    /// into its OVERLAPPED. `lock_file` must wait for that, not return with the OVERLAPPED
    /// still in the kernel's hands.
    #[test]
    fn a_waiting_lock_on_an_overlapped_handle_returns_holding_the_lock() {
        let path = lease_path("overlapped");
        let holder = acquire(&path, LeaseKind::Exclusive, false).unwrap().expect("first lease");
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
            .custom_flags(FILE_FLAG_OVERLAPPED)
            .open(&path)
            .unwrap();
        let (tx, rx) = mpsc::channel();
        let (release, released) = mpsc::channel::<()>();
        let waiter = std::thread::spawn(move || {
            let got = lock_file(&file, LeaseKind::Exclusive, true);
            tx.send(got.map_err(|e| e.to_string())).unwrap();
            // Holds the lock until the test has looked.
            let _ = released.recv();
            unlock_file(&file);
        });
        if let Ok(early) = rx.recv_timeout(Duration::from_millis(300)) {
            panic!("lock_file returned {early:?} while another handle held the lock");
        }
        drop(holder);
        let got = rx.recv_timeout(Duration::from_secs(10)).expect("lock_file returned");
        assert_eq!(got, Ok(true));
        assert_eq!(probe(&path).unwrap(), LeaseProbe::Held);
        release.send(()).unwrap();
        waiter.join().unwrap();
        assert_eq!(probe(&path).unwrap(), LeaseProbe::Free);
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }

    /// The same handle, not waiting: a held lock is a plain `Ok(false)`.
    #[test]
    fn a_try_lock_on_an_overlapped_handle_sees_a_held_lock() {
        let path = lease_path("overlapped-try");
        let _holder = acquire(&path, LeaseKind::Exclusive, false).unwrap().expect("first lease");
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
            .custom_flags(FILE_FLAG_OVERLAPPED)
            .open(&path)
            .unwrap();
        assert_eq!(
            lock_file(&file, LeaseKind::Exclusive, false).map_err(|e| e.to_string()),
            Ok(false)
        );
        drop((file, _holder));
        let _ = std::fs::remove_dir_all(path.parent().unwrap());
    }
}
