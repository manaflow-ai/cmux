#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;
use cmux_tui_core::terminal_host::{
    CAPABILITY_TOKEN_LEN, CapabilityRights, CapabilityToken, ClientHello, ClientRole, TerminalId,
};
use cmux_tui_core::terminal_host_protocol::{
    FLAG_COLORS_FOLLOW, FLAG_VIEWER_SIZE_ACKS, Frame, MAX_FRAME_PAYLOAD, MessageKind,
    PROTOCOL_VERSION, ProtocolError, RESIZE_ACK_CANONICAL_CHANGED, read_frame, write_frame,
};
use cmux_tui_core::terminal_host_runtime::{
    TerminalHostLiveness, adopt_terminal_host, decode_terminal_color_overrides,
    load_terminal_host_records, remove_stale_terminal_host_record, terminal_host_record_liveness,
    terminal_host_root,
};
use ghostty_vt::{Rgb, TerminalColorOverrides};

struct RecoveryHarness {
    child: Option<Child>,
    dir: PathBuf,
    socket: PathBuf,
    state: PathBuf,
    session: String,
    host_ready_delay_ms: Option<u64>,
}

impl RecoveryHarness {
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp")
            .join(format!("cmux-terminal-host-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        let mut harness = Self {
            child: None,
            socket: dir.join("mux.sock"),
            state: dir.join("state"),
            session: "host-recovery".into(),
            host_ready_delay_ms: None,
            dir,
        };
        harness.restart();
        harness
    }

    fn start_with_host_ready_delay(name: &str, delay_ms: u64) -> Self {
        let mut harness = Self::start_unstarted(name);
        harness.host_ready_delay_ms = Some(delay_ms);
        harness.restart();
        harness
    }

    fn start_in_own_session(name: &str) -> Self {
        let mut harness = Self::start_unstarted(name);
        let mut command = harness.daemon_command();
        // SAFETY: setsid(2) is async-signal-safe and touches no Rust state in
        // the post-fork child. A private daemon session lets this test send a
        // real process-group hangup without affecting the test runner.
        unsafe {
            command.pre_exec(|| {
                if libc::setsid() < 0 { Err(std::io::Error::last_os_error()) } else { Ok(()) }
            });
        }
        harness.child = Some(command.spawn().unwrap());
        wait_for_socket(&harness.socket);
        harness
    }

    fn start_with_hosted_spawn_failure(name: &str, delay_ms: u64) -> Self {
        let mut harness = Self::start_unstarted(name);
        let mut command = harness.daemon_command();
        command.env("CMUX_TUI_TEST_HOSTED_SPAWN_FAIL_AFTER_CONNECT", delay_ms.to_string());
        harness.child = Some(command.spawn().unwrap());
        wait_for_socket(&harness.socket);
        harness
    }

    fn start_unstarted(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp")
            .join(format!("cmux-terminal-host-{name}-{}-{stamp}", std::process::id()));
        fs::create_dir_all(&dir).unwrap();
        Self {
            child: None,
            socket: dir.join("mux.sock"),
            state: dir.join("state"),
            session: "host-recovery".into(),
            host_ready_delay_ms: None,
            dir,
        }
    }

    fn restart(&mut self) {
        assert!(self.child.is_none());
        let child = self.daemon_command().spawn().unwrap();
        self.child = Some(child);
        wait_for_socket(&self.socket);
    }

    fn daemon_command(&self) -> Command {
        let mut command = Command::new(bin());
        command
            .args(["--headless", "--session", &self.session, "--socket"])
            .arg(&self.socket)
            .arg("--state")
            .arg(&self.state)
            .stdout(Stdio::null())
            .stderr(Stdio::null());
        if let Some(delay_ms) = self.host_ready_delay_ms {
            command.env("CMUX_TUI_TEST_HOST_READY_DELAY_MS", delay_ms.to_string());
        }
        command
    }

    fn sigkill(&mut self) {
        let mut child = self.child.take().unwrap();
        child.kill().unwrap();
        child.wait().unwrap();
        let _ = fs::remove_file(&self.socket);
    }

    fn signal_daemon(&self, signal: libc::c_int) {
        let pid = self.child.as_ref().unwrap().id() as libc::pid_t;
        // SAFETY: the harness owns this child process and passes a platform
        // signal constant.
        assert_eq!(unsafe { libc::kill(pid, signal) }, 0);
    }

    fn hangup_daemon_process_group(&mut self) {
        let mut child = self.child.take().unwrap();
        let pid = child.id() as libc::pid_t;
        // SAFETY: start_in_own_session made this daemon its private process
        // group leader; a negative pid addresses exactly that group.
        assert_eq!(unsafe { libc::kill(-pid, libc::SIGHUP) }, 0);
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            if let Some(status) = child.try_wait().unwrap() {
                let _ = status;
                break;
            }
            if Instant::now() >= deadline {
                let _ = child.kill();
                let _ = child.wait();
                panic!("daemon did not exit after process-group SIGHUP");
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let _ = fs::remove_file(&self.socket);
    }

    fn host_root(&self) -> PathBuf {
        terminal_host_root(&self.state, &self.session)
    }
}

impl Drop for RecoveryHarness {
    fn drop(&mut self) {
        if let Some(mut child) = self.child.take() {
            let _ = child.kill();
            let _ = child.wait();
        }

        let records = load_terminal_host_records(&self.host_root()).unwrap_or_default();
        let endpoints =
            records.iter().map(|(_, record)| PathBuf::from(&record.endpoint)).collect::<Vec<_>>();
        for (path, record) in &records {
            if let Ok(host) = adopt_terminal_host(record.clone(), path.clone()) {
                let _ = host.terminate();
                host.disconnect();
            }
        }
        let deadline = Instant::now() + Duration::from_secs(2);
        while endpoints.iter().any(|endpoint| endpoint.exists()) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        for (path, record) in &records {
            if terminal_host_record_liveness(path, record).ok() != Some(TerminalHostLiveness::Dead)
            {
                // SAFETY: test teardown owns these dedicated host processes;
                // SIGKILL is a last resort after graceful Terminate timed out.
                let _ = unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) };
                let deadline = Instant::now() + Duration::from_secs(2);
                while terminal_host_record_liveness(path, record).ok()
                    != Some(TerminalHostLiveness::Dead)
                    && Instant::now() < deadline
                {
                    std::thread::sleep(Duration::from_millis(20));
                }
            }
            let _ = remove_stale_terminal_host_record(path, record);
        }
        for endpoint in endpoints {
            let _ = fs::remove_file(endpoint);
        }
        let _ = fs::remove_dir_all(&self.dir);
    }
}

