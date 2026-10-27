//! Thread quality of service: one table for every cmux thread.
//!
//! The classes and their macOS values copy Chromium's ThreadType table
//! (base/threading/platform_thread_apple.mm `ThreadTypeToQoSClass`). The
//! Linux nice values are the p02-threads spec's (task 200: 0/0/0/5/10), not
//! Chromium's `kThreadTypeToNiceValueMap` (base/threading/platform_thread_linux.cc
//! maps kBackground 10, kUtility 1, kResourceEfficient 0, kDefault 0):
//!
//! | ThreadQos       | Chromium ThreadType          | macOS QoS class            | Linux nice |
//! | --------------- | ---------------------------- | -------------------------- | ---------- |
//! | Background      | kBackground                  | QOS_CLASS_BACKGROUND       | 10         |
//! | Utility         | kUtility, kResourceEfficient | QOS_CLASS_UTILITY          | 5          |
//! | Default         | (none: child processes)      | QOS_CLASS_DEFAULT          | 0          |
//! | UserInitiated   | kDefault                     | QOS_CLASS_USER_INITIATED   | 0          |
//! | UserInteractive | kDisplayCritical             | QOS_CLASS_USER_INTERACTIVE | 0          |
//!
//! Utility is nice 5, not Chromium's 1, by cmux choice: automation lanes
//! then clearly yield to the nice-0 request and echo threads on a loaded
//! Linux host.
//!
//! Linux stops at nice 0 because an unprivileged thread cannot lower its
//! nice value. A change that would lower it is attempted only when Chromium's
//! `CanLowerNiceTo` test passes (base/threading/platform_thread_internal_posix.cc:
//! root, or a target inside RLIMIT_NICE); otherwise it is refused and counted.

use std::marker::PhantomData;
use std::sync::atomic::{AtomicU64, Ordering};

use crate::registry;

/// QoS overrides one thread starts on another (a lock waiter on its owner).
pub(crate) mod boost;

/// The QoS a cmux thread declares. Ordered from lowest to highest priority.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(u8)]
pub enum ThreadQos {
    /// Idle work only (Chromium kBackground).
    Background = 0,
    /// Automation, watchers, best-effort lanes (Chromium kUtility).
    Utility = 1,
    /// The class a user shell or agent child process starts at (see
    /// [`crate::process`]). Not a class for daemon threads.
    Default = 2,
    /// Request dispatch the person waits on (Chromium kDefault).
    UserInitiated = 3,
    /// The key echo path and frame work (Chromium kDisplayCritical).
    UserInteractive = 4,
}

impl ThreadQos {
    /// Every class, lowest priority first.
    pub const ALL: [Self; 5] = [
        Self::Background,
        Self::Utility,
        Self::Default,
        Self::UserInitiated,
        Self::UserInteractive,
    ];

