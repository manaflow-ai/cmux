#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, mpsc};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use base64::Engine;
use cmux_tui_core::platform::transport;
use cmux_tui_core::terminal_host::{
    CAPABILITY_TOKEN_LEN, CapabilityRights, CapabilityToken, ClientHello, ClientRole, TerminalId,
};
use cmux_tui_core::terminal_host_protocol::{
    FLAG_COLORS_FOLLOW, FLAG_VIEWER_SIZE_ACKS, Frame, MAX_FRAME_PAYLOAD, MessageKind,
    PROTOCOL_VERSION, ProtocolError, RESIZE_ACK_CANONICAL_CHANGED, read_frame, write_frame,
};
use cmux_tui_core::terminal_host_runtime::{
    TerminalHostLiveness, TerminalHostRecord, acknowledge_terminal_host_exit_record,
    adopt_terminal_host, decode_terminal_color_overrides, load_terminal_host_exit_records,
    load_terminal_host_records, remove_stale_terminal_host_record, terminal_host_record_liveness,
    terminal_host_root,
};
use ghostty_vt::{Rgb, TerminalColorOverrides};

const KITTY_REPLAY_STATE_ENCODED_LEN: usize = 52;

fn test_timeout(timeout: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .unwrap_or(1)
        .clamp(1, 16);
    timeout.saturating_mul(scale)
}

struct RecoveryHarness {
    child: Option<Child>,
    dir: PathBuf,
    socket: PathBuf,
    state: PathBuf,
    session: String,
    host_ready_delay_ms: Option<u64>,
    reconnect_completion_failures: Option<u64>,
    adoption_insert_failures: Option<u64>,
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
            reconnect_completion_failures: None,
            adoption_insert_failures: None,
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

    fn start_with_reconnect_completion_failures(name: &str, failures: u64) -> Self {
        let mut harness = Self::start_unstarted(name);
        harness.reconnect_completion_failures = Some(failures);
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
            reconnect_completion_failures: None,
            adoption_insert_failures: None,
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
        if let Some(failures) = self.reconnect_completion_failures {
            command.env("CMUX_TUI_TEST_RECONNECT_COMPLETION_FAILURES", failures.to_string());
            command.env("CMUX_TUI_TEST_DISCONNECT_HOST_AFTER_SPAWN_MS", "1000");
        }
        if let Some(failures) = self.adoption_insert_failures {
            command.env("CMUX_TUI_TEST_ADOPTION_INSERT_FAILURES", failures.to_string());
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
            if let Ok(mut host) = adopt_terminal_host(record.clone(), path.clone()) {
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
fn short_lived_terminal_launch_converges_to_durable_exited_result() {
    let harness = RecoveryHarness::start("short-lived-launch");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/sh", "-c", "exit 23"],
            "new_workspace": true,
            "name": "short-lived-command",
        }),
    );
    let already_exited = created["already_exited"].as_bool().unwrap();
    assert_eq!(created["lifecycle"], if already_exited { "exited" } else { "running" });
    for field in ["surface", "pane", "screen", "workspace"] {
        assert_eq!(created[field].is_null(), already_exited, "unexpected {field}: {created}");
    }
    if already_exited {
        assert_eq!(created["exit"]["outcome"], serde_json::json!({"kind":"exit","code":23}));
    } else {
        assert!(created["exit"].is_null());
    }
    assert!(created["terminal_revision"].as_u64().is_some());

    let terminal_id = created["terminal_id"].as_str().expect("run omitted terminal id").to_string();
    assert!(created["terminal_incarnation"].as_str().is_some());
    let deadline = Instant::now() + Duration::from_secs(10);
    let resolved = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id":2,"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if resolved["lifecycle"] == "exited" {
            break resolved;
        }
        assert!(Instant::now() < deadline, "short-lived terminal did not exit: {resolved}");
        std::thread::sleep(Duration::from_millis(10));
    };
    assert_eq!(resolved["surface"], serde_json::Value::Null);
    assert_eq!(resolved["lifecycle"], "exited");
    assert_eq!(resolved["exit"]["outcome"], serde_json::json!({"kind":"exit","code":23}));
    assert!(resolved["exit"]["exited_at"].as_str().is_some());
    assert!(resolved["exit"]["revision"].as_str().is_some());
}

#[test]
fn short_lived_resource_terminal_journals_initial_output_after_its_topology() {
    let harness = RecoveryHarness::start_with_host_ready_delay("journal-initial-output", 250);
    let marker = format!("fast-journal-marker-{}", std::process::id());
    let created = resource_request(
        &harness.socket,
        "journal-initial-workspace",
        "workspace.create",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "name":"Journal initial output",
            "initial_content":"empty",
        }),
        Some("journal-initial-workspace"),
    );
    let workspace = created["value"]["workspace_id"].as_str().unwrap();
    let run = resource_request(
        &harness.socket,
        "journal-initial-run",
        "workspace.run",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "workspace":workspace,
            "argv":["/bin/sh","-c",format!("printf '{marker}\\n'")],
        }),
        Some("journal-initial-run"),
    );
    let path = &run["value"];
    let terminal = path["terminal_id"].as_str().unwrap();
    resource_request(
        &harness.socket,
        "journal-initial-wait",
        "terminal.wait_exit",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "terminal":terminal,
            "timeout_ms":"5000",
        }),
        None,
    );

    let stream = transport::connect(&harness.socket).unwrap();
    stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(
        writer,
        "{}",
        serde_json::json!({
            "protocol":"cmux.protocol/2",
            "type":"request",
            "id":"journal-initial-subscribe",
            "operation":"session.journal.subscribe",
            "params":{
                "machine":"current",
                "session":"current",
                "stream_id":"stream_11111111111141118111111111111111",
                "start":"beginning",
                "filter":{
                    "kinds":["workspace.run","terminal.output","terminal.exited"],
                    "subjects":[{"kind":"terminal","id":terminal}],
                    "max_sensitivity":"sensitive",
                },
            },
        })
    )
    .unwrap();

    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let opened: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(opened["ok"], true, "journal subscription failed: {opened}");

    let mut run_sequence = None;
    let mut output_sequence = None;
    let mut exit_sequence = None;
    while exit_sequence.is_none() {
        line.clear();
        reader.read_line(&mut line).expect("journal stream omitted short-lived terminal output");
        let envelope: serde_json::Value = serde_json::from_str(&line).unwrap();
        let record = &envelope["item"];
        let sequence = record["sequence"].as_str().unwrap().parse::<u64>().unwrap();
        match record["kind"].as_str().unwrap() {
            "workspace.run" => run_sequence = Some(sequence),
            "terminal.output" => {
                let bytes = base64::engine::general_purpose::STANDARD
                    .decode(record["payload"]["data"].as_str().unwrap())
                    .unwrap();
                assert!(
                    bytes.windows(marker.len()).any(|window| window == marker.as_bytes()),
                    "journal output omitted marker: {:?}",
                    String::from_utf8_lossy(&bytes)
                );
                for (kind, id) in [
                    ("terminal", terminal),
                    ("tab", path["tab_id"].as_str().unwrap()),
                    ("pane", path["pane_id"].as_str().unwrap()),
                    ("screen", path["screen_id"].as_str().unwrap()),
                    ("workspace", path["workspace_id"].as_str().unwrap()),
                ] {
                    assert!(
                        record["subjects"].as_array().unwrap().iter().any(|subject| {
                            subject["kind"].as_str() == Some(kind)
                                && subject["id"].as_str() == Some(id)
                        }),
                        "terminal output omitted {kind}:{id}: {record}"
                    );
                }
                output_sequence = Some(sequence);
            }
            "terminal.exited" => exit_sequence = Some(sequence),
            other => panic!("unexpected journal record {other}: {record}"),
        }
    }
    assert!(
        run_sequence < output_sequence && output_sequence < exit_sequence,
        "journal order was run={run_sequence:?}, output={output_sequence:?}, exit={exit_sequence:?}"
    );
}

