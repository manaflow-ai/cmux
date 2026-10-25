//! Thread quality of service: one table for every cmux thread.
//!
//! The classes and their macOS values copy Chromium's ThreadType table
//! (base/threading/platform_thread_apple.mm `ThreadTypeToQoSClass`). Linux
//! uses nice values like Chromium's `kThreadTypeToNiceValueMap`
//! (base/threading/platform_thread_linux.cc), capped at 0:
//!
//! | ThreadQos       | Chromium ThreadType          | macOS QoS class            | Linux nice |
//! | --------------- | ---------------------------- | -------------------------- | ---------- |
//! | Background      | kBackground                  | QOS_CLASS_BACKGROUND       | 10         |
//! | Utility         | kUtility, kResourceEfficient | QOS_CLASS_UTILITY          | 5          |
//! | Default         | (none: unclassified work)    | QOS_CLASS_DEFAULT          | 0          |
//! | UserInitiated   | kDefault                     | QOS_CLASS_USER_INITIATED   | 0          |
//! | UserInteractive | kDisplayCritical             | QOS_CLASS_USER_INTERACTIVE | 0          |
//!
//! Linux stops at nice 0 because an unprivileged thread cannot lower its
//! nice value. A change that would lower it is attempted only when Chromium's
//! `CanLowerNiceTo` test passes (base/threading/platform_thread_internal_posix.cc:
//! root, or a target inside RLIMIT_NICE); otherwise it is refused and counted.

use std::sync::atomic::{AtomicU64, Ordering};

use crate::registry;

/// The QoS a cmux thread declares. Ordered from lowest to highest priority.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(u8)]
pub enum ThreadQos {
    /// Idle work only (Chromium kBackground).
    Background = 0,
    /// Automation, watchers, best-effort lanes (Chromium kUtility).
    Utility = 1,
    /// Work that has not been classified yet.
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