    /// The stable name used in snapshots and diagnostics.
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Background => "background",
            Self::Utility => "utility",
            Self::Default => "default",
            Self::UserInitiated => "user-initiated",
            Self::UserInteractive => "user-interactive",
        }
    }

    /// The Linux nice value of the class (see the module table).
    pub const fn linux_nice(self) -> i32 {
        match self {
            Self::Background => 10,
            Self::Utility => 5,
            Self::Default | Self::UserInitiated | Self::UserInteractive => 0,
        }
    }

    pub(crate) const fn from_u8(raw: u8) -> Self {
        match raw {
            0 => Self::Background,
            1 => Self::Utility,
            2 => Self::Default,
            3 => Self::UserInitiated,
            _ => Self::UserInteractive,
        }
    }

    /// The macOS QoS class of the class (see the module table).
    #[cfg(target_vendor = "apple")]
    pub const fn qos_class(self) -> libc::qos_class_t {
        use libc::qos_class_t::*;
        match self {
            Self::Background => QOS_CLASS_BACKGROUND,
            Self::Utility => QOS_CLASS_UTILITY,
            Self::Default => QOS_CLASS_DEFAULT,
            Self::UserInitiated => QOS_CLASS_USER_INITIATED,
            Self::UserInteractive => QOS_CLASS_USER_INTERACTIVE,
        }
    }

    /// The base scheduler priority of the class on macOS (xnu
    /// osfmk/kern/thread_policy.c `thread_qos_policy_params.qos_pri`): what
    /// `THREAD_EXTENDED_INFO` `pth_priority` reads for a thread at the class
    /// with relative priority 0, overrides included. UserInteractive is
    /// BASEPRI_BACKGROUND (46); xnu `thread_recompute_priority` adds 1 (47)
    /// only in the frontmost app (`thep_qos_ui_is_urgent`).
    #[cfg(target_vendor = "apple")]
    pub const fn macos_base_priority(self) -> i32 {
        match self {
            Self::Background => 4,
            Self::Utility => 20,
            Self::Default => 31,
            Self::UserInitiated => 37,
            Self::UserInteractive => 46,
        }
    }

    /// The highest class whose base priority is at most `priority`, `None`
    /// below Background's. The frontmost app's UserInteractive priority (47)
    /// is UserInteractive too.
    #[cfg(target_vendor = "apple")]
    pub fn from_macos_base_priority(priority: i32) -> Option<Self> {
        Self::ALL.into_iter().rev().find(|qos| qos.macos_base_priority() <= priority)
    }

    /// The class of a raw macOS QoS class value as the kernel reports it,
    /// `None` for QOS_CLASS_UNSPECIFIED and for classes outside the table
    /// (QOS_CLASS_MAINTENANCE).
    #[cfg(target_vendor = "apple")]
    pub fn from_qos_class(raw: u32) -> Option<Self> {
        Self::ALL.into_iter().find(|qos| qos.qos_class() as u32 == raw)
    }
}

impl std::fmt::Display for ThreadQos {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(self.as_str())
    }
}

/// What the kernel reports for a thread now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LiveQos {
    /// macOS: the thread's QoS class.
    Class(ThreadQos),
    /// macOS: the thread has no QoS class (QOS_CLASS_UNSPECIFIED).
    Unspecified,
    /// macOS: a raw QoS class outside the table, such as
    /// QOS_CLASS_MAINTENANCE (0x05) inherited from a maintenance workqueue.
    Other(u32),
    /// Linux: the thread's nice value.
    Nice(i32),
    /// The platform has no per-thread QoS, or the read failed.
    Unknown,
}

/// The result of a QoS change.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum QosChange {
    /// The thread now runs at the requested class.
    Applied,
    /// The kernel or the Linux nice rule refused the change; it is counted
    /// in [`refused_changes`] and in the thread's registry row.
    Refused,
    /// The platform has no per-thread QoS.
    Unsupported,
}

static REFUSED_CHANGES: AtomicU64 = AtomicU64::new(0);

/// QoS changes refused in this process since start.
pub fn refused_changes() -> u64 {
    REFUSED_CHANGES.load(Ordering::Relaxed)
}

fn record_refusal() {
    REFUSED_CHANGES.fetch_add(1, Ordering::Relaxed);
    registry::with_current(registry::Row::record_refusal);
}

/// Sets the calling thread's QoS and its registry row's effective QoS.
pub fn set_current(qos: ThreadQos) -> QosChange {
    let change = sys::apply_self(qos);
    match change {
        QosChange::Applied => {
            registry::with_current(|row| row.set_effective(Some(qos)));
        }
        QosChange::Refused => record_refusal(),
        QosChange::Unsupported => {}
    }
    change
}

/// The calling thread's QoS as the kernel reports it.
pub fn current() -> LiveQos {
    sys::live_self()
}

/// The calling thread's QoS as the scheduler applies it, overrides included
/// ([`current`] reads the class the thread asked for). macOS: the class of
/// the thread's base priority (`THREAD_EXTENDED_INFO` `pth_priority`, see
/// [`ThreadQos::from_macos_base_priority`]); Linux: the nice value, which an
/// override sets.
pub fn current_effective() -> LiveQos {
    sys::effective_self()
}

/// True when a thread at the process's base class (macOS: any class in the
/// table; Linux: nice 0) can change to `qos` and take the change back. A
/// process property, so a caller can ask once and skip a change it cannot
/// make instead of having every attempt refused and counted. Linux: root,
/// a class at nice 0, or an RLIMIT_NICE that allows nice 0 again (Chromium's
/// `CanLowerNiceTo`).
pub fn reversible(qos: ThreadQos) -> bool {
    sys::reversible(qos)
}

