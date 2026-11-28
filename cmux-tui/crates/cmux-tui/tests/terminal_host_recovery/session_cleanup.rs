use cmux_tui_core::terminal_host_protocol::TerminalExitOutcome;
use cmux_tui_core::terminal_host_runtime::{
    TerminalHostAdoption, TerminalHostIdentity, launch_terminal_host_adopting,
    request_terminal_host_pty_custody,
};
use cmux_tui_core::{DefaultColors, SurfaceOptions};
use ghostty_vt::KittyGraphicsLimits;

use super::*;

struct SessionDescendantFixture {
    harness: RecoveryHarness,
    direct_pid_path: PathBuf,
    descendant_pid_path: PathBuf,
    session_id: libc::pid_t,
    unrelated: Option<Child>,
}

impl SessionDescendantFixture {
    fn start(name: &str) -> Self {
        let harness = RecoveryHarness::start_without_respawn(name);
        let mut fixture = Self {
            direct_pid_path: harness.dir.join("direct.pid"),
            descendant_pid_path: harness.dir.join("descendant.pid"),
            session_id: 0,
            harness,
            unrelated: None,
        };
        let marker = format!("{name}-ready-{}", std::process::id());
        // There are exactly two fixture processes, without a shell's extra
        // sleep child. Publish each PID atomically; the descendant publishes
        // readiness only after changing groups and installing SIGHUP-ignore.
        let script = r#"import os, signal, sys, time

def publish(path):
    with open(path + '.tmp', 'w') as ready:
        ready.write(str(os.getpid()))
    os.replace(path + '.tmp', path)

publish(sys.argv[1])
if os.fork() == 0:
    os.setpgid(0, 0)
    signal.signal(signal.SIGHUP, signal.SIG_IGN)
    publish(sys.argv[2])
    print(sys.argv[3], flush=True)
time.sleep(600)
"#;
        let created = request(
            &fixture.harness.socket,
            serde_json::json!({
                "id": 1,
                "cmd": "run",
                "argv": [
                    "python3", "-c", script,
                    fixture.direct_pid_path, fixture.descendant_pid_path, marker,
                ],
                "new_workspace": true,
                "name": name,
            }),
        );
        let surface = created["surface"].as_u64().unwrap();
        assert!(wait_for_screen(&fixture.harness.socket, surface, &marker).contains(&marker));
        let direct_pid = fixture.direct_pid();
        let descendant_pid = fixture.descendant_pid();
        // SAFETY: both PIDs were atomically published by this fixture.
        let direct_group = unsafe { libc::getpgid(direct_pid) };
        // SAFETY: this PID was atomically published by this fixture.
        let descendant_group = unsafe { libc::getpgid(descendant_pid) };
        // SAFETY: these are signal-free identity queries for the fixture PIDs.
        let direct_session = unsafe { libc::getsid(direct_pid) };
        // SAFETY: this is a signal-free identity query for the fixture PID.
        let descendant_session = unsafe { libc::getsid(descendant_pid) };
        assert_eq!(direct_group, direct_pid);
        assert_eq!(direct_session, direct_pid);
        assert_eq!(descendant_group, descendant_pid);
        assert_ne!(descendant_group, direct_group, "fixture did not make a new process group");
        assert_eq!(descendant_session, direct_session, "fixture left the PTY session");
        fixture.session_id = direct_session;

        let mut unrelated = Command::new("python3");
        unrelated.args(["-c", "import time; time.sleep(600)"]);
        // SAFETY: setsid is async-signal-safe; this exact child belongs to
        // the test and must be in an unrelated session.
        unsafe {
            unrelated.pre_exec(|| {
                if libc::setsid() < 0 { Err(std::io::Error::last_os_error()) } else { Ok(()) }
            });
        }
        fixture.unrelated = Some(unrelated.spawn().unwrap());
        fixture
    }

    fn direct_pid(&self) -> libc::pid_t {
        wait_for_pid_file(&self.direct_pid_path)
    }

    fn descendant_pid(&self) -> libc::pid_t {
        wait_for_pid_file(&self.descendant_pid_path)
    }

    fn host(&self) -> (PathBuf, TerminalHostRecord) {
        let (path, record) = wait_for_host_records(&self.harness.host_root(), 1).remove(0);
        let observer = adopt_terminal_host(record.clone(), path.clone()).unwrap();
        assert_eq!(observer.snapshot.pid, Some(self.direct_pid() as u32));
        observer.disconnect();
        (path, record)
    }

    fn assert_session_stopped(&self) {
        wait_for_process_stopped(self.descendant_pid());
        wait_for_process_stopped(self.direct_pid());
        let unrelated_pid = self.unrelated.as_ref().unwrap().id() as libc::pid_t;
        assert!(process_running(unrelated_pid), "cleanup signaled an unrelated session");
    }
}

