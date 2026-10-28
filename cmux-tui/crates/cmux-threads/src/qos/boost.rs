//! QoS overrides: one thread raises another for a while, then ends it.
//!
//! - macOS: `pthread_override_qos_class_start_np` / `_end_np`, as Chromium's
//!   `SetCurrentThreadTypeOverride` (base/threading/platform_thread_apple.mm).
//!   The kernel applies the highest override in force and ends each one by
//!   its token, so the target's own class is back once the last one ends.
//! - Linux: the target's nice value is lowered to the class's when the
//!   process may lower it (root, or inside RLIMIT_NICE: Chromium's
//!   `CanLowerNiceTo`), and put back at the end; raising nice needs no
//!   privilege. Otherwise the override is refused.
//!
//! Every start takes a [`Target`] the caller guarantees is alive. Only a
//! macOS override may end after its target exited
//! ([`ENDS_AFTER_TARGET_EXITS`]).

use crate::qos::ThreadQos;
use crate::registry;

/// The class of the calling thread by its registry row (see
/// [`registry::Row::class`]); `None` for a thread that is not registered.
pub(crate) fn current_class() -> Option<ThreadQos> {
    registry::with_current(registry::Row::class)
}

pub(crate) use sys::{Override, Target, end, raise, start, target_of, target_self};

/// True when an override may end after its target thread exited: macOS,
/// whose token keeps a send right to the thread's port (libpthread
/// `pthread_override_qos_class_start_np`), so the end is a refused no-op. A
/// Linux end would set the nice value of whatever thread has the tid then.
pub(crate) const ENDS_AFTER_TARGET_EXITS: bool = cfg!(target_vendor = "apple");

#[cfg(target_vendor = "apple")]
mod sys {
    use crate::qos::ThreadQos;
    use crate::registry::NativeThread;

    unsafe extern "C" {
        fn pthread_override_qos_class_start_np(
            thread: libc::pthread_t,
            qos: libc::qos_class_t,
            relative_priority: libc::c_int,
        ) -> *mut libc::c_void;
        fn pthread_override_qos_class_end_np(token: *mut libc::c_void) -> libc::c_int;
    }

    /// A thread an override can raise, recorded by the thread itself.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub(crate) struct Target {
        pthread: usize,
    }

    /// An override in force: the kernel's token and its target.
    #[derive(Debug)]
    pub(crate) struct Override {
        target: Target,
        token: usize,
    }

    /// The calling thread.
    pub(crate) fn target_self() -> Target {
        // SAFETY: pthread_self has no preconditions.
        Target { pthread: unsafe { libc::pthread_self() } as usize }
    }

    /// A registered thread.
    pub(crate) fn target_of(thread: &NativeThread) -> Target {
        Target { pthread: thread.pthread() as usize }
    }

    /// Raises `target` to at least `qos`; `None` when the kernel refused.
    pub(crate) fn start(target: Target, qos: ThreadQos) -> Option<Override> {
        // SAFETY: the caller guarantees `target` is a live thread; the call
        // takes no other pointer.
        let token = unsafe {
            pthread_override_qos_class_start_np(
                target.pthread as libc::pthread_t,
                qos.qos_class(),
                0,
            )
        };
        (!token.is_null()).then_some(Override { target, token: token as usize })
    }

    /// Raises an override in force to `qos`; false, and `active` unchanged,
    /// when refused. The new override starts before the old one ends, so
    /// the target never drops between.
    pub(crate) fn raise(active: &mut Override, qos: ThreadQos) -> bool {
        let Some(raised) = start(active.target, qos) else {
            return false;
        };
        end(std::mem::replace(active, raised));
        true
    }

    /// Ends an override: its target runs at its own class again.
    pub(crate) fn end(active: Override) {
        // SAFETY: the token came from pthread_override_qos_class_start_np and
        // is ended once (`active` is consumed).
        unsafe { pthread_override_qos_class_end_np(active.token as *mut libc::c_void) };
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod sys {
    use std::cell::Cell;

    use crate::qos::ThreadQos;
    use crate::qos::sys::{may_lower_nice_to, nice_of};
    use crate::registry::NativeThread;

    /// A thread an override can raise, recorded by the thread itself.
    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub(crate) struct Target {
        tid: Option<u64>,
    }

    /// A lowered nice value in force on thread `tid`, and the value it had
    /// before (`None`: it needed no change).
    #[derive(Debug)]
    pub(crate) struct Override {
        tid: u64,
        before: Option<i32>,
    }

    thread_local! {
        /// The calling thread's tid, read once (gettid is a syscall).
        static TID: Cell<Option<u64>> = const { Cell::new(None) };
    }

    /// The calling thread.
    pub(crate) fn target_self() -> Target {
        let cached = TID.try_with(|cached| {
            if cached.get().is_none() {
                cached.set(crate::registry::current_tid());
            }
            cached.get()
        });
        Target { tid: cached.unwrap_or_else(|_| crate::registry::current_tid()) }
    }

    /// A registered thread.
    pub(crate) fn target_of(thread: &NativeThread) -> Target {
        Target { tid: thread.tid() }
    }

    /// Lowers `tid`'s nice value to `qos`'s when it is higher: `Some(before)`
    /// with the value it had (`Some(None)`: no change was needed), `None`
    /// when the nice rule or the kernel refused.
    fn lower_nice(tid: u64, qos: ThreadQos) -> Option<Option<i32>> {
        let current = nice_of(tid)?;
        let nice = qos.linux_nice();
        if nice >= current {
            return Some(None);
        }
        if !may_lower_nice_to(nice) {
            return None;
        }
        // SAFETY: plain FFI call; PRIO_PROCESS with a tid sets that one
        // thread's nice value.
        let set = unsafe { libc::setpriority(libc::PRIO_PROCESS, tid as libc::id_t, nice) } == 0;
        set.then_some(Some(current))
    }

    /// Raises `target` to at least `qos`; `None` when refused.
    pub(crate) fn start(target: Target, qos: ThreadQos) -> Option<Override> {
        let tid = target.tid?;
        lower_nice(tid, qos).map(|before| Override { tid, before })
    }

    /// Raises an override in force to `qos`; false, and `active` unchanged,
    /// when refused. The end still puts back the value from before the
    /// first lowering.
    pub(crate) fn raise(active: &mut Override, qos: ThreadQos) -> bool {
        let Some(before) = lower_nice(active.tid, qos) else {
            return false;
        };
        active.before = active.before.or(before);
        true
    }

    /// Ends an override: its target's nice value is put back.
    pub(crate) fn end(active: Override) {
        if let Some(nice) = active.before {
            // SAFETY: as in `lower_nice`.
            unsafe { libc::setpriority(libc::PRIO_PROCESS, active.tid as libc::id_t, nice) };
        }
    }
}

#[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
mod sys {
    use crate::qos::ThreadQos;

    #[derive(Clone, Copy, Debug, PartialEq, Eq)]
    pub(crate) struct Target;

    #[derive(Debug)]
    pub(crate) struct Override;

    pub(crate) fn target_self() -> Target {
        Target
    }

    pub(crate) fn target_of(_thread: &crate::registry::NativeThread) -> Target {
        Target
    }

    pub(crate) fn start(_target: Target, _qos: ThreadQos) -> Option<Override> {
        None
    }

    pub(crate) fn raise(_active: &mut Override, _qos: ThreadQos) -> bool {
        false
    }

    pub(crate) fn end(_active: Override) {}
}