/// True when the calling thread can change to `qos` now without a refusal,
/// so a thread it starts can too (a new thread starts at its creator's
/// class or nice). macOS: any class in the table; Linux: a nice value at or
/// above the thread's own, or one the process may lower nice to (root or
/// RLIMIT_NICE, Chromium's `CanLowerNiceTo`). A daemon started under
/// `nice -n 10` without that right reaches only Background.
pub fn reachable(qos: ThreadQos) -> bool {
    #[cfg(any(target_os = "linux", target_os = "android"))]
    return sys::reachable(qos);
    #[cfg(not(any(target_os = "linux", target_os = "android")))]
    {
        let _ = qos;
        true
    }
}

/// Runs `f` at `qos` and restores the calling thread's QoS after, also when
/// `f` panics. [`QosScope`] is the same rule as a guard.
pub fn with_qos<R>(qos: ThreadQos, f: impl FnOnce() -> R) -> R {
    let _scope = QosScope::enter(qos);
    f()
}

/// The calling thread runs at a QoS until the scope drops, then gets back
/// the QoS it had (Chromium's `ScopedBoostPriority`,
/// base/threading/scoped_thread_priority.h). Scopes nest; it is not `Send`,
/// so it ends on the thread it began.
///
/// A change the thread could not undo is not made: the thread stays at its
/// current QoS and the refusal is counted. On Linux that is a demotion
/// (raising nice above a value it may not lower back to); on macOS a thread
/// whose class is outside the table (QOS_CLASS_MAINTENANCE), which the
/// kernel takes no request for. A macOS thread with no class
/// (QOS_CLASS_UNSPECIFIED) comes back at [`ThreadQos::Default`], the class
/// with the same base priority (31), and its registry row records Default
/// as its effective QoS.
#[must_use = "the QoS holds only while the scope lives"]
pub struct QosScope {
    /// Dropped with the scope: puts the saved QoS back.
    _restore: Option<Restore>,
    applied: bool,
    _not_send: PhantomData<*const ()>,
}

impl QosScope {
    /// Runs the calling thread at `qos` until the scope drops.
    pub fn enter(qos: ThreadQos) -> Self {
        let saved = sys::save();
        let effective = registry::with_current(registry::Row::effective);
        if !sys::can_restore(qos, &saved) {
            record_refusal();
            return Self { _restore: None, applied: false, _not_send: PhantomData };
        }
        let restore = Restore { saved, effective };
        let applied = set_current(qos) == QosChange::Applied;
        Self { _restore: Some(restore), applied, _not_send: PhantomData }
    }

    /// True when the thread runs at the scope's QoS; false when the change
    /// was refused (counted) or the platform has none.
    pub fn applied(&self) -> bool {
        self.applied
    }
}

impl std::fmt::Debug for QosScope {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("QosScope").field("applied", &self.applied).finish()
    }
}

struct Restore {
    saved: sys::Saved,
    effective: Option<Option<ThreadQos>>,
}

/// What [`sys::restore`] put back: `Ok(Some(qos))` when the thread now runs
/// at `qos` (macOS), `Ok(None)` when the saved native value is back (a Linux
/// nice), so the effective QoS saved from the registry row holds again.
/// `Err` when the kernel refused.
type Restored = Result<Option<ThreadQos>, ()>;

impl Drop for Restore {
    fn drop(&mut self) {
        match sys::restore(&self.saved) {
            Ok(Some(qos)) => {
                registry::with_current(|row| row.set_effective(Some(qos)));
            }
            Ok(None) => {
                if let Some(effective) = self.effective {
                    registry::with_current(|row| row.set_effective(effective));
                }
            }
            Err(()) => record_refusal(),
        }
    }
}

/// The live QoS of a registered thread. The caller guarantees the thread has
/// not exited (the registry holds its lock, and a thread removes its row
/// under that lock before it exits).
pub(crate) fn live_of(thread: &registry::NativeThread) -> LiveQos {
    sys::live_of(thread)
}