#[test]
fn hosted_exit_detaches_existing_and_later_render_streams() {
    let harness = RecoveryHarness::start("hosted-exit-detaches-render");
    let marker = format!("hosted-exit-marker-{}", std::process::id());
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": [
                "/bin/sh",
                "-c",
                format!("IFS= read -r trigger; printf '{marker}\\n'"),
            ],
            "new_workspace": true,
            "name": "hosted-exit-detach",
        }),
    );
    let surface = created["surface"].as_u64().expect("hosted command returned a surface");

    let attached = transport::connect(&harness.socket).unwrap();
    attached.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut attached_writer = attached.try_clone_box().unwrap();
    let mut attached_reader = BufReader::new(attached);
    writeln!(
        attached_writer,
        "{}",
        serde_json::json!({
            "id": 2,
            "cmd": "attach-surface",
            "surface": surface,
            "mode": "render",
        })
    )
    .unwrap();
    wait_for_attach_response(&mut attached_reader, 2);

    request(
        &harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "send",
            "surface": surface,
            "text": "go\n",
        }),
    );
    wait_for_render_text_then_detached(&mut attached_reader, surface, &marker);

    let later = transport::connect(&harness.socket).unwrap();
    later.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut later_writer = later.try_clone_box().unwrap();
    let mut later_reader = BufReader::new(later);
    writeln!(
        later_writer,
        "{}",
        serde_json::json!({
            "id": 4,
            "cmd": "attach-surface",
            "surface": surface,
            "mode": "render",
        })
    )
    .unwrap();
    loop {
        let mut line = String::new();
        later_reader.read_line(&mut line).expect("later attach stream closed before response");
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        if value["id"] == 4 {
            assert_eq!(value["ok"], false, "later attach unexpectedly succeeded: {value}");
            assert!(value["error"].as_str().unwrap().contains("unknown surface"));
            break;
        }
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
    let mut host = adopt_terminal_host(record, record_path.clone()).unwrap();
    let exit = host.terminate_and_wait_for_exit().unwrap();
    host.disconnect();
    assert!(
        acknowledge_terminal_host_exit_record(&record_path.with_extension("exit"), &exit).unwrap(),
        "terminated host exit receipt was not acknowledged"
    );
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

    wait_for_terminal_host_dead(&record_path, &record);
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
    let mut host = adopt_terminal_host(record.clone(), record_path.clone()).unwrap();
    let shell_pid = host.snapshot.pid.unwrap() as libc::pid_t;
    host.terminate().unwrap();
    host.disconnect();
    wait_for_no_host_records(&harness.host_root());
    wait_for_terminal_host_dead(&record_path, &record);
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
    let mut host = adopt_terminal_host(record.clone(), record_path.clone()).unwrap();
    host.terminate().unwrap();
    host.disconnect();
    wait_for_no_host_records(&harness.host_root());
    wait_for_terminal_host_dead(&record_path, &record);
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
fn c1_output_is_normalized_once_before_host_and_frontend_mirrors_observe_it() {
    let harness = RecoveryHarness::start("c1-normalized-output");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": [
                "/bin/sh",
                "-c",
                concat!(
                    "sleep 1; ",
                    "printf '\\302'; sleep 0.1; ",
                    "printf '\\235UTF8-continued '; sleep 0.1; ",
                    "printf '\\2354;9;#090909'; sleep 0.1; ",
                    "printf '\\234VISIBLE'; sleep 30",
                ),
            ],
            "new_workspace": true,
            "name": "c1-normalized-output",
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let (_, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let mut renderer = connect_host_detailed(
        &record.endpoint,
        &record.terminal_id,
        &record.owner_token,
        ClientRole::Admin,
        CapabilityRights::ADMIN,
    )
    .unwrap();
    renderer.stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();

    let mut output = Vec::new();
    let mut awaiting_colors = false;
    let mut saw_palette = false;
    let deadline = Instant::now() + Duration::from_secs(10);
    while Instant::now() < deadline
        && (!contains_bytes(&output, b"VISIBLE") || awaiting_colors || !saw_palette)
    {
        let frame = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD)
            .expect("read normalized terminal-host frame")
            .expect("terminal host closed before normalized output");
        assert_eq!(frame.request_id, 0);
        assert_eq!(frame.sequence, renderer.next_sequence);
        renderer.next_sequence = renderer.next_sequence.wrapping_add(1);
        match frame.kind {
            MessageKind::Output => {
                assert!(!awaiting_colors, "Output split a coupled color transition");
                output.extend_from_slice(&frame.payload);
                awaiting_colors = match frame.flags {
                    0 => false,
                    FLAG_COLORS_FOLLOW => true,
                    flags => panic!("unexpected Output flags {flags:#x}"),
                };
            }
            MessageKind::Colors => {
                assert!(awaiting_colors, "unpaired Colors frame");
                assert_eq!(frame.flags, 0);
                let colors = decode_terminal_color_overrides(&frame.payload).unwrap();
                saw_palette |= colors.palette[9] == Some(Rgb { r: 9, g: 9, b: 9 });
                awaiting_colors = false;
            }
            MessageKind::Exit => panic!("terminal exited before C1 verification"),
            _ => assert!(!awaiting_colors, "metadata split a coupled color transition"),
        }
    }

    let expected = b"\xc2\x9dUTF8-continued \x1b]4;9;#090909\x1b\\VISIBLE";
    assert!(contains_bytes(&output, expected), "host emitted divergent C1 bytes: {output:?}");
    assert!(!contains_bytes(&output, b"\x9d4;9;#090909"));
    assert!(!contains_bytes(&output, b"\x9cVISIBLE"));
    assert!(saw_palette, "normalized OSC did not publish its sparse palette state");

    let screen = wait_for_screen(&harness.socket, surface, "VISIBLE");
    assert!(screen.contains("VISIBLE"));
    let state = attach_state(&harness.socket, surface);
    assert_eq!(state["colors"]["palette"]["9"], "#090909");

    close_terminal_surface(&harness.socket, surface, 2);
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn cleared_history_stays_cleared_after_daemon_reconnect() {
    let mut harness = RecoveryHarness::start("clear-history-reconnect");
    let history = format!("history-before-clear-{}", std::process::id());
    let pending = format!("typed-input-{}", std::process::id());
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": [
                "/bin/sh",
                "-c",
                concat!(
                    "i=0; while [ \"$i\" -lt 40 ]; do ",
                    "printf '%s-%02d\\r\\n' \"$1\" \"$i\"; i=$((i + 1)); done; ",
                    "printf '\\033]133;A\\007prompt> \\033]133;B\\007%s' \"$2\"; sleep 30",
                ),
                "cmux-clear-history",
                &history,
                &pending,
            ],
            "new_workspace": true,
            "name": "clear-history-survivor",
            "cols": 80,
            "rows": 8,
        }),
    );
    let original_surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    let prompt = format!("prompt> {pending}");
    assert!(wait_for_screen(&harness.socket, original_surface, &prompt).contains(&prompt));
    let before = request(
        &harness.socket,
        serde_json::json!({"id": 2, "cmd": "copy", "surface": original_surface, "mode": "scrollback"}),
    );
    assert!(before["text"].as_str().unwrap().contains(&history));
    let records = wait_for_host_records(&harness.host_root(), 1);
    assert!(records[0].1.supports_clear_history);

    let host_pid = records[0].1.host_pid as libc::pid_t;
    // SAFETY: the durable record identifies this harness's live terminal host.
    assert_eq!(unsafe { libc::kill(host_pid, libc::SIGSTOP) }, 0);
    std::thread::sleep(Duration::from_millis(50));
    let resume_host = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(250));
        // SAFETY: this resumes the same host stopped immediately above.
        assert_eq!(unsafe { libc::kill(host_pid, libc::SIGCONT) }, 0);
    });
    let clear_started = Instant::now();
    request(
        &harness.socket,
        serde_json::json!({"id": 3, "cmd": "clear-history", "surface": original_surface}),
    );
    let clear_elapsed = clear_started.elapsed();
    resume_host.join().unwrap();
    assert!(
        clear_elapsed >= Duration::from_millis(150),
        "clear-history returned before the stopped host applied it: {clear_elapsed:?}"
    );
    let screen = request(
        &harness.socket,
        serde_json::json!({"id": 4, "cmd": "read-screen", "surface": original_surface}),
    )["text"]
        .as_str()
        .unwrap()
        .to_string();
    let scrollback = request(
        &harness.socket,
        serde_json::json!({
            "id": 5,
            "cmd": "copy",
            "surface": original_surface,
            "mode": "scrollback",
        }),
    )["text"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(screen.contains(&prompt));
    assert!(!screen.contains(&history));
    assert!(!scrollback.contains(&history));

    harness.sigkill();
    harness.restart();
    let deadline = Instant::now() + Duration::from_secs(15);
    let adopted_surface = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({
                "id": 6,
                "cmd": "resolve-terminal",
                "terminal_id": &terminal_id,
            }),
        );
        if resolved["lifecycle"] == "running"
            && resolved["terminal_incarnation"].as_str() == Some(incarnation.as_str())
            && let Some(surface) = resolved["surface"].as_u64()
        {
            break surface;
        }
        assert!(Instant::now() < deadline, "replacement daemon did not adopt cleared terminal");
        std::thread::sleep(Duration::from_millis(50));
    };
    let replay = wait_for_screen(&harness.socket, adopted_surface, &prompt);
    assert!(replay.contains(&prompt));
    assert!(!replay.contains(&history), "cleared visible history returned after adoption");
    let recovered = request(
        &harness.socket,
        serde_json::json!({
            "id": 7,
            "cmd": "copy",
            "surface": adopted_surface,
            "mode": "scrollback",
        }),
    );
    assert!(
        !recovered["text"].as_str().unwrap().contains(&history),
        "cleared scrollback returned after adoption"
    );

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
fn hosted_clear_history_encodes_fallback_from_authoritative_keyboard_mode() {
    let harness = RecoveryHarness::start("clear-history-fallback");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": [
                "/bin/sh",
                "-c",
                "stty raw -echo; printf '\\033[?1049h\\033[>1uready'; exec cat",
            ],
            "new_workspace": true,
            "name": "clear-history-fallback",
            "cols": 80,
            "rows": 8,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    assert!(wait_for_screen(&harness.socket, surface, "ready").contains("ready"));
    let (_, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    assert!(record.supports_clear_history);
    let mut observer = connect_host_detailed(
        &record.endpoint,
        &record.terminal_id,
        &record.owner_token,
        ClientRole::Admin,
        CapabilityRights::ADMIN,
    )
    .unwrap();
    observer.stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();

    request(
        &harness.socket,
        serde_json::json!({
            "id": 2,
            "cmd": "clear-history",
            "surface": surface,
            "fallback_key": {
                "key": "k",
                "mods": {
                    "shift": false,
                    "control": false,
                    "alt": false,
                    "super": true,
                    "caps_lock": false,
                    "num_lock": false,
                },
                "consumed_mods": {
                    "shift": false,
                    "control": false,
                    "alt": false,
                    "super": false,
                    "caps_lock": false,
                    "num_lock": false,
                },
                "utf8": "",
                "unshifted_codepoint": "k",
                "action": "press",
                "macos_option_as_alt": true,
            },
        }),
    );
    let expected = b"\x1b[107;9u";
    loop {
        let frame = read_frame(&mut observer.stream, MAX_FRAME_PAYLOAD)
            .expect("read clear-history fallback output")
            .expect("host closed before clear-history fallback output");
        if frame.request_id == 0 {
            assert_eq!(frame.sequence, observer.next_sequence);
            observer.next_sequence = observer.next_sequence.wrapping_add(1);
        }
        if frame.kind == MessageKind::Output && contains_bytes(&frame.payload, expected) {
            break;
        }
    }

    close_terminal_surface(&harness.socket, surface, 3);
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn adopted_legacy_host_rejects_clear_history_fallback() {
    let mut harness = RecoveryHarness::start("legacy-clear-history-fallback");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": [
                "/bin/sh",
                "-c",
                "stty raw -echo; printf '\\033[?1049hready'; exec cat",
            ],
            "new_workspace": true,
            "name": "legacy-clear-history-fallback",
            "cols": 80,
            "rows": 8,
        }),
    );
    let original_surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    assert!(wait_for_screen(&harness.socket, original_surface, "ready").contains("ready"));
    let (record_path, mut record) = wait_for_host_records(&harness.host_root(), 1).remove(0);

    harness.sigkill();
    record.supports_clear_history = false;
    fs::write(&record_path, serde_json::to_vec(&record).unwrap()).unwrap();
    harness.restart();
    let deadline = Instant::now() + Duration::from_secs(15);
    let adopted_surface = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({
                "id": 2,
                "cmd": "resolve-terminal",
                "terminal_id": &terminal_id,
            }),
        );
        if resolved["lifecycle"] == "running"
            && resolved["terminal_incarnation"].as_str() == Some(incarnation.as_str())
            && let Some(surface) = resolved["surface"].as_u64()
        {
            break surface;
        }
        assert!(Instant::now() < deadline, "replacement daemon did not adopt legacy host");
        std::thread::sleep(Duration::from_millis(50));
    };
    assert!(wait_for_screen(&harness.socket, adopted_surface, "ready").contains("ready"));

    let tree = request(&harness.socket, serde_json::json!({"id": 3, "cmd": "list-workspaces"}));
    let adopted_tab = tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .find(|tab| tab["surface"].as_u64() == Some(adopted_surface))
        .expect("adopted terminal missing from workspace tree");
    assert_eq!(
        adopted_tab["supports_clear_history_key_fallback"].as_bool(),
        Some(false),
        "legacy terminal host was advertised as safe for atomic clear-history fallback"
    );

    let unsupported = request_response(
        &harness.socket,
        serde_json::json!({
            "id": 4,
            "cmd": "clear-history",
            "surface": adopted_surface,
            "fallback_key": {
                "key": "z",
                "mods": {
                    "shift": false,
                    "control": false,
                    "alt": false,
                    "super": false,
                    "caps_lock": false,
                    "num_lock": false,
                },
                "consumed_mods": {
                    "shift": false,
                    "control": false,
                    "alt": false,
                    "super": false,
                    "caps_lock": false,
                    "num_lock": false,
                },
                "utf8": "z",
                "unshifted_codepoint": "z",
                "action": "press",
                "macos_option_as_alt": true,
            },
        }),
    );
    assert_eq!(unsupported["ok"], false, "legacy host fallback was silently accepted");
    assert!(
        unsupported["error"].as_str().unwrap().contains("does not support clear-history"),
        "unexpected rejection: {unsupported}"
    );
    std::thread::sleep(Duration::from_millis(100));
    let screen = request(
        &harness.socket,
        serde_json::json!({"id": 5, "cmd": "read-screen", "surface": adopted_surface}),
    )["text"]
        .as_str()
        .unwrap()
        .to_string();
    assert!(screen.contains("ready"));
    assert!(!screen.contains("readyz"), "fallback key reached legacy host: {screen:?}");

    request(
        &harness.socket,
        serde_json::json!({
            "id": 6,
            "cmd": "close-terminal",
            "terminal_id": terminal_id,
            "terminal_incarnation": incarnation,
        }),
    );
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn existing_host_defaults_survive_output_resize_and_renderer_reconnects() {
    let harness = RecoveryHarness::start("live-default-update");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": ["/bin/cat"],
            "new_workspace": true,
            "cols": 80,
            "rows": 24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let (_, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    assert!(record.supports_set_defaults);
    // Ghostty's application default differs intentionally from the raw VT
    // library default: an absent cursor-style-blink starts blinking while
    // remaining controllable by DEC mode 12.
    let builtin_cursor = (ghostty_vt::CursorShape::Block, true);

    request(
        &harness.socket,
        serde_json::json!({
            "id": 2,
            "cmd": "set-default-colors",
            "complete": true,
            "fg": "#010203",
            "bg": "#040506",
            "cursor": "#070809",
            "selection_bg": "#101112",
            "selection_fg": "#131415",
            "cursor_style": "bar",
            "cursor_blink": false,
            "palette": {"9": "#161718", "255": "#191a1b"},
        }),
    );
    let state = wait_for_cursor_visual(&harness.socket, surface, "bar", false);
    assert_eq!(state["colors"]["fg"], "#010203");
    assert_eq!(state["colors"]["bg"], "#040506");
    assert_eq!(state["colors"]["cursor"], "#070809");
    assert_eq!(state["colors"]["selection_bg"], "#101112");
    assert_eq!(state["colors"]["selection_fg"], "#131415");
    wait_for_host_cursor_snapshot(&record, ghostty_vt::CursorShape::Bar, false);

    let marker = format!("defaults-after-output-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({"id": 3, "cmd": "send", "surface": surface, "text": format!("{marker}\n")}),
    );
    assert!(wait_for_screen(&harness.socket, surface, &marker).contains(&marker));
    wait_for_host_cursor_snapshot(&record, ghostty_vt::CursorShape::Bar, false);

    attach_claim_and_resize_surface(&harness.socket, surface, 101, 37, 4);
    wait_for_host_size(&harness.host_root(), 101, 37);
    wait_for_vt_size(&harness.socket, surface, 101, 37);
    wait_for_host_cursor_snapshot(&record, ghostty_vt::CursorShape::Bar, false);

    // Complete replacement must also clear prior explicit embedder defaults;
    // sparse setters intentionally cannot represent this transition.
    request(
        &harness.socket,
        serde_json::json!({
            "id": 5,
            "cmd": "set-default-colors",
            "complete": true,
            "palette": {},
        }),
    );
    let builtin_style = match builtin_cursor.0 {
        ghostty_vt::CursorShape::Bar => "bar",
        ghostty_vt::CursorShape::Underline => "underline",
        ghostty_vt::CursorShape::Block | ghostty_vt::CursorShape::BlockHollow => "block",
    };
    let reset_state =
        wait_for_cursor_visual(&harness.socket, surface, builtin_style, builtin_cursor.1);
    for channel in ["fg", "bg", "cursor", "selection_bg", "selection_fg"] {
        assert!(reset_state["colors"][channel].is_null(), "{channel} default did not clear");
    }
    wait_for_host_cursor_snapshot(&record, builtin_cursor.0, builtin_cursor.1);

    attach_claim_and_resize_surface(&harness.socket, surface, 99, 35, 6);
    wait_for_host_size(&harness.host_root(), 99, 35);
    wait_for_host_cursor_snapshot(&record, builtin_cursor.0, builtin_cursor.1);

    close_terminal_surface(&harness.socket, surface, 7);
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
    close_terminal_surface(&harness.socket, surface, 2);
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
    let initial_colors = renderer.colors.clone();
    assert!(initial_colors.cursor_visual.is_some(), "v2 snapshot omitted resolved cursor");
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
            cursor_visual: Some((ghostty_vt::CursorShape::Bar, true)),
            ..Default::default()
        };
        colors.palette[3] = Some(Rgb { r: 1, g: 2, b: 3 });
        colors
    };
    write_frame(
        &mut renderer.stream,
        &Frame::new(
            MessageKind::Input,
            b"\x1b]4;3;#010203\x07\x1b]10;#111213\x07\x1b]11;#212223\x07\x1b]12;#313233\x07\x1b[5 q\n"
                .to_vec(),
        ),
    )
    .unwrap();
    renderer.wait_for_colors(&expected_colors);
    let state = wait_for_cursor_visual(&harness.socket, original_surface, "bar", true);
    assert_eq!(state["colors"]["cursor_style"], "bar");
    assert_eq!(state["colors"]["cursor_blink"], true);

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
            b"\x1b]104;3\x07\x1b]110\x07\x1b]111\x07\x1b]112\x07\x1b[0 q\n".to_vec(),
        ),
    )
    .unwrap();
    renderer.wait_for_colors(&initial_colors);
    let mut reconnect_colors = initial_colors.clone();
    reconnect_colors.cursor_visual = Some((ghostty_vt::CursorShape::Block, true));
    write_frame(&mut renderer.stream, &Frame::new(MessageKind::Input, b"\x1b[1 q\n".to_vec()))
        .unwrap();
    renderer.wait_for_colors(&reconnect_colors);
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
    let state = wait_for_cursor_visual(&harness.socket, adopted_surface, "block", true);
    assert_eq!(state["colors"]["cursor_style"], "block");
    assert_eq!(state["colors"]["cursor_blink"], true);
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

    attach_claim_and_resize_surface(&harness.socket, adopted_surface, 101, 37, 6);
    let state = wait_for_vt_size(&harness.socket, adopted_surface, 101, 37);
    assert_eq!(state["cols"].as_u64(), Some(101));
    assert_eq!(state["rows"].as_u64(), Some(37));
    let cursor_state = wait_for_cursor_visual(&harness.socket, adopted_surface, "block", true);
    assert_eq!(cursor_state["colors"]["cursor_style"], "block");
    assert_eq!(cursor_state["colors"]["cursor_blink"], true);
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
    let cursor_state = wait_for_cursor_visual(&harness.socket, resized_surface, "block", true);
    assert_eq!(cursor_state["colors"]["cursor_style"], "block");
    assert_eq!(cursor_state["colors"]["cursor_blink"], true);
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
fn adoption_topology_failures_retry_same_host_without_exited_transition() {
    let mut harness = RecoveryHarness::start("retry-adopt-topology");
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
    let incarnation = created["terminal_incarnation"].as_str().unwrap().to_string();
    let before_revision = request(
        &harness.socket,
        serde_json::json!({"id":2,"cmd":"list-terminals"}),
    )["terminal_revision"]
        .as_u64()
        .unwrap();
    let before = wait_for_host_records(&harness.host_root(), 1).remove(0).1;

    harness.sigkill();
    harness.adoption_insert_failures = Some(3);
    harness.restart();

    let pending = request(
        &harness.socket,
        serde_json::json!({"id":3,"cmd":"resolve-terminal","terminal_id":terminal_id}),
    );
    assert_eq!(pending["lifecycle"], "adopting");
    assert_eq!(pending["surface"], serde_json::Value::Null);

    let deadline = Instant::now() + Duration::from_secs(15);
    let surface = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id":4,"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if resolved["lifecycle"] == "running"
            && let Some(surface) = resolved["surface"].as_u64()
        {
            assert_eq!(resolved["terminal_incarnation"], incarnation);
            break surface;
        }
        assert!(Instant::now() < deadline, "terminal never recovered from topology failures");
        std::thread::sleep(Duration::from_millis(25));
    };

    let after = wait_for_host_records(&harness.host_root(), 1).remove(0).1;
    assert_eq!(after.host_pid, before.host_pid);
    assert_eq!(after.host_start_nonce, before.host_start_nonce);
    assert_eq!(after.incarnation, before.incarnation);
    let lifecycle_events = request(
        &harness.socket,
        serde_json::json!({
            "id":5,"cmd":"terminal-events","after_revision":before_revision,
        }),
    );
    let kinds = lifecycle_events["events"]
        .as_array()
        .unwrap()
        .iter()
        .map(|event| event["kind"].as_str().unwrap())
        .collect::<Vec<_>>();
    assert_eq!(kinds, vec!["terminal-adopting", "terminal-ready"]);

    let marker = format!("topology-retry-survivor-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({"id":6,"cmd":"send","surface":surface,"text":format!("{marker}\n")}),
    );
    assert!(wait_for_screen(&harness.socket, surface, &marker).contains(&marker));
    request(
        &harness.socket,
        serde_json::json!({
            "id":7,"cmd":"close-terminal","terminal_id":terminal_id,
            "terminal_incarnation":incarnation,
        }),
    );
    wait_for_no_host_records(&harness.host_root());
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
fn client_reserved_short_lived_create_replays_its_durable_exit_without_topology() {
    let harness = RecoveryHarness::start("reserved-short-lived-create");
    let workspace = request(
        &harness.socket,
        serde_json::json!({
            "id":1,
            "cmd":"create-workspace",
            "name":"Short-lived",
            "key":"018f6e21-7b70-7e70-8000-000000000046",
            "origin":"browser",
            "mutation_id":"workspace-create",
            "expected_revision":0,
        }),
    );
    let terminal_id = TerminalId::random().unwrap().to_hex();
    let create = serde_json::json!({
        "id":2,
        "cmd":"create-terminal",
        "key":"018f6e21-7b70-7e70-8000-000000000046",
        "argv":["/bin/sh","-c","exit 17"],
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
    let already_exited = first["already_exited"].as_bool().unwrap();
    assert_eq!(first["lifecycle"], if already_exited { "exited" } else { "running" });
    for field in ["surface", "pane", "screen", "workspace"] {
        assert_eq!(first[field].is_null(), already_exited, "unexpected {field}: {first}");
    }
    if already_exited {
        assert_eq!(first["exit"]["outcome"], serde_json::json!({"kind":"exit","code":17}));
    } else {
        assert!(first["exit"].is_null());
    }
    wait_for_no_host_records(&harness.host_root());

    let retry = request(&harness.socket, create);
    assert_eq!(retry["replayed"], true);
    assert_eq!(retry["terminal_id"], terminal_id);
    assert_eq!(retry["already_exited"], true);
    assert_eq!(retry["lifecycle"], "exited");
    assert_eq!(retry["exit"]["outcome"], serde_json::json!({"kind":"exit","code":17}));
    assert_eq!(retry["surface"], serde_json::Value::Null);
    assert_eq!(retry["pane"], serde_json::Value::Null);
    assert_eq!(retry["screen"], serde_json::Value::Null);
    assert_eq!(retry["workspace"], serde_json::Value::Null);
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
    let stalled = connect_host_detailed(
        grant["endpoint"].as_str().unwrap(),
        grant["terminal_id"].as_str().unwrap(),
        grant["token"].as_str().unwrap(),
        ClientRole::Renderer,
        CapabilityRights::RENDERER,
    )
    .unwrap();

    request(
        &harness.socket,
        serde_json::json!({
            "id": 3,
            "cmd": "send",
            "surface": surface,
            // A finite burst can fit in Darwin's dynamically sized socket
            // buffers under some scheduler interleavings. One streaming
            // process fills the bounded host tap without per-megabyte process
            // launches competing with the parallel recovery suite.
            "text": "/bin/cat /dev/zero\n",
        }),
    );
    assert!(
        wait_for_socket_hangup(&stalled.stream, Duration::from_secs(15)),
        "stalled renderer silently froze instead of being disconnected"
    );

    request(
        &harness.socket,
        serde_json::json!({"id": 31, "cmd": "send", "surface": surface, "text": "\u{3}"}),
    );
    std::thread::sleep(Duration::from_millis(50));

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

    close_terminal_surface(&harness.socket, surface, 5);
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
    let resolved = wait_for_terminal_lifecycle(&harness.socket, &terminal_id, "running");
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
    close_terminal_surface(&harness.socket, surface, 4);
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn failed_reconnect_completion_disconnects_and_retries_without_freezing() {
    let harness = RecoveryHarness::start_with_reconnect_completion_failures("completion-retry", 1);
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
        request(&harness.socket, serde_json::json!({"id":2,"cmd":"list-terminals"}));
    let before_revision = terminal_snapshot["terminal_revision"].as_u64().unwrap();

    let deadline = Instant::now() + Duration::from_secs(15);
    let kinds = loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id":3,"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        let lifecycle_events = request(
            &harness.socket,
            serde_json::json!({
                "id":4,"cmd":"terminal-events","after_revision":before_revision,
            }),
        );
        let kinds = lifecycle_events["events"]
            .as_array()
            .unwrap()
            .iter()
            .map(|event| event["kind"].as_str().unwrap().to_string())
            .collect::<Vec<_>>();
        let adopting = kinds.iter().filter(|kind| kind.as_str() == "terminal-adopting").count();
        let ready = kinds.iter().filter(|kind| kind.as_str() == "terminal-ready").count();
        if resolved["lifecycle"] == "running" && adopting == 2 && ready == 2 {
            assert_eq!(resolved["terminal_incarnation"], incarnation);
            break kinds;
        }
        assert!(
            Instant::now() < deadline,
            "terminal never completed its reconnect retry: lifecycle={}, events={kinds:?}",
            resolved["lifecycle"]
        );
        std::thread::sleep(Duration::from_millis(25));
    };
    assert_eq!(kinds.iter().filter(|kind| kind.as_str() == "terminal-adopting").count(), 2);
    assert_eq!(kinds.iter().filter(|kind| kind.as_str() == "terminal-ready").count(), 2);

    let marker = format!("completion-retry-live-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({
            "id":5,"cmd":"send","surface":surface,"text":format!("printf '{marker}\\n'\n"),
        }),
    );
    assert!(wait_for_screen(&harness.socket, surface, &marker).contains(&marker));
    let after_record = wait_for_host_records(&harness.host_root(), 1).remove(0).1;
    assert_eq!(after_record.host_pid, before_record.host_pid);
    assert_eq!(after_record.host_start_nonce, before_record.host_start_nonce);
    assert_eq!(after_record.incarnation, before_record.incarnation);

    close_terminal_surface(&harness.socket, surface, 6);
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn failed_terminate_and_rejected_resize_leave_live_record_discoverable() {
    let harness = RecoveryHarness::start("failed-control");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id":1,"cmd":"run","argv":[
                "/bin/sh", "-c",
                "stty raw -echo; printf 'CURSOR-ACTIVITY-READY'; exec /bin/cat"
            ],"new_workspace":true,
            "cols":80,"rows":24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    assert!(
        wait_for_screen(&harness.socket, surface, "CURSOR-ACTIVITY-READY")
            .contains("CURSOR-ACTIVITY-READY")
    );
    let (record_path, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);

    let mut disconnected = adopt_terminal_host(record.clone(), record_path.clone()).unwrap();
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
    let default_cursor_colors = renderer.colors.clone();
    let hybrid_cursor = TerminalColorOverrides {
        cursor_visual: Some((ghostty_vt::CursorShape::Bar, false)),
        ..Default::default()
    };
    write_frame(
        &mut renderer.stream,
        &Frame::new(
            MessageKind::Input,
            b"\x1b[6 q\x1b[?1049h\x1b[3 q\x1b[?12l\x1b[?1049l\n".to_vec(),
        ),
    )
    .unwrap();
    renderer.wait_for_colors(&hybrid_cursor);
    let state = wait_for_cursor_visual(&harness.socket, surface, "bar", false);
    assert_eq!(state["colors"]["cursor_style"], "bar");
    assert_eq!(state["colors"]["cursor_blink"], false);

    let cursor_colors = TerminalColorOverrides {
        cursor_visual: Some((ghostty_vt::CursorShape::Underline, true)),
        ..Default::default()
    };
    write_frame(&mut renderer.stream, &Frame::new(MessageKind::Input, b"\x1b[3 q\n".to_vec()))
        .unwrap();
    renderer.wait_for_colors(&cursor_colors);

    write_frame(
        &mut renderer.stream,
        &Frame::new(MessageKind::Input, b"\x1b[?1049h\x1b[?1049l".to_vec()),
    )
    .unwrap();
    renderer.wait_for_colors(&cursor_colors);

    for sequence in [b"\x1b[0 q".as_slice(), b"\x1b[0 q", b"\x1bc", b"\x1bc"] {
        write_frame(&mut renderer.stream, &Frame::new(MessageKind::Input, sequence.to_vec()))
            .unwrap();
        renderer.wait_for_colors(&default_cursor_colors);
    }
    write_frame(&mut renderer.stream, &Frame::new(MessageKind::Input, b"\x1b[3 q".to_vec()))
        .unwrap();
    renderer.wait_for_colors(&cursor_colors);

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
    let alias_count_offset = 8 + replay_len;
    assert_eq!(resized.payload.len(), alias_count_offset + 6 + KITTY_REPLAY_STATE_ENCODED_LEN);
    assert_eq!(&resized.payload[alias_count_offset..alias_count_offset + 2], &0u16.to_le_bytes());
    assert_eq!(&resized.payload[alias_count_offset + 2..alias_count_offset + 6], &[8, 0, 16, 0]);
    let colors = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(colors.sequence, renderer.next_sequence);
    renderer.next_sequence = renderer.next_sequence.wrapping_add(1);
    assert_eq!(colors.kind, MessageKind::Colors);
    assert_eq!(colors.flags, 0);
    assert_eq!(decode_terminal_color_overrides(&colors.payload).unwrap(), cursor_colors);

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
    let cursor_state = wait_for_cursor_visual(&harness.socket, surface, "underline", true);
    assert_eq!(cursor_state["colors"]["cursor_style"], "underline");
    assert_eq!(cursor_state["colors"]["cursor_blink"], true);
    assert!(record_path.exists());

    let marker = format!("after-failed-controls-{}", std::process::id());
    request(
        &harness.socket,
        serde_json::json!({
            "id":4,"cmd":"send","surface":surface,"text":format!("{marker}\\n"),
        }),
    );
    assert!(wait_for_screen(&harness.socket, surface, &marker).contains(&marker));
    close_terminal_surface(&harness.socket, surface, 5);
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn direct_renderer_geometry_ignores_passive_control_viewers() {
    let harness = RecoveryHarness::start("renderer-sole-viewer");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,
            "cols":80,"rows":24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let metrics = request(
        &harness.socket,
        serde_json::json!({
            "id":2,"cmd":"set-cell-pixels","width_px":9,"height_px":18,
        }),
    );
    assert_eq!(metrics["failures"], serde_json::json!([]));
    let grant = request(
        &harness.socket,
        serde_json::json!({
            "id":3,"cmd":"mint-terminal-renderer","surface":surface,"ttl_ms":10_000,
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
    assert_eq!(resize_cell_pixels(&resized.payload), (9, 18));
    let colors = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(colors.kind, MessageKind::Colors);

    let state = wait_for_vt_size(&harness.socket, surface, 120, 40);
    assert_eq!(state["cols"], 120);
    assert_eq!(state["rows"], 40);

    // A control attachment mirrors the terminal without acquiring geometry
    // authority. Its viewport must not reduce the canonical PTY grid.
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
    let resized = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(resized.kind, MessageKind::Resized);
    assert_eq!(&resized.payload[..4], &[160, 0, 50, 0]);
    let colors = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(colors.kind, MessageKind::Colors);
    let state = wait_for_vt_size(&harness.socket, surface, 160, 50);
    assert_eq!(state["cols"], 160);
    assert_eq!(state["rows"], 50);

    drop(attach_writer);
    drop(attach_reader);
    let mut final_size = Vec::new();
    final_size.extend_from_slice(&150u16.to_le_bytes());
    final_size.extend_from_slice(&45u16.to_le_bytes());
    write_frame(&mut renderer.stream, &Frame::new(MessageKind::ViewerSize, final_size)).unwrap();
    let resized = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(resized.kind, MessageKind::Resized);
    assert_eq!(&resized.payload[..4], &[150, 0, 45, 0]);
    let colors = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(colors.kind, MessageKind::Colors);
    let state = wait_for_vt_size(&harness.socket, surface, 150, 45);
    assert_eq!(state["cols"], 150);
    assert_eq!(state["rows"], 45);

    close_terminal_surface(&harness.socket, surface, 4);
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

    let mut cell_pixels = Frame::new(MessageKind::SetCellPixelSize, Vec::new());
    cell_pixels.request_id = 41;
    cell_pixels.payload.extend_from_slice(&11u16.to_le_bytes());
    cell_pixels.payload.extend_from_slice(&22u16.to_le_bytes());
    write_frame(&mut renderer.stream, &cell_pixels).unwrap();
    let resized = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(resized.kind, MessageKind::Resized);
    assert_eq!(resized.flags, FLAG_COLORS_FOLLOW);
    assert_eq!(resized.request_id, 0);
    assert_eq!(resized.sequence, renderer.next_sequence);
    renderer.next_sequence = renderer.next_sequence.wrapping_add(1);
    assert_eq!(resize_cell_pixels(&resized.payload), (11, 22));
    let colors = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(colors.kind, MessageKind::Colors);
    assert_eq!(colors.request_id, 0);
    assert_eq!(colors.sequence, renderer.next_sequence);
    renderer.next_sequence = renderer.next_sequence.wrapping_add(1);
    let ack = read_frame(&mut renderer.stream, MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(ack.kind, MessageKind::CellPixelSizeAck);
    assert_eq!(ack.request_id, 41);
    assert_eq!(ack.sequence, 0);
    assert_eq!(ack.payload, vec![11, 0, 22, 0]);

    let resnapshot_grant = request(
        &harness.socket,
        serde_json::json!({
            "id":3,"cmd":"mint-terminal-renderer","surface":surface,"ttl_ms":10_000,
        }),
    );
    let resnapshot = connect_host_detailed(
        resnapshot_grant["endpoint"].as_str().unwrap(),
        resnapshot_grant["terminal_id"].as_str().unwrap(),
        resnapshot_grant["token"].as_str().unwrap(),
        ClientRole::Renderer,
        CapabilityRights::RENDERER,
    )
    .unwrap();
    assert_eq!(
        snapshot_cell_pixels(&resnapshot.snapshot.payload),
        (11, 22),
        "a reconnect snapshot must expose the host's committed cell geometry"
    );
    drop(resnapshot);

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
    let alias_count_offset = 8 + replay_len;
    assert_eq!(resized.payload.len(), alias_count_offset + 6 + KITTY_REPLAY_STATE_ENCODED_LEN);
    assert_eq!(&resized.payload[alias_count_offset..alias_count_offset + 2], &0u16.to_le_bytes());
    assert_eq!(&resized.payload[alias_count_offset + 2..alias_count_offset + 6], &[11, 0, 22, 0]);
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

    close_terminal_surface(&harness.socket, surface, 3);
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
fn interrupted_creation_waits_for_transient_host_adoption_before_serving() {
    let mut harness = RecoveryHarness::start_with_host_ready_delay("pre-ready-retry", 2_000);
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
    let (_, record) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    let endpoint = PathBuf::from(&record.endpoint);
    let held_endpoint = endpoint.with_extension("held-for-interrupted-creation");
    let terminal_id = record.terminal_id.clone();
    let incarnation = record.incarnation.clone();
    let host_pid = record.host_pid;
    harness.sigkill();
    drop(writer);
    drop(stream);
    fs::rename(&endpoint, &held_endpoint).unwrap();
    let restore_endpoint = std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(500));
        fs::rename(held_endpoint, endpoint).unwrap();
    });
    let started = Instant::now();
    harness.restart();
    restore_endpoint.join().unwrap();
    assert!(
        started.elapsed() >= Duration::from_millis(400),
        "daemon served before interrupted host adoption settled"
    );

    let resolved = request(
        &harness.socket,
        serde_json::json!({"id":2,"cmd":"resolve-terminal","terminal_id":terminal_id}),
    );
    let surface = resolved["surface"].as_u64().expect("recovered terminal has a surface");
    assert_eq!(resolved["lifecycle"], "running");
    assert_eq!(resolved["terminal_incarnation"], incarnation);
    let adopted = wait_for_host_records(&harness.host_root(), 1).remove(0).1;
    assert_eq!(adopted.host_pid, host_pid);
    close_terminal_surface(&harness.socket, surface, 3);
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn interrupted_public_creation_publishes_once_and_replays_stable_ids_after_two_restarts() {
    let mut harness = RecoveryHarness::start_with_host_ready_delay("public-create-recovery", 2_000);
    let create = serde_json::json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":"public-create-request",
        "operation":"workspace.create",
        "idempotency_key":"public-create-attempt",
        "params":{
            "machine":"current",
            "session":"current",
            "name":"Recovered public workspace",
            "initial_content":"terminal",
            "correlation_key":"public-create-correlation",
        },
    });
    let stream = transport::connect(&harness.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    writeln!(writer, "{create}").unwrap();
    let (_, before) = wait_for_host_records(&harness.host_root(), 1).remove(0);
    harness.sigkill();
    drop(writer);
    drop(stream);
    harness.restart();

    let first_resolution = resource_request(
        &harness.socket,
        "public-create-resolution-one",
        "session.creation.resolve",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "correlation_key":"public-create-correlation",
        }),
        None,
    );
    assert_eq!(first_resolution["state"], "created");
    assert_eq!(first_resolution["revision"], "1");
    let created_path = first_resolution["created_path"].clone();
    for field in ["workspace_id", "screen_id", "pane_id", "tab_id", "terminal_id"] {
        assert!(created_path[field].as_str().is_some(), "{field}");
    }
    let first_snapshot = resource_request(
        &harness.socket,
        "public-create-snapshot-one",
        "session.snapshot",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    assert_eq!(first_snapshot["cursor"]["revision"], "1");
    assert_eq!(first_snapshot["workspaces"].as_array().unwrap().len(), 1);
    assert_eq!(first_snapshot["terminals"].as_array().unwrap().len(), 1);
    let after_first_restart = wait_for_host_records(&harness.host_root(), 1).remove(0).1;
    assert_eq!(after_first_restart.host_pid, before.host_pid);
    assert_eq!(after_first_restart.host_start_nonce, before.host_start_nonce);
    assert_eq!(after_first_restart.incarnation, before.incarnation);

    harness.sigkill();
    harness.restart();

    let second_resolution = resource_request(
        &harness.socket,
        "public-create-resolution-two",
        "session.creation.resolve",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "correlation_key":"public-create-correlation",
        }),
        None,
    );
    assert_eq!(second_resolution, first_resolution);
    let replay = resource_request(
        &harness.socket,
        "public-create-replay",
        "workspace.create",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "name":"Recovered public workspace",
            "initial_content":"terminal",
            "correlation_key":"public-create-correlation",
        }),
        Some("public-create-attempt"),
    );
    assert_eq!(replay["value"], created_path);
    assert_eq!(replay["revision"], "1");
    assert_eq!(replay["replayed"], true);
    let second_snapshot = resource_request(
        &harness.socket,
        "public-create-snapshot-two",
        "session.snapshot",
        serde_json::json!({"machine":"current","session":"current"}),
        None,
    );
    assert_eq!(second_snapshot["cursor"]["revision"], "1");
    assert_eq!(second_snapshot["workspaces"].as_array().unwrap().len(), 1);
    assert_eq!(second_snapshot["terminals"].as_array().unwrap().len(), 1);
    let after_second_restart = wait_for_host_records(&harness.host_root(), 1).remove(0).1;
    assert_eq!(after_second_restart.host_pid, before.host_pid);
    assert_eq!(after_second_restart.host_start_nonce, before.host_start_nonce);
    assert_eq!(after_second_restart.incarnation, before.incarnation);

    resource_request(
        &harness.socket,
        "public-create-close",
        "terminal.close",
        serde_json::json!({
            "machine":"current",
            "session":"current",
            "terminal":created_path["terminal_id"],
        }),
        Some("public-create-close"),
    );
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn rapid_public_create_close_acknowledges_every_exit_sidecar() {
    let harness = RecoveryHarness::start("public-create-close-stress");
    for index in 0..12 {
        let created = resource_request(
            &harness.socket,
            &format!("rapid-create-{index}"),
            "workspace.create",
            serde_json::json!({
                "machine":"current",
                "session":"current",
                "name":format!("Rapid close {index}"),
                "initial_content":"terminal",
                "correlation_key":format!("rapid-close-{index}"),
            }),
            Some(&format!("rapid-create-{index}")),
        );
        resource_request(
            &harness.socket,
            &format!("rapid-close-{index}"),
            "terminal.close",
            serde_json::json!({
                "machine":"current",
                "session":"current",
                "terminal":created["value"]["terminal_id"],
            }),
            Some(&format!("rapid-close-{index}")),
        );
    }
    wait_for_no_host_records(&harness.host_root());
}

