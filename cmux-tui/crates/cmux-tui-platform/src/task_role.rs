//! The macOS task role of this process (`TASK_CATEGORY_POLICY`).
//!
//! A process an app starts has no role (`TASK_UNSPECIFIED`). XNU then holds every thread of it at the legacy QoS
//! ceiling (`task_policy.c`: an `APP_DEFAULT` task with no role): a thread that asks for user-interactive or
//! user-initiated runs at scheduler priority 31, the default. A process with an application role has user-interactive
//! at 46, user-initiated at 37, default at 31 and utility at 20. A role is the process's own: a process it starts
//! does not get it.

/// `TASK_UNSPECIFIED`: the process has no role (a child of an app, a shell's child).
pub const UNSPECIFIED: i32 = 0;
/// `TASK_DEFAULT_APPLICATION`: an application that is not the foreground one.
pub const APPLICATION: i32 = 7;

/// Gives this process the application role, as Chromium gives a child process its role
/// (`base/process/process_mac.cc`: `task_policy_set(task, TASK_CATEGORY_POLICY, ...)`). Chromium's browser sets it on
/// the child's task port; a cmux process has no task port of its child, so each process that carries a person's
/// input (the terminal owner, a terminal host) calls this for itself when it starts, before it starts a thread. Off
/// macOS this does nothing.
pub fn take_application() {
    #[cfg(target_os = "macos")]
    {
        if let Err(code) = imp::set(APPLICATION) {
            eprintln!("cmux-tui: could not take the application task role (kern_return {code})");
        }
    }
}

/// This process's task role (`task_policy_get`); `None` off macOS or when the kernel refuses the read.
pub fn current() -> Option<i32> {
    #[cfg(target_os = "macos")]
    {
        imp::current()
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

#[cfg(target_os = "macos")]
mod imp {
    use std::ffi::c_int;

    /// `mach_port_t`.
    type MachPort = u32;
    /// `TASK_CATEGORY_POLICY`: the policy whose one field is the role.
    const TASK_CATEGORY_POLICY: u32 = 1;
    /// `TASK_CATEGORY_POLICY_COUNT`: one `integer_t`.
    const TASK_CATEGORY_POLICY_COUNT: u32 = 1;

    #[allow(non_upper_case_globals)]
    unsafe extern "C" {
        /// What `mach_task_self()` reads: this process's task port.
        static mach_task_self_: MachPort;
        fn task_policy_set(
            task: MachPort,
            flavor: u32,
            policy_info: *mut c_int,
            count: u32,
        ) -> c_int;
        fn task_policy_get(
            task: MachPort,
            flavor: u32,
            policy_info: *mut c_int,
            count: *mut u32,
            get_default: *mut c_int,
        ) -> c_int;
    }

    /// Sets this process's role; the error is the `kern_return_t`.
    pub(super) fn set(role: i32) -> Result<(), c_int> {
        let mut role: c_int = role;
        // SAFETY: passes one `integer_t` (the role) for this process's own task port, as the flavor's count says.
        let rc = unsafe {
            task_policy_set(
                mach_task_self_,
                TASK_CATEGORY_POLICY,
                &mut role,
                TASK_CATEGORY_POLICY_COUNT,
            )
        };
        if rc == 0 { Ok(()) } else { Err(rc) }
    }

    pub(super) fn current() -> Option<i32> {
        let mut role: c_int = 0;
        let mut count = TASK_CATEGORY_POLICY_COUNT;
        let mut get_default: c_int = 0;
        // SAFETY: reads this process's own role into locals of the sizes the call names.
        let rc = unsafe {
            task_policy_get(
                mach_task_self_,
                TASK_CATEGORY_POLICY,
                &mut role,
                &mut count,
                &mut get_default,
            )
        };
        (rc == 0).then_some(role)
    }
}
