//! The process's Mach task role: set at start, moved between foreground and
//! background, and read for diagnostics (`server-threads`).
//!
//! Chromium's child processes call `SetCurrentTaskDefaultRole` at start
//! (base/process/process_mac.cc): TASK_FOREGROUND_APPLICATION with latency
//! and throughput tier 0; that is [`set_default_role`]. `Process::SetPriority`
//! moves a child to TASK_BACKGROUND_APPLICATION with tier 5 timers and
//! throughput for `Priority::kBestEffort`; that is [`ProcessRole::Background`].
//! [`ProcessRole::BackgroundSuppressed`] adds PRIO_DARWIN_BG (low-priority
//! CPU, throttled disk and network I/O), which the other two roles clear.
//! The kernel picks a thread's scheduling band from the task role together
//! with its QoS, so a thread row means little without it; [`current`] reads
//! it back (`task_policy_get(TASK_CATEGORY_POLICY)`, as Chromium's priority
//! tests do).
//!
//! XNU keeps two PRIO_DARWIN_BG flags per task (bsd/kern/kern_resource.c,
//! `do_background_proc`): the internal one a process sets on itself
//! ([`set_role`]) and the external one another process sets by pid
//! ([`set_child_suppressed`]) or a child inherits from a suppressed parent.
//! Either suppresses the task, and a process can clear only its own internal
//! one. [`darwin_background`] and [`darwin_background_of`] read both
//! (`proc_pidinfo(PROC_PIDTBSDINFO)`, `PROC_FLAG_DARWINBG` and
//! `PROC_FLAG_EXT_DARWINBG`).
//!
//! Linux has no task roles: the setters do nothing and the reads are `None`.

/// A `task_role_t` value (<mach/task_policy.h>).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TaskRole {
    /// TASK_RENICED: the role follows a nice value someone set.
    Reniced,
    /// TASK_UNSPECIFIED: no role was set.
    Unspecified,
    /// TASK_FOREGROUND_APPLICATION.
    Foreground,
    /// TASK_BACKGROUND_APPLICATION.
    Background,
    /// TASK_CONTROL_APPLICATION.
    Control,
    /// TASK_GRAPHICS_SERVER.
    GraphicsServer,
    /// TASK_THROTTLE_APPLICATION.
    Throttle,
    /// TASK_NONUI_APPLICATION.
    NonUi,
    /// TASK_DEFAULT_APPLICATION.
    Default,
    /// TASK_DARWINBG_APPLICATION: background-suppressed (PRIO_DARWIN_BG).
    DarwinBg,
    /// A value outside this table.
    Other(i32),
}

impl TaskRole {
    /// The role for a raw `task_role_t`.
    pub const fn from_raw(raw: i32) -> Self {
        match raw {
            -1 => Self::Reniced,
            0 => Self::Unspecified,
            1 => Self::Foreground,
            2 => Self::Background,
            3 => Self::Control,
            4 => Self::GraphicsServer,
            5 => Self::Throttle,
            6 => Self::NonUi,
            7 => Self::Default,
            8 => Self::DarwinBg,
            other => Self::Other(other),
        }
    }

    /// The stable name used in snapshots, `None` for [`TaskRole::Other`].
    pub const fn as_str(self) -> Option<&'static str> {
        Some(match self {
            Self::Reniced => "reniced",
            Self::Unspecified => "unspecified",
            Self::Foreground => "foreground",
            Self::Background => "background",
            Self::Control => "control",
            Self::GraphicsServer => "graphics-server",
            Self::Throttle => "throttle",
            Self::NonUi => "non-ui",
            Self::Default => "default",
            Self::DarwinBg => "darwin-bg",
            Self::Other(_) => return None,
        })
    }
}

/// The calling process's task role, `None` where the platform has none or
/// the read failed.
pub fn current() -> Option<TaskRole> {
    sys::current().map(TaskRole::from_raw)
}

/// A role this process asks for itself with [`set_role`].
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProcessRole {
    /// TASK_FOREGROUND_APPLICATION, tier 0 timers and throughput, no
    /// PRIO_DARWIN_BG.
    Foreground,
    /// TASK_BACKGROUND_APPLICATION, tier 5 timers and throughput, no
    /// PRIO_DARWIN_BG (Chromium's `Priority::kBestEffort`).
    Background,
    /// [`ProcessRole::Background`] plus PRIO_DARWIN_BG.
    BackgroundSuppressed,
}

