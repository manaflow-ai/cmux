//! Raises the worker of a running block item to UserInitiated when shutdown starts.
//!
//! Chrome runs BLOCK_SHUTDOWN tasks "with a normal thread priority" once shutdown has started
//! (`TaskTracker::StartShutdown`, base/task/thread_pool/task_tracker.cc, and
//! `WorkerThread::GetDesiredThreadType`, base/task/thread_pool/worker_thread.cc). Shutdown waits for
//! such an item, so it must not keep running at Utility or Background behind other work.
//!
//! - macOS: a QoS override on the worker's thread (`pthread_override_qos_class_start_np`, as
//!   Chrome's `SetCurrentThreadTypeOverride` in base/threading/platform_thread_apple.mm), ended by the
//!   worker after the item.
//! - Linux: the worker's nice value goes to 0 when the process may lower nice values (root or an
//!   RLIMIT_NICE that allows it, Chromium's `CanLowerNiceTo`); otherwise the raise is refused. The
//!   worker puts its class's nice value back after the item; raising nice needs no privilege.

use crate::qos::ThreadQos;

/// The thread of a worker that runs a block item, recorded when it takes the item.
#[derive(Clone, Copy, Debug)]
pub(super) struct Target {
    #[cfg(target_vendor = "apple")]
    pthread: usize,
    #[cfg(any(target_os = "linux", target_os = "android"))]
    tid: Option<u64>,
}

impl Target {
    /// The calling thread.
    pub(super) fn current() -> Target {
        Target {
            // SAFETY: pthread_self has no preconditions.
            #[cfg(target_vendor = "apple")]
            pthread: unsafe { libc::pthread_self() } as usize,
            #[cfg(any(target_os = "linux", target_os = "android"))]
            tid: crate::registry::current_tid(),
        }
    }
}

/// A raise in force; the worker passes it to [`end`] after its item.
#[derive(Debug)]
pub(super) struct Boost {
    #[cfg(target_vendor = "apple")]
    token: usize,
}

#[cfg(target_vendor = "apple")]
unsafe extern "C" {
    fn pthread_override_qos_class_start_np(
        thread: libc::pthread_t,
        qos: libc::qos_class_t,
        relative_priority: libc::c_int,
    ) -> *mut libc::c_void;
    fn pthread_override_qos_class_end_np(token: *mut libc::c_void) -> libc::c_int;
}

/// Raises `target` to UserInitiated; `None` when the kernel or the nice rule refused. The caller
/// holds the lane lock and `target` runs its item, so the thread is alive.
#[cfg(target_vendor = "apple")]
pub(super) fn start(target: Target) -> Option<Boost> {
    // SAFETY: `target.pthread` is a live thread (see above); the call takes no other pointer.
    let token = unsafe {
        pthread_override_qos_class_start_np(
            target.pthread as libc::pthread_t,
            ThreadQos::UserInitiated.qos_class(),
            0,
        )
    };
    (!token.is_null()).then_some(Boost { token: token as usize })
}

#[cfg(any(target_os = "linux", target_os = "android"))]
pub(super) fn start(target: Target) -> Option<Boost> {
    let tid = target.tid?;
    // Nice 0 again is allowed only to root or inside RLIMIT_NICE.
    if !crate::qos::reversible(ThreadQos::Background) {
        return None;
    }
    let nice = ThreadQos::UserInitiated.linux_nice();
    // SAFETY: plain FFI call; PRIO_PROCESS with a tid sets that one thread's nice value.
    let set = unsafe { libc::setpriority(libc::PRIO_PROCESS, tid as libc::id_t, nice) } == 0;
    set.then_some(Boost {})
}

#[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
pub(super) fn start(_target: Target) -> Option<Boost> {
    None
}

/// Ends `boost` on the worker it raised, after its item; `class` is the worker's QoS for life.
pub(super) fn end(boost: Boost, class: ThreadQos) {
    #[cfg(target_vendor = "apple")]
    {
        let _ = class;
        // SAFETY: the token came from pthread_override_qos_class_start_np and is ended once.
        unsafe { pthread_override_qos_class_end_np(boost.token as *mut libc::c_void) };
    }
    #[cfg(not(target_vendor = "apple"))]
    {
        let Boost {} = boost;
        // The worker raises its own nice value back to its class's; that needs no privilege.
        let _ = crate::qos::set_current(class);
    }
}