#[test]
fn ctrl_d_exits_shell_and_detaches_terminal_topology() {
    let harness = RecoveryHarness::start("ctrl-d-exit");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id":1,"cmd":"run","argv":["/bin/sh","-i"],"new_workspace":true,
            "cols":80,"rows":24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
    let terminal_id = created["terminal_id"].as_str().unwrap().to_string();
    let workspace_id = created["workspace"].as_u64().unwrap();

    request(
        &harness.socket,
        serde_json::json!({"id":2,"cmd":"send-key","surface":surface,"keys":["ctrl+d"]}),
    );

    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id":3,"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if resolved["lifecycle"] == "exited" {
            assert_eq!(resolved["surface"], serde_json::Value::Null);
            break;
        }
        assert!(Instant::now() < deadline, "Ctrl-D never exited the shell");
        std::thread::sleep(Duration::from_millis(20));
    }

    let tree = request(&harness.socket, serde_json::json!({"id":4,"cmd":"list-workspaces"}));
    let workspace = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["id"].as_u64() == Some(workspace_id))
        .expect("Ctrl-D removed the workspace identity");
    assert!(first_tab(workspace).is_none(), "Ctrl-D left an exited terminal tab behind");
}

#[test]
fn running_host_sigkill_detaches_exited_terminal_topology() {
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
            assert_eq!(resolved["surface"], serde_json::Value::Null);
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
    assert!(write["error"].as_str().unwrap().contains("unknown surface"));
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
fn daemon_restart_safe_prunes_dead_host_without_rematerializing_exited_terminal() {
    let mut harness = RecoveryHarness::start("dead-host-restart");
    let created = request(
        &harness.socket,
        serde_json::json!({
            "id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,
            "cols":80,"rows":24,
        }),
    );
    let surface = created["surface"].as_u64().unwrap();
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
    loop {
        let resolved = request(
            &harness.socket,
            serde_json::json!({"id":3,"cmd":"resolve-terminal","terminal_id":terminal_id}),
        );
        if resolved["lifecycle"] == "exited" {
            assert_eq!(resolved["terminal_incarnation"], incarnation);
            assert_eq!(resolved["surface"], serde_json::Value::Null);
            break;
        }
        assert!(Instant::now() < deadline, "dead startup host was not projected as Exited");
        std::thread::sleep(Duration::from_millis(25));
    }
    wait_for_no_host_records(&harness.host_root());
    let recovered = request(&harness.socket, serde_json::json!({"id":4,"cmd":"list-workspaces"}));
    let workspace = recovered["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["key"].as_str() == Some(&workspace_key))
        .expect("original workspace was not recovered");
    assert!(first_tab(workspace).is_none(), "Exited terminal was rematerialized after restart");

    let write = request_response(
        &harness.socket,
        serde_json::json!({
            "id":5,"cmd":"send","surface":surface,"text":"must-not-respawn\\n",
        }),
    );
    assert_eq!(write["ok"], false);
    assert!(write["error"].as_str().unwrap().contains("unknown surface"));
    request(
        &harness.socket,
        serde_json::json!({
            "id":6,"cmd":"close-terminal","terminal_id":terminal_id,
            "terminal_incarnation":incarnation,
        }),
    );
}

#[test]
fn daemon_restart_prunes_every_dead_host_behind_one_pane() {
    let mut harness = RecoveryHarness::start("dead-hosts-restart");
    let first = request(
        &harness.socket,
        serde_json::json!({
            "id":1,"cmd":"run","argv":["/bin/cat"],"new_workspace":true,
            "cols":80,"rows":24,
        }),
    );
    let pane = first["pane"].as_u64().unwrap();
    let workspace_id = first["workspace"].as_u64().unwrap();
    let first_terminal = first["terminal_id"].as_str().unwrap().to_string();
    let second = request(
        &harness.socket,
        serde_json::json!({
            "id":2,"cmd":"run","argv":["/bin/cat"],"pane":pane,
            "cols":80,"rows":24,
        }),
    );
    let second_terminal = second["terminal_id"].as_str().unwrap().to_string();
    assert_eq!(second["pane"].as_u64(), Some(pane), "second terminal left the first pane");
    let tree = request(&harness.socket, serde_json::json!({"id":3,"cmd":"list-workspaces"}));
    let workspace_key = tree["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["id"].as_u64() == Some(workspace_id))
        .unwrap()["key"]
        .as_str()
        .unwrap()
        .to_string();
    let records = wait_for_host_records(&harness.host_root(), 2);

    // Stop the mux first so it observes neither Exit. Startup then has to
    // reconcile two dead hosts behind the same pane. Recovery of the first
    // one must not depend on the second one already having a live surface.
    harness.signal_daemon(libc::SIGSTOP);
    for (_, record) in &records {
        // SAFETY: the record PIDs are the harness-owned terminal hosts.
        assert_eq!(unsafe { libc::kill(record.host_pid as libc::pid_t, libc::SIGKILL) }, 0);
    }
    harness.sigkill();
    harness.restart();

    for terminal_id in [&first_terminal, &second_terminal] {
        let deadline = Instant::now() + Duration::from_secs(15);
        loop {
            let resolved = request(
                &harness.socket,
                serde_json::json!({"id":4,"cmd":"resolve-terminal","terminal_id":terminal_id}),
            );
            if resolved["lifecycle"] == "exited" {
                assert_eq!(resolved["surface"], serde_json::Value::Null);
                break;
            }
            assert!(
                Instant::now() < deadline,
                "dead startup host {terminal_id} was not projected as Exited"
            );
            std::thread::sleep(Duration::from_millis(25));
        }
    }
    wait_for_no_host_records(&harness.host_root());
    let recovered = request(&harness.socket, serde_json::json!({"id":5,"cmd":"list-workspaces"}));
    let workspace = recovered["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["key"].as_str() == Some(&workspace_key))
        .expect("original workspace was not recovered");
    assert!(first_tab(workspace).is_none(), "Exited terminals were rematerialized after restart");
}

fn request(path: &Path, value: serde_json::Value) -> serde_json::Value {
    let response = request_response(path, value);
    assert_eq!(response["ok"], true, "request failed: {response}");
    response["data"].clone()
}

fn attach_claim_and_resize_surface(
    path: &Path,
    surface: u64,
    cols: u16,
    rows: u16,
    request_id: u64,
) {
    let stream = transport::connect(path).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    let attach_id = request_id.saturating_mul(2);
    let claim_id = attach_id.saturating_add(1);
    stream_request(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id":attach_id,
            "cmd":"attach-surface",
            "surface":surface,
            "cols":cols,
            "rows":rows,
        }),
    );
    stream_request(
        &mut writer,
        &mut reader,
        serde_json::json!({
            "id":claim_id,
            "cmd":"set-client-sizing",
            "surface":surface,
            "enabled":true,
            "exclusive":true,
        }),
    );
}

fn stream_request(
    writer: &mut Box<dyn transport::Stream>,
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    value: serde_json::Value,
) -> serde_json::Value {
    let request_id = value["id"].clone();
    writeln!(writer, "{value}").unwrap();
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).unwrap();
        let response: serde_json::Value = serde_json::from_str(&line).unwrap();
        if response["id"] == request_id {
            assert_eq!(response["ok"], true, "request failed: {response}");
            return response["data"].clone();
        }
        assert!(response["event"].is_string(), "unexpected control message: {response}");
    }
}