/// Why [`set_default_role`] or [`set_role`] failed; the process keeps the
/// parts applied before the failing call.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RoleError {
    /// `task_policy_set(TASK_CATEGORY_POLICY)` returned this `kern_return_t`.
    Category(i32),
    /// `task_policy_set(TASK_BASE_QOS_POLICY)` returned this `kern_return_t`.
    BaseQos(i32),
    /// `setpriority(PRIO_DARWIN_PROCESS)` failed with this errno.
    DarwinBackground(i32),
}

impl std::fmt::Display for RoleError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Category(code) => {
                write!(f, "task_policy_set(TASK_CATEGORY_POLICY) failed: {code}")
            }
            Self::BaseQos(code) => {
                write!(f, "task_policy_set(TASK_BASE_QOS_POLICY) failed: {code}")
            }
            Self::DarwinBackground(errno) => {
                write!(f, "setpriority(PRIO_DARWIN_PROCESS) failed: errno {errno}")
            }
        }
    }
}

impl std::error::Error for RoleError {}

/// Chromium's `SetCurrentTaskDefaultRole`: TASK_FOREGROUND_APPLICATION with
/// tier 0 timers and throughput, once at daemon, holder and terminal host
/// start. It leaves PRIO_DARWIN_BG as inherited, so `taskpolicy -b cmux ...`
/// stays suppressed.
///
/// # Errors
///
/// [`RoleError::Category`] or [`RoleError::BaseQos`] when the kernel refuses
/// a policy. Never on Linux.
pub fn set_default_role() -> Result<(), RoleError> {
    sys::set_policies(ProcessRole::Foreground)
}

/// Moves this process to `role`. Leaving suppression clears this process's
/// internal PRIO_DARWIN_BG before the role changes; entering it sets that
/// flag last. The external flag (a parent's [`set_child_suppressed`], or
/// inherited) stays: only another process can clear it.
///
/// # Errors
///
/// The first [`RoleError`] the kernel returns. Never on Linux.
pub fn set_role(role: ProcessRole) -> Result<(), RoleError> {
    let suppressed = role == ProcessRole::BackgroundSuppressed;
    if !suppressed {
        sys::set_darwin_background(false)?;
    }
    sys::set_policies(role)?;
    if suppressed {
        sys::set_darwin_background(true)?;
    }
    Ok(())
}

/// The two PRIO_DARWIN_BG flags of a process (see the module docs).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct DarwinBackground {
    /// Set by the process on itself ([`set_role`]), `PROC_FLAG_DARWINBG`.
    pub internal: bool,
    /// Set by another process by pid ([`set_child_suppressed`]) or inherited
    /// from a suppressed parent, `PROC_FLAG_EXT_DARWINBG`.
    pub external: bool,
}

impl DarwinBackground {
    /// Whether either flag suppresses the process.
    pub const fn suppressed(self) -> bool {
        self.internal || self.external
    }
}

/// This process's PRIO_DARWIN_BG flags, `None` on Linux or when the read
/// failed.
pub fn darwin_background() -> Option<DarwinBackground> {
    darwin_background_of(std::process::id().try_into().ok()?)
}

/// The PRIO_DARWIN_BG flags of `pid` (a process this user may inspect),
/// `None` on Linux or when the read failed.
pub fn darwin_background_of(pid: i32) -> Option<DarwinBackground> {
    sys::darwin_background_of(pid)
}

/// Sets or clears the external PRIO_DARWIN_BG flag of `pid`, a child this
/// process started (Chromium's `Process::SetPriority` for a child). A parent
/// holds no task port of its child, so the child's task role stays the
/// child's own ([`set_default_role`]).
///
/// # Errors
///
/// [`RoleError::DarwinBackground`] with the errno. Never on Linux.
pub fn set_child_suppressed(pid: i32, suppressed: bool) -> Result<(), RoleError> {
    sys::set_darwin_background_of(pid, suppressed)
}

#[cfg(target_vendor = "apple")]
mod sys {
    use super::{DarwinBackground, ProcessRole, RoleError};