#[test]
fn terminal_host_survives_daemon_process_group_hangup() {
    let mut harness = RecoveryHarness::start_in_own_session("session-hangup");
    let daemon_pid = harness.child.as_ref().unwrap().id() as libc::pid_t;
    // SAFETY: the daemon is live and owned by this harness.
    assert_eq!(unsafe { libc::getsid(daemon_pid) }, daemon_pid);
    // SAFETY: the daemon is live and owned by this harness.
    assert_eq!(unsafe { libc::getpgid(daemon_pid) }, daemon_pid);

    request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/cat"],
            "new_workspace": true,
            "name": "session-survivor",
        }),
    );
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let host_pid = record.host_pid as libc::pid_t;
    // The host is both session and process-group leader, rather than a member
    // of the daemon's group that the following SIGHUP targets.
    // SAFETY: the discovery record's locked nonce proves this host is live.
    assert_eq!(unsafe { libc::getsid(host_pid) }, host_pid);
    // SAFETY: the discovery record's locked nonce proves this host is live.
    assert_eq!(unsafe { libc::getpgid(host_pid) }, host_pid);

    harness.hangup_daemon_process_group();
    assert_eq!(
        terminal_host_record_liveness(&record_path, &record).unwrap(),
        TerminalHostLiveness::Live,
    );
    let host = adopt_terminal_host(record, record_path).unwrap();
    host.terminate().unwrap();
    host.disconnect();
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn fenced_daemon_shutdown_acks_then_preserves_and_re_adopts_terminal_host() {
    let mut harness = RecoveryHarness::start("fenced-shutdown-adopt");
    let marker = format!("before-fenced-shutdown-{}", std::process::id());
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/cat"],
            "new_workspace": true,
            "name": "handover-survivor",
        }),
    );
    let original_surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    request(
        &harness.socket,
        serde_json::json!({
            "id": 2,
            "cmd": "send",
            "surface": original_surface,
            "text": format!("{marker}\n"),
        }),
    );
    assert!(wait_for_screen(&harness.socket, original_surface, &marker).contains(&marker));

    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let host_pid = record.host_pid;
    let identify = request(&harness.socket, serde_json::json!({"id": 3, "cmd": "identify"}));
    let daemon_pid = identify["pid"].as_u64().unwrap();
    let generation = identify["generation"].as_str().unwrap().to_string();

    let stale = request_response(
        &harness.socket,
        serde_json::json!({
            "id": 4,
            "cmd": "shutdown-daemon",
            "pid": daemon_pid,
            "generation": "stale-generation",
        }),
    );
    assert_eq!(stale["ok"], false);
    assert!(stale["error"].as_str().unwrap().contains("generation changed"));
    assert!(harness.child.as_mut().unwrap().try_wait().unwrap().is_none());

    // Receiving this response proves the acknowledgement was flushed before
    // the daemon entered its normal shutdown path.
    let accepted = request(
        &harness.socket,
        serde_json::json!({
            "id": 5,
            "cmd": "shutdown-daemon",
            "pid": daemon_pid,
            "generation": generation,
        }),
    );
    assert_eq!(accepted["accepted"], true);
    assert_eq!(accepted["pid"].as_u64(), Some(daemon_pid));

    let mut daemon = harness.child.take().unwrap();
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if daemon.try_wait().unwrap().is_some() {
            break;
        }
        assert!(Instant::now() < deadline, "daemon did not exit after fenced shutdown");
        std::thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(
        terminal_host_record_liveness(&record_path, &record).unwrap(),
        TerminalHostLiveness::Live,
    );
    assert_eq!(wait_for_host_records(&harness.host_root(), 1)[0].1.host_pid, host_pid);

    harness.restart();
    let deadline = Instant::now() + Duration::from_secs(15);
    let adopted_surface = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({
                "id": 6,
                "cmd": "resolve-terminal",
                "terminal_id": terminal_id,
            }),
        );
        if resolved["lifecycle"] == "running"
            && resolved["terminal_incarnation"].as_str() == Some(incarnation.as_str())
            && let Some(surface) = resolved["surface"].as_u64()
        {
            break surface;
        }
        assert!(Instant::now() < deadline, "replacement daemon did not adopt terminal host");
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(wait_for_screen(&harness.socket, adopted_surface, &marker).contains(&marker));
    assert_eq!(wait_for_host_records(&harness.host_root(), 1)[0].1.host_pid, host_pid);

    let after = format!("after-fenced-shutdown-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({
            "id": 7,
            "cmd": "send",
            "surface": adopted_surface,
            "text": format!("{after}\n"),
        }),
    );
    assert!(wait_for_screen(&harness.socket, adopted_surface, &after).contains(&after));
    request(
        &harness.socket,
        serde_json::json!({
            "id": 8,
            "cmd": "close-terminal",
            "terminal_id": terminal_id,
            "terminal_incarnation": incarnation,
        }),
    );
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn new_host_rolls_back_when_surface_setup_fails_after_connect() {
    let harness = RecoveryHarness::start_with_hosted_spawn_failure("post-connect-rollback", 500);
    let socket = harness.socket.clone();
    let shell_pid_path = harness.dir.join("rollback-shell.pid");
    let request_value = serde_json::json!({
        "id": 1,
        "cmd": "run",
        "argv": [
            "/bin/sh",
            "-c",
            "trap '' HUP; printf '%s' \"$$\" > \"$1\"; while :; do sleep 60; done",
            "cmux-rollback-shell",
            shell_pid_path,
        ],
        "new_workspace": true,
        "name": "must-roll-back",
    });
    let request_thread = std::thread::spawn(move || request_response(&socket, request_value));

    // The injection runs only after the host has published its record and the
    // daemon has authenticated a complete Snapshot, proving this exercises
    // the ownership handoff rather than an earlier spawn failure.
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    assert_eq!(
        terminal_host_record_liveness(&record_path, &record).unwrap(),
        TerminalHostLiveness::Live,
    );
    let shell_pid = wait_for_pid_file(&harness.dir.join("rollback-shell.pid"));
    let response = request_thread.join().unwrap();
    assert_eq!(response["ok"], false);

    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        if terminal_host_record_liveness(&record_path, &record).unwrap()
            == TerminalHostLiveness::Dead
        {
            break;
        }
        assert!(Instant::now() < deadline, "rolled-back host remained alive");
        std::thread::sleep(Duration::from_millis(20));
    }
    wait_for_no_host_records(&harness.host_root());
    wait_for_process_and_group_absent(shell_pid);
}

#[test]
fn explicit_terminate_escalates_past_a_sighup_ignoring_child() {
    let harness = RecoveryHarness::start("terminate-hup-ignoring-child");
    let marker = format!("hup-ignored-ready-{}", std::process::id());
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": [
                "/bin/sh",
                "-c",
                format!("trap '' HUP; printf '{marker}\\n'; while :; do sleep 60; done"),
            ],
            "new_workspace": true,
            "name": "hup-ignoring-child",
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    assert!(wait_for_screen(&harness.socket, surface, &marker).contains(&marker));

    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let host = adopt_terminal_host(record.clone(), record_path.clone()).unwrap();
    let shell_pid = host.snapshot.pid.unwrap() as libc::pid_t;
    host.terminate().unwrap();
    host.disconnect();
    wait_for_no_host_records(&harness.host_root());
    assert_eq!(
        terminal_host_record_liveness(&record_path, &record).unwrap(),
        TerminalHostLiveness::Dead,
    );
    wait_for_process_and_group_absent(shell_pid);
}

#[test]
fn explicit_terminate_reaps_descendants_in_the_pty_group() {
    let harness = RecoveryHarness::start("terminate-pty-descendant");
    let marker = format!("descendant-retained-pty-{}", std::process::id());
    let descendant_pid_path = harness.dir.join("pty-descendant.pid");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": [
                "/bin/sh",
                "-c",
                concat!(
                    "(trap '' HUP; while :; do sleep 60; done) & ",
                    "printf '%s' \"$!\" > \"$1\"; printf '%s\\n' \"$2\"; ",
                    "while :; do sleep 60; done",
                ),
                "cmux-pty-descendant",
                descendant_pid_path,
                marker,
            ],
            "new_workspace": true,
            "name": "pty-retaining-descendant",
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    assert!(wait_for_screen(&harness.socket, surface, &marker).contains(&marker));
    let descendant_pid = wait_for_pid_file(&harness.dir.join("pty-descendant.pid"));
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let observer = adopt_terminal_host(record.clone(), record_path.clone()).unwrap();
    let direct_pid = observer.snapshot.pid.unwrap() as libc::pid_t;
    observer.disconnect();
    assert!(process_exists(direct_pid), "direct PTY child exited before Terminate");
    assert!(process_exists(descendant_pid), "PTY-retaining descendant exited before Terminate");
    // SAFETY: both fixture processes are live and owned by this test.
    let direct_group = unsafe { libc::getpgid(direct_pid) };
    // SAFETY: both fixture processes are live and owned by this test.
    let descendant_group = unsafe { libc::getpgid(descendant_pid) };
    assert!(direct_group > 0);
    assert_eq!(descendant_group, direct_group, "fixture descendant left the PTY process group");

    // ProcessSignaller's HUP exits the direct child while the descendant
    // ignores it. The reserved-PGID escalation must still reap the latter.
    assert_eq!(
        terminal_host_record_liveness(&record_path, &record).unwrap(),
        TerminalHostLiveness::Live,
    );
    let host = adopt_terminal_host(record.clone(), record_path.clone()).unwrap();
    host.terminate().unwrap();
    host.disconnect();
    wait_for_no_host_records(&harness.host_root());
    assert_eq!(
        terminal_host_record_liveness(&record_path, &record).unwrap(),
        TerminalHostLiveness::Dead,
    );
    wait_for_process_and_group_absent(direct_pid);
    wait_for_process_and_group_absent(descendant_pid);
}