fn close_terminal_surface(path: &Path, surface: u64, request_id: u64) {
    let tree = request(path, serde_json::json!({"id":request_id,"cmd":"list-workspaces"}));
    let tab = tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .flat_map(|workspace| workspace["screens"].as_array().into_iter().flatten())
        .flat_map(|screen| screen["panes"].as_array().into_iter().flatten())
        .flat_map(|pane| pane["tabs"].as_array().into_iter().flatten())
        .find(|tab| tab["surface"].as_u64() == Some(surface))
        .unwrap_or_else(|| panic!("surface {surface} was absent from the workspace tree"));
    let terminal_id = tab["terminal_id"].as_str().expect("terminal view has a host identity");
    let incarnation =
        tab["terminal_incarnation"].as_str().expect("terminal view has an incarnation");
    request(
        path,
        serde_json::json!({
            "id":request_id,
            "cmd":"close-terminal",
            "terminal_id":terminal_id,
            "terminal_incarnation":incarnation,
        }),
    );
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

#[test]
fn terminal_launch_rejection_preserves_the_host_error() {
    let mut harness = RecoveryHarness::start_unstarted("launch-rejection-detail");
    let child = harness.daemon_command().spawn().unwrap();
    harness.child = Some(child);
    wait_for_socket(&harness.socket);

    let missing = format!("/tmp/cmux-terminal-host-missing-{}", std::process::id());
    let response = request_response(
        &harness.socket,
        serde_json::json!({
            "id": 1,
            "cmd": "run",
            "argv": [missing],
            "new_workspace": true,
            "name": "must-fail",
            "cols": 80,
            "rows": 24,
        }),
    );

    assert_eq!(response["ok"], false, "missing command unexpectedly launched: {response}");
    let error = response["error"].as_str().expect("rejection includes an error string");
    assert!(
        error.contains("No such file") || error.contains("not found"),
        "terminal host discarded its launch error: {error}"
    );
    assert!(
        !error.contains("closed before launch ready"),
        "launcher exposed transport fallout instead of the host error: {error}"
    );
}

fn resource_request(
    path: &Path,
    id: &str,
    operation: &str,
    params: serde_json::Value,
    idempotency_key: Option<&str>,
) -> serde_json::Value {
    let mut value = serde_json::json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":id,
        "operation":operation,
        "params":params,
    });
    if let Some(idempotency_key) = idempotency_key {
        value["idempotency_key"] = serde_json::json!(idempotency_key);
    }
    let response = request_response(path, value);
    assert_eq!(response["protocol"], "cmux.protocol/2", "request failed: {response}");
    assert_eq!(response["type"], "response", "request failed: {response}");
    assert_eq!(response["id"], id, "request failed: {response}");
    assert_eq!(response["ok"], true, "request failed: {response}");
    response["result"].clone()
}

