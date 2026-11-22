//! The owner's termination-signal handler and the sender it records
//! (cx-0tgl LA): the first signal, the sender's PID and real user id, for
//! the owner's `daemon_signal` loss-log line.

use std::sync::atomic::{AtomicI32, AtomicU32, Ordering};

use crate::{SHUTDOWN_REQUESTED, SIGNAL_WAKE_WRITER};

static SHUTDOWN_SIGNAL: AtomicI32 = AtomicI32::new(0);
static SHUTDOWN_SIGNAL_SENDER: AtomicI32 = AtomicI32::new(0);
static SHUTDOWN_SIGNAL_SENDER_UID: AtomicU32 = AtomicU32::new(u32::MAX);

/// The sender's real user id from an `SA_SIGINFO` record.
#[cfg(any(target_os = "macos", target_os = "ios", target_os = "freebsd"))]
unsafe fn siginfo_uid(info: *mut libc::siginfo_t) -> u32 {
    // SAFETY: the caller passes the kernel's non-null siginfo.
    unsafe { (*info).si_uid }
}

/// The sender's real user id from an `SA_SIGINFO` record.
#[cfg(not(any(target_os = "macos", target_os = "ios", target_os = "freebsd")))]
unsafe fn siginfo_uid(info: *mut libc::siginfo_t) -> u32 {
    // SAFETY: the caller passes the kernel's non-null siginfo.
    unsafe { (*info).si_uid() }
}

/// `SA_SIGINFO` handler for TERM, INT and HUP: record the first signal and
/// its sender, request shutdown, wake the waiters. Async-signal-safe.
pub(crate) extern "C" fn handle_signal(
    signal: libc::c_int,
    info: *mut libc::siginfo_t,
    _context: *mut libc::c_void,
) {
    // SAFETY: the kernel passes a valid siginfo for an SA_SIGINFO handler;
    // reading it is async-signal-safe.
    let sender = if info.is_null() { 0 } else { unsafe { (*info).si_pid() } };
    // SAFETY: as above.
    let uid = if info.is_null() { u32::MAX } else { unsafe { siginfo_uid(info) } };
    if SHUTDOWN_SIGNAL.compare_exchange(0, signal, Ordering::AcqRel, Ordering::Acquire).is_ok() {
        SHUTDOWN_SIGNAL_SENDER.store(sender, Ordering::Release);
        SHUTDOWN_SIGNAL_SENDER_UID.store(uid, Ordering::Release);
    }
    SHUTDOWN_REQUESTED.store(true, Ordering::Release);
    let writer = SIGNAL_WAKE_WRITER.load(Ordering::Relaxed);
    if writer >= 0 {
        let byte = 1_u8;
        // SAFETY: write(2) is async-signal-safe, `writer` is a process-lifetime
        // socket descriptor, and the one-byte source remains valid for the call.
        unsafe {
            let _ = libc::write(writer, std::ptr::from_ref(&byte).cast(), 1);
        }
    }
}

/// The first termination signal this process got, its sender PID and the
/// sender's user id.
pub(crate) fn shutdown_signal() -> Option<(i32, i32, Option<u32>)> {
    let signal = SHUTDOWN_SIGNAL.load(Ordering::Acquire);
    let uid = SHUTDOWN_SIGNAL_SENDER_UID.load(Ordering::Acquire);
    (signal != 0).then(|| {
        (signal, SHUTDOWN_SIGNAL_SENDER.load(Ordering::Acquire), (uid != u32::MAX).then_some(uid))
    })
}