#[test]
fn exit_follows_all_final_pty_bytes_on_the_live_stream() {
    let harness = RecoveryHarness::start("exit-after-final-bytes");
    request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": [
                "/bin/sh",
                "-c",
                concat!(
                    "IFS= read -r trigger; i=0; ",
                    "while [ \"$i\" -lt 20000 ]; do ",
                    "printf 'drain-%05d-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n' \"$i\"; ",
                    "i=$((i + 1)); done; ",
                    "printf 'FINAL-PTY-BYTE-MARKER\\n'",
                ),
            ],
            "new_workspace": true,
            "name": "final-byte-ordering",
        }),
    );
    let (_, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let mut renderer = connect_host_detailed(
        &record.endpoint,
        &record.terminal_id,
        &record.owner_token,
        ClientRole::Admin,
        CapabilityRights::ADMIN,
    )
    .unwrap();
    renderer.stream.set_read_timeout(Some(Duration::from_secs(15))).unwrap();
    write_frame(&mut renderer.stream, &Frame::new(MessageKind::Input, b"go\n".to_vec())).unwrap();

    let mut output = Vec::new();
    loop {
        let frame = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD)
            .unwrap()
            .expect("terminal host closed before sequenced Exit");
        assert_eq!(frame.sequence, renderer.next_sequence);
        renderer.next_sequence = renderer.next_sequence.wrapping_add(1);
        if frame.kind == MessageKind::Output {
            output.extend_from_slice(&frame.payload);
        }
        if frame.kind == MessageKind::Exit {
            break;
        }
    }
    assert!(contains_bytes(&output, b"FINAL-PTY-BYTE-MARKER"), "Exit overtook the final PTY bytes");
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn mint_capability_fences_prior_admin_input_before_renderer_input() {
    let harness = RecoveryHarness::start("mint-input-barrier");
    let prior_fragments = (0..32).map(|index| format!("a{index:02}")).collect::<Vec<_>>();
    let expected = format!("{}renderer", prior_fragments.concat());
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": [
                "/bin/sh",
                "-c",
                concat!(
                    "stty -echo; printf 'INPUT-BARRIER-READY\\n'; ",
                    "IFS= read -r line; ",
                    "if [ \"$line\" = \"$1\" ]; then ",
                    "printf 'INPUT-BARRIER-RESULT:OK\\n'; ",
                    "else printf 'INPUT-BARRIER-RESULT:BAD\\n'; fi; ",
                    "sleep 30",
                ),
                "cmux-input-barrier",
                &expected,
            ],
            "new_workspace": true,
            "name": "mint-input-barrier",
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    assert!(
        wait_for_screen(&harness.socket, surface, "INPUT-BARRIER-READY")
            .contains("INPUT-BARRIER-READY")
    );
    let (_, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let mut admin = connect_host_detailed(
        &record.endpoint,
        &record.terminal_id,
        &record.owner_token,
        ClientRole::Admin,
        CapabilityRights::ADMIN,
    )
    .unwrap();

    // These compatibility-route writes and the mint request share one admin
    // stream. Receiving Capability is the cutover fence: the host cannot
    // process MintCapability until every preceding Input frame has completed
    // its PTY write and flush.
    for fragment in &prior_fragments {
        write_frame(
            &mut admin.stream,
            &Frame::new(MessageKind::Input, fragment.as_bytes().to_vec()),
        )
        .unwrap();
    }
    let request_id = 0x6261_7272_6965_7201;
    let mut mint_payload = Vec::with_capacity(8);
    mint_payload.extend_from_slice(&CapabilityRights::RENDERER.bits().to_le_bytes());
    mint_payload.extend_from_slice(&10_000u32.to_le_bytes());
    let mut mint = Frame::new(MessageKind::MintCapability, mint_payload);
    mint.request_id = request_id;
    write_frame(&mut admin.stream, &mint).unwrap();

    admin.stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    let token = loop {
        let frame = read_frame(&mut admin.stream, MAX_FRAME_PAYLOAD)
            .expect("read admin terminal-host frame")
            .expect("admin terminal-host closed before Capability fence");
        if frame.request_id == request_id {
            assert_eq!(frame.kind, MessageKind::Capability);
            assert_eq!(frame.flags, 0);
            assert_eq!(frame.sequence, 0);
            assert_eq!(frame.payload.len(), CAPABILITY_TOKEN_LEN);
            break frame.payload.iter().map(|byte| format!("{byte:02x}")).collect::<String>();
        }
        assert_eq!(frame.request_id, 0, "unexpected targeted admin response");
        assert_eq!(frame.sequence, admin.next_sequence, "admin live sequence was not contiguous");
        admin.next_sequence = admin.next_sequence.wrapping_add(1);
    };

    let mut renderer = connect_host_detailed(
        &record.endpoint,
        &record.terminal_id,
        &token,
        ClientRole::Renderer,
        CapabilityRights::RENDERER,
    )
    .unwrap();
    write_frame(&mut renderer.stream, &Frame::new(MessageKind::Input, b"renderer\n".to_vec()))
        .unwrap();

    let screen = wait_for_screen(&harness.socket, surface, "INPUT-BARRIER-RESULT:");
    assert!(
        screen.contains("INPUT-BARRIER-RESULT:OK"),
        "renderer input overtook pre-mint admin input: {screen:?}"
    );

    drop(renderer);
    drop(admin);
    request(
        &harness.socket,
        serde_json::json!({"id": 2, "cmd": "close-surface", "surface": surface}),
    );
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn terminal_host_survives_sigkill_and_is_adopted_with_io_and_size() {
    let mut harness = RecoveryHarness::start("sigkill-adopt");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/cat"],
            "new_workspace": true,
            "name": "survivor",
            "cols": 80,
            "rows": 24,
        }),
    );
    let original_surface = created["surface"].as_u64().unwrap();
    let workspace = created["workspace"].as_u64().unwrap();

    let tree = request(&harness.socket, serde_json::json!({"id": 2, "cmd": "list-workspaces"}));
    let workspace_key = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["id"].as_u64() == Some(workspace))
        .and_then(|item| item["key"].as_str())
        .unwrap()
        .to_string();

    let before = format!("before-sigkill-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "send",
            "surface": original_surface,
            "text": format!("{before}\n"),
        }),
    );
    assert!(wait_for_screen(&harness.socket, original_surface, &before).contains(&before));

    let records = wait_for_host_records(&harness.host_root(), 1);
    assert_eq!(records[0].1.workspace_key, workspace_key);
    let terminal_id = records[0].1.terminal_id.clone();
    let incarnation = records[0].1.incarnation.clone();
    let endpoint = PathBuf::from(&records[0].1.endpoint);
    assert!(endpoint.exists());
    assert_eq!(created["terminal_id"].as_str(), Some(terminal_id.as_str()));
    assert_eq!(created["terminal_incarnation"].as_str(), Some(incarnation.as_str()));
    let tree_workspace = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["id"].as_u64() == Some(workspace))
        .unwrap();
    let tree_tab = first_tab(tree_workspace).unwrap();
    assert_eq!(tree_tab["terminal_id"].as_str(), Some(terminal_id.as_str()));
    assert_eq!(tree_tab["terminal_incarnation"].as_str(), Some(incarnation.as_str()));
    let resolved = request(
        &harness.socket,
        serde_json::json!({"id": 21, "cmd": "resolve-terminal", "terminal_id": &terminal_id}),
    );
    assert_eq!(resolved["surface"].as_u64(), Some(original_surface));
    assert_eq!(resolved["terminal_id"].as_str(), Some(terminal_id.as_str()));
    assert_eq!(resolved["terminal_incarnation"].as_str(), Some(incarnation.as_str()));
    let missing = request_response(
        &harness.socket,
        serde_json::json!({
            "id": 22,
            "cmd": "resolve-terminal",
            "terminal_id": "ffffffffffff4fffbfffffffffffffff",
        }),
    );
    assert_eq!(missing["ok"], false);
    assert_eq!(missing["error"], "terminal_not_found");

    // Rights are enforced after authentication, not merely reported in the
    // hello. A READ-only owner connection cannot terminate the terminal.
    let mut read_only = connect_host(
        &records[0].1.endpoint,
        &terminal_id,
        &records[0].1.owner_token,
        ClientRole::Admin,
        CapabilityRights::READ,
    )
    .unwrap();
    write_frame(&mut read_only, &Frame::new(MessageKind::Terminate, Vec::new())).unwrap();
    drop(read_only);

    // JSON brokers a one-use renderer grant while keeping the durable owner
    // secret private. The minted renderer attaches directly to the host and
    // writes to the same PTY.
    let grant = request(
        &harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "mint-terminal-renderer",
            "surface": original_surface,
            "ttl_ms": 10_000,
        }),
    );
    assert_eq!(grant["terminal_id"].as_str(), Some(terminal_id.as_str()));
    assert_eq!(grant["incarnation"].as_str(), Some(incarnation.as_str()));
    assert_eq!(grant["rights"].as_u64(), Some(u64::from(CapabilityRights::RENDERER.bits())));
    let mut renderer = connect_host_detailed(
        grant["endpoint"].as_str().unwrap(),
        grant["terminal_id"].as_str().unwrap(),
        grant["token"].as_str().unwrap(),
        ClientRole::Renderer,
        CapabilityRights::RENDERER,
    )
    .unwrap();
    let direct = format!("direct-renderer-{}", std::process::id());
    write_frame(
        &mut renderer.stream,
        &Frame::new(MessageKind::Input, format!("{direct}\n").into_bytes()),
    )
    .unwrap();
    assert!(wait_for_screen(&harness.socket, original_surface, &direct).contains(&direct));
    assert!(
        connect_host(
            grant["endpoint"].as_str().unwrap(),
            grant["terminal_id"].as_str().unwrap(),
            grant["token"].as_str().unwrap(),
            ClientRole::Renderer,
            CapabilityRights::RENDERER,
        )
        .is_err(),
        "renderer capability was reusable"
    );
    let expected_colors = {
        let mut colors = TerminalColorOverrides {
            foreground: Some(Rgb { r: 17, g: 18, b: 19 }),
            background: Some(Rgb { r: 33, g: 34, b: 35 }),
            cursor: Some(Rgb { r: 49, g: 50, b: 51 }),
            ..Default::default()
        };
        colors.palette[3] = Some(Rgb { r: 1, g: 2, b: 3 });
        colors
    };
    write_frame(
        &mut renderer.stream,
        &Frame::new(
            MessageKind::Input,
            b"\x1b]4;3;#010203\x07\x1b]10;#111213\x07\x1b]11;#212223\x07\x1b]12;#313233\x07\n"
                .to_vec(),
        ),
    )
    .unwrap();
    renderer.wait_for_colors(&expected_colors);

    // A fresh renderer receives portable VT state and the complete sparse
    // color state as a separate frame at the same atomic sequence boundary.
    let color_grant = request(
        &harness.socket,
        serde_json::json!({
            "id": 31,
            "cmd": "mint-terminal-renderer",
            "surface": original_surface,
            "ttl_ms": 10_000,
        }),
    );
    let color_snapshot = connect_host_detailed(
        color_grant["endpoint"].as_str().unwrap(),
        color_grant["terminal_id"].as_str().unwrap(),
        color_grant["token"].as_str().unwrap(),
        ClientRole::Renderer,
        CapabilityRights::RENDERER,
    )
    .unwrap();
    assert_eq!(color_snapshot.colors, expected_colors);
    let replay = snapshot_replay(&color_snapshot.snapshot.payload);
    for forbidden in [b"\x1b]4;".as_slice(), b"\x1b]10;", b"\x1b]11;", b"\x1b]12;"] {
        assert!(!contains_bytes(replay, forbidden), "portable Snapshot leaked color OSC");
    }
    drop(color_snapshot);

    write_frame(
        &mut renderer.stream,
        &Frame::new(
            MessageKind::Input,
            b"\x1b]104;3\x07\x1b]110\x07\x1b]111\x07\x1b]112\x07\n".to_vec(),
        ),
    )
    .unwrap();
    renderer.wait_for_colors(&TerminalColorOverrides::default());
    drop(renderer);

    // Child::kill is SIGKILL on Unix. The mux cannot run shutdown hooks, so
    // this proves the PTY and parser live in the independent host process.
    harness.sigkill();
    assert!(endpoint.exists(), "terminal host socket disappeared with the daemon");
    assert_eq!(wait_for_host_records(&harness.host_root(), 1)[0].1.terminal_id, terminal_id);

    harness.restart();
    let recovered =
        request(&harness.socket, serde_json::json!({"id": 4, "cmd": "list-workspaces"}));
    let recovered_workspace = recovered["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["key"].as_str() == Some(&workspace_key))
        .expect("durable workspace was not recovered");
    let adopted_surface =
        first_surface(recovered_workspace).expect("terminal host was not adopted");
    let rebound = request(
        &harness.socket,
        serde_json::json!({"id": 41, "cmd": "resolve-terminal", "terminal_id": &terminal_id}),
    );
    assert_eq!(rebound["surface"].as_u64(), Some(adopted_surface));
    assert_eq!(rebound["terminal_id"].as_str(), Some(terminal_id.as_str()));
    assert_eq!(rebound["terminal_incarnation"].as_str(), Some(incarnation.as_str()));

    let replay = wait_for_screen(&harness.socket, adopted_surface, &before);
    assert!(replay.contains(&before), "host replay did not survive SIGKILL: {replay:?}");

    let after = format!("after-adoption-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({
            "id": 5,
            "cmd": "send",
            "surface": adopted_surface,
            "text": format!("{after}\n"),
        }),
    );
    assert!(wait_for_screen(&harness.socket, adopted_surface, &after).contains(&after));

    let resized = request(
        &harness.socket,
        serde_json::json!({
            "id": 6,
            "cmd": "resize-surface",
            "surface": adopted_surface,
            "cols": 101,
            "rows": 37,
        }),
    );
    assert_eq!(resized["accepted"], true);
    let state = wait_for_vt_size(&harness.socket, adopted_surface, 101, 37);
    assert_eq!(state["cols"].as_u64(), Some(101));
    assert_eq!(state["rows"].as_u64(), Some(37));
    wait_for_host_size(&harness.host_root(), 101, 37);

    let records = wait_for_host_records(&harness.host_root(), 1);
    assert_eq!(records[0].1.terminal_id, terminal_id);
    assert_eq!(records[0].1.incarnation, incarnation);

    // A second crash proves the resize landed in the PTY-owning process, not
    // only in the disposable daemon-side Ghostty mirror.
    harness.sigkill();
    harness.restart();
    let recovered =
        request(&harness.socket, serde_json::json!({"id": 8, "cmd": "list-workspaces"}));
    let recovered_workspace = recovered["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|item| item["key"].as_str() == Some(&workspace_key))
        .expect("workspace was not recovered after the resized host survived again");
    let resized_surface =
        first_surface(recovered_workspace).expect("resized terminal host was not adopted");
    let state = request(
        &harness.socket,
        serde_json::json!({"id": 9, "cmd": "vt-state", "surface": resized_surface}),
    );
    assert_eq!(state["cols"].as_u64(), Some(101));
    assert_eq!(state["rows"].as_u64(), Some(37));
    assert!(wait_for_screen(&harness.socket, resized_surface, &after).contains(&after));

    let stale_close = request_response(
        &harness.socket,
        serde_json::json!({
            "id": 10,
            "cmd": "close-terminal",
            "terminal_id": &terminal_id,
            "terminal_incarnation": "00000000000040008000000000000000",
        }),
    );
    assert_eq!(stale_close["ok"], false);
    assert_eq!(stale_close["error"], "terminal_incarnation_mismatch");
    assert_eq!(wait_for_host_records(&harness.host_root(), 1).len(), 1);

    // This stable-id close was logically queued while the daemon was down;
    // after adoption it atomically resolves the new local surface generation,
    // verifies the incarnation, removes it, and only then terminates the host.
    let closed = request(
        &harness.socket,
        serde_json::json!({
            "id": 11,
            "cmd": "close-terminal",
            "terminal_id": &terminal_id,
            "terminal_incarnation": &incarnation,
        }),
    );
    assert_eq!(closed["surface"].as_u64(), Some(resized_surface));
    assert_eq!(closed["terminal_id"].as_str(), Some(terminal_id.as_str()));
    assert_eq!(closed["terminal_incarnation"].as_str(), Some(incarnation.as_str()));
    let tombstoned = request_response(
        &harness.socket,
        serde_json::json!({"id": 12, "cmd": "resolve-terminal", "terminal_id": &terminal_id}),
    );
    assert_eq!(tombstoned["ok"], true);
    assert_eq!(tombstoned["data"]["surface"], serde_json::Value::Null);
    assert_eq!(tombstoned["data"]["lifecycle"], "tombstoned");
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn transient_startup_adoption_failure_retries_in_process_until_running() {
    let mut harness = RecoveryHarness::start("retry-adopt");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id":1,
            "cmd":"run",
            "argv":["/bin/cat"],
            "new_workspace":true,
            "cols":80,
            "rows":24,
        }),
    );
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let records = wait_for_host_records(&harness.host_root(), 1);
    let endpoint = PathBuf::from(&records[0].1.endpoint);
    let held_endpoint = endpoint.with_extension("held-for-adoption-test");

    harness.sigkill();
    fs::rename(&endpoint, &held_endpoint).unwrap();
    harness.restart();

    let pending = request(
        &harness.socket,
        serde_json::json!({"id":2,"cmd":"resolve-terminal","terminal_id":terminal_id}),
    );
    assert_eq!(pending["surface"], serde_json::Value::Null);
    assert_eq!(pending["lifecycle"], "adopting");

    fs::rename(&held_endpoint, &endpoint).unwrap();
    let deadline = Instant::now() + Duration::from_secs(15);
    let surface = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id":3,"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if resolved["lifecycle"] == "running"
            && let Some(surface) = resolved["surface"].as_u64()
        {
            break surface;
        }
        assert!(Instant::now() < deadline, "terminal never completed in-process adoption");
        std::thread::sleep(Duration::from_millis(50));
    };

    let marker = format!("scheduled-adoption-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({"id":4,"cmd":"send","surface":surface,"text":format!("{marker}\n")}),
    );
    assert!(wait_for_screen(&harness.socket, surface, &marker).contains(&marker));
}

