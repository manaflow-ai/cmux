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
//!
//! [`Booster`] is the seam: [`Booster::system`] makes these calls, tests pass one that counts them.

use crate::qos::ThreadQos;
use std::sync::Arc;

/// The thread of a worker that runs a block item, recorded when it takes the item.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
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

/// The block items running on a BestEffort or Idle worker of one lane, under the lane lock.
#[derive(Default)]
pub(super) struct Raises {
    running: Vec<RunningBlock>,
    next_id: u64,
    /// Workers shutdown raised.
    pub(super) raised: u64,
    /// Raises the kernel or the Linux nice rule refused.
    pub(super) refused: u64,
}

/// A block item running on a BestEffort or Idle worker.
struct RunningBlock {
    id: u64,
    worker: Target,
    /// Shutdown raised it (at most once); the worker ends the raise after the item.
    raised: bool,
    end: Option<EndBoost>,
}

impl Raises {
    /// Raises the worker of every tracked block item shutdown has not raised yet.
    pub(super) fn raise_all(&mut self, booster: &Booster) {
        for running in self.running.iter_mut().filter(|running| !running.raised) {
            running.raised = true;
            // Under the lane lock: the worker untracks its item under it, so the raise never
            // outlives it.
            running.end = booster.start(running.worker);
            if running.end.is_some() {
                self.raised += 1;
            } else {
                self.refused += 1;
            }
        }
    }

    /// Tracks a block item the calling worker takes below the foreground class; raised at once when
    /// shutdown has started (`closed`). Returns its id.
    pub(super) fn track(&mut self, worker: Target, closed: bool, booster: &Booster) -> u64 {
        let id = self.next_id;
        self.next_id += 1;
        self.running.push(RunningBlock { id, worker, raised: false, end: None });
        if closed {
            self.raise_all(booster);
        }
        id
    }

    /// Stops tracking item `id`; returns the end of its raise, which the worker calls.
    pub(super) fn untrack(&mut self, id: u64) -> Option<EndBoost> {
        let index = self.running.iter().position(|running| running.id == id)?;
        self.running.swap_remove(index).end
    }
}

/// Ends a raise in force: the worker calls it after its item, on its own thread, with its class's QoS.
pub(super) type EndBoost = Box<dyn FnOnce(ThreadQos) + Send>;

type StartFn = dyn Fn(Target) -> Option<EndBoost> + Send + Sync;

/// Raises the worker of a running block item at shutdown.
#[derive(Clone)]
pub(super) struct Booster(Arc<StartFn>);

impl Booster {
    /// `start` raises a worker that runs its item and returns the call that ends the raise, or `None`
    /// when the raise was refused. The lane calls it under its lock: it must not wait.
    pub(super) fn new(
        start: impl Fn(Target) -> Option<EndBoost> + Send + Sync + 'static,
    ) -> Booster {
        Booster(Arc::new(start))
    }

    /// The kernel's raise: a macOS QoS override, or nice 0 on Linux.
    pub(super) fn system() -> Booster {
        Booster::new(start_system)
    }

    pub(super) fn start(&self, target: Target) -> Option<EndBoost> {
        (self.0)(target)
    }
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

/// Raises `target` to UserInitiated; `None` when the kernel refused. The caller holds the lane lock
/// and `target` runs its item, so the thread is alive. The end ignores the class: ending the override
/// puts the worker's own QoS back.
#[cfg(target_vendor = "apple")]
fn start_system(target: Target) -> Option<EndBoost> {
    // SAFETY: `target.pthread` is a live thread (see above); the call takes no other pointer.
    let token = unsafe {
        pthread_override_qos_class_start_np(
            target.pthread as libc::pthread_t,
            ThreadQos::UserInitiated.qos_class(),
            0,
        )
    };
    if token.is_null() {
        return None;
    }
    let token = token as usize;
    Some(Box::new(move |_class| {
        // SAFETY: the token came from pthread_override_qos_class_start_np and is ended once.
        unsafe { pthread_override_qos_class_end_np(token as *mut libc::c_void) };
    }))
}

/// Raises `target` to nice 0; `None` when the nice rule or the kernel refused. The end puts the
/// worker's class nice value back on the worker itself; raising nice needs no privilege.
#[cfg(any(target_os = "linux", target_os = "android"))]
fn start_system(target: Target) -> Option<EndBoost> {
    let tid = target.tid?;
    // Nice 0 again is allowed only to root or inside RLIMIT_NICE.
    if !crate::qos::reversible(ThreadQos::Background) {
        return None;
    }
    let nice = ThreadQos::UserInitiated.linux_nice();
    // SAFETY: plain FFI call; PRIO_PROCESS with a tid sets that one thread's nice value.
    let set = unsafe { libc::setpriority(libc::PRIO_PROCESS, tid as libc::id_t, nice) } == 0;
    set.then(|| -> EndBoost {
        Box::new(|class| {
            let _ = crate::qos::set_current(class);
        })
    })
}

#[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
fn start_system(_target: Target) -> Option<EndBoost> {
    None
}