    /// <sys/proc_info.h> `pbi_flags`: the internal and the external
    /// PRIO_DARWIN_BG flag (XNU `proc_get_darwinbgstate`).
    const PROC_FLAG_DARWINBG: u32 = 0x8000;
    const PROC_FLAG_EXT_DARWINBG: u32 = 0x10000;
    /// <mach/task_policy.h>: the flavor whose policy is one `task_role_t`.
    const TASK_CATEGORY_POLICY: libc::c_uint = 1;
    /// <mach/task_policy.h>: `struct task_qos_policy`, latency then
    /// throughput tier.
    const TASK_BASE_QOS_POLICY: libc::c_uint = 8;
    const TASK_FOREGROUND_APPLICATION: libc::integer_t = 1;
    const TASK_BACKGROUND_APPLICATION: libc::integer_t = 2;
    /// <mach/thread_policy.h>: `(0xFF << 16) | (tier + 1)`.
    const LATENCY_QOS_TIER_0: libc::integer_t = 0x00FF_0001;
    const LATENCY_QOS_TIER_5: libc::integer_t = 0x00FF_0006;
    /// <mach/thread_policy.h>: `(0xFE << 16) | (tier + 1)`.
    const THROUGHPUT_QOS_TIER_0: libc::integer_t = 0x00FE_0001;
    const THROUGHPUT_QOS_TIER_5: libc::integer_t = 0x00FE_0006;

    unsafe extern "C" {
        /// This task's port, set by libSystem before main (<mach/mach_init.h>).
        static mach_task_self_: libc::mach_port_t;
        fn task_policy_get(
            task: libc::task_t,
            flavor: libc::c_uint,
            policy_info: *mut libc::integer_t,
            count: *mut libc::mach_msg_type_number_t,
            get_default: *mut libc::boolean_t,
        ) -> libc::kern_return_t;
        fn task_policy_set(
            task: libc::task_t,
            flavor: libc::c_uint,
            policy_info: *mut libc::integer_t,
            count: libc::mach_msg_type_number_t,
        ) -> libc::kern_return_t;
    }

    pub(super) fn current() -> Option<i32> {
        let mut role: libc::integer_t = 0;
        let mut count: libc::mach_msg_type_number_t = 1;
        // 0 asks for the current policy, not the default one.
        let mut get_default: libc::boolean_t = 0;
        // SAFETY: `role` has room for the one integer `count` names; the
        // task port is this process's own, valid for its whole life.
        let rc = unsafe {
            task_policy_get(
                mach_task_self_,
                TASK_CATEGORY_POLICY,
                &mut role,
                &mut count,
                &mut get_default,
            )
        };
        (rc == libc::KERN_SUCCESS && count == 1).then_some(role)
    }

    fn set_policy(
        flavor: libc::c_uint,
        policy: &mut [libc::integer_t],
        error: fn(i32) -> RoleError,
    ) -> Result<(), RoleError> {
        let count = libc::mach_msg_type_number_t::try_from(policy.len()).unwrap_or(0);
        // SAFETY: `policy` holds the `count` integers the flavor reads; the
        // task port is this process's own, valid for its whole life.
        let rc = unsafe { task_policy_set(mach_task_self_, flavor, policy.as_mut_ptr(), count) };
        if rc == libc::KERN_SUCCESS { Ok(()) } else { Err(error(rc)) }
    }

    pub(super) fn set_policies(role: ProcessRole) -> Result<(), RoleError> {
        let (category, latency, throughput) = match role {
            ProcessRole::Foreground => {
                (TASK_FOREGROUND_APPLICATION, LATENCY_QOS_TIER_0, THROUGHPUT_QOS_TIER_0)
            }
            ProcessRole::Background | ProcessRole::BackgroundSuppressed => {
                (TASK_BACKGROUND_APPLICATION, LATENCY_QOS_TIER_5, THROUGHPUT_QOS_TIER_5)
            }
        };
        set_policy(TASK_CATEGORY_POLICY, &mut [category], RoleError::Category)?;
        set_policy(TASK_BASE_QOS_POLICY, &mut [latency, throughput], RoleError::BaseQos)
    }

    pub(super) fn set_darwin_background(on: bool) -> Result<(), RoleError> {
        // `who` 0 is this process: XNU sets its internal flag.
        set_darwin_background_of(0, on)
    }

