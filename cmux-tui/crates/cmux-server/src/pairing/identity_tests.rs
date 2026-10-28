//! The lock must be released even while a concurrently forked child has
//! inherited the open file description but has not yet applied CLOEXEC.

use super::*;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::time::Duration;

#[test]
fn server_pairing_lock_release_does_not_wait_for_an_inherited_child_fd() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("pairing/identity.json");
    inherited_lock_release(|| Store::acquire(&path));
}

#[test]
fn server_pairing_package_lock_release_does_not_wait_for_an_inherited_child_fd() {
    let dir = tempfile::tempdir().unwrap();
    inherited_lock_release(|| crate::store::state::StoreLock::acquire(dir.path()));
}

fn inherited_lock_release<G>(acquire: impl Fn() -> Result<G>) {
    let store = acquire().unwrap();
    assert!(acquire().is_err(), "a live guard must still exclude a second operation");
    let (mut parent, child) = UnixStream::pair().unwrap();
    parent.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let parent_fd = parent.as_raw_fd();
    let child_fd = child.as_raw_fd();
    // SAFETY: fork copies this test's live descriptors. The child below uses
    // only async-signal-safe libc calls and _exit; no Rust allocator, runtime,
    // mutex, destructor or application code runs in the child.
    let pid = unsafe { libc::fork() };
    assert!(pid >= 0, "fork fixture failed");
    if pid == 0 {
        // SAFETY: the descriptors and one-byte buffers are live in this child.
        // _exit avoids running inherited Rust destructors, including Store.
        unsafe {
            libc::close(parent_fd);
            if libc::write(child_fd, b"R".as_ptr().cast(), 1) != 1 {
                libc::_exit(1);
            }
            let mut done = [0u8; 1];
            let read = libc::read(child_fd, done.as_mut_ptr().cast(), 1);
            libc::close(child_fd);
            libc::_exit(if read >= 0 { 0 } else { 1 });
        }
    }
    drop(child);
    let mut ready = [0u8; 1];
    let signaled = parent.read_exact(&mut ready);
    drop(store);
    // The child is still alive and holds its inherited file descriptor.
    let next = acquire();
    // Reap the child before asserting the regression, including on old code.
    let _ = parent.write_all(b"X");
    let mut status = 0;
    // SAFETY: pid is the child created above; status points to live memory.
    let waited = unsafe { libc::waitpid(pid, &mut status, 0) };
    assert!(signaled.is_ok() && ready == *b"R");
    assert_eq!(waited, pid);
    assert_eq!(status, 0);
    assert!(next.is_ok(), "a completed enrollment left the lock held by a forked child");
}
