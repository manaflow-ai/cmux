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
            ThreadQos::Default,
            ThreadQos::Utility,
            ThreadQos::Background,
        ]
    );
}

/// cmux-holder sits below this crate and names its link reader's class
/// itself; it must be the class of the key echo path.
#[test]
fn holder_link_reader_is_input_critical() {
    assert_eq!(cmux_holder::link::LINK_READER_QOS, ThreadType::InputCritical.qos());
}

/// The echo path threads (`echo_thread::spawn`) declare the InputCritical
/// class.
#[test]
fn echo_path_threads_are_input_critical() {
    assert_eq!(crate::echo_thread::ECHO_PATH_QOS, ThreadType::InputCritical.qos());
}

/// The class the kernel reports for the calling thread, read with
/// `pthread_get_qos_class_np`.
#[cfg(target_vendor = "apple")]
fn kernel_class() -> u32 {
    let mut class = libc::qos_class_t::QOS_CLASS_UNSPECIFIED as u32;
    let mut relative_priority = 0;
    // SAFETY: pthread_self is the live calling thread and both out pointers
    // are valid for the call. The class is read into a `u32`, the enum's
    // repr, so a class the enum has no variant for is still a valid value.
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
        (ThreadType::UnclassifiedClient, QOS_CLASS_DEFAULT),
        (ThreadType::Utility, QOS_CLASS_UTILITY),
        (ThreadType::Background, QOS_CLASS_BACKGROUND),
    ];
    for (thread_type, class) in expected {
        let (change, read) = on_new_thread(move || (set(thread_type), kernel_class()));
        assert_eq!(change, QosChange::Applied, "{thread_type:?}");
        assert_eq!(read, class as u32, "{thread_type:?}");
    }
}

/// A thread can always raise its nice value, so the two lowest classes apply
/// on Linux whatever nice the test runner starts at below them.
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

/// The registry rows of the live threads named `name`, waiting (bounded)
/// until there is one: the thread registers itself as it starts.
fn rows_named(name: &str) -> Vec<cmux_threads::ThreadInfo> {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(5);
    loop {
        let rows: Vec<_> =
            cmux_threads::snapshot().into_iter().filter(|row| row.name == name).collect();
        if !rows.is_empty() {
            return rows;
        }
        assert!(std::time::Instant::now() < deadline, "no {name} thread row");
        std::thread::yield_now();
    }
}

/// Daemon watchers (p05-ipc-080) start at Utility through `spawn_raisable`
/// and run there: the kernel reports the class of the running thread
/// (`pthread_get_qos_class_np`, macOS). Where Utility could not be taken
/// back for a lock (Linux without the right to lower nice) they start at
/// Default.
#[test]
fn daemon_watchers_run_at_utility() {
    let mux = crate::Mux::new_for_test("daemon-watchers-qos", crate::SurfaceOptions::default());
    let terminal_reaper = crate::start_terminal_reaper(&mux).expect("terminal reaper");
    let idle_reaper = crate::start_idle_terminal_reaper(
        std::sync::Arc::downgrade(&mux),
        crate::IDLE_CLOSE_REAP_INTERVAL,
    )
    .expect("idle reaper");
    let class = cmux_tui_platform::qos::raisable_class(ThreadType::Utility.qos());
    for name in ["mux-terminal-reap", "mux-idle-close"] {
        for row in rows_named(name) {
            assert_eq!(row.declared, class, "{name}");
            #[cfg(target_vendor = "apple")]
            assert_eq!(row.live, cmux_threads::LiveQos::Class(ThreadQos::Utility), "{name}");
            #[cfg(any(target_os = "linux", target_os = "android"))]
            if class == ThreadQos::Utility {
                assert_eq!(row.live, cmux_threads::LiveQos::Nice(class.linux_nice()), "{name}");
            }
            assert_eq!(row.refused_changes, 0, "{name}");
        }
    }
    terminal_reaper.stop();
    idle_reaper.stop();
}