fn wait_for_socket(path: &Path) {
    let deadline = Instant::now() + test_timeout(Duration::from_secs(15));
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

fn wait_for_host_records(root: &Path, expected: usize) -> Vec<(PathBuf, TerminalHostRecord)> {
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
        if load_terminal_host_records(root).unwrap().is_empty()
            && load_terminal_host_exit_records(root).unwrap().is_empty()
        {
            return;
        }
        std::thread::sleep(Duration::from_millis(25));
    }
    let records = load_terminal_host_records(root).unwrap();
    let exits = load_terminal_host_exit_records(root).unwrap();
    panic!("terminal host records or exit sidecars remained after close: {records:?}; {exits:?}");
}

fn wait_for_socket_hangup(stream: &UnixStream, timeout: Duration) -> bool {
    let deadline = Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return false;
        }
        let mut descriptor = libc::pollfd {
            fd: stream.as_raw_fd(),
            events: libc::POLLIN | libc::POLLHUP,
            revents: 0,
        };
        let timeout_ms =
            remaining.min(Duration::from_millis(100)).as_millis().clamp(1, i32::MAX as u128) as i32;
        // SAFETY: descriptor points to one initialized pollfd and the stream
        // remains borrowed for the duration of poll.
        let ready = unsafe { libc::poll(&raw mut descriptor, 1, timeout_ms) };
        if ready < 0 {
            let error = std::io::Error::last_os_error();
            if error.kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            panic!("poll stalled renderer: {error}");
        }
        if descriptor.revents & (libc::POLLHUP | libc::POLLERR | libc::POLLNVAL) != 0 {
            return true;
        }
        if ready > 0 {
            std::thread::sleep(Duration::from_millis(1));
        }
    }
}

