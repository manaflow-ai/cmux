use super::*;

#[test]
fn a_bare_program_name_is_tried_in_each_path_entry_and_a_path_as_it_is() {
    let env = vec![b"HOME=/".to_vec(), b"PATH=/nonexistent-cmux-dir::bin:/usr/bin".to_vec()];
    let tried = program_candidates(b"sh", &env).unwrap();
    let tried: Vec<&[u8]> = tried.iter().map(|path| path.to_bytes()).collect();
    assert_eq!(tried, [&b"/nonexistent-cmux-dir/sh"[..], b"./sh", b"bin/sh", b"/usr/bin/sh"]);
    let default = program_candidates(b"sh", &[]).unwrap();
    let default: Vec<&[u8]> = default.iter().map(|path| path.to_bytes()).collect();
    assert_eq!(default, [&b"/usr/bin/sh"[..], b"/bin/sh"]);
    let named = program_candidates(b"/bin/sh", &env).unwrap();
    assert_eq!(named.len(), 1);
    assert_eq!(named[0].to_bytes(), b"/bin/sh");
    assert!(program_candidates(b"", &env).is_err());
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

/// Waits until the child [`spawn`] forked runs its program ([`Start::poll`]):
/// `spawn` returns right after the fork.
fn started(spawned: &mut Spawned) {
    let deadline = std::time::Instant::now() + std::time::Duration::from_secs(10);
    loop {
        match spawned.start.poll() {
            Some(result) => return result.unwrap(),
            None => {
                assert!(std::time::Instant::now() < deadline, "the child never started");
                std::thread::sleep(std::time::Duration::from_millis(1));
            }
        }
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
        let mut spawned = spawn(&sleeper(), None).unwrap();
        started(&mut spawned);
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
        let mut spawned = spawn(&sleeper(), None).unwrap();
        started(&mut spawned);
        let (parent, child) = (nice_of(tid), nice_of(spawned.pid));
        end(spawned);
        assert_eq!(child, parent);
    })
    .join()
    .unwrap();
}