/// The scheduler priority a registered thread runs at now, after QoS,
/// overrides and decay: macOS `THREAD_EXTENDED_INFO` `pth_curpri` (Default
/// 31, UserInteractive 47), Linux the `priority` field of
/// `/proc/<pid>/task/<tid>/stat` (20 + nice for normal policies,
/// -1 - rt_priority for FIFO and RR), read with syscalls. `None` when the
/// read fails or the platform has none. Same caller guarantee as [`live_of`].
pub(crate) fn priority_of(thread: &registry::NativeThread) -> Option<i32> {
    sys::priority_of(thread)
}

#[cfg(target_vendor = "apple")]
mod sys {
    use super::{LiveQos, QosChange, Restored, ThreadQos};
    use crate::registry::NativeThread;

    pub(super) const UNSPECIFIED: u32 = libc::qos_class_t::QOS_CLASS_UNSPECIFIED as u32;

    /// A thread's QoS as the kernel reported it. The class stays a raw `u32`:
    /// the kernel can report classes `libc::qos_class_t` has no variant for
    /// (QOS_CLASS_MAINTENANCE).
    #[derive(Clone, Copy)]
    pub(super) struct Raw {
        pub(super) class: u32,
        pub(super) relative_priority: libc::c_int,
    }

    pub(super) struct Saved(pub(super) Option<Raw>);

    pub(super) fn apply_self(qos: ThreadQos) -> QosChange {
        // SAFETY: plain FFI call on the calling thread.
        let rc = unsafe { libc::pthread_set_qos_class_self_np(qos.qos_class(), 0) };
        if rc == 0 { QosChange::Applied } else { QosChange::Refused }
    }

    fn read(pthread: libc::pthread_t) -> Option<Raw> {
        let mut class: u32 = UNSPECIFIED;
        let mut relative_priority = 0;
        // SAFETY: `pthread` is a live thread (see `live_of`). The class
        // out-pointer is a `u32`, the enum's repr, so every value the kernel
        // writes is valid; the out pointers are valid for the call.
        let rc = unsafe {
            libc::pthread_get_qos_class_np(
                pthread,
                (&raw mut class).cast::<libc::qos_class_t>(),
                &mut relative_priority,
            )
        };
        (rc == 0).then_some(Raw { class, relative_priority })
    }

    fn live(pthread: libc::pthread_t) -> LiveQos {
        match read(pthread) {
            None => LiveQos::Unknown,
            Some(Raw { class: UNSPECIFIED, .. }) => LiveQos::Unspecified,
            Some(Raw { class, .. }) => {
                ThreadQos::from_qos_class(class).map_or(LiveQos::Other(class), LiveQos::Class)
            }
        }
    }

    pub(super) fn live_self() -> LiveQos {
        // SAFETY: pthread_self has no preconditions.
        live(unsafe { libc::pthread_self() })
    }

    pub(super) fn live_of(thread: &NativeThread) -> LiveQos {
        live(thread.pthread())
    }

    pub(super) fn priority_of(thread: &NativeThread) -> Option<i32> {
        // SAFETY: `thread` is live (see `live_of`). The port name is the
        // thread's own; this takes no reference, so none is released.
        let port = unsafe { libc::pthread_mach_thread_np(thread.pthread()) };
        if port == 0 {
            return None;
        }
        let mut info = std::mem::MaybeUninit::<libc::thread_extended_info>::zeroed();
        let mut count = libc::THREAD_EXTENDED_INFO_COUNT;
        // SAFETY: `info` has room for THREAD_EXTENDED_INFO_COUNT integers,
        // the count passed; the kernel writes at most that many.
        let rc = unsafe {
            libc::thread_info(
                port,
                libc::THREAD_EXTENDED_INFO as libc::thread_flavor_t,
                info.as_mut_ptr().cast::<libc::integer_t>(),
                &mut count,
            )
        };
        // SAFETY: zero-initialized (a valid thread_extended_info), then filled.
        (rc == libc::KERN_SUCCESS).then(|| unsafe { info.assume_init() }.pth_curpri)
    }

