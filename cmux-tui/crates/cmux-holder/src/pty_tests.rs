use super::*;

#[test]
fn a_bare_program_name_resolves_on_the_requests_path() {
    let env = vec![b"HOME=/".to_vec(), b"PATH=/nonexistent-cmux-dir:/bin:/usr/bin".to_vec()];
    let resolved = resolve_program(b"sh", &env, b"/").unwrap();
    assert!(resolved.to_bytes().ends_with(b"/sh"), "{resolved:?}");
    assert_eq!(resolve_program(b"/bin/sh", &[], b"/").unwrap().to_bytes(), b"/bin/sh");
    let missing = resolve_program(b"cmux-no-such-program", &env, b"/").unwrap_err();
    assert_eq!(missing.kind(), io::ErrorKind::NotFound);
}

/// A `/bin/sleep 30` on a new PTY, as a terminal's shell.
fn sleeper() -> SpawnRequest {
    SpawnRequest {
        cols: 80,
        rows: 24,
        cwd: b"/".to_vec(),
        argv: vec![b"/bin/sleep".to_vec(), b"30".to_vec()],
        env: vec![b"PATH=/bin:/usr/bin".to_vec()],
        ..SpawnRequest::default()
    }
}

/// Ends and reaps a child [`spawn`] started.
fn end(spawned: Spawned) {
    // SAFETY: signals and reaps the child this test spawned.
    unsafe {
        libc::kill(spawned.pid, libc::SIGKILL);
        let mut status = 0;
        libc::waitpid(spawned.pid, &mut status, 0);
    }
}

/// macOS: a shell the holder forks from a UserInteractive thread runs at
/// QOS_CLASS_DEFAULT, not the thread's class (p02-threads task 223), and the
/// thread keeps its class.
#[cfg(target_vendor = "apple")]
#[test]
fn a_shell_forked_from_a_user_interactive_thread_runs_at_default() {
    use cmux_threads::process::probe;
    use cmux_threads::{LiveQos, QosChange, ThreadQos, current, set_current};

    let default = probe::base_priority_at(ThreadQos::Default).unwrap();
    let interactive = probe::base_priority_at(ThreadQos::UserInteractive).unwrap();
    assert_ne!(default, interactive);
    let child = std::thread::spawn(|| {
        assert_eq!(set_current(ThreadQos::UserInteractive), QosChange::Applied);
        let spawned = spawn(&sleeper(), None).unwrap();
        let priority = probe::first_thread_base_priority(spawned.pid);
        end(spawned);
        assert_eq!(current(), LiveQos::Class(ThreadQos::UserInteractive));
        priority.unwrap()
    })
    .join()
    .unwrap();
    assert_eq!(child, default, "shell {child}: default {default}, user-interactive {interactive}");
}

/// Linux: the shell keeps the holder thread's nice value, as before.
#[cfg(target_os = "linux")]
#[test]
fn a_shell_keeps_the_holders_nice_value_on_linux() {
    let nice_of = |pid: libc::pid_t| {
        // SAFETY: the raw syscall returns 20 - nice (1..=40), no -1 ambiguity.
        let raw = unsafe {
            libc::syscall(libc::SYS_getpriority, libc::PRIO_PROCESS, pid as libc::c_long)
        };
        assert!(raw > 0, "getpriority({pid}): {}", io::Error::last_os_error());
        20 - raw as i32
    };
    std::thread::spawn(move || {
        // SAFETY: gettid has no preconditions.
        let tid = unsafe { libc::gettid() };
        let spawned = spawn(&sleeper(), None).unwrap();
        let (parent, child) = (nice_of(tid), nice_of(spawned.pid));
        end(spawned);
        assert_eq!(child, parent);
    })
    .join()
    .unwrap();
}
