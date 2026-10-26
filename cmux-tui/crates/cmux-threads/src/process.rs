//! The QoS a child process starts at.
//!
//! On macOS a new process's first thread starts at the QoS of the thread
//! that forked or posix_spawned it, and keeps it across `execve`. A user
//! shell started from an echo thread would then run at USER_INTERACTIVE for
//! its whole life, ahead of the daemon work the person waits on. Chromium's
//! launcher sets no QoS at spawn (base/process/launch_mac.cc) because it
//! launches from a thread that is not display-critical; cmux starts children
//! from request and echo threads, so every spawn states the class:
//!
//! | Child                                     | Class   |
//! | ----------------------------------------- | ------- |
//! | A user shell or agent ([`USER_CHILD`])    | Default |
//! | git, ss/netstat, hooks ([`HELPER_CHILD`]) | Utility |
//!
//! A `posix_spawn` states the class through `cmux_process::Command::qos`: a
//! helper's Utility is a ceiling in the spawn attributes
//! (`posix_spawnattr_set_qos_class_np`, which takes Utility and Background
//! only), so the spawning thread is untouched; a user child's Default is the
//! class the spawning thread holds for the one `posix_spawn` call. A
//! single-threaded process that forks (cmux-holder) sets the class in the
//! child before `execve` with `pthread_set_qos_class_self_np`.
//!
//! Linux does not apply these classes: a child keeps its creator's nice
//! value, so a helper started from a nice-0 request thread runs at nice 0,
//! not at Utility's nice 5.

use crate::qos::ThreadQos;

/// The class a user shell or agent child starts at.
pub const USER_CHILD: ThreadQos = ThreadQos::Default;

/// The class a helper command (git, ss/netstat, hooks) starts at.
pub const HELPER_CHILD: ThreadQos = ThreadQos::Utility;

/// Reads the QoS a process's thread runs at (macOS), for tests of spawn
/// paths. The QoS class of another process's thread cannot be read; its base
/// scheduling priority, which the class sets (Default 31, UserInteractive
/// 46), can (`proc_pidinfo`, sys/proc_info.h).
#[cfg(target_vendor = "apple")]
pub mod probe {
    use std::io;

    use crate::qos::{QosChange, ThreadQos, set_current};

    /// sys/proc_info.h flavors the libc crate has no constant for.
    const PROC_PIDLISTTHREADS: libc::c_int = 6;
    const PROC_PIDTHREADID64INFO: libc::c_int = 15;

    fn thread_info(
        pid: libc::pid_t,
        flavor: libc::c_int,
        thread: u64,
    ) -> io::Result<libc::proc_threadinfo> {
        let mut info = std::mem::MaybeUninit::<libc::proc_threadinfo>::zeroed();
        let size = size_of::<libc::proc_threadinfo>() as libc::c_int;
        // SAFETY: proc_pidinfo writes at most `size` bytes into `info`.
        let read =
            unsafe { libc::proc_pidinfo(pid, flavor, thread, info.as_mut_ptr().cast(), size) };
        if read != size {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: zero-initialized (a valid proc_threadinfo), then filled.
        Ok(unsafe { info.assume_init() })
    }

    /// The base priority of the first thread of process `pid`.
    pub fn first_thread_base_priority(pid: libc::pid_t) -> io::Result<i32> {
        let mut threads = [0u64; 64];
        let room = size_of_val(&threads) as libc::c_int;
        // SAFETY: proc_pidinfo writes at most `room` bytes into `threads`.
        let listed = unsafe {
            libc::proc_pidinfo(pid, PROC_PIDLISTTHREADS, 0, threads.as_mut_ptr().cast(), room)
        };
        if listed < size_of::<u64>() as libc::c_int {
            return Err(io::Error::last_os_error());
        }
        Ok(thread_info(pid, libc::PROC_PIDTHREADINFO, threads[0])?.pth_priority)
    }

    /// The base priority of a thread of this process at `qos`: the value a
    /// child spawned at `qos` is compared with.
    pub fn base_priority_at(qos: ThreadQos) -> io::Result<i32> {
        std::thread::scope(|scope| {
            scope
                .spawn(|| {
                    if set_current(qos) != QosChange::Applied {
                        return Err(io::Error::other(format!("could not set {qos}")));
                    }
                    let mut tid = 0u64;
                    // SAFETY: a null pthread_t names the calling thread; the
                    // id goes into a live local.
                    if unsafe { libc::pthread_threadid_np(0 as libc::pthread_t, &mut tid) } != 0 {
                        return Err(io::Error::last_os_error());
                    }
                    // SAFETY: getpid has no preconditions.
                    let pid = unsafe { libc::getpid() };
                    Ok(thread_info(pid, PROC_PIDTHREADID64INFO, tid)?.pth_priority)
                })
                .join()
                .unwrap_or_else(|_| Err(io::Error::other("priority probe panicked")))
        })
    }
}