fn wait_for_terminal_lifecycle(
    socket: &Path,
    terminal_id: &str,
    expected: &str,
) -> serde_json::Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let resolved = request(
            socket,
            serde_json::json!({
                "cmd":"resolve-terminal",
                "terminal_id":terminal_id,
            }),
        );
        if resolved["lifecycle"] == expected {
            return resolved;
        }
        assert!(
            Instant::now() < deadline,
            "terminal {terminal_id} remained in lifecycle {:?}, expected {expected}",
            resolved["lifecycle"],
        );
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn wait_for_terminal_host_dead(path: &Path, record: &TerminalHostRecord) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if terminal_host_record_liveness(path, record).unwrap() == TerminalHostLiveness::Dead {
            return;
        }
        assert!(Instant::now() < deadline, "terminal host remained alive after termination");
        std::thread::sleep(Duration::from_millis(20));
    }
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

fn wait_for_cursor_visual(
    path: &Path,
    surface: u64,
    style: &str,
    blink: bool,
) -> serde_json::Value {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        let state = attach_state(path, surface);
        if state["colors"]["cursor_style"].as_str() == Some(style)
            && state["colors"]["cursor_blink"].as_bool() == Some(blink)
        {
            return state;
        }
        assert!(
            Instant::now() < deadline,
            "daemon mirror did not apply {style}/{blink} cursor: {state}"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
}

fn attach_state(path: &Path, surface: u64) -> serde_json::Value {
    let stream = transport::connect(path).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(
        writer,
        "{}",
        serde_json::json!({"id": 9001, "cmd": "attach-surface", "surface": surface})
    )
    .unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    let state: serde_json::Value = serde_json::from_str(&line).unwrap();
    assert_eq!(state["event"], "vt-state", "unexpected attach probe: {state}");
    state
}

fn wait_for_attach_response(reader: &mut BufReader<Box<dyn transport::Stream>>, request_id: u64) {
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).expect("attach stream closed before response");
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        if value["id"] == request_id {
            assert_eq!(value["ok"], true, "attach failed: {value}");
            return;
        }
    }
}

