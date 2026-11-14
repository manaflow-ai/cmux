//! Causal capture admission tests. No native host, account, credentials, or Keychain.
use super::capture::Transport;
use super::capture_lease::{Admission, Binding, Lease, Phase, Stamp, persist};
use super::*;
use std::cell::Cell;
use std::net::Shutdown;
use std::os::unix::fs::DirBuilderExt;
use std::os::unix::net::UnixStream;
use std::thread::JoinHandle;

fn mock_record() -> HostRecord {
    HostRecord {
        pid: 321,
        start_sec: 654,
        start_usec: 987,
        secret: "mock-supervisor-secret".into(),
        bundle_digest: "mock-source-digest".into(),
        socket: PathBuf::from("/unused-capture-test.sock"),
    }
}

struct Fixture {
    root: PathBuf,
    paths: Paths,
    binding: Binding,
    owner: Stamp,
}

impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir()
            .canonicalize()
            .unwrap()
            .join(format!("remote-capture-test-{}", mint_secret().unwrap()));
        std::fs::DirBuilder::new().mode(0o700).create(&root).unwrap();
        let paths = Paths {
            runtime: root.join("runtime"),
            state: root.join("state"),
            scope: "capture-test".into(),
            daemon_socket: root.join("daemon.sock"),
        };
        for path in [&paths.runtime, &paths.state] {
            std::fs::DirBuilder::new().mode(0o700).create(path).unwrap();
        }
        write_config(&paths.config(), &RemoteConfig::default());
        let binding = Binding::parse(json!({
            "lease_id": "0123456789abcdef01234567",
            "bundle_id": "com.cmuxterm.app.debug.capturetest",
            "private_root": root,
        }))
        .unwrap();
        Self { root, paths, binding, owner: Stamp { pid: 123, start_sec: 456, start_usec: 789 } }
    }

    fn supervisor(&self) -> RemoteHostSupervisor {
        let supervisor = RemoteHostSupervisor::default();
        supervisor.configure(self.paths.clone());
        supervisor
    }

    fn hold(&self, phase: Phase) -> RemoteHostSupervisor {
        persist(
            &self.paths.state,
            &Lease {
                binding: self.binding.clone(),
                owner: self.owner,
                phase,
                host: Some(mock_record()),
            },
        )
        .unwrap();
        self.supervisor()
    }

    fn fence_bytes(&self) -> Vec<u8> {
        std::fs::read(self.paths.state.join("capture-supervisor.json")).unwrap()
    }

    fn config_bytes(&self) -> Vec<u8> {
        std::fs::read(self.paths.config()).unwrap()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

/// Exercise production framing, pending request delivery and result decoding over real sockets.
/// Both threads are unblocked and joined on drop, including assertion failure paths.
struct MockHost {
    connection: Arc<Connection>,
    peer: UnixStream,
    requests: Arc<Mutex<Vec<Value>>>,
    threads: Vec<JoinHandle<()>>,
}

impl MockHost {
    fn new(proof_override: Option<(&str, Value)>) -> Self {
        let (client, server) = UnixStream::pair().unwrap();
        let reader = BufReader::new(client.try_clone().unwrap());
        let peer = server.try_clone().unwrap();
        let record = mock_record();
        let connection = Arc::new(Connection {
            pid: record.pid,
            record,
            adopted: false,
            started: Instant::now(),
            writer: Mutex::new(client),
            pending: Mutex::new(HashMap::new()),
            next_id: std::sync::atomic::AtomicU64::new(1),
            status: Mutex::new(json!({"busy": false})),
            closed: (Mutex::new(false), std::sync::Condvar::new()),
        });
        let reading = Arc::clone(&connection);
        let read_thread = std::thread::spawn(move || Inner::read(&Weak::new(), &reading, reader));
        let requests = Arc::new(Mutex::new(Vec::new()));
        let observed = Arc::clone(&requests);
        let mut proof = json!({
            "ok": false,
            "host_stamp": Stamp::of_record(&connection.record),
            "lease_bound": true,
            "worker_started": false,
            "identity_removed": 0,
            "relays_removed": 0,
            "worker_quiescent": true,
            "verified_absent": true,
            "worker_pid_exited": false,
            "descendants_exited": false,
        });
        if let Some((key, value)) = proof_override {
            proof[key] = value;
        }
        let host_thread = std::thread::spawn(move || {
            let mut reader = BufReader::new(server);
            let mut line = String::new();
            loop {
                line.clear();
                if !matches!(reader.read_line(&mut line), Ok(count) if count > 0) {
                    break;
                }
                let Ok(request) = serde_json::from_str::<Value>(&line) else {
                    break;
                };
                lock(&observed).push(request.clone());
                let method = request["method"].as_str().unwrap_or("");
                let result = match method {
                    "app_grant" => json!({"host_pid": 321, "secret": "mock-app-secret"}),
                    "capture.prepare" | "capture.cleanup" => {
                        let mut result = proof.clone();
                        result["code"] = json!(if method == "capture.prepare" {
                            "no_remote_started"
                        } else {
                            "remote_exit_unverified"
                        });
                        result
                    }
                    _ => Value::Null,
                };
                let answer = json!({"id": request["id"], "ok": true, "result": result});
                if writeln!(reader.get_mut(), "{answer}").is_err() {
                    break;
                }
            }
        });
        Self { connection, peer, requests, threads: vec![host_thread, read_thread] }
    }
}

impl Drop for MockHost {
    fn drop(&mut self) {
        let _ = self.peer.shutdown(Shutdown::Both);
        let _ = lock(&self.connection.writer).shutdown(Shutdown::Both);
        for thread in self.threads.drain(..) {
            let _ = thread.join();
        }
    }
}

fn phase(supervisor: &RemoteHostSupervisor) -> Phase {
    match &*lock(&supervisor.inner.capture) {
        Admission::Held(lease) => lease.phase,
        _ => panic!("expected a durable capture lease"),
    }
}

fn assert_fenced(supervisor: &RemoteHostSupervisor, fixture: &Fixture) {
    let disk_before = fixture.config_bytes();
    let memory_before = lock(&supervisor.inner.config).clone();
    assert_eq!(supervisor.call("status", json!({})).unwrap_err(), "remote_capture_quiescing");
    assert_eq!(
        supervisor.set_config(&json!({"computer_use": true, "screen_sharing": true})).unwrap_err(),
        "remote_capture_quiescing"
    );
    assert_eq!(Inner::ensure(&supervisor.inner).err().as_deref(), Some("remote_capture_quiescing"));
    assert_eq!(*lock(&supervisor.inner.config), memory_before);
    assert_eq!(fixture.config_bytes(), disk_before);
}

fn run_capture(
    fixture: &Fixture,
    supervisor: &RemoteHostSupervisor,
    method: &str,
    binding: Binding,
    app: Stamp,
    host: &MockHost,
    drain_error: Option<&str>,
) -> (Result<Value, String>, usize, usize) {
    let ensured = Cell::new(0);
    let drained = Cell::new(0);
    let ensure = |config: &RemoteConfig| {
        ensured.set(ensured.get() + 1);
        assert!(
            !config.computer_use && !config.screen_sharing,
            "capture started an enabled worker"
        );
        assert!(lock(&supervisor.inner.capture).fenced(), "admission must close before ensure");
        *lock(&supervisor.inner.state) = State::Running(Arc::clone(&host.connection));
        Ok(Arc::clone(&host.connection))
    };
    let drain = |connection: &Arc<Connection>| {
        drained.set(drained.get() + 1);
        assert!(Arc::ptr_eq(connection, &host.connection));
        assert!(lock(&supervisor.inner.capture).fenced(), "drain must retain admission fence");
        if let Some(error) = drain_error {
            Err(error.to_owned())
        } else {
            // The platform callback owns actual stamped exit proof; this test controls its verdict.
            // Production must retire the exact connection after this succeeds.
            Ok(())
        }
    };
    let _starting = lock(&supervisor.inner.starting);
    let result = supervisor.capture_locked(
        method,
        binding,
        app,
        &fixture.paths,
        Transport { ensure: &ensure, drain: &drain },
    );
    (result, ensured.get(), drained.get())
}

#[test]
fn capture_signed_out_prepare_is_quiet_and_never_changes_persisted_config() {
    let fixture = Fixture::new();
    let supervisor = fixture.supervisor();
    let host = MockHost::new(None);
    let before = fixture.config_bytes();
    let (result, ensured, drained) = run_capture(
        &fixture,
        &supervisor,
        "capture.prepare",
        fixture.binding.clone(),
        fixture.owner,
        &host,
        None,
    );
    let result = result.unwrap();
    assert_eq!((ensured, drained), (1, 1));
    assert_eq!(result["code"], "no_remote_started");
    assert_eq!(result["ok"], true);
    assert_eq!(result["worker_pid_exited"], true);
    assert_eq!(result["descendants_exited"], true);
    assert_eq!(phase(&supervisor), Phase::Prepared);
    assert!(matches!(*lock(&supervisor.inner.state), State::Idle));
    assert_eq!(*lock(&supervisor.inner.config), RemoteConfig::default());
    assert_eq!(fixture.config_bytes(), before);
    let requests = lock(&host.requests);
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0]["method"], "app_grant");
    assert_eq!(requests[0]["params"]["app"], json!(fixture.owner));
    assert_eq!(requests[1]["method"], "capture.prepare");
    assert_eq!(requests[1]["params"], json!(fixture.binding));
    drop(requests);
    assert_fenced(&supervisor, &fixture);
}