    /// The class of a macOS QoS class, `None` for QOS_CLASS_UNSPECIFIED.
    #[cfg(target_vendor = "apple")]
    pub fn from_qos_class(class: libc::qos_class_t) -> Option<Self> {
        Self::ALL.into_iter().find(|qos| qos.qos_class() as u32 == class as u32)
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

/// Runs `f` at `qos` and restores the calling thread's QoS after, also when
/// `f` panics.
///
/// On Linux a demotion that the thread could not undo (raising nice above a
/// value it may not lower back to) is not made: `f` runs at the current QoS
/// and the refusal is counted, so the thread never leaves `with_qos` slower
/// than it entered.
pub fn with_qos<R>(qos: ThreadQos, f: impl FnOnce() -> R) -> R {
    let saved = sys::save();
    let effective = registry::with_current(registry::Row::effective);
    if !sys::can_restore(qos, &saved) {
        record_refusal();
        return f();
    }
    let _restore = Restore { saved, effective };
    set_current(qos);
    f()
}

struct Restore {
    saved: sys::Saved,
    effective: Option<Option<ThreadQos>>,
}

impl Drop for Restore {
    fn drop(&mut self) {
        if sys::restore(&self.saved) {
            if let Some(effective) = self.effective {
                registry::with_current(|row| row.set_effective(effective));
            }
        } else {
            record_refusal();
        }
    }
}

/// The live QoS of a registered thread. The caller guarantees the thread has
/// not exited (the registry holds its lock, and a thread removes its row
/// under that lock before it exits).
pub(crate) fn live_of(thread: &registry::NativeThread) -> LiveQos {
    sys::live_of(thread)
}

#[cfg(target_vendor = "apple")]
mod sys {
    use super::{LiveQos, QosChange, ThreadQos};
    use crate::registry::NativeThread;

    pub(super) struct Saved {
        class: libc::qos_class_t,
        relative_priority: libc::c_int,
    }

    pub(super) fn apply_self(qos: ThreadQos) -> QosChange {
        // SAFETY: plain FFI call on the calling thread.
        let rc = unsafe { libc::pthread_set_qos_class_self_np(qos.qos_class(), 0) };
        if rc == 0 { QosChange::Applied } else { QosChange::Refused }
    }

    fn read(pthread: libc::pthread_t) -> Option<Saved> {
        let mut class = libc::qos_class_t::QOS_CLASS_UNSPECIFIED;
        let mut relative_priority = 0;
        // SAFETY: `pthread` is a live thread (see `live_of`); the out
        // pointers are valid for the call.
        let rc =
            unsafe { libc::pthread_get_qos_class_np(pthread, &mut class, &mut relative_priority) };
        (rc == 0).then_some(Saved { class, relative_priority })
    }

    fn live(pthread: libc::pthread_t) -> LiveQos {
        match read(pthread) {
            Some(saved) => {
                ThreadQos::from_qos_class(saved.class).map_or(LiveQos::Unspecified, LiveQos::Class)
            }
            None => LiveQos::Unknown,
        }
    }

    pub(super) fn live_self() -> LiveQos {
        // SAFETY: pthread_self has no preconditions.
        live(unsafe { libc::pthread_self() })
    }

    pub(super) fn live_of(thread: &NativeThread) -> LiveQos {
        live(thread.pthread())
    }

    pub(super) fn save() -> Saved {
        // SAFETY: pthread_self has no preconditions.
        read(unsafe { libc::pthread_self() })
            .unwrap_or(Saved { class: libc::qos_class_t::QOS_CLASS_DEFAULT, relative_priority: 0 })
    }

    pub(super) fn can_restore(_qos: ThreadQos, _saved: &Saved) -> bool {
        true
    }

    pub(super) fn restore(saved: &Saved) -> bool {
        // A thread with no class goes back to the default class: the kernel
        // takes no "unspecified" request.
        let class = match saved.class {
            libc::qos_class_t::QOS_CLASS_UNSPECIFIED => libc::qos_class_t::QOS_CLASS_DEFAULT,
            class => class,
        };
        // SAFETY: plain FFI call on the calling thread.
        unsafe { libc::pthread_set_qos_class_self_np(class, saved.relative_priority) == 0 }
    }
}

#[cfg(any(target_os = "linux", target_os = "android"))]
mod sys {
    use super::{LiveQos, QosChange, ThreadQos};
    use crate::registry::NativeThread;

    pub(super) struct Saved {
        nice: Option<i32>,
    }

    fn self_tid() -> u64 {
        crate::registry::current_tid().unwrap_or(0)
    }

    /// The nice value of thread `tid`. The raw syscall returns `20 - nice`
    /// (1..=40), so unlike libc's getpriority it has no -1 ambiguity.
    fn nice_of(tid: u64) -> Option<i32> {
        // SAFETY: plain syscall with integer arguments.
        let raw = unsafe {
            libc::syscall(libc::SYS_getpriority, libc::PRIO_PROCESS, tid as libc::c_long)
        };
        (raw > 0).then(|| 20 - raw as i32)
    }

    /// Chromium's `CanLowerNiceTo`
    /// (base/threading/platform_thread_internal_posix.cc): root, or a target
    /// inside the RLIMIT_NICE soft limit. CAP_SYS_NICE is not checked.
    fn may_lower_nice_to(nice: i32) -> bool {
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

    pub(super) fn save() -> Saved {
        Saved { nice: nice_of(self_tid()) }
    }

    pub(super) fn can_restore(qos: ThreadQos, saved: &Saved) -> bool {
        saved.nice.is_some_and(|nice| qos.linux_nice() <= nice || may_lower_nice_to(nice))
    }

    pub(super) fn restore(saved: &Saved) -> bool {
        saved.nice.is_some_and(set_nice)
    }
}

#[cfg(not(any(target_vendor = "apple", target_os = "linux", target_os = "android")))]
mod sys {
    use super::{LiveQos, QosChange, ThreadQos};
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

    pub(super) fn save() -> Saved {
        Saved
    }

    pub(super) fn can_restore(_qos: ThreadQos, _saved: &Saved) -> bool {
        true
    }

    pub(super) fn restore(_saved: &Saved) -> bool {
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn linux_nice_table_matches_chromium_capped_at_zero() {
        let nice: Vec<i32> = ThreadQos::ALL.iter().map(|qos| qos.linux_nice()).collect();
        assert_eq!(nice, [10, 5, 0, 0, 0]);
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
            assert_eq!(ThreadQos::from_qos_class(qos.qos_class()), Some(qos));
        }
        assert_eq!(ThreadQos::from_qos_class(QOS_CLASS_UNSPECIFIED), None);
    }
}
