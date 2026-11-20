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

/// The clamp takes effect: a child spawned under it, and the shell it
/// starts, run at priority 20 (utility), not 31 (cmux#27587's first cut
/// passed `QOS_CLASS_UTILITY`, which the setter takes and ignores).
#[cfg(target_os = "macos")]
#[test]
fn a_clamped_child_and_what_it_starts_run_at_utility() {
    let dir = tempfile::tempdir().unwrap();
    let out = dir.path().join("pri");
    let script = format!(
        "/bin/sh -c 'ps -o pri= -p $$' > '{}'; ps -o pri= -p $$ >> '{}'",
        out.display(),
        out.display()
    );
    let argv: Vec<OsString> = vec!["sh".into(), "-c".into(), script.into()];
    let pid = imp::spawn_clamped(std::path::Path::new("/bin/sh"), &argv, &[], false)
        .expect("spawn under the clamp");
    let mut status = 0;
    // SAFETY: waits for the child this test started.
    unsafe { libc::waitpid(pid, &mut status, 0) };
    let text = std::fs::read_to_string(&out).unwrap();
    let pris: Vec<&str> = text.split_whitespace().collect();
    assert_eq!(pris.len(), 2, "{text:?}");
    for pri in pris {
        assert!(pri.starts_with("20"), "expected priority 20, got {text:?}");
    }
}

#[test]
fn the_reexec_marks_itself_once() {
    let vars = vec![("PATH".into(), "/bin".into()), (CLAMPED_ENV.into(), "stale".into())];
    let out = reexec_env(vars);
    assert_eq!(out.iter().filter(|(k, _)| k == CLAMPED_ENV).count(), 1);
    assert!(out.contains(&(CLAMPED_ENV.into(), "utility".into())));
    assert!(out.contains(&("PATH".into(), "/bin".into())));
}