#[test]
fn capture_wrong_lease_has_no_transport_or_fence_effects() {
    for held in [Phase::Preparing, Phase::Prepared, Phase::Active, Phase::Cleaning] {
        let fixture = Fixture::new();
        let supervisor = fixture.hold(held);
        let host = MockHost::new(None);
        let before = fixture.fence_bytes();
        let mut wrong = fixture.binding.clone();
        wrong.lease_id = "aaaaaaaaaaaaaaaaaaaaaaaa".into();
        for method in ["capture.prepare", "capture.resume", "capture.cleanup"] {
            let (result, ensured, drained) = run_capture(
                &fixture,
                &supervisor,
                method,
                wrong.clone(),
                fixture.owner,
                &host,
                None,
            );
            assert_eq!(result.unwrap_err(), "remote_lease_mismatch");
            assert_eq!((ensured, drained), (0, 0));
            assert_eq!(phase(&supervisor), held);
            assert_eq!(fixture.fence_bytes(), before);
        }
        assert!(lock(&host.requests).is_empty());
    }
}

#[test]
fn capture_fence_blocks_normal_entry_points_even_with_an_existing_connection() {
    for held in [Phase::Preparing, Phase::Prepared, Phase::Cleaning] {
        let fixture = Fixture::new();
        let supervisor = fixture.hold(held);
        let host = MockHost::new(None);
        *lock(&supervisor.inner.state) = State::Running(Arc::clone(&host.connection));
        // Make the normal-path preconditions pass: only the capture fence can reject this call.
        lock(&supervisor.inner.config).computer_use = true;
        assert_fenced(&supervisor, &fixture);
        assert!(lock(&host.requests).is_empty());
    }
}