#[test]
fn client_reserved_create_retry_returns_original_binding_without_second_host() {
    let harness = RecoveryHarness::start("reserved-create");
    let workspace = request(
        &harness.socket,
        serde_json::json!({
            "id":1,
            "cmd":"create-workspace",
            "name":"Browser",
            "key":"018f6e21-7b70-7e70-8000-000000000045",
            "origin":"browser",
            "mutation_id":"workspace-create",
            "expected_revision":0,
        }),
    );
    let terminal_id = TerminalId::random().unwrap().to_hex();
    let create = serde_json::json!({
        "id":2,
        "cmd":"create-terminal",
        "key":"018f6e21-7b70-7e70-8000-000000000045",
        "argv":["/bin/cat"],
        "terminal_id":terminal_id,
        "origin":"browser",
        "mutation_id":"terminal-create",
        "expected_generation":workspace["generation"],
        "expected_terminal_revision":0,
        "cols":80,
        "rows":24,
    });
    let first = request(&harness.socket, create.clone());
    assert_eq!(first["terminal_id"], terminal_id);
    assert_eq!(first["replayed"], false);
    assert_eq!(wait_for_host_records(&harness.host_root(), 1).len(), 1);

    let retry = request(&harness.socket, create);
    assert_eq!(retry["replayed"], true);
    assert_eq!(retry["terminal_id"], terminal_id);
    assert_eq!(retry["surface"], first["surface"]);
    assert_eq!(retry["pane"], first["pane"]);
    assert_eq!(retry["screen"], first["screen"]);
    assert_eq!(wait_for_host_records(&harness.host_root(), 1).len(), 1);

    let mismatch = request_response(
        &harness.socket,
        serde_json::json!({
            "id":3,
            "cmd":"create-terminal",
            "key":"018f6e21-7b70-7e70-8000-000000000045",
            "argv":["/bin/echo","different"],
            "terminal_id":terminal_id,
            "origin":"browser",
            "mutation_id":"terminal-create",
            "expected_terminal_revision":0,
        }),
    );
    assert_eq!(mismatch["ok"], false);
    assert!(mismatch["error"].as_str().unwrap().contains("different payload"));
}

