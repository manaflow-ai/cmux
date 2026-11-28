use super::*;

#[test]
fn the_daemon_keeps_its_cpu_and_agents_yield() {
    assert_eq!(tier(Role::Daemon), Tier::Serving);
    assert_eq!(tier(Role::AgentHost), Tier::AgentStart);
    assert_eq!(tier(Role::BackgroundTaskRunner), Tier::Agent);
    assert_eq!(tier(Role::Housekeeping), Tier::Background);
    assert_eq!(tier(Role::VisibleOpen), Tier::OnScreen);
}

#[test]
fn an_on_screen_read_returns_its_value() {
    assert_eq!(on_screen(|| 7), 7);
}

/// The read runs at user-initiated QoS, and the thread goes back to what it had: tokio
/// reuses it for other work, and the next on-screen read on it is raised again.
#[cfg(target_os = "macos")]
#[test]
fn an_on_screen_read_raises_the_thread_and_puts_it_back() {
    if !enabled() {
        return;
    }
    // `qos_class_t` has no `PartialEq` in libc, so the classes compare as their numbers.
    let class = |qos: libc::qos_class_t| qos as u32;
    let (qos, io) = (imp::thread_qos(), imp::thread_io());
    // The thread's own I/O policy is left alone: a thread-scope `setiopolicy_np` drops the
    // thread out of QoS (it read 0, unspecified, on macOS 26 and 27) and makes every later
    // `pthread_set_qos_class_self_np` on it fail with EPERM.
    let inside = on_screen(|| (class(imp::thread_qos()), imp::thread_io()));
    assert_eq!(inside, (class(libc::qos_class_t::QOS_CLASS_USER_INITIATED), io));
    let after = (class(imp::thread_qos()), imp::thread_io());
    let expected_qos = match qos {
        libc::qos_class_t::QOS_CLASS_UNSPECIFIED => libc::qos_class_t::QOS_CLASS_DEFAULT,
        qos => qos,
    };
    assert_eq!(after, (class(expected_qos), io));
    // A pool thread is reused: the next on-screen read on it is raised again.
    let again = on_screen(|| class(imp::thread_qos()));
    assert_eq!(again, class(libc::qos_class_t::QOS_CLASS_USER_INITIATED), "the second raise");
}

/// A background pass (`background`) puts the pool thread back as it found it, so a later
/// on-screen read on that thread is still raised.
#[cfg(target_os = "macos")]
#[test]
fn a_background_pass_leaves_the_thread_raisable() {
    if !enabled() {
        return;
    }
    let class = |qos: libc::qos_class_t| qos as u32;
    let before = class(imp::thread_qos());
    background(|| ());
    assert_eq!(class(imp::thread_qos()), before, "the class after a background pass");
    let raised = on_screen(|| class(imp::thread_qos()));
    assert_eq!(raised, class(libc::qos_class_t::QOS_CLASS_USER_INITIATED), "raised after it");
}
