use super::*;

/// A process that ended and is not reaped is a zombie whatever bytes
/// the name of its program has.
#[cfg(target_os = "linux")]
#[test]
fn an_ended_process_is_a_zombie_for_each_program_name() {
    let mut child = cmux_tui_platform::CutNameChild::start("zombie").expect("child");
    child.end_unreaped().expect("end");
    let pid = libc::pid_t::try_from(child.id()).unwrap();
    assert!(is_zombie(pid), "an ended child that is not reaped is not a zombie");
}

/// A shell that died a moment before its host must not get a
/// replacement: an exited, unreaped process is a zombie on every
/// platform, never a live session leader (L1.3).
#[test]
fn an_exited_unreaped_process_is_a_zombie_and_no_longer_leads_its_session() {
    let mut leader = Command::new("/bin/sh");
    leader.args(["-c", "exit 0"]);
    // SAFETY: setsid is async-signal-safe in the forked child.
    unsafe {
        leader.pre_exec(|| {
            if libc::setsid() < 0 { Err(std_io::Error::last_os_error()) } else { Ok(()) }
        });
    }
    let mut child = leader.spawn().unwrap();
    let pid = libc::pid_t::try_from(child.id()).unwrap();
    // Wait for the exit without reaping, so the PID stays a zombie.
    let mut info = std::mem::MaybeUninit::<libc::siginfo_t>::zeroed();
    // SAFETY: waitid writes one siginfo_t for this exact child.
    let waited = unsafe {
        libc::waitid(
            libc::P_PID,
            pid as libc::id_t,
            info.as_mut_ptr(),
            libc::WEXITED | libc::WNOWAIT,
        )
    };
    assert_eq!(waited, 0, "{}", std_io::Error::last_os_error());
    assert!(is_zombie(pid), "an exited, unreaped child is not reported as a zombie");
    assert!(!leads_session(pid, pid), "a zombie still counts as a live session leader");
    child.wait().unwrap();
}

/// Wait (up to 5 s) until `pid` runs `name`, so a signal reaches the
/// final program and not a process still between fork and exec. Linux
/// reads `/proc/<pid>/comm`; elsewhere it waits a fixed short time.
fn wait_until_exec(pid: u32, name: &str) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while Instant::now() < deadline {
        match fs::read_to_string(format!("/proc/{pid}/comm")) {
            Ok(comm) if comm.trim() == name => return,
            Ok(_) => {}
            Err(_) if !cfg!(target_os = "linux") => {
                thread::sleep(Duration::from_millis(200));
                return;
            }
            Err(_) => {}
        }
        thread::sleep(Duration::from_millis(5));
    }
}

#[test]
fn adopted_child_sees_a_non_child_session_end_and_never_signals_on_drop() {
    // A session leader this test spawned stands in for an adopted one:
    // it is waited on only through the adoption path.
    let mut leader = Command::new("/bin/sh");
    leader.args(["-c", "exec sleep 30"]);
    // The leader must not depend on this test process's signal state:
    // other tests in the process may change dispositions or a thread's
    // mask, and ignored signals and the mask survive exec.
    // SAFETY: signal, sigprocmask and setsid are async-signal-safe in
    // the forked child.
    unsafe {
        leader.pre_exec(|| {
            libc::signal(libc::SIGHUP, libc::SIG_DFL);
            let mut empty = std::mem::MaybeUninit::<libc::sigset_t>::uninit();
            libc::sigemptyset(empty.as_mut_ptr());
            libc::sigprocmask(libc::SIG_SETMASK, empty.as_ptr(), std::ptr::null_mut());
            if libc::setsid() < 0 { Err(std_io::Error::last_os_error()) } else { Ok(()) }
        });
    }
    let mut leader = leader.spawn().unwrap();
    let pid = leader.id();
    wait_until_exec(pid, "sleep");
    assert!(AdoptedChild::adopt(pid, pid + 1).is_err(), "a non-leader was adopted");
    let adopted = AdoptedChild::adopt(pid, pid).unwrap();
    drop(AdoptedChild::adopt(pid, pid).unwrap());
    let raw = libc::pid_t::try_from(pid).unwrap();
    assert!(leads_session(raw, raw), "dropping an adopted child signaled it");
    let before = fs::read_to_string(format!("/proc/{pid}/status")).unwrap_or_default();
    let kill_result = adopted.killer().kill();
    let watcher = thread::spawn(move || adopted.wait_for_exit());
    let status = leader.wait().unwrap();
    let state = before
        .lines()
        .filter(|line| line.starts_with("Sig") || line.starts_with("Name"))
        .collect::<Vec<_>>();
    assert!(
        status.code().is_none(),
        "SIGHUP did not end the leader: {status:?}, kill {kill_result:?}, {state:?}"
    );
    watcher.join().unwrap();
    assert!(AdoptedChild::adopt(pid, pid).is_err(), "an ended session was adopted");
}
