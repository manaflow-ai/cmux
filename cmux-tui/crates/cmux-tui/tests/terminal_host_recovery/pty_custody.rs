//! cx-6so.49 L1: PTY custody. The owner keeps a copy of a host's PTY
//! master, so a host SIGKILL no longer hangs up the shell, and a
//! replacement host started on that copy serves the same running session
//! under the same terminal id and incarnation. Only the owner token gets
//! custody, and a stopped host is never replaced.

use cmux_tui_core::terminal_host_protocol::{FLAG_PTY_CUSTODY, TerminalExitOutcome};
use cmux_tui_core::terminal_host_runtime::{
    HostAttachment, TerminalHostAdoption, TerminalHostIdentity, launch_terminal_host_adopting,
    request_terminal_host_pty_custody, terminal_host_exit_record,
};
use cmux_tui_core::{DefaultColors, SurfaceOptions};
use ghostty_vt::KittyGraphicsLimits;

use super::*;

fn run_in_new_workspace(socket: &Path, argv: &[&str], name: &str) -> u64 {
    let created = request(
        socket,
        serde_json::json!({"id":1,"cmd":"run","argv":argv,"new_workspace":true,"name":name}),
    );
    created["surface"].as_u64().unwrap()
}

fn send_line(socket: &Path, surface: u64, line: &str) {
    request(socket, serde_json::json!({"cmd":"send","surface":surface,"text":format!("{line}\n")}));
}

fn signal_pid(pid: u32, signal: libc::c_int) {
    // SAFETY: the PID is a process this test started (a terminal host or its
    // shell); the signal is a constant.
    assert_eq!(unsafe { libc::kill(pid as libc::pid_t, signal) }, 0, "signal {signal} to {pid}");
}

/// Alive and not a zombie of whichever process inherited it.
fn process_running(pid: u32) -> bool {
    // SAFETY: signal 0 only probes the PID.
    if unsafe { libc::kill(pid as libc::pid_t, 0) } != 0 {
        return false;
    }
    #[cfg(target_os = "linux")]
    if let Ok(stat) = fs::read_to_string(format!("/proc/{pid}/stat"))
        && stat.rsplit_once(')').is_some_and(|(_, rest)| rest.trim_start().starts_with('Z'))
    {
        return false;
    }
    true
}

fn wait_for_dead_host(record_path: &Path, record: &TerminalHostRecord) {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(5));
    while terminal_host_record_liveness(record_path, record).unwrap() != TerminalHostLiveness::Dead
    {
        assert!(Instant::now() < deadline, "the SIGKILLed host still holds its liveness lock");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn adoption<'a>(
    custody: &'a cmux_tui_core::terminal_host_runtime::PtyCustody,
    record: &TerminalHostRecord,
    options: &'a SurfaceOptions,
    seed: &'a [u8],
) -> TerminalHostAdoption<'a> {
    TerminalHostAdoption {
        custody,
        identity: TerminalHostIdentity {
            terminal_id: record.terminal_id.clone(),
            incarnation: record.incarnation.clone(),
        },
        owner_token: CapabilityToken::from_bytes(decode_hex(&record.owner_token).unwrap()),
        options,
        default_colors: DefaultColors::default(),
        cell_pixels: (8, 16),
        kitty_graphics_limits: KittyGraphicsLimits::default(),
        seed,
        host_binary: Some(PathBuf::from(bin())),
    }
}

/// Read live Output from an owner attachment until it contains `needle`.
fn read_output_until(attachment: &mut HostAttachment, needle: &str) -> String {
    let mut reader = attachment.take_reader().unwrap();
    reader.set_read_timeout(Some(test_timeout(Duration::from_secs(10)))).unwrap();
    let mut seen = Vec::new();
    loop {
        let frame = read_frame(&mut reader, MAX_FRAME_PAYLOAD)
            .unwrap_or_else(|error| {
                panic!("no {needle:?} in {:?}: {error}", String::from_utf8_lossy(&seen))
            })
            .expect("replacement host closed the stream");
        if frame.kind == MessageKind::Output {
            seen.extend_from_slice(&frame.payload);
            let text = String::from_utf8_lossy(&seen).into_owned();
            if text.contains(needle) {
                return text;
            }
        }
    }
}