#[test]
fn stalled_renderer_is_disconnected_without_freezing_the_host() {
    let harness = RecoveryHarness::start("stalled-renderer");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/sh"],
            "new_workspace": true,
            "cols": 80,
            "rows": 24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let grant = request(
        &harness.socket,
        serde_json::json!({
            "id": 2,
            "cmd": "mint-terminal-renderer",
            "surface": surface,
            "ttl_ms": 10_000,
        }),
    );
    let mut stalled = connect_host_detailed(
        grant["endpoint"].as_str().unwrap(),
        grant["terminal_id"].as_str().unwrap(),
        grant["token"].as_str().unwrap(),
        ClientRole::Renderer,
        CapabilityRights::RENDERER,
    )
    .unwrap();

    let done = format!("overflow-done-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "send",
            "surface": surface,
            "text": format!(
                "/usr/bin/head -c 20000000 /dev/zero; printf '{done}\\n'\n"
            ),
        }),
    );
    assert!(wait_for_screen(&harness.socket, surface, &done).contains(&done));

    let disconnected_before_drain =
        match stalled.stream.set_read_timeout(Some(Duration::from_secs(5))) {
            Ok(()) => false,
            // Darwin reports EINVAL when setting SO_RCVTIMEO after the peer has
            // already issued shutdown(2); that is the overflow outcome under test.
            Err(error) if error.kind() == std::io::ErrorKind::InvalidInput => true,
            Err(error) => panic!("set stalled-renderer timeout: {error}"),
        };
    let mut complete_frames = 0usize;
    if !disconnected_before_drain {
        loop {
            match read_frame(&mut stalled.stream, MAX_FRAME_PAYLOAD) {
                Ok(Some(frame)) => {
                    assert_eq!(frame.request_id, 0);
                    assert_eq!(frame.sequence, stalled.next_sequence);
                    stalled.next_sequence = stalled.next_sequence.wrapping_add(1);
                    complete_frames += 1;
                }
                Ok(None) => break,
                Err(ProtocolError::Io(error))
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::WouldBlock | std::io::ErrorKind::TimedOut
                    ) =>
                {
                    panic!("stalled renderer silently froze instead of being disconnected")
                }
                // Shutdown can interrupt a frame already being copied into the
                // kernel socket buffer. A clean EOF or truncated final frame are
                // both explicit disconnects and require a fresh Snapshot.
                Err(ProtocolError::Truncated { .. }) | Err(ProtocolError::Io(_)) => break,
                Err(error) => panic!("stalled renderer received invalid protocol data: {error}"),
            }
        }
    }
    assert!(
        disconnected_before_drain || complete_frames > 0,
        "stalled renderer received no output before disconnect"
    );

    // Overflow is isolated to the stalled renderer. The daemon proxy and PTY
    // remain responsive and the durable host record remains adoptable.
    let after = format!("host-still-live-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({
            "id": 4,
            "cmd": "send",
            "surface": surface,
            "text": format!("printf '{after}\\n'\n"),
        }),
    );
    assert!(wait_for_screen(&harness.socket, surface, &after).contains(&after));
    assert_eq!(wait_for_host_records(&harness.host_root(), 1).len(), 1);

    request(
        &harness.socket,
        serde_json::json!({"id": 5, "cmd": "close-surface", "surface": surface}),
    );
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn daemon_admin_backpressure_reconnects_without_restarting_host_or_renderer() {
    let harness = RecoveryHarness::start("admin-reconnect");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id":1,"cmd":"run","argv":["/bin/sh"],"new_workspace":true,
            "cols":80,"rows":24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    let before_record = wait_for_host_records(&harness.host_root(), 1).remove(0).1;
    let terminal_snapshot =
        request(&harness.socket, serde_json::json!({"id":20,"cmd":"list-terminals"}));
    let before_revision = terminal_snapshot["terminal_revision"].as_u64().unwrap();
    let grant = request(
        &harness.socket,
        serde_json::json!({
            "id":2,"cmd":"mint-terminal-renderer","surface":surface,"ttl_ms":10_000,
        }),
    );
    let renderer = connect_host_detailed(
        grant["endpoint"].as_str().unwrap(),
        grant["terminal_id"].as_str().unwrap(),
        grant["token"].as_str().unwrap(),
        ClientRole::Renderer,
        CapabilityRights::RENDERER,
    )
    .unwrap();
    let mut renderer_writer = renderer.stream.try_clone().unwrap();
    let drained = Arc::new(AtomicUsize::new(0));
    let drain_count = drained.clone();
    let (overflow_tx, overflow_rx) = mpsc::sync_channel(1);
    let drain = std::thread::spawn(move || {
        let mut renderer = renderer;
        let mut reported = false;
        loop {
            match read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD) {
                Ok(Some(frame)) => {
                    if frame.request_id == 0 {
                        assert_eq!(frame.sequence, renderer.next_sequence);
                        renderer.next_sequence = renderer.next_sequence.wrapping_add(1);
                    }
                    if frame.kind == MessageKind::Output {
                        let total = drain_count.fetch_add(frame.payload.len(), Ordering::AcqRel)
                            + frame.payload.len();
                        if total >= 12_000_000 && !reported {
                            reported = true;
                            let _ = overflow_tx.send(());
                        }
                    }
                }
                Ok(None) | Err(ProtocolError::Truncated { .. }) | Err(ProtocolError::Io(_)) => {
                    break;
                }
                Err(error) => panic!("renderer stream failed during admin reconnect: {error}"),
            }
        }
    });

    // Freeze only the mux. The terminal host and renderer remain scheduled;
    // enough PTY output fills the daemon tap's bounded queue and deliberately
    // disconnects that admin stream.
    harness.signal_daemon(libc::SIGSTOP);
    write_frame(
        &mut renderer_writer,
        &Frame::new(
            MessageKind::Input,
            b"/usr/bin/head -c 14000000 /dev/zero; printf '\\nadmin-flood-done\\n'\n".to_vec(),
        ),
    )
    .unwrap();
    overflow_rx.recv_timeout(Duration::from_secs(15)).unwrap();
    harness.signal_daemon(libc::SIGCONT);

    let after = format!("renderer-after-reconnect-{}", std::process::id());
    write_frame(
        &mut renderer_writer,
        &Frame::new(MessageKind::Input, format!("printf '{after}\\n'\n").into_bytes()),
    )
    .unwrap();
    assert!(wait_for_screen(&harness.socket, surface, &after).contains(&after));
    let resolved = request(
        &harness.socket,
        serde_json::json!({"id":3,"cmd":"resolve-terminal","terminal_id":terminal_id}),
    );
    assert_eq!(resolved["lifecycle"], "running");
    assert_eq!(resolved["terminal_incarnation"], incarnation);
    let after_record = wait_for_host_records(&harness.host_root(), 1).remove(0).1;
    assert_eq!(after_record.host_pid, before_record.host_pid);
    assert_eq!(after_record.host_start_nonce, before_record.host_start_nonce);
    assert_eq!(after_record.incarnation, before_record.incarnation);
    assert!(drained.load(Ordering::Acquire) >= 12_000_000);
    let lifecycle_events = request(
        &harness.socket,
        serde_json::json!({
            "id":21,"cmd":"terminal-events","after_revision":before_revision,
        }),
    );
    let kinds = lifecycle_events["events"]
        .as_array()
        .unwrap()
        .iter()
        .map(|event| event["kind"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert!(kinds.contains(&"terminal-adopting"));
    assert!(kinds.contains(&"terminal-ready"));

    let _ = renderer_writer.shutdown(std::net::Shutdown::Both);
    drain.join().unwrap();
    request(&harness.socket, serde_json::json!({"id":4,"cmd":"close-surface","surface":surface}));
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn failed_terminate_and_rejected_resize_leave_live_record_discoverable() {
    let harness = RecoveryHarness::start("failed-control");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,
            "cols":80,"rows":24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);

    let disconnected = adopt_terminal_host(record.clone(), record_path.clone()).unwrap();
    disconnected.disconnect();
    assert!(disconnected.terminate().is_err());
    assert!(record_path.exists(), "failed Terminate unlinked a live host record");
    assert_eq!(
        terminal_host_record_liveness(&record_path, &record).unwrap(),
        TerminalHostLiveness::Live
    );

    let grant = request(
        &harness.socket,
        serde_json::json!({
            "id":2,"cmd":"mint-terminal-renderer","surface":surface,"ttl_ms":10_000,
        }),
    );
    let mut renderer = connect_host_detailed(
        grant["endpoint"].as_str().unwrap(),
        grant["terminal_id"].as_str().unwrap(),
        grant["token"].as_str().unwrap(),
        ClientRole::Renderer,
        CapabilityRights::RENDERER,
    )
    .unwrap();
    let mut non_minimum = Vec::new();
    non_minimum.extend_from_slice(&120u16.to_le_bytes());
    non_minimum.extend_from_slice(&40u16.to_le_bytes());
    write_frame(&mut renderer.stream, &Frame::new(MessageKind::ViewerSize, non_minimum)).unwrap();
    renderer.stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let resized = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(resized.sequence, renderer.next_sequence);
    renderer.next_sequence = renderer.next_sequence.wrapping_add(1);
    assert_eq!(resized.kind, MessageKind::Resized);
    assert_eq!(resized.flags, FLAG_COLORS_FOLLOW);
    assert_eq!(&resized.payload[..4], &[120, 0, 40, 0]);
    let replay_len = u32::from_le_bytes(resized.payload[4..8].try_into().unwrap()) as usize;
    assert_eq!(resized.payload.len(), 8 + replay_len);
    let colors = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(colors.sequence, renderer.next_sequence);
    renderer.next_sequence = renderer.next_sequence.wrapping_add(1);
    assert_eq!(colors.kind, MessageKind::Colors);
    assert_eq!(colors.flags, 0);

    let mut oversized = Vec::new();
    oversized.extend_from_slice(&5_000u16.to_le_bytes());
    oversized.extend_from_slice(&1_000u16.to_le_bytes());
    write_frame(&mut renderer.stream, &Frame::new(MessageKind::ViewerSize, oversized)).unwrap();
    renderer.stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    loop {
        match read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD) {
            Ok(None) | Err(ProtocolError::Truncated { .. }) | Err(ProtocolError::Io(_)) => break,
            Ok(Some(frame)) => assert_ne!(frame.kind, MessageKind::Resized),
            Err(error) => panic!("invalid resize produced malformed stream: {error}"),
        }
    }
    let state = wait_for_vt_size(&harness.socket, surface, 120, 40);
    assert_eq!(state["cols"], 120);
    assert_eq!(state["rows"], 40);
    assert!(record_path.exists());

    let marker = format!("after-failed-controls-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({
            "id":4,"cmd":"send","surface":surface,"text":format!("{marker}\\n"),
        }),
    );
    assert!(wait_for_screen(&harness.socket, surface, &marker).contains(&marker));
    request(&harness.socket, serde_json::json!({"id":5,"cmd":"close-surface","surface":surface}));
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn direct_renderer_becomes_sole_viewer_after_control_client_disconnect() {
    let harness = RecoveryHarness::start("renderer-sole-viewer");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,
            "cols":80,"rows":24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let grant = request(
        &harness.socket,
        serde_json::json!({
            "id":2,"cmd":"mint-terminal-renderer","surface":surface,"ttl_ms":10_000,
        }),
    );
    let mut renderer = connect_host_detailed(
        grant["endpoint"].as_str().unwrap(),
        grant["terminal_id"].as_str().unwrap(),
        grant["token"].as_str().unwrap(),
        ClientRole::Renderer,
        CapabilityRights::RENDERER,
    )
    .unwrap();

    let mut larger = Vec::new();
    larger.extend_from_slice(&120u16.to_le_bytes());
    larger.extend_from_slice(&40u16.to_le_bytes());
    write_frame(&mut renderer.stream, &Frame::new(MessageKind::ViewerSize, larger)).unwrap();
    renderer.stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let resized = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(resized.kind, MessageKind::Resized);
    assert_eq!(resized.flags, FLAG_COLORS_FOLLOW);
    assert_eq!(&resized.payload[..4], &[120, 0, 40, 0]);
    let colors = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(colors.kind, MessageKind::Colors);

    let state = wait_for_vt_size(&harness.socket, surface, 120, 40);
    assert_eq!(state["cols"], 120);
    assert_eq!(state["rows"], 40);

    // Re-registering the daemon mirror at the already-canonical grid must
    // still create a real host viewer lease. Otherwise a later direct resize
    // would silently bypass the TUI's smallest-viewer arbitration.
    let attach_stream = transport::connect(&harness.socket).unwrap();
    let mut attach_writer = attach_stream.try_clone_box().unwrap();
    let mut attach_reader = BufReader::new(attach_stream);
    writeln!(
        attach_writer,
        "{}",
        serde_json::json!({
            "id":4,"cmd":"attach-surface","surface":surface,"cols":120,"rows":40,
        })
    )
    .unwrap();
    let mut attach_state = String::new();
    attach_reader.read_line(&mut attach_state).unwrap();
    let attach_state: serde_json::Value = serde_json::from_str(&attach_state).unwrap();
    assert_eq!(attach_state["event"], "vt-state");
    let attach_response = loop {
        let mut line = String::new();
        attach_reader.read_line(&mut line).unwrap();
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        if value["id"] == 4 {
            break value;
        }
        assert!(value["event"].is_string(), "unexpected attach line: {value}");
    };
    assert_eq!(attach_response["ok"], true);

    let mut largest = Vec::new();
    largest.extend_from_slice(&160u16.to_le_bytes());
    largest.extend_from_slice(&50u16.to_le_bytes());
    write_frame(&mut renderer.stream, &Frame::new(MessageKind::ViewerSize, largest)).unwrap();
    let clamped = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(clamped.kind, MessageKind::Resized);
    assert_eq!(&clamped.payload[..4], &[120, 0, 40, 0]);
    let colors = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(colors.kind, MessageKind::Colors);
    let state = wait_for_vt_size(&harness.socket, surface, 120, 40);
    assert_eq!(state["cols"], 120);
    assert_eq!(state["rows"], 40);

    drop(attach_writer);
    drop(attach_reader);
    // The legacy renderer stream may still contain an unchanged 120x40
    // replay acknowledged while the attach lease was being installed. Drain
    // complete resize/color pairs until detach restores the direct request.
    loop {
        let restored = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
        assert_eq!(restored.kind, MessageKind::Resized);
        assert!(matches!(&restored.payload[..4], [120, 0, 40, 0] | [160, 0, 50, 0]));
        let colors = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
        assert_eq!(colors.kind, MessageKind::Colors);
        if &restored.payload[..4] == [160, 0, 50, 0] {
            break;
        }
    }
    let state = wait_for_vt_size(&harness.socket, surface, 160, 50);
    assert_eq!(state["cols"], 160);
    assert_eq!(state["rows"], 50);

    request(&harness.socket, serde_json::json!({"id":4,"cmd":"close-surface","surface":surface}));
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn negotiated_viewer_size_ack_skips_unchanged_replay_and_follows_changed_pair() {
    let harness = RecoveryHarness::start("viewer-size-ack");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,
            "cols":80,"rows":24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let grant = request(
        &harness.socket,
        serde_json::json!({
            "id":2,"cmd":"mint-terminal-renderer","surface":surface,"ttl_ms":10_000,
        }),
    );
    let mut renderer = connect_host_detailed_with_flags(
        grant["endpoint"].as_str().unwrap(),
        grant["terminal_id"].as_str().unwrap(),
        grant["token"].as_str().unwrap(),
        ClientRole::Renderer,
        CapabilityRights::RENDERER,
        FLAG_VIEWER_SIZE_ACKS,
    )
    .unwrap();
    assert_eq!(renderer.hello_flags, FLAG_VIEWER_SIZE_ACKS);
    renderer.stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();

    let mut unchanged = Frame::new(MessageKind::ViewerSize, Vec::new());
    unchanged.request_id = 42;
    unchanged.payload.extend_from_slice(&80u16.to_le_bytes());
    unchanged.payload.extend_from_slice(&24u16.to_le_bytes());
    write_frame(&mut renderer.stream, &unchanged).unwrap();
    let ack = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(ack.kind, MessageKind::ResizeAck);
    assert_eq!(ack.flags, 0);
    assert_eq!(ack.request_id, 42);
    assert_eq!(ack.sequence, 0);
    assert_eq!(ack.payload, vec![80, 0, 24, 0, 0, 0, 0, 0]);

    let mut changed = Frame::new(MessageKind::ViewerSize, Vec::new());
    changed.request_id = 43;
    changed.payload.extend_from_slice(&70u16.to_le_bytes());
    changed.payload.extend_from_slice(&20u16.to_le_bytes());
    write_frame(&mut renderer.stream, &changed).unwrap();
    let resized = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(resized.kind, MessageKind::Resized);
    assert_eq!(resized.flags, FLAG_COLORS_FOLLOW);
    assert_eq!(resized.request_id, 0);
    assert_eq!(resized.sequence, renderer.next_sequence);
    renderer.next_sequence = renderer.next_sequence.wrapping_add(1);
    assert_eq!(&resized.payload[..4], &[70, 0, 20, 0]);
    let replay_len = u32::from_le_bytes(resized.payload[4..8].try_into().unwrap()) as usize;
    assert_eq!(resized.payload.len(), 8 + replay_len);
    let colors = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(colors.kind, MessageKind::Colors);
    assert_eq!(colors.flags, 0);
    assert_eq!(colors.request_id, 0);
    assert_eq!(colors.sequence, renderer.next_sequence);
    renderer.next_sequence = renderer.next_sequence.wrapping_add(1);
    let ack = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(ack.kind, MessageKind::ResizeAck);
    assert_eq!(ack.flags, 0);
    assert_eq!(ack.request_id, 43);
    assert_eq!(ack.sequence, 0);
    let mut changed_ack = Vec::new();
    changed_ack.extend_from_slice(&70u16.to_le_bytes());
    changed_ack.extend_from_slice(&20u16.to_le_bytes());
    changed_ack.extend_from_slice(&RESIZE_ACK_CANONICAL_CHANGED.to_le_bytes());
    assert_eq!(ack.payload, changed_ack);

    request(&harness.socket, serde_json::json!({"id":3,"cmd":"close-surface","surface":surface}));
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn daemon_crash_after_record_before_ready_adopts_same_live_host() {
    let mut harness = RecoveryHarness::start_with_host_ready_delay("pre-ready-crash", 2_000);
    let stream = transport::connect(&harness.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    writeln!(
        writer,
        "{}",
        serde_json::json!({
            "id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,
            "cols":80,"rows":24,
        })
    )
    .unwrap();
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    assert_eq!(
        terminal_host_record_liveness(&record_path, &record).unwrap(),
        TerminalHostLiveness::Live,
        "record was not live while the host was paused before Ready"
    );
    let host_pid = record.host_pid;
    let terminal_id = record.terminal_id.clone();
    let incarnation = record.incarnation.clone();
    harness.sigkill();
    drop(writer);
    drop(stream);
    assert_eq!(
        terminal_host_record_liveness(&record_path, &record).unwrap(),
        TerminalHostLiveness::Live,
        "daemon crash incorrectly killed the already-published terminal host"
    );
    harness.restart();

    let deadline = Instant::now() + Duration::from_secs(15);
    let surface = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id":2,"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if resolved["lifecycle"] == "running"
            && let Some(surface) = resolved["surface"].as_u64()
        {
            assert_eq!(resolved["terminal_incarnation"], incarnation);
            break surface;
        }
        assert!(Instant::now() < deadline, "pre-Ready host was not adopted after restart");
        std::thread::sleep(Duration::from_millis(25));
    };
    let adopted = wait_for_host_records(&harness.host_root(), 1).remove(0).1;
    assert_eq!(adopted.host_pid, host_pid);
    assert_eq!(adopted.host_start_nonce, record.host_start_nonce);
    assert_eq!(adopted.incarnation, incarnation);
    let marker = format!("pre-ready-survivor-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({
            "id":3,"cmd":"send","surface":surface,"text":format!("{marker}\\n"),
        }),
    );
    assert!(wait_for_screen(&harness.socket, surface, &marker).contains(&marker));
    request(
        &harness.socket,
        serde_json::json!({
            "id":4,"cmd":"close-terminal","terminal_id":terminal_id,
            "terminal_incarnation":incarnation,
        }),
    );
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn running_host_sigkill_retains_read_only_exited_binding() {
    let harness = RecoveryHarness::start("running-host-sigkill");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,
            "cols":80,"rows":24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    // SAFETY: the record PID is the dedicated host process owned by this
    // harness; killing it is the failure under test.
    assert_eq!(unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) }, 0);

    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id":2,"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if resolved["lifecycle"] == "exited" {
            assert_eq!(resolved["surface"].as_u64(), Some(surface));
            break;
        }
        assert!(Instant::now() < deadline, "running host never transitioned to Exited");
        std::thread::sleep(Duration::from_millis(20));
    }
    let write = request_response(
        &harness.socket,
        serde_json::json!({
            "id":3,"cmd":"send","surface":surface,"text":"must-not-write\\n",
        }),
    );
    assert_eq!(write["ok"], false);
    assert!(write["error"].as_str().unwrap().contains("exited"));
    assert_eq!(
        terminal_host_record_liveness(&record_path, &record).unwrap(),
        TerminalHostLiveness::Dead
    );
    assert!(remove_stale_terminal_host_record(&record_path, &record).unwrap());

    request(
        &harness.socket,
        serde_json::json!({
            "id":4,"cmd":"close-terminal","terminal_id":terminal_id,
            "terminal_incarnation":record.incarnation,
        }),
    );
}

