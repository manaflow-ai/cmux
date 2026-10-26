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