    pub(super) fn save() -> Saved {
        // SAFETY: pthread_self has no preconditions.
        Saved(read(unsafe { libc::pthread_self() }))
    }

    /// The class a restore sets: the saved class, or Default for no class
    /// (the kernel takes no "unspecified" request; both run at base priority
    /// 31). `None` when the saved class is outside the table or was not read.
    pub(super) fn restore_class(saved: &Saved) -> Option<(ThreadQos, libc::c_int)> {
        let raw = saved.0?;
        let qos = match raw.class {
            UNSPECIFIED => ThreadQos::Default,
            class => ThreadQos::from_qos_class(class)?,
        };
        Some((qos, raw.relative_priority))
    }

    pub(super) fn can_restore(_qos: ThreadQos, saved: &Saved) -> bool {
        restore_class(saved).is_some()
    }

    pub(super) fn reversible(_qos: ThreadQos) -> bool {
        true
    }

    pub(super) fn effective_self() -> LiveQos {
        // SAFETY: pthread_self has no preconditions; the port it maps to
        // carries no reference to release (unlike mach_thread_self).
        let port = unsafe { libc::pthread_mach_thread_np(libc::pthread_self()) };
        // SAFETY: plain old data the kernel fills.
        let mut info: libc::thread_extended_info_data_t = unsafe { std::mem::zeroed() };
        let mut count = libc::THREAD_EXTENDED_INFO_COUNT;
        // SAFETY: `info` is valid for `count` integers, the size of the
        // flavor's struct.
        let rc = unsafe {
            libc::thread_info(
                port,
                libc::THREAD_EXTENDED_INFO as libc::thread_flavor_t,
                (&raw mut info).cast::<libc::integer_t>(),
                &mut count,
            )
        };
        if rc != libc::KERN_SUCCESS {
            return LiveQos::Unknown;
        }
        ThreadQos::from_macos_base_priority(info.pth_priority)
            .map_or(LiveQos::Unknown, LiveQos::Class)
    }