#[test]
fn daemon_restart_safe_prunes_dead_host_and_materializes_exited_workspace_binding() {
    let mut harness = RecoveryHarness::start("dead-host-restart");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,
            "cols":80,"rows":24,
        }),
    );
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    let workspace_id = created["workspace"].as_u64().unwrap();
    let tree = request(&harness.socket, serde_json::json!({"id":2,"cmd":"list-workspaces"}));
    let workspace_key = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["id"].as_u64() == Some(workspace_id))
        .unwrap()["key"]
        .as_str()
        .unwrap()
        .to_string();
    let (_, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);

    // Stop the mux first so it cannot observe the host Exit and update the
    // registry. The restart must reconcile a dead proof against a still-
    // Running/Adopting row without spawning a replacement shell.
    harness.signal_daemon(libc::SIGSTOP);
    // SAFETY: the record PID is the harness-owned terminal host.
    assert_eq!(unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) }, 0);
    harness.sigkill();
    harness.restart();

    let deadline = Instant::now() + Duration::from_secs(15);
    let exited_surface = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id":3,"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if resolved["lifecycle"] == "exited"
            && let Some(surface) = resolved["surface"].as_u64()
        {
            assert_eq!(resolved["terminal_incarnation"], incarnation);
            break surface;
        }
        assert!(Instant::now() < deadline, "dead startup host was not projected as Exited");
        std::thread::sleep(Duration::from_millis(25));
    };
    wait_for_no_host_records(&harness.host_root());
    let recovered = request(&harness.socket, serde_json::json!({"id":4,"cmd":"list-workspaces"}));
    let workspace = recovered["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["key"].as_str() == Some(&workspace_key))
        .expect("original workspace was not recovered");
    let tab = first_tab(workspace).expect("Exited terminal placeholder was not materialized");
    assert_eq!(tab["surface"].as_u64(), Some(exited_surface));
    assert_eq!(tab["terminal_id"].as_str(), Some(terminal_id.as_str()));

    let write = request_response(
        &harness.socket,
        serde_json::json!({
            "id":5,"cmd":"send","surface":exited_surface,"text":"must-not-respawn\\n",
        }),
    );
    assert_eq!(write["ok"], false);
    request(
        &harness.socket,
        serde_json::json!({
            "id":6,"cmd":"close-terminal","terminal_id":terminal_id,
            "terminal_incarnation":incarnation,
        }),
    );
}

