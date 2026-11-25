//! Leases with `LockFileEx`, the Windows counterpart of the hosts' `flock`
//! leases (liveness `.live`, `.publication.lock` shared and reset
//! exclusive). The kernel releases a byte-range lock when its handle closes
//! or its process ends, so a held exclusive lease proves the holder lives.
//! Locks belong to the file handle: a second handle, even in the same
//! process, conflicts like another process would.

use std::fs::{File, OpenOptions};
use std::io;
use std::os::windows::fs::OpenOptionsExt;
use std::os::windows::io::{AsRawHandle, FromRawHandle, OwnedHandle};
use std::path::Path;
use std::ptr;

use windows_sys::Win32::Foundation::{ERROR_IO_PENDING, ERROR_LOCK_VIOLATION, HANDLE};
use windows_sys::Win32::Storage::FileSystem::{
    FILE_SHARE_DELETE, FILE_SHARE_READ, FILE_SHARE_WRITE, LOCKFILE_EXCLUSIVE_LOCK,
    LOCKFILE_FAIL_IMMEDIATELY, LockFileEx, UnlockFileEx,
};
use windows_sys::Win32::System::IO::{GetOverlappedResult, OVERLAPPED};
use windows_sys::Win32::System::Threading::CreateEventW;
use windows_sys::core::BOOL;

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
    // SAFETY: a valid file handle, and an OVERLAPPED `completed` keeps alive until the kernel
    // is done with it.
    let locked = completed(file, |handle, overlapped| unsafe {
        LockFileEx(handle, flags, 0, u32::MAX, u32::MAX, overlapped)
    });
    match locked {
        Ok(()) => Ok(true),
        Err(e) if e.raw_os_error() == Some(ERROR_LOCK_VIOLATION as i32) => Ok(false),
        Err(e) => Err(e),
    }
}

/// Releases this handle's whole-file lock.
pub fn unlock_file(file: &File) {
    // SAFETY: a valid handle; the whole range `lock_file` locked. `UnlockFileEx` is
    // synchronous on every handle (`NtUnlockFile` takes no event or completion context and
    // finishes in the call), so the OVERLAPPED is read and written only during it.
    let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
    unsafe { UnlockFileEx(file.as_raw_handle() as HANDLE, 0, u32::MAX, u32::MAX, &mut overlapped) };
}

/// Runs one `LockFileEx` call on `file` with an OVERLAPPED on this frame and returns only
/// once the kernel is done with it. Any `&File` may come here, including one opened with
/// `FILE_FLAG_OVERLAPPED`: there the call can answer `ERROR_IO_PENDING` and the kernel writes
/// its result into the OVERLAPPED later, so this waits for that before the frame (and the
/// OVERLAPPED) goes away. A handle bound to an I/O completion port would also get a
/// completion packet naming the OVERLAPPED, read after this returned; the event's low bit set
/// tells the kernel to post none.
fn completed(file: &File, call: impl FnOnce(HANDLE, *mut OVERLAPPED) -> BOOL) -> io::Result<()> {
    let handle = file.as_raw_handle() as HANDLE;
    // A manual-reset event of its own: with none, the wait would be on the file handle, which
    // any other I/O on it also signals, and the low-bit tag needs a real handle.
    // SAFETY: no security attributes, no name.
    let event = unsafe { CreateEventW(ptr::null(), 1, 0, ptr::null()) };
    if event.is_null() {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a fresh handle nothing else owns; it closes when this returns, after the wait.
    let _event = unsafe { OwnedHandle::from_raw_handle(event) };
    // SAFETY: all-zero is a valid OVERLAPPED (offset 0).
    let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
    overlapped.hEvent = (event as usize | 1) as HANDLE;
    // One raw pointer for the call and the wait: no reference to the OVERLAPPED exists while
    // the kernel may write it.
    let overlapped = ptr::addr_of_mut!(overlapped);
    if call(handle, overlapped) != 0 {
        return Ok(());
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() != Some(ERROR_IO_PENDING as i32) {
        return Err(error);
    }
    let mut transferred = 0;
    // SAFETY: the OVERLAPPED the pending call holds. bWait = TRUE returns only when the call
    // is done, so the kernel writes nothing into it after this.
    if unsafe { GetOverlappedResult(handle, overlapped, &mut transferred, 1) } != 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
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
#[path = "liveness_tests.rs"]
mod tests;
