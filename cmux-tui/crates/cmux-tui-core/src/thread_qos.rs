//! The role of each daemon and terminal-host thread, mapped to a QoS class in
//! one place.
//!
//! Chromium names a thread by what it does (`ThreadType`) and maps the type
//! to a macOS QoS class in one function, `ThreadTypeToQoSClass` in
//! base/threading/platform_thread_apple.mm. cmux does the same in two steps:
//! [`ThreadType::qos`] maps a role to a [`ThreadQos`], and cmux-threads maps
//! that class to the OS (`pthread_set_qos_class_self_np` on macOS, a nice
//! value on Linux, no change elsewhere; see `cmux_threads::qos`).
//!
//! | ThreadType    | ThreadQos       | macOS QoS class            | Chromium ThreadType |
//! | ------------- | --------------- | -------------------------- | ------------------- |
//! | InputCritical | UserInteractive | QOS_CLASS_USER_INTERACTIVE | kDisplayCritical    |
//! | Interactive   | UserInitiated   | QOS_CLASS_USER_INITIATED   | kDefault            |
//! | Utility       | Utility         | QOS_CLASS_UTILITY          | kUtility            |
//! | Background    | Background      | QOS_CLASS_BACKGROUND       | kBackground         |
//!
//! A thread calls [`set`] as the first statement of its body, before it does
//! any I/O. The InputCritical threads are the ones a key press and its echo
//! go through:
//!
//! - `mux-conn`: the reader of each daemon connection (server/listen.rs).
//! - `mux-control-dispatch`: the per-connection surface request dispatcher
//!   (server/connection_scheduler.rs).
//! - `terminal-host-client-input`: reads client frames and writes input to
//!   the PTY (terminal_host_runtime/shared/host_serve.rs).
//! - `terminal-host-pty`: reads the PTY, the source of the echo
//!   (terminal_host_runtime/shared/host_start.rs).
//! - `terminal-host-parser`: parses the PTY output into the screen
//!   (terminal_host_runtime/shared/host_start.rs).
//! - `holder-link`: routes holder output to its surfaces (cmux-holder
//!   src/link.rs). cmux-holder sits below this crate, so it sets
//!   `ThreadQos::UserInteractive`, the class [`ThreadType::InputCritical`]
//!   maps to; the `input_critical_is_user_interactive` test keeps the two
//!   the same.

pub use cmux_threads::QosChange;
use cmux_threads::ThreadQos;

/// What a thread does, which sets the QoS class it runs at.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum ThreadType {
    /// On the path from a key press to its echo on screen (Chromium
    /// kDisplayCritical).
    InputCritical,
    /// Request work the person waits on (Chromium kDefault).
    Interactive,
    /// Automation, watchers and best-effort work (Chromium kUtility).
    Utility,
    /// Idle work only (Chromium kBackground).
    Background,
}

impl ThreadType {
    /// Every type, highest priority first.
    pub const ALL: [Self; 4] =
        [Self::InputCritical, Self::Interactive, Self::Utility, Self::Background];

    /// The QoS class of the type: the one map from a thread role to a class.
    pub const fn qos(self) -> ThreadQos {
        match self {
            Self::InputCritical => ThreadQos::UserInteractive,
            Self::Interactive => ThreadQos::UserInitiated,
            Self::Utility => ThreadQos::Utility,
            Self::Background => ThreadQos::Background,
        }
    }
}

/// Sets the calling thread's QoS class to the class of `thread_type`. A
/// thread registered with cmux-threads also gets its registry row updated.
/// A refused change is counted by cmux-threads (`refused_changes`); the
/// thread then keeps running at its current class.
pub fn set(thread_type: ThreadType) -> QosChange {
    cmux_threads::set_current(thread_type.qos())
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Runs `f` on a new thread, so a QoS change does not leak into the test
    /// runner's thread.
    fn on_new_thread<R: Send + 'static>(f: impl FnOnce() -> R + Send + 'static) -> R {
        std::thread::spawn(f).join().expect("the probe thread does not panic")
    }

    #[test]
    fn types_map_to_the_chromium_thread_type_classes() {
        let classes: Vec<ThreadQos> = ThreadType::ALL.iter().map(|ty| ty.qos()).collect();
        assert_eq!(
            classes,
            [
                ThreadQos::UserInteractive,
                ThreadQos::UserInitiated,
                ThreadQos::Utility,
                ThreadQos::Background,
            ]
        );
    }

    /// cmux-holder's `holder-link` sets this class by name (see the module
    /// doc); a change here must change it there too.
    #[test]
    fn input_critical_is_user_interactive() {
        assert_eq!(ThreadType::InputCritical.qos(), ThreadQos::UserInteractive);
    }

    /// The class the kernel reports for the calling thread, read with
    /// `pthread_get_qos_class_np`.
    #[cfg(target_vendor = "apple")]
    fn kernel_class() -> u32 {
        let mut class = libc::qos_class_t::QOS_CLASS_UNSPECIFIED as u32;
        let mut relative_priority = 0;
        // SAFETY: pthread_self is the live calling thread and both out
        // pointers are valid for the call. The class is read into a `u32`,
        // the enum's repr, so a class the enum has no variant for is valid.
        let rc = unsafe {
            libc::pthread_get_qos_class_np(
                libc::pthread_self(),
                (&raw mut class).cast::<libc::qos_class_t>(),
                &mut relative_priority,
            )
        };
        assert_eq!(rc, 0, "pthread_get_qos_class_np reads the calling thread");
        class
    }

    #[cfg(target_vendor = "apple")]
    #[test]
    fn set_applies_the_class_the_kernel_reports() {
        use libc::qos_class_t::*;
        let expected = [
            (ThreadType::InputCritical, QOS_CLASS_USER_INTERACTIVE),
            (ThreadType::Interactive, QOS_CLASS_USER_INITIATED),
            (ThreadType::Utility, QOS_CLASS_UTILITY),
            (ThreadType::Background, QOS_CLASS_BACKGROUND),
        ];
        for (thread_type, class) in expected {
            let (change, read) = on_new_thread(move || (set(thread_type), kernel_class()));
            assert_eq!(change, QosChange::Applied, "{thread_type:?}");
            assert_eq!(read, class as u32, "{thread_type:?}");
        }
    }

    /// A thread can always raise its nice value, so the two lowest classes
    /// apply on Linux whatever nice the test runner starts at (below them).
    #[cfg(any(target_os = "linux", target_os = "android"))]
    #[test]
    fn set_applies_the_nice_value_on_linux() {
        use cmux_threads::LiveQos;
        for thread_type in [ThreadType::Utility, ThreadType::Background] {
            let (start, change, read) = on_new_thread(move || {
                let start = cmux_threads::current();
                (start, set(thread_type), cmux_threads::current())
            });
            let target = thread_type.qos().linux_nice();
            let LiveQos::Nice(start) = start else {
                panic!("Linux reads a nice value, got {start:?}");
            };
            if start > target {
                continue;
            }
            assert_eq!(change, QosChange::Applied, "{thread_type:?}");
            assert_eq!(read, LiveQos::Nice(target), "{thread_type:?}");
        }
    }
}
