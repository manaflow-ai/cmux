use super::*;

#[test]
fn explicit_terminate_reaps_descendants_in_other_process_groups_of_the_pty_session() {
    let harness = RecoveryHarness::start("terminate-session-descendant");
    let marker = format!("session-descendant-ready-{}", std::process::id());
    let descendant_pid_path = harness.dir.join("session-descendant.pid");
    let script = concat!(
        "python3 -c \"",
        "import os,signal,sys,time; ",
        "os.setpgid(0,0); ",
        "open(sys.argv[1], 'w').write(str(os.getpid())); ",
        "signal.signal(signal.SIGHUP, signal.SIG_IGN); ",
        "time.sleep(60)\""
    );
    let script = format!("{script} \"$1\" & printf '%s\\n' \"$2\"; while :; do sleep 60; done");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": [
                "/bin/sh",
                "-c",
                script,
                "cmux-session-descendant",
                descendant_pid_path,
                marker,
            ],
            "new_workspace": true,
            "name": "session-descendant",
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    assert!(wait_for_screen(&harness.socket, surface, &marker).contains(&marker));
    let descendant_pid = wait_for_pid_file(&descendant_pid_path);
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let observer = adopt_terminal_host(record.clone(), record_path.clone()).unwrap();
    let direct_pid = observer.snapshot.pid.unwrap() as libc::pid_t;
    observer.disconnect();

    // The fixture deliberately creates a second process group while retaining
    // the terminal host's session. The old cleanup only knew the direct and
    // foreground groups, so this process survives the old SIGKILL path.
    // SAFETY: both PIDs came from this test's terminal host fixture.
    let direct_group = unsafe { libc::getpgid(direct_pid) };
    // SAFETY: the descendant PID was written by the fixture we started.
    let descendant_group = unsafe { libc::getpgid(descendant_pid) };
    // SAFETY: both PIDs came from this test's terminal host fixture.
    let direct_session = unsafe { libc::getsid(direct_pid) };
    // SAFETY: the descendant PID was written by the fixture we started.
    let descendant_session = unsafe { libc::getsid(descendant_pid) };
    assert!(direct_group > 0);
    assert!(descendant_group > 0);
    assert_ne!(descendant_group, direct_group, "fixture did not make a new process group");
    assert_eq!(descendant_session, direct_session, "fixture left the PTY session");

    let mut unrelated = Command::new("python3");
    unrelated.args(["-c", "import time; time.sleep(60)"]);
    // SAFETY: setsid is async-signal-safe and this exact child belongs to the
    // test, so it gives us a private session to protect from cleanup.
    unsafe {
        unrelated.pre_exec(|| {
            if libc::setsid() < 0 { Err(std::io::Error::last_os_error()) } else { Ok(()) }
        });
    }
    let mut unrelated = unrelated.spawn().unwrap();
    let unrelated_pid = unrelated.id() as libc::pid_t;

    let mut host = adopt_terminal_host(record.clone(), record_path.clone()).unwrap();
    host.terminate().unwrap();
    host.disconnect();
    wait_for_no_host_records(&harness.host_root());
    wait_for_terminal_host_dead(&record_path, &record);

    let descendant_survived = process_exists(descendant_pid);
    if descendant_survived {
        // Keep a red regression run from leaking its exact fixture process.
        // SAFETY: this is the descendant PID written by this test.
        let _ = unsafe { libc::kill(descendant_pid, libc::SIGKILL) };
        wait_for_process_and_group_absent(descendant_pid);
    }
    assert!(process_exists(unrelated_pid), "Terminate signaled an unrelated session");
    // SAFETY: this is the exact unrelated child spawned by this test.
    let _ = unsafe { libc::kill(unrelated_pid, libc::SIGKILL) };
    unrelated.wait().unwrap();
    assert!(!descendant_survived, "Terminate left a same-session descendant alive");
}