fn wait_for_render_text_then_detached(
    reader: &mut BufReader<Box<dyn transport::Stream>>,
    surface: u64,
    marker: &str,
) {
    let mut saw_marker = false;
    loop {
        let mut line = String::new();
        reader.read_line(&mut line).expect("timed out waiting for hosted detach");
        let value: serde_json::Value = serde_json::from_str(&line).unwrap();
        if matches!(value["event"].as_str(), Some("render-state" | "render-delta")) {
            saw_marker |= value["rows"].as_array().into_iter().flatten().any(|row| {
                row["runs"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|run| run["text"].as_str())
                    .collect::<String>()
                    .contains(marker)
            });
        }
        if value["event"] == "detached" {
            assert_eq!(value["surface"], surface);
            assert!(saw_marker, "hosted exit detached before its final render frame: {value}");
            return;
        }
    }
}

fn wait_for_host_cursor_snapshot(
    record: &TerminalHostRecord,
    style: ghostty_vt::CursorShape,
    blink: bool,
) {
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if let Ok(connection) = connect_host_detailed(
            &record.endpoint,
            &record.terminal_id,
            &record.owner_token,
            ClientRole::Admin,
            CapabilityRights::ADMIN,
        ) && connection.colors.cursor_visual == Some((style, blink))
        {
            return;
        }
        assert!(Instant::now() < deadline, "host snapshot did not apply {style:?}/{blink}");
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

fn snapshot_cell_pixels(payload: &[u8]) -> (u16, u16) {
    assert!(
        payload.len() >= 4 + KITTY_REPLAY_STATE_ENCODED_LEN,
        "Snapshot payload omitted cell geometry"
    );
    let offset = payload.len() - KITTY_REPLAY_STATE_ENCODED_LEN - 4;
    (
        u16::from_le_bytes(payload[offset..offset + 2].try_into().unwrap()),
        u16::from_le_bytes(payload[offset + 2..offset + 4].try_into().unwrap()),
    )
}

fn resize_cell_pixels(payload: &[u8]) -> (u16, u16) {
    assert!(payload.len() >= 8, "Resized payload was truncated");
    let replay_len = u32::from_le_bytes(payload[4..8].try_into().unwrap()) as usize;
    let alias_count_offset = 8usize.checked_add(replay_len).expect("replay length overflow");
    assert!(alias_count_offset + 2 <= payload.len(), "Resized payload omitted Kitty alias count");
    let alias_count =
        u16::from_le_bytes(payload[alias_count_offset..alias_count_offset + 2].try_into().unwrap())
            as usize;
    let offset = alias_count_offset + 2 + alias_count * 8;
    assert_eq!(
        payload.len(),
        offset + 4 + KITTY_REPLAY_STATE_ENCODED_LEN,
        "Resized payload has an invalid suffix"
    );
    (
        u16::from_le_bytes(payload[offset..offset + 2].try_into().unwrap()),
        u16::from_le_bytes(payload[offset + 2..offset + 4].try_into().unwrap()),
    )
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