#[test]
fn pty_custody_keeps_the_shell_alive_through_a_host_sigkill_and_a_replacement_host_serves_it() {
    let _exclusive = exclusive_process_test();
    let mut harness = RecoveryHarness::start("pty-custody-replace");
    let surface = run_in_new_workspace(&harness.socket, &["/bin/sh"], "custody");
    let marker = format!("before-custody-{}", std::process::id());
    send_line(&harness.socket, surface, &format!("echo {marker}"));
    assert!(wait_for_screen(&harness.socket, surface, &marker).contains(&marker));
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    assert!(record.supports_pty_custody, "{record:?}");

    let custody = request_terminal_host_pty_custody(&record, &record_path).unwrap();
    assert_eq!(custody.child_pid, custody.session_id);
    assert_ne!(custody.child_pid, record.host_pid);

    // No daemon may react to the host's death: stop it, then kill it.
    harness.signal_daemon(libc::SIGSTOP);
    harness.sigkill();
    signal_pid(record.host_pid, libc::SIGKILL);
    wait_for_dead_host(&record_path, &record);
    std::thread::sleep(Duration::from_millis(500));
    assert!(
        process_running(custody.child_pid),
        "the shell died with its host although the owner held the PTY master"
    );

    let options = SurfaceOptions { cols: 80, rows: 24, ..SurfaceOptions::default() };
    let seed = b"seeded-screen-marker\r\n";
    let mut owner = launch_terminal_host_adopting(
        &harness.host_root(),
        adoption(&custody, &record, &options, seed),
    )
    .unwrap();
    let identity = TerminalHostIdentity {
        terminal_id: record.terminal_id.clone(),
        incarnation: record.incarnation.clone(),
    };
    assert_eq!(owner.identity(), identity);
    assert!(
        contains_bytes(&owner.snapshot.replay, b"seeded-screen-marker"),
        "the seed did not reach the replacement host's parser"
    );

    let (new_path, new_record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    assert_eq!(new_path, record_path, "the replacement published at another path");
    assert_eq!(new_record.incarnation, record.incarnation);
    assert_ne!(new_record.host_pid, record.host_pid);
    assert_ne!(new_record.host_start_nonce, record.host_start_nonce);
    assert_eq!(
        terminal_host_record_liveness(&new_path, &new_record).unwrap(),
        TerminalHostLiveness::Live
    );

    // A second owner connection to the new record drives the same shell.
    let mut observer = adopt_terminal_host(new_record, new_path).unwrap();
    observer.send(MessageKind::Input, b"echo pid=$$\n").unwrap();
    let output = read_output_until(&mut observer, &format!("pid={}", custody.child_pid));
    assert!(output.contains("pid="), "{output}");

    let exit = owner.terminate_and_wait_for_exit().unwrap();
    assert_eq!(
        exit.exit.outcome,
        TerminalExitOutcome::Unknown { reason: "exit-unobserved".into() },
        "{exit:?}"
    );
    assert_eq!(exit.incarnation, record.incarnation);
    let (_, sidecar) = terminal_host_exit_record(&record_path).unwrap().expect("exit sidecar");
    assert_eq!(sidecar.exit.outcome, exit.exit.outcome);
    assert_eq!(sidecar.incarnation, record.incarnation);
    let deadline = Instant::now() + test_timeout(Duration::from_secs(5));
    while process_running(custody.child_pid) {
        assert!(Instant::now() < deadline, "Terminate left the adopted shell running");
        std::thread::sleep(Duration::from_millis(20));
    }
    observer.disconnect();
    owner.disconnect();
}

#[test]
fn pty_custody_is_refused_without_the_owner_token() {
    let harness = RecoveryHarness::start("pty-custody-refused");
    let surface = run_in_new_workspace(&harness.socket, &["/bin/cat"], "refused");
    let (_, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let grant = request(
        &harness.socket,
        serde_json::json!({"id":2,"cmd":"mint-terminal-renderer","surface":surface,"ttl_ms":10_000}),
    );
    let attempts = [
        (
            grant["token"].as_str().unwrap().to_string(),
            ClientRole::Renderer,
            CapabilityRights::RENDERER,
        ),
        // The owner token without CLIPBOARD_READ does not prove the owner.
        (record.owner_token.clone(), ClientRole::Admin, CapabilityRights::ADMIN),
    ];
    for (token, role, rights) in attempts {
        let mut stream = UnixStream::connect(&record.endpoint).unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let hello = ClientHello {
            min_version: PROTOCOL_VERSION,
            max_version: PROTOCOL_VERSION,
            role,
            requested_rights: rights,
            terminal_id: TerminalId::from_bytes(decode_hex(&record.terminal_id).unwrap()),
            token: CapabilityToken::from_bytes(decode_hex(&token).unwrap()),
        };
        let mut frame = hello.into_frame(1);
        frame.flags = FLAG_PTY_CUSTODY;
        write_frame(&mut stream, &frame).unwrap();
        let mut bytes = Vec::new();
        // Closed with nothing sent: no HostHello, no frame, no descriptor.
        let _ = std::io::Read::read_to_end(&mut stream, &mut bytes);
        assert!(bytes.is_empty(), "{role:?} got a custody reply of {} bytes", bytes.len());
    }
    // The owner still gets custody, and the terminal keeps running.
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let custody = request_terminal_host_pty_custody(&record, &record_path).unwrap();
    assert!(process_running(custody.child_pid));
    let marker = format!("after-refused-custody-{}", std::process::id());
    send_line(&harness.socket, surface, &marker);
    assert!(wait_for_screen(&harness.socket, surface, &marker).contains(&marker));
}

#[test]
fn a_stopped_host_is_never_replaced_and_keeps_serving_after_it_resumes() {
    let _exclusive = exclusive_process_test();
    let harness = RecoveryHarness::start("pty-custody-stopped");
    let surface = run_in_new_workspace(&harness.socket, &["/bin/cat"], "stopped");
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let custody = request_terminal_host_pty_custody(&record, &record_path).unwrap();

    signal_pid(record.host_pid, libc::SIGSTOP);
    let options = SurfaceOptions { cols: 80, rows: 24, ..SurfaceOptions::default() };
    let result = launch_terminal_host_adopting(
        &harness.host_root(),
        adoption(&custody, &record, &options, b""),
    );
    let still_published: TerminalHostRecord =
        serde_json::from_slice(&fs::read(&record_path).unwrap()).unwrap();
    signal_pid(record.host_pid, libc::SIGCONT);
    let error = match result {
        Ok(_) => panic!("a stopped host was replaced"),
        Err(error) => format!("{error:#}"),
    };
    assert!(error.contains("still owns the PTY"), "{error}");
    assert_eq!(still_published, record, "the refused replacement wrote a record");
    assert!(Path::new(&record.endpoint).exists(), "the refused replacement removed the endpoint");

    assert!(process_running(custody.child_pid));
    let marker = format!("after-stopped-host-{}", std::process::id());
    send_line(&harness.socket, surface, &marker);
    assert!(wait_for_screen(&harness.socket, surface, &marker).contains(&marker));
    let (_, current) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    assert_eq!(current.host_pid, record.host_pid);
    assert_eq!(current.host_start_nonce, record.host_start_nonce);
}
