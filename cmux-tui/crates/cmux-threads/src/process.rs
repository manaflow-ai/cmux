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
//! A spawn through `posix_spawn` or a multi-threaded `fork` runs inside
//! [`spawn_qos`], which restores the calling thread's QoS after it. A
//! single-threaded process that forks (cmux-holder) sets the class in the
//! child before `execve` with `pthread_set_qos_class_self_np`.
//!
//! Linux is unchanged: a child inherits its creator's nice value, and the
//! classes children start at are nice 0 like the echo and request threads.

use crate::qos::ThreadQos;

/// The class a user shell or agent child starts at.
pub const USER_CHILD: ThreadQos = ThreadQos::Default;

/// The class a helper command (git, ss/netstat, hooks) starts at.
pub const HELPER_CHILD: ThreadQos = ThreadQos::Utility;

/// Runs `spawn` (a fork, `posix_spawn` or `Command::spawn`) so the child it
/// starts runs at `qos`, then restores the calling thread's QoS, also when
/// `spawn` panics. macOS only; elsewhere `spawn` runs unchanged.
pub fn spawn_qos<R>(qos: ThreadQos, spawn: impl FnOnce() -> R) -> R {
    #[cfg(target_vendor = "apple")]
    {
        crate::qos::with_qos(qos, spawn)
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let _ = qos;
        spawn()
    }
}

/// [`spawn_qos`] at [`USER_CHILD`]: for a user shell or agent.
pub fn spawn_user_child<R>(spawn: impl FnOnce() -> R) -> R {
    spawn_qos(USER_CHILD, spawn)
}

/// [`spawn_qos`] at [`HELPER_CHILD`]: for git, ss/netstat and hooks.
pub fn spawn_helper<R>(spawn: impl FnOnce() -> R) -> R {
    spawn_qos(HELPER_CHILD, spawn)
}

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spawn_qos_returns_the_spawn_result() {
        assert_eq!(spawn_user_child(|| 7), 7);
        assert_eq!(spawn_helper(|| "helper"), "helper");
    }

    #[test]
    fn the_child_table_is_default_for_users_and_utility_for_helpers() {
        assert_eq!(USER_CHILD, ThreadQos::Default);
        assert_eq!(HELPER_CHILD, ThreadQos::Utility);
    }

    /// Linux: a spawn changes neither the thread's nice value nor the
    /// refusal count.
    #[cfg(any(target_os = "linux", target_os = "android"))]
    #[test]
    fn linux_spawns_leave_the_thread_unchanged() {
        use crate::qos::{current, refused_changes};
        std::thread::spawn(|| {
            let before = current();
            let refused = refused_changes();
            assert_eq!(spawn_helper(current), before);
            assert_eq!(spawn_user_child(current), before);
            assert_eq!(current(), before);
            assert_eq!(refused_changes(), refused);
        })
        .join()
        .unwrap();
    }

    /// macOS: a spawn from a UserInteractive thread runs at the child's class
    /// and the thread is back at UserInteractive after.
    #[cfg(target_vendor = "apple")]
    #[test]
    fn macos_spawn_runs_at_the_child_class_and_restores_the_thread() {
        use crate::qos::{LiveQos, QosChange, current, set_current};
        std::thread::spawn(|| {
            assert_eq!(set_current(ThreadQos::UserInteractive), QosChange::Applied);
            assert_eq!(spawn_user_child(current), LiveQos::Class(ThreadQos::Default));
            assert_eq!(current(), LiveQos::Class(ThreadQos::UserInteractive));
            assert_eq!(spawn_helper(current), LiveQos::Class(ThreadQos::Utility));
            assert_eq!(current(), LiveQos::Class(ThreadQos::UserInteractive));
        })
        .join()
        .unwrap();
    }

    /// macOS: a child spawned inside [`spawn_user_child`] from a
    /// UserInteractive thread runs at Default and the thread is restored;
    /// one spawned outside it inherits UserInteractive (the bug).
    #[cfg(target_vendor = "apple")]
    #[test]
    fn macos_a_user_child_of_an_echo_thread_runs_at_default() {
        use crate::qos::{LiveQos, QosChange, current, set_current};
        let default = probe::base_priority_at(ThreadQos::Default).unwrap();
        let interactive = probe::base_priority_at(ThreadQos::UserInteractive).unwrap();
        assert_ne!(default, interactive);
        let sleep = || std::process::Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let read = |mut child: std::process::Child| {
            let priority = probe::first_thread_base_priority(child.id() as libc::pid_t);
            let _ = child.kill();
            let _ = child.wait();
            priority.unwrap()
        };
        let (wrapped, raw) = std::thread::spawn(move || {
            assert_eq!(set_current(ThreadQos::UserInteractive), QosChange::Applied);
            let wrapped = read(spawn_user_child(sleep));
            assert_eq!(current(), LiveQos::Class(ThreadQos::UserInteractive));
            (wrapped, read(sleep()))
        })
        .join()
        .unwrap();
        assert_eq!(wrapped, default, "user child {wrapped}: default {default}, ui {interactive}");
        assert_eq!(raw, interactive, "an unwrapped child inherits the thread's class");
    }
}