#[test]
fn capture_resume_requires_a_distinct_app_generation_and_prepared_phase() {
    let fixture = Fixture::new();
    let supervisor = fixture.hold(Phase::Prepared);
    let host = MockHost::new(None);
    let before = fixture.fence_bytes();
    let (same, ensured, drained) = run_capture(
        &fixture,
        &supervisor,
        "capture.resume",
        fixture.binding.clone(),
        fixture.owner,
        &host,
        None,
    );
    assert_eq!(same.unwrap_err(), "remote_capture_resume_unverified");
    assert_eq!((ensured, drained), (0, 0));
    assert_eq!(fixture.fence_bytes(), before);
    // PID alone is not the generation: a fresh stamped app can reuse the old PID.
    let fresh = Stamp { start_sec: fixture.owner.start_sec + 1, ..fixture.owner };
    let (resumed, ensured, drained) = run_capture(
        &fixture,
        &supervisor,
        "capture.resume",
        fixture.binding.clone(),
        fresh,
        &host,
        None,
    );
    assert_eq!(resumed.unwrap()["code"], "remote_capture_resumed");
    assert_eq!((ensured, drained), (0, 0));
    assert_eq!(phase(&supervisor), Phase::Active);
    assert!(capture::require_open(&supervisor.inner).is_ok());
    let (again, _, _) = run_capture(
        &fixture,
        &supervisor,
        "capture.resume",
        fixture.binding.clone(),
        fresh,
        &host,
        None,
    );
    assert_eq!(again.unwrap_err(), "remote_capture_resume_unverified");
    assert!(lock(&host.requests).is_empty());
}