    pub(super) fn set_darwin_background_of(pid: i32, on: bool) -> Result<(), RoleError> {
        let value = if on { libc::PRIO_DARWIN_BG } else { 0 };
        let who =
            libc::id_t::try_from(pid).map_err(|_| RoleError::DarwinBackground(libc::ESRCH))?;
        // SAFETY: a plain syscall on integer arguments.
        if unsafe { libc::setpriority(libc::PRIO_DARWIN_PROCESS, who, value) } == 0 {
            Ok(())
        } else {
            let errno = std::io::Error::last_os_error().raw_os_error().unwrap_or(0);
            Err(RoleError::DarwinBackground(errno))
        }
    }

    pub(super) fn darwin_background_of(pid: i32) -> Option<DarwinBackground> {
        let mut info = std::mem::MaybeUninit::<libc::proc_bsdinfo>::zeroed();
        let size = libc::c_int::try_from(size_of::<libc::proc_bsdinfo>()).ok()?;
        // SAFETY: `info` has room for the `size` bytes the flavor writes.
        let written = unsafe {
            libc::proc_pidinfo(pid, libc::PROC_PIDTBSDINFO, 0, info.as_mut_ptr().cast(), size)
        };
        if written != size {
            return None;
        }
        // SAFETY: the kernel filled the whole struct (`written == size`).
        let flags = unsafe { info.assume_init() }.pbi_flags;
        Some(DarwinBackground {
            internal: flags & PROC_FLAG_DARWINBG != 0,
            external: flags & PROC_FLAG_EXT_DARWINBG != 0,
        })
    }
}

#[cfg(not(target_vendor = "apple"))]
mod sys {
    use super::{DarwinBackground, ProcessRole, RoleError};

    pub(super) fn current() -> Option<i32> {
        None
    }

    pub(super) fn set_policies(_role: ProcessRole) -> Result<(), RoleError> {
        Ok(())
    }

    pub(super) fn set_darwin_background(_on: bool) -> Result<(), RoleError> {
        Ok(())
    }

    pub(super) fn set_darwin_background_of(_pid: i32, _on: bool) -> Result<(), RoleError> {
        Ok(())
    }

    pub(super) fn darwin_background_of(_pid: i32) -> Option<DarwinBackground> {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_roles_map_to_their_names() {
        assert_eq!(TaskRole::from_raw(1), TaskRole::Foreground);
        assert_eq!(TaskRole::from_raw(1).as_str(), Some("foreground"));
        assert_eq!(TaskRole::from_raw(8).as_str(), Some("darwin-bg"));
        assert_eq!(TaskRole::from_raw(-1), TaskRole::Reniced);
        assert_eq!(TaskRole::from_raw(42), TaskRole::Other(42));
        assert_eq!(TaskRole::Other(42).as_str(), None);
    }

    #[test]
    fn role_errors_name_the_refused_call() {
        assert_eq!(
            RoleError::Category(4).to_string(),
            "task_policy_set(TASK_CATEGORY_POLICY) failed: 4"
        );
        assert_eq!(
            RoleError::DarwinBackground(1).to_string(),
            "setpriority(PRIO_DARWIN_PROCESS) failed: errno 1"
        );
    }

    #[cfg(target_vendor = "apple")]
    #[test]
    fn a_macos_process_reads_a_role() {
        assert!(current().is_some(), "task_policy_get(TASK_CATEGORY_POLICY) succeeds");
        assert!(darwin_background().is_some(), "getpriority(PRIO_DARWIN_PROCESS) succeeds");
    }

    #[cfg(not(target_vendor = "apple"))]
    #[test]
    fn other_platforms_have_no_role() {
        assert_eq!(current(), None);
        assert_eq!(darwin_background(), None);
        assert_eq!(darwin_background_of(1), None);
    }

    #[test]
    fn either_flag_suppresses() {
        assert!(!DarwinBackground::default().suppressed());
        assert!(DarwinBackground { internal: true, external: false }.suppressed());
        assert!(DarwinBackground { internal: false, external: true }.suppressed());
    }

    #[cfg(not(target_vendor = "apple"))]
    #[test]
    fn setting_a_role_elsewhere_does_nothing() {
        assert_eq!(set_default_role(), Ok(()));
        for role in
            [ProcessRole::BackgroundSuppressed, ProcessRole::Background, ProcessRole::Foreground]
        {
            assert_eq!(set_role(role), Ok(()));
        }
        assert_eq!(set_child_suppressed(1, true), Ok(()));
        assert_eq!(current(), None);
        assert_eq!(darwin_background(), None);
    }
}