fn request(path: &Path, value: serde_json::Value) -> serde_json::Value {
    let response = request_response(path, value);
    assert_eq!(response["ok"], true, "request failed: {response}");
    response["data"].clone()
}

fn request_response(path: &Path, value: serde_json::Value) -> serde_json::Value {
    let stream = transport::connect(path).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{value}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

fn wait_for_socket(path: &Path) {
    let deadline = Instant::now() + Duration::from_secs(15);
    while Instant::now() < deadline {
        if transport::connect(path).is_ok() {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("server did not accept connections at {}", path.display());
}

fn wait_for_screen(path: &Path, surface: u64, marker: &str) -> String {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut last = String::new();
    while Instant::now() < deadline {
        last = request(path, serde_json::json!({"cmd": "read-screen", "surface": surface}))["text"]
            .as_str()
            .unwrap()
            .to_string();
        if last.contains(marker) {
            return last;
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    last
}

fn wait_for_host_records(
    root: &Path,
    expected: usize,
) -> Vec<(PathBuf, cmux_tui_core::terminal_host_runtime::TerminalHostRecord)> {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let records = load_terminal_host_records(root).unwrap();
        if records.len() == expected {
            return records;
        }
        assert!(Instant::now() < deadline, "expected {expected} host records, got {records:?}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn wait_for_no_host_records(root: &Path) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline {
        if load_terminal_host_records(root).unwrap().is_empty() {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    panic!("terminal host record was not removed after close");
}

fn wait_for_pid_file(path: &Path) -> libc::pid_t {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Ok(contents) = fs::read_to_string(path)
            && let Ok(pid) = contents.trim().parse::<libc::pid_t>()
            && pid > 0
        {
            return pid;
        }
        assert!(Instant::now() < deadline, "process did not publish pid at {}", path.display());
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn wait_for_process_and_group_absent(pid: libc::pid_t) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let process_exists = process_exists(pid);
        // SAFETY: same signal-0 probe for the positive process-group id.
        let group_exists = unsafe { libc::killpg(pid, 0) } == 0
            || std::io::Error::last_os_error().kind() == std::io::ErrorKind::PermissionDenied;
        if !process_exists && !group_exists {
            return;
        }
        assert!(Instant::now() < deadline, "terminated PTY process/group {pid} remained alive");
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn process_exists(pid: libc::pid_t) -> bool {
    // SAFETY: signal 0 performs existence/permission checks only.
    (unsafe { libc::kill(pid, 0) }) == 0
        || std::io::Error::last_os_error().kind() == std::io::ErrorKind::PermissionDenied
}

fn wait_for_host_size(root: &Path, cols: u16, rows: u16) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let mut records = load_terminal_host_records(root).unwrap();
        if records.len() == 1 {
            let (path, record) = records.pop().unwrap();
            if let Ok(host) = adopt_terminal_host(record, path) {
                let size = (host.snapshot.cols, host.snapshot.rows);
                host.disconnect();
                if size == (cols, rows) {
                    return;
                }
            }
        }
        assert!(Instant::now() < deadline, "host did not resize to {cols}x{rows}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn wait_for_vt_size(path: &Path, surface: u64, cols: u16, rows: u16) -> serde_json::Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let state = request(path, serde_json::json!({"cmd": "vt-state", "surface": surface}));
        if state["cols"].as_u64() == Some(u64::from(cols))
            && state["rows"].as_u64() == Some(u64::from(rows))
        {
            return state;
        }
        assert!(Instant::now() < deadline, "daemon mirror did not resize to {cols}x{rows}");
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn first_surface(workspace: &serde_json::Value) -> Option<u64> {
    first_tab(workspace)?.get("surface")?.as_u64()
}

fn first_tab(workspace: &serde_json::Value) -> Option<&serde_json::Value> {
    workspace["screens"]
        .as_array()?
        .iter()
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .next()
}

fn connect_host(
    endpoint: &str,
    terminal_id: &str,
    token: &str,
    role: ClientRole,
    rights: CapabilityRights,
) -> anyhow::Result<UnixStream> {
    Ok(connect_host_detailed(endpoint, terminal_id, token, role, rights)?.stream)
}

struct DirectHostConnection {
    stream: UnixStream,
    snapshot: Frame,
    colors: TerminalColorOverrides,
    next_sequence: u64,
    hello_flags: u32,
}

impl DirectHostConnection {
    fn wait_for_colors(&mut self, expected: &TerminalColorOverrides) {
        self.stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let mut awaiting_colors = false;
        loop {
            let frame = read_frame(&mut self.stream, MAX_FRAME_PAYLOAD)
                .expect("read terminal-host live frame")
                .expect("terminal host closed before Colors");
            assert_eq!(frame.request_id, 0, "unexpected control response on renderer stream");
            assert_eq!(
                frame.sequence, self.next_sequence,
                "terminal-host live sequence was not contiguous"
            );
            self.next_sequence = self.next_sequence.wrapping_add(1);
            match frame.kind {
                MessageKind::Output => match frame.flags {
                    0 => assert!(!awaiting_colors, "unflagged Output split a coupled pair"),
                    FLAG_COLORS_FOLLOW => {
                        assert!(!awaiting_colors, "nested coupled Output frames");
                        awaiting_colors = true;
                    }
                    flags => panic!("unknown Output flags {flags:#x}"),
                },
                MessageKind::Colors => {
                    assert_eq!(frame.flags, 0, "Colors defines no flags");
                    assert!(awaiting_colors, "unpaired live Colors frame");
                    awaiting_colors = false;
                    let colors = decode_terminal_color_overrides(&frame.payload).unwrap();
                    if &colors == expected {
                        return;
                    }
                }
                MessageKind::ResyncRequired => panic!("renderer was told to resync"),
                _ => {
                    assert_eq!(frame.flags, 0, "flags on non-coupled live frame");
                    assert!(!awaiting_colors, "live frame split Output/Colors pair");
                }
            }
        }
    }
}

fn connect_host_detailed(
    endpoint: &str,
    terminal_id: &str,
    token: &str,
    role: ClientRole,
    rights: CapabilityRights,
) -> anyhow::Result<DirectHostConnection> {
    connect_host_detailed_with_flags(endpoint, terminal_id, token, role, rights, 0)
}

fn connect_host_detailed_with_flags(
    endpoint: &str,
    terminal_id: &str,
    token: &str,
    role: ClientRole,
    rights: CapabilityRights,
    hello_flags: u32,
) -> anyhow::Result<DirectHostConnection> {
    let mut stream = UnixStream::connect(endpoint)?;
    let hello = ClientHello {
        min_version: PROTOCOL_VERSION,
        max_version: PROTOCOL_VERSION,
        role,
        requested_rights: rights,
        terminal_id: TerminalId::from_bytes(decode_hex(terminal_id)?),
        token: CapabilityToken::from_bytes(decode_hex(token)?),
    };
    let mut hello = hello.into_frame(1);
    hello.flags = hello_flags;
    write_frame(&mut stream, &hello)?;
    let hello = read_frame(&mut stream, MAX_FRAME_PAYLOAD)?
        .ok_or_else(|| anyhow::anyhow!("host rejected capability"))?;
    if hello.kind != MessageKind::HostHello {
        anyhow::bail!("host did not return HostHello");
    }
    let snapshot = read_frame(&mut stream, MAX_FRAME_PAYLOAD)?
        .ok_or_else(|| anyhow::anyhow!("host closed before snapshot"))?;
    if snapshot.kind != MessageKind::Snapshot || snapshot.flags != 0 || snapshot.request_id != 0 {
        anyhow::bail!("host did not return Snapshot");
    }
    let colors_frame = read_frame(&mut stream, MAX_FRAME_PAYLOAD)?
        .ok_or_else(|| anyhow::anyhow!("host closed before Colors"))?;
    if colors_frame.kind != MessageKind::Colors
        || colors_frame.flags != 0
        || colors_frame.sequence != snapshot.sequence
        || colors_frame.request_id != 0
    {
        anyhow::bail!("host did not return Colors at the Snapshot boundary");
    }
    let colors = decode_terminal_color_overrides(&colors_frame.payload)?;
    Ok(DirectHostConnection {
        stream,
        next_sequence: snapshot.sequence.wrapping_add(1),
        snapshot,
        colors,
        hello_flags: hello.flags,
    })
}

fn snapshot_replay(payload: &[u8]) -> &[u8] {
    assert!(payload.len() >= 12, "Snapshot payload was truncated");
    let replay_len = u32::from_le_bytes(payload[8..12].try_into().unwrap()) as usize;
    let end = 12usize.checked_add(replay_len).expect("Snapshot replay length overflow");
    assert!(end <= payload.len(), "Snapshot replay was truncated");
    &payload[12..end]
}

fn contains_bytes(haystack: &[u8], needle: &[u8]) -> bool {
    haystack.windows(needle.len()).any(|window| window == needle)
}

fn decode_hex<const N: usize>(text: &str) -> anyhow::Result<[u8; N]> {
    if text.len() != N * 2 {
        anyhow::bail!("hex value has wrong length");
    }
    let mut output = [0; N];
    for (index, byte) in output.iter_mut().enumerate() {
        *byte = u8::from_str_radix(&text[index * 2..index * 2 + 2], 16)?;
    }
    Ok(output)
}

fn bin() -> &'static str {
    env!("CARGO_BIN_EXE_cmux-tui")
}