#[test]
fn capture_failed_resume_publication_does_not_open_memory_admission() {
    let fixture = Fixture::new();
    let supervisor = fixture.hold(Phase::Prepared);
    let host = MockHost::new(None);
    let target = fixture.paths.state.join("capture-supervisor.json");
    // Replace only our fixture's record with a directory, making atomic publication fail.
    std::fs::remove_file(&target).unwrap();
    std::fs::create_dir(&target).unwrap();
    let fresh = Stamp { start_sec: fixture.owner.start_sec + 1, ..fixture.owner };
    let (result, ensured, drained) = run_capture(
        &fixture,
        &supervisor,
        "capture.resume",
        fixture.binding.clone(),
        fresh,
        &host,
        None,
    );
    assert_eq!(result.unwrap_err(), "remote_capture_fence_unverified");
    assert_eq!((ensured, drained), (0, 0));
    assert_eq!(phase(&supervisor), Phase::Cleaning);
    assert_fenced(&supervisor, &fixture);
    let restored = fixture.supervisor();
    assert!(matches!(*lock(&restored.inner.capture), Admission::Unreadable));
    assert_fenced(&restored, &fixture);
}

#[test]
fn capture_cleanup_success_retains_the_durable_fence_after_exit() {
    let fixture = Fixture::new();
    let supervisor = fixture.hold(Phase::Active);
    let host = MockHost::new(Some(("worker_started", json!(true))));
    let (result, ensured, drained) = run_capture(
        &fixture,
        &supervisor,
        "capture.cleanup",
        fixture.binding.clone(),
        fixture.owner,
        &host,
        None,
    );
    let result = result.unwrap();
    assert_eq!((ensured, drained), (1, 1));
    assert_eq!(result["code"], "remote_cleaned");
    assert_eq!(result["ok"], true);
    assert_eq!(result["worker_pid_exited"], true);
    assert_eq!(result["descendants_exited"], true);
    assert_eq!(phase(&supervisor), Phase::Cleaning);
    assert!(matches!(*lock(&supervisor.inner.state), State::Idle));
    assert_fenced(&supervisor, &fixture);
    let restored = fixture.supervisor();
    assert_eq!(phase(&restored), Phase::Cleaning);
    assert_fenced(&restored, &fixture);
}

#[test]
fn capture_bad_host_proof_and_failed_exit_never_release_cleanup_fence() {
    for (proof, drain_error, expected_drains) in [
        (Some(("verified_absent", json!(false))), None, 0),
        (Some(("worker_quiescent", json!(false))), None, 0),
        (Some(("host_stamp", json!({"pid": 321, "start_sec": 0, "start_usec": 0}))), None, 0),
        (None, Some("remote_host_exit_unverified"), 1),
    ] {
        let fixture = Fixture::new();
        let supervisor = fixture.hold(Phase::Active);
        let host = MockHost::new(proof);
        let (result, ensured, drained) = run_capture(
            &fixture,
            &supervisor,
            "capture.cleanup",
            fixture.binding.clone(),
            fixture.owner,
            &host,
            drain_error,
        );
        assert_eq!(result.unwrap_err(), drain_error.unwrap_or("remote_capture_proof_unverified"));
        assert_eq!((ensured, drained), (1, expected_drains));
        assert_eq!(phase(&supervisor), Phase::Cleaning);
        assert_fenced(&supervisor, &fixture);
        assert_fenced(&fixture.supervisor(), &fixture);
    }
}

#[test]
fn capture_failed_ensure_leaves_a_recoverable_durable_fence() {
    for (method, expected) in
        [("capture.prepare", Phase::Preparing), ("capture.cleanup", Phase::Cleaning)]
    {
        let fixture = Fixture::new();
        let supervisor = if method == "capture.prepare" {
            fixture.supervisor()
        } else {
            fixture.hold(Phase::Active)
        };
        let ensured = Cell::new(0);
        let ensure = |config: &RemoteConfig| {
            ensured.set(ensured.get() + 1);
            assert!(!config.wanted());
            Err("test_host_start_failed".to_owned())
        };
        let drain = |_: &Arc<Connection>| -> Result<(), String> {
            panic!("a failed start cannot reach drain")
        };
        let result = {
            let _starting = lock(&supervisor.inner.starting);
            supervisor.capture_locked(
                method,
                fixture.binding.clone(),
                fixture.owner,
                &fixture.paths,
                Transport { ensure: &ensure, drain: &drain },
            )
        };
        assert_eq!(result.unwrap_err(), "test_host_start_failed");
        assert_eq!(ensured.get(), 1);
        assert_eq!(phase(&supervisor), expected);
        let restored = fixture.supervisor();
        assert_eq!(phase(&restored), expected);
        assert_fenced(&restored, &fixture);
    }
}