    pub(super) fn restore(saved: &Saved) -> Restored {
        let Some((qos, relative_priority)) = restore_class(saved) else {
            return Err(());
        };
        // SAFETY: plain FFI call on the calling thread.
        let rc = unsafe { libc::pthread_set_qos_class_self_np(qos.qos_class(), relative_priority) };
        if rc == 0 { Ok(Some(qos)) } else { Err(()) }
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod sys {
    use super::{LiveQos, QosChange, Restored, ThreadQos};
    use crate::registry::NativeThread;

    pub(super) struct Saved {
        pub(super) nice: Option<i32>,
    }

    fn self_tid() -> u64 {
        crate::registry::current_tid().unwrap_or(0)
    }

    /// The nice value of thread `tid`. The raw syscall returns `20 - nice`
    /// (1..=40), so unlike libc's getpriority it has no -1 ambiguity.
    pub(super) fn nice_of(tid: u64) -> Option<i32> {
        // SAFETY: plain syscall with integer arguments.
        let raw = unsafe {
            libc::syscall(libc::SYS_getpriority, libc::PRIO_PROCESS, tid as libc::c_long)
        };
        (raw > 0).then(|| 20 - raw as i32)
    }

    /// Chromium's `CanLowerNiceTo`
    /// (base/threading/platform_thread_internal_posix.cc): root, or a target
    /// inside the RLIMIT_NICE soft limit. CAP_SYS_NICE is not checked.
    pub(super) fn may_lower_nice_to(nice: i32) -> bool {
        // SAFETY: geteuid has no preconditions.
        if unsafe { libc::geteuid() } == 0 {
            return true;
        }
        let mut limit = libc::rlimit { rlim_cur: 0, rlim_max: 0 };
        // SAFETY: `limit` is valid for the call.
        if unsafe { libc::getrlimit(libc::RLIMIT_NICE, &mut limit) } != 0 {
            return false;
        }
        let lowest_allowed = 20 - limit.rlim_cur.min(40) as i32;
        nice >= lowest_allowed
    }

    fn set_nice(nice: i32) -> bool {
        let tid = self_tid();
        let Some(current) = nice_of(tid) else {
            return false;
        };
        if nice == current {
            return true;
        }
        if nice < current && !may_lower_nice_to(nice) {
            return false;
        }
        // SAFETY: plain FFI call; on Linux PRIO_PROCESS with a tid sets that
        // one thread's nice value.
        unsafe { libc::setpriority(libc::PRIO_PROCESS, tid as libc::id_t, nice) == 0 }
    }

    pub(super) fn apply_self(qos: ThreadQos) -> QosChange {
        if set_nice(qos.linux_nice()) { QosChange::Applied } else { QosChange::Refused }
    }

    pub(super) fn live_self() -> LiveQos {
        nice_of(self_tid()).map_or(LiveQos::Unknown, LiveQos::Nice)
    }

    pub(super) fn live_of(thread: &NativeThread) -> LiveQos {
        thread.tid().and_then(nice_of).map_or(LiveQos::Unknown, LiveQos::Nice)
    }

    pub(super) fn priority_of(thread: &NativeThread) -> Option<i32> {
        let tid = thread.tid()?;
        let pid = libc::pid_t::try_from(tid).ok()?;
        // SAFETY: plain syscall with an integer argument; on Linux a tid
        // names that one thread.
        let policy = unsafe { libc::sched_getscheduler(pid) };
        match policy & !libc::SCHED_RESET_ON_FORK {
            libc::SCHED_FIFO | libc::SCHED_RR => {
                let mut param = libc::sched_param { sched_priority: 0 };
                // SAFETY: `param` is valid for the call.
                (unsafe { libc::sched_getparam(pid, &mut param) } == 0)
                    .then(|| -1 - param.sched_priority)
            }
            _ if policy >= 0 => nice_of(tid).map(|nice| 20 + nice),
            _ => None,
        }
    }

    pub(super) fn save() -> Saved {
        Saved { nice: nice_of(self_tid()) }
    }

    pub(super) fn can_restore(qos: ThreadQos, saved: &Saved) -> bool {
        saved.nice.is_some_and(|nice| qos.linux_nice() <= nice || may_lower_nice_to(nice))
    }

    pub(super) fn reversible(qos: ThreadQos) -> bool {
        qos.linux_nice() <= 0 || may_lower_nice_to(0)
    }

    pub(super) fn reachable(qos: ThreadQos) -> bool {
        let target = qos.linux_nice();
        nice_of(self_tid()).is_some_and(|nice| target >= nice) || may_lower_nice_to(target)
    }

    pub(super) fn restore(saved: &Saved) -> Restored {
        if saved.nice.is_some_and(set_nice) { Ok(None) } else { Err(()) }
    }

    pub(super) fn effective_self() -> LiveQos {
        live_self()
    }
}

#[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
mod sys {
    use super::{LiveQos, QosChange, Restored, ThreadQos};
    use crate::registry::NativeThread;

    pub(super) struct Saved;

    pub(super) fn apply_self(_qos: ThreadQos) -> QosChange {
        QosChange::Unsupported
    }

    pub(super) fn live_self() -> LiveQos {
        LiveQos::Unknown
    }

    pub(super) fn live_of(_thread: &NativeThread) -> LiveQos {
        LiveQos::Unknown
    }

    pub(super) fn priority_of(_thread: &NativeThread) -> Option<i32> {
        None
    }

    pub(super) fn save() -> Saved {
        Saved
    }

    pub(super) fn can_restore(_qos: ThreadQos, _saved: &Saved) -> bool {
        true
    }

    pub(super) fn reversible(_qos: ThreadQos) -> bool {
        true
    }

    pub(super) fn restore(_saved: &Saved) -> Restored {
        Ok(None)
    }

    pub(super) fn effective_self() -> LiveQos {
        LiveQos::Unknown
    }
}

#[cfg(test)]
#[path = "qos/reachable_tests.rs"]
mod reachable_tests;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn linux_nice_table_matches_spec_capped_at_zero() {
        let nice: Vec<i32> = ThreadQos::ALL.iter().map(|qos| qos.linux_nice()).collect();
        assert_eq!(nice, [10, 5, 0, 0, 0]);
    }

    #[test]
    fn classes_at_the_base_nice_are_always_reversible() {
        for qos in [ThreadQos::Default, ThreadQos::UserInitiated, ThreadQos::UserInteractive] {
            assert!(reversible(qos), "{qos}");
        }
        // A lowering is reversible exactly when a thread at the base class
        // could take it back: the rule a QosScope applies per change.
        #[cfg(any(target_os = "linux", target_os = "android"))]
        assert_eq!(
            reversible(ThreadQos::Utility),
            sys::can_restore(ThreadQos::Utility, &sys::Saved { nice: Some(0) })
        );
    }

    #[test]
    fn classes_round_trip_through_their_raw_value() {
        for qos in ThreadQos::ALL {
            assert_eq!(ThreadQos::from_u8(qos as u8), qos);
        }
        assert!(ThreadQos::Background < ThreadQos::UserInteractive);
    }

    #[cfg(target_vendor = "apple")]
    #[test]
    fn macos_classes_match_chromium_thread_type_table() {
        use libc::qos_class_t::*;
        assert_eq!(ThreadQos::Background.qos_class() as u32, QOS_CLASS_BACKGROUND as u32);
        assert_eq!(ThreadQos::Utility.qos_class() as u32, QOS_CLASS_UTILITY as u32);
        assert_eq!(ThreadQos::UserInitiated.qos_class() as u32, QOS_CLASS_USER_INITIATED as u32);
        assert_eq!(
            ThreadQos::UserInteractive.qos_class() as u32,
            QOS_CLASS_USER_INTERACTIVE as u32
        );
        for qos in ThreadQos::ALL {
            assert_eq!(ThreadQos::from_qos_class(qos.qos_class() as u32), Some(qos));
        }
        assert_eq!(ThreadQos::from_qos_class(QOS_CLASS_UNSPECIFIED as u32), None);
        assert_eq!(ThreadQos::from_qos_class(QOS_CLASS_MAINTENANCE), None);
    }

    #[cfg(target_vendor = "apple")]
    #[test]
    fn macos_base_priorities_round_trip_including_the_frontmost_boost() {
        for qos in ThreadQos::ALL {
            assert_eq!(ThreadQos::from_macos_base_priority(qos.macos_base_priority()), Some(qos));
        }
        assert_eq!(ThreadQos::UserInteractive.macos_base_priority(), 46);
        assert_eq!(ThreadQos::from_macos_base_priority(47), Some(ThreadQos::UserInteractive));
        assert_eq!(ThreadQos::from_macos_base_priority(45), Some(ThreadQos::UserInitiated));
        assert_eq!(ThreadQos::from_macos_base_priority(3), None);
    }

    #[cfg(target_vendor = "apple")]
    #[test]
    fn macos_current_effective_reports_each_class_a_thread_runs_at() {
        for qos in ThreadQos::ALL {
            let read = crate::spawn("qos-effective-test", qos, current_effective)
                .expect("spawn")
                .join()
                .expect("thread");
            assert_eq!(read, LiveQos::Class(qos), "{qos}");
        }
    }

    #[cfg(target_vendor = "apple")]
    const QOS_CLASS_MAINTENANCE: u32 = 0x05;

    #[cfg(target_vendor = "apple")]
    #[test]
    fn macos_restore_rule_for_classes_outside_the_table() {
        use sys::{Raw, Saved, UNSPECIFIED, can_restore, restore_class};
        let saved = |class| Saved(Some(Raw { class, relative_priority: -3 }));
        // No class comes back as Default, the class the kernel takes.
        assert_eq!(restore_class(&saved(UNSPECIFIED)), Some((ThreadQos::Default, -3)));
        let utility = ThreadQos::Utility.qos_class() as u32;
        assert_eq!(restore_class(&saved(utility)), Some((ThreadQos::Utility, -3)));
        // A class with no request (maintenance) or an unread one cannot be
        // put back, so with_qos does not change it.
        assert_eq!(restore_class(&saved(QOS_CLASS_MAINTENANCE)), None);
        assert!(!can_restore(ThreadQos::Background, &saved(QOS_CLASS_MAINTENANCE)));
        assert!(!can_restore(ThreadQos::Background, &Saved(None)));
    }
}
