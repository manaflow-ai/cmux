//! The process's Mach task role, read for diagnostics (`server-threads`).
//!
//! Chromium sets a child's role with `SetCurrentTaskDefaultRole`
//! (base/process/process_mac.cc) and reads it back with
//! `task_policy_get(TASK_CATEGORY_POLICY)` for its priority tests; this is
//! that read. The kernel picks a thread's scheduling band from the task role
//! together with its QoS, so a thread row means little without it.
//!
//! Linux has no task roles: [`current`] is `None` there.

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

#[cfg(target_vendor = "apple")]
mod sys {
    /// <mach/task_policy.h>: the flavor whose policy is one `task_role_t`.
    const TASK_CATEGORY_POLICY: libc::c_uint = 1;

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
}

#[cfg(not(target_vendor = "apple"))]
mod sys {
    pub(super) fn current() -> Option<i32> {
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

    #[cfg(target_vendor = "apple")]
    #[test]
    fn a_macos_process_reads_a_role() {
        assert!(current().is_some(), "task_policy_get(TASK_CATEGORY_POLICY) succeeds");
    }

    #[cfg(not(target_vendor = "apple"))]
    #[test]
    fn other_platforms_have_no_role() {
        assert_eq!(current(), None);
    }
}