#[test]
fn capture_durable_prepared_record_survives_configure_and_malformed_record_fails_closed() {
    let fixture = Fixture::new();
    let original = fixture.hold(Phase::Prepared);
    assert_fenced(&original, &fixture);
    drop(original);
    let restored = fixture.supervisor();
    assert_eq!(phase(&restored), Phase::Prepared);
    assert_fenced(&restored, &fixture);
    for bytes in [b"{".as_slice(), b"{\"phase\":\"Active\"}".as_slice()] {
        write_private(&fixture.paths.state.join("capture-supervisor.json"), bytes);
        let malformed = fixture.supervisor();
        assert!(matches!(*lock(&malformed.inner.capture), Admission::Unreadable));
        assert_fenced(&malformed, &fixture);
    }
    // Syntactically valid JSON must not bypass semantic lease validation during reload.
    let mut lease = Lease {
        binding: fixture.binding.clone(),
        owner: fixture.owner,
        phase: Phase::Active,
        host: Some(mock_record()),
    };
    lease.binding.lease_id = "not-a-lease".into();
    persist(&fixture.paths.state, &lease).unwrap();
    let invalid_binding = fixture.supervisor();
    assert!(matches!(*lock(&invalid_binding.inner.capture), Admission::Unreadable));
    assert_fenced(&invalid_binding, &fixture);
}

#[test]
fn capture_fifo_record_is_rejected_without_waiting_for_a_writer() {
    use std::ffi::CString;
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::OpenOptionsExt;

    let fixture = Fixture::new();
    let path = fixture.paths.state.join("capture-supervisor.json");
    let name = CString::new(path.as_os_str().as_bytes()).unwrap();
    // SAFETY: the NUL-terminated path names only this test's private temporary directory.
    assert_eq!(unsafe { libc::mkfifo(name.as_ptr(), 0o600) }, 0);
    let state = fixture.paths.state.clone();
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    let reader = std::thread::spawn(move || {
        let rejected = matches!(Admission::load(&state), Admission::Unreadable);
        let _ = sender.send(rejected);
    });

    let prompt = receiver.recv_timeout(Duration::from_secs(2)).ok();
    let mut rescue = None;
    let rejected = if let Some(rejected) = prompt {
        rejected
    } else {
        // The old blocking open needs a writer. This owned nonblocking read/write endpoint
        // releases it even if the reader has not reached open yet, so that regression fails
        // an assertion rather than leaving a stuck test thread or hanging the whole suite.
        rescue = Some(
            std::fs::OpenOptions::new()
                .read(true)
                .write(true)
                .custom_flags(libc::O_NONBLOCK)
                .open(&path)
                .unwrap(),
        );
        receiver.recv_timeout(Duration::from_secs(5)).expect("FIFO reader must finish after rescue")
    };
    reader.join().unwrap();
    drop(rescue);
    assert!(rejected, "a FIFO is never a valid durable lease");
    assert!(prompt.is_some(), "loading a FIFO waited for a writer instead of failing closed");
}

#[test]
fn capture_dead_parent_with_living_group_child_cannot_be_replaced() {
    let group = capture::group_absence(Ok(()));
    assert_eq!(group.as_ref().unwrap_err(), "remote_descendants_still_running");
    assert!(!capture::replacement_verified(true, group));
}

#[test]
fn capture_absent_group_requires_independent_leader_exit() {
    assert!(capture::replacement_verified(true, capture::group_absence(Err(libc::ESRCH))));
    assert!(!capture::replacement_verified(false, capture::group_absence(Err(libc::ESRCH))));
}

#[test]
fn capture_permission_or_unknown_group_evidence_never_allows_replacement() {
    for error in [libc::EPERM, libc::EINVAL, 0] {
        let group = capture::group_absence(Err(error));
        assert_eq!(group.as_ref().unwrap_err(), "remote_descendants_unverified");
        assert!(!capture::replacement_verified(true, group));
    }
}

#[cfg(target_os = "macos")]
#[test]
fn capture_owned_group_query_holds_running_child_and_releases_after_reap() {
    use cmux_process::{Command, Stdio};
    let mut child = Command::new("/bin/sh")
        .args(["-c", "read line"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .unwrap();
    let group = child.id();
    let held = capture_platform::group_absent(group);
    drop(child.stdin.take());
    child.wait().unwrap();
    assert!(held.is_err(), "a running owned writer must hold admission");
    assert!(capture_platform::group_absent(group).is_ok());
    for invalid in [0, 1, u32::MAX] {
        assert!(capture_platform::group_absent(invalid).is_err());
    }
}
