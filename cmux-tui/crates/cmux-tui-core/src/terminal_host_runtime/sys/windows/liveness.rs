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
        let mut overlapped: OVERLAPPED = unsafe { std::mem::zeroed() };
        // SAFETY: the handle this lease owns; the whole range it locked.
        unsafe {
            UnlockFileEx(
                self.file.as_raw_handle() as HANDLE,
                0,
                u32::MAX,
                u32::MAX,
                &mut overlapped,
            )
        };
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
        return Ok(Some(Lease { file, kind }));
    }
    let error = io::Error::last_os_error();
    if error.raw_os_error() == Some(ERROR_LOCK_VIOLATION as i32) {
        return Ok(None);
    }
    Err(error)
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

    fn temp(name: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("cth-lease-{name}-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("x.live")
    }

    #[test]
    fn a_held_exclusive_lease_reads_held_and_free_after_it_drops() {
        let path = temp("exclusive");
        assert_eq!(probe(&path).unwrap(), LeaseProbe::Missing);
        let lease = acquire(&path, LeaseKind::Exclusive, false).unwrap().expect("free file");
        assert_eq!(probe(&path).unwrap(), LeaseProbe::Held);
        assert!(
            acquire(&path, LeaseKind::Shared, false).unwrap().is_none(),
            "exclusive blocks shared"
        );
        drop(lease);
        assert_eq!(probe(&path).unwrap(), LeaseProbe::Free);
    }

    #[test]
    fn shared_leases_coexist_and_block_an_exclusive_one() {
        let path = temp("shared");
        let a = acquire(&path, LeaseKind::Shared, false).unwrap().expect("first shared");
        let b = acquire(&path, LeaseKind::Shared, false).unwrap().expect("second shared");
        assert!(
            acquire(&path, LeaseKind::Exclusive, false).unwrap().is_none(),
            "reset waits for publishers"
        );
        assert_eq!(probe(&path).unwrap(), LeaseProbe::Held);
        drop((a, b));
        assert!(acquire(&path, LeaseKind::Exclusive, false).unwrap().is_some());
    }

    #[test]
    fn a_lease_held_by_a_process_that_ended_reads_free() {
        // The kernel drops the lock with its process: a child takes the
        // lease, exits, and the probe reads it free.
        let path = temp("child");
        let script = format!(
            "$f=[IO.File]::Open('{}','OpenOrCreate','ReadWrite','ReadWrite'); $f.Lock(0,1); 'locked'; Start-Sleep 30",
            path.display()
        );
        let mut child = std::process::Command::new("powershell.exe")
            .args(["-NoProfile", "-Command", &script])
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let mut line = String::new();
        std::io::BufRead::read_line(
            &mut std::io::BufReader::new(child.stdout.take().unwrap()),
            &mut line,
        )
        .unwrap();
        assert_eq!(line.trim(), "locked");
        assert_eq!(probe(&path).unwrap(), LeaseProbe::Held, "a live holder in another process");
        child.kill().unwrap();
        child.wait().unwrap();
        assert_eq!(probe(&path).unwrap(), LeaseProbe::Free, "the lock went with its process");
    }
}
