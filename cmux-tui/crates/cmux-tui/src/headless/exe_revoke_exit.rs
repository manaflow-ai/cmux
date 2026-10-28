//! macOS: a headless owner whose own executable is revoked exits at once.
//!
//! A force-removed volume (an ejected disk image, a CI runner's
//! instance-store volume that vanished under a DerivedData build) revokes
//! the executable's vnode. Every code page of the owner that is not resident
//! then faults in the kernel without end: each thread that runs code it has
//! not run before spins at about 100% system time, and the owner can neither
//! serve nor run its own shutdown. Two orphaned probe owners on aws-m4pro-5
//! spun at 390-570% for 13 hours this way (`sample` itself died of SIGBUS
//! reading them); an owner whose binary is still on disk stays idle.
//!
//! So one thread waits on the executable's kqueue `NOTE_REVOKE` and ends the
//! process with a raw `exit` system call: from the event to the exit only the
//! watcher's own code runs, wired (`mlock`) before it waits so it is
//! resident when the event comes, with no call through the executable's
//! stubs. The owner's terminal
//! hosts are separate processes and keep running; the next owner of the
//! session adopts them, as after any owner exit.
//!
//! One thread, blocked in `kevent` on the revoke or a stop pipe: no timer.
//! It ends with the process, or when the owner stops ([`ExeRevokeExit::stop`]
//! closes the pipe and joins it).

use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd};
use std::os::unix::fs::OpenOptionsExt;

/// The owner's exit status after its executable was revoked
/// (`EX_UNAVAILABLE`).
const REVOKED_EXIT: libc::c_int = 69;

/// The running watcher; [`ExeRevokeExit::stop`] ends and joins it.
pub(crate) struct ExeRevokeExit {
    stop: io::PipeWriter,
    thread: std::thread::JoinHandle<()>,
}

impl ExeRevokeExit {
    pub(crate) fn stop(self) {
        drop(self.stop);
        let _ = self.thread.join();
    }
}

/// Starts the watcher; one that cannot start is logged and the owner runs
/// as before.
pub(crate) fn start() -> Option<ExeRevokeExit> {
    match arm() {
        Ok(watcher) => Some(watcher),
        Err(error) => {
            crate::client_log::stderr_log!(
                "startup",
                "{BIN}: cannot watch this executable for a revoke: {error}"
            );
            None
        }
    }
}

fn arm() -> io::Result<ExeRevokeExit> {
    // O_EVTONLY: an event-only descriptor, which never keeps the volume
    // from being unmounted.
    let exe = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_EVTONLY)
        .open(std::env::current_exe()?)?;
    let (reader, stop) = io::pipe()?;
    // SAFETY: kqueue returns a new descriptor or -1.
    let raw = unsafe { libc::kqueue() };
    if raw < 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: a new descriptor this function owns.
    let queue = unsafe { OwnedFd::from_raw_fd(raw) };
    let change = |ident: libc::c_int, filter, fflags| {
        // SAFETY: kevent is plain data; all-zero is a valid value.
        let mut change: libc::kevent = unsafe { std::mem::zeroed() };
        change.ident = ident as _;
        change.filter = filter;
        // EV_RECEIPT: each registration reports its outcome (data 0 on
        // success) instead of a real event.
        change.flags = libc::EV_ADD | libc::EV_CLEAR | libc::EV_RECEIPT;
        change.fflags = fflags;
        change
    };
    let changes = [
        change(exe.as_raw_fd(), libc::EVFILT_VNODE, libc::NOTE_REVOKE),
        change(reader.as_raw_fd(), libc::EVFILT_READ, 0),
    ];
    // SAFETY: as above.
    let mut receipts: [libc::kevent; 2] = unsafe { std::mem::zeroed() };
    // SAFETY: two changes in, at most two receipts out, no timeout.
    let n = unsafe {
        libc::kevent(raw, changes.as_ptr(), 2, receipts.as_mut_ptr(), 2, std::ptr::null())
    };
    if n < 0 {
        return Err(io::Error::last_os_error());
    }
    if let Some(failed) = receipts[..n as usize].iter().find(|receipt| receipt.data != 0) {
        return Err(io::Error::from_raw_os_error(failed.data as i32));
    }
    // Without its exit path resident the watcher could fault like the rest.
    wire(wait_for_revoke as *const () as usize)?;
    let thread = std::thread::Builder::new().name("exe-revoke-exit".into()).spawn(move || {
        // Both descriptors stay open while the thread waits.
        let _held = (exe, reader);
        // No signal reaches this thread, so `kevent` never returns EINTR and
        // the wait never has to call into the executable again.
        // SAFETY: a full set, applied to this thread only.
        unsafe {
            let mut all: libc::sigset_t = std::mem::zeroed();
            libc::sigfillset(&mut all);
            libc::pthread_sigmask(libc::SIG_BLOCK, &all, std::ptr::null_mut());
        }
        wait_for_revoke(queue.as_raw_fd());
    })?;
    Ok(ExeRevokeExit { stop, thread })
}

/// Waits for the revoke (then exits the process) or the stop pipe (then
/// returns). From the event to the exit only this function's wired code
/// runs: `kevent` returns straight into it, and the exit is a raw system
/// call, not a call through the executable's stubs (whose page may no
/// longer be resident).
#[inline(never)]
fn wait_for_revoke(queue: libc::c_int) {
    // SAFETY: kevent is plain data; all-zero is a valid value.
    let mut event: libc::kevent = unsafe { std::mem::zeroed() };
    // SAFETY: a live queue, no changes, one event slot, no timeout.
    let n = unsafe { libc::kevent(queue, std::ptr::null(), 0, &mut event, 1, std::ptr::null()) };
    if n == 1 && event.filter == libc::EVFILT_VNODE {
        exit_now();
    }
}

/// `exit(2)` with [`REVOKED_EXIT`], as a raw system call (Darwin's `SYS_exit`
/// is 1): it ends every thread of the process.
#[inline(always)]
fn exit_now() -> ! {
    // SAFETY: SYS_exit takes the status and never returns.
    #[cfg(target_arch = "aarch64")]
    unsafe {
        std::arch::asm!("svc #0x80", in("x16") 1u64, in("x0") REVOKED_EXIT as u64, options(noreturn));
    }
    // SAFETY: as above (BSD system calls are class 2 on x86_64).
    #[cfg(target_arch = "x86_64")]
    unsafe {
        std::arch::asm!("syscall", in("rax") 0x200_0001u64, in("rdi") REVOKED_EXIT as u64, options(noreturn));
    }
    // SAFETY: as above, through the system library.
    #[cfg(not(any(target_arch = "aarch64", target_arch = "x86_64")))]
    unsafe {
        libc::_exit(REVOKED_EXIT)
    }
}

/// Wires the code pages at `address` (and the next one, as the function may
/// cross a page), so they stay resident after the executable is revoked.
fn wire(address: usize) -> io::Result<()> {
    // SAFETY: sysconf has no preconditions.
    let page = unsafe { libc::sysconf(libc::_SC_PAGESIZE) } as usize;
    let start = address & !(page - 1);
    // SAFETY: two mapped text pages of this executable; mlock only pins them.
    if unsafe { libc::mlock(start as *const libc::c_void, 2 * page) } != 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn the_revoke_watcher_starts_and_stops() {
        let watcher = super::arm().expect("watch this test binary for a revoke");
        watcher.stop();
    }
}