impl Drop for SessionDescendantFixture {
    fn drop(&mut self) {
        // Stop the owner before failure cleanup so it cannot recreate a
        // terminal. Keep the child in the harness until it is reaped.
        if let Some(daemon) = self.harness.child.as_mut() {
            let _ = daemon.kill();
            let _ = daemon.wait();
        }
        let read_pid = |path: &Path| {
            fs::read_to_string(path).ok()?.trim().parse::<libc::pid_t>().ok().filter(|pid| *pid > 0)
        };
        // This also runs when setup or any assertion panics. Use only the
        // fixture's exact PIDs, and require its original session identity.
        if let Some(direct_pid) = read_pid(&self.direct_pid_path) {
            let pids = [read_pid(&self.descendant_pid_path), Some(direct_pid)];
            for pid in pids.into_iter().flatten() {
                // SAFETY: the positive PID came from this test's private file;
                // verify session membership before sending an exact-PID kill.
                if unsafe { libc::getsid(pid) } == self.session_id {
                    let _ = unsafe { libc::kill(pid, libc::SIGKILL) };
                }
            }
            let deadline = Instant::now() + test_timeout(Duration::from_secs(2));
            while pids.into_iter().flatten().any(process_running) && Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(20));
            }
        }
        if let Some(mut unrelated) = self.unrelated.take() {
            let _ = unrelated.kill();
            let _ = unrelated.wait();
        }
        // RecoveryHarness also tears down the exact original or replacement
        // host record, including when an adoption or receipt assertion fails.
    }
}

#[test]
fn explicit_terminate_reaps_descendants_in_other_process_groups_of_the_pty_session() {
    let _exclusive = exclusive_process_test();
    let fixture = SessionDescendantFixture::start("terminate-session-descendant");
    let (record_path, record) = fixture.host();
    let mut host = adopt_terminal_host(record.clone(), record_path.clone()).unwrap();
    host.terminate().unwrap();
    host.disconnect();
    wait_for_no_host_records(&fixture.harness.host_root());
    wait_for_terminal_host_dead(&record_path, &record);
    fixture.assert_session_stopped();
}

#[test]
fn shutdown_daemon_end_terminals_reaps_session_descendant() {
    let _exclusive = exclusive_process_test();
    let mut fixture = SessionDescendantFixture::start("shutdown-session-descendant");
    let (record_path, record) = fixture.host();
    let identify =
        request(&fixture.harness.socket, serde_json::json!({"id": 2, "cmd": "identify"}));
    let accepted = request(
        &fixture.harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "shutdown-daemon",
            "pid": identify["pid"],
            "generation": identify["generation"],
            "end_terminals": true,
        }),
    );
    assert_eq!(accepted["accepted"], true);
    assert_eq!(accepted["ended_terminals"], 1);
    let daemon = fixture.harness.child.as_mut().unwrap();
    let deadline = Instant::now() + test_timeout(Duration::from_secs(10));
    while daemon.try_wait().unwrap().is_none() {
        assert!(Instant::now() < deadline, "daemon did not exit after shutdown");
        std::thread::sleep(Duration::from_millis(20));
    }
    wait_for_no_host_records(&fixture.harness.host_root());
    wait_for_terminal_host_dead(&record_path, &record);
    fixture.assert_session_stopped();
}

#[test]
fn adopted_replacement_host_terminate_reaps_session_descendant() {
    let _exclusive = exclusive_process_test();
    let mut fixture = SessionDescendantFixture::start("adopted-session-descendant");
    let (record_path, record) = fixture.host();
    let custody = request_terminal_host_pty_custody(&record, &record_path).unwrap();
    assert_eq!(custody.child_pid, fixture.direct_pid() as u32);
    assert_eq!(custody.session_id, custody.child_pid);

    // Replace the process that owns the PTY child, rather than merely making
    // another attachment to the original host. The replacement cannot waitpid
    // the original child, so this exercises HostChild::Adopted cleanup.
    fixture.harness.signal_daemon(libc::SIGSTOP);
    fixture.harness.sigkill();
    // SAFETY: this is the exact host PID in this fixture's live record.
    assert_eq!(unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) }, 0);
    wait_for_terminal_host_dead(&record_path, &record);
    assert!(process_running(fixture.direct_pid()), "custody did not preserve the direct child");
    assert!(process_running(fixture.descendant_pid()), "descendant exited before adoption");

    let options = SurfaceOptions { cols: 80, rows: 24, ..SurfaceOptions::default() };
    let mut owner = launch_terminal_host_adopting(
        &fixture.harness.host_root(),
        TerminalHostAdoption {
            custody: &custody,
            identity: TerminalHostIdentity {
                terminal_id: record.terminal_id.clone(),
                incarnation: record.incarnation.clone(),
            },
            owner_token: CapabilityToken::from_bytes(decode_hex(&record.owner_token).unwrap()),
            options: &options,
            default_colors: DefaultColors::default(),
            cell_pixels: (8, 16),
            kitty_graphics_limits: KittyGraphicsLimits::default(),
            seed: b"",
            host_binary: Some(PathBuf::from(bin())),
        },
    )
    .unwrap();
    let (replacement_path, replacement) = fixture.host();
    assert_eq!(replacement_path, record_path);
    assert_eq!(replacement.incarnation, record.incarnation);
    assert_ne!(replacement.host_pid, record.host_pid);
    assert_ne!(replacement.host_start_nonce, record.host_start_nonce);

    let exit = owner.terminate_and_wait_for_exit().unwrap();
    assert_eq!(
        exit.exit.outcome,
        TerminalExitOutcome::Unknown { reason: "exit-unobserved".into() },
        "{exit:?}"
    );
    assert_eq!(exit.incarnation, record.incarnation);
    owner.disconnect();
    wait_for_terminal_host_dead(&replacement_path, &replacement);
    fixture.assert_session_stopped();
}
