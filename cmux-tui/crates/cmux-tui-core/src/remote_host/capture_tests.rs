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
        supervisor.configure(self.paths.clone(), Weak::new());
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
                native_prepared: Some(phase != Phase::Preparing),
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
        Self::refusing(proof_override, &[])
    }

    /// `refused` methods answer as the host does for a binding it does not own: no effects.
    fn refusing(proof_override: Option<(&str, Value)>, refused: &[&'static str]) -> Self {
        let refused = refused.to_vec();
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
            quit: std::sync::atomic::AtomicBool::new(false),
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
                    "capture.prepare" | "capture.cleanup" | "capture.cleanup.unprepared" => {
                        let mut result = proof.clone();
                        result["code"] = json!(if method == "capture.prepare"
                            || method == "capture.cleanup.unprepared"
                        {
                            "no_remote_started"
                        } else {
                            "remote_exit_unverified"
                        });
                        if refused.contains(&method) {
                            result = json!({"code": "remote_lease_mismatch", "lease_bound": true});
                        }
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
    for (method, initial, expected) in [
        ("capture.prepare", None, Phase::Preparing),
        ("capture.cleanup", Some(Phase::Active), Phase::Cleaning),
        ("capture.cleanup", Some(Phase::Preparing), Phase::Cleaning),
    ] {
        let fixture = Fixture::new();
        if let Some(phase) = initial {
            persist(
                &fixture.paths.state,
                &Lease {
                    binding: fixture.binding.clone(),
                    owner: fixture.owner,
                    phase,
                    host: if phase == Phase::Preparing { None } else { Some(mock_record()) },
                    native_prepared: Some(false),
                },
            )
            .unwrap();
        }
        let supervisor = fixture.supervisor();
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
        // A restarted daemon must retain same-lease retry ownership even when neither
        // prepare nor cleanup has obtained a host. It must not become Unreadable.
        let retry = {
            let _starting = lock(&restored.inner.starting);
            restored.capture_locked(
                method,
                fixture.binding.clone(),
                fixture.owner,
                &fixture.paths,
                Transport { ensure: &ensure, drain: &drain },
            )
        };
        assert_eq!(retry.unwrap_err(), "test_host_start_failed");
        assert_eq!(ensured.get(), 2);
        assert_fenced(&fixture.supervisor(), &fixture);
    }
}

#[test]
fn capture_cleanup_recovers_after_prepare_failed_before_native_marker() {
    let fixture = Fixture::new();
    persist(
        &fixture.paths.state,
        &Lease {
            binding: fixture.binding.clone(),
            owner: fixture.owner,
            phase: Phase::Preparing,
            host: None,
            native_prepared: Some(false),
        },
    )
    .unwrap();
    let supervisor = fixture.supervisor();
    let host = MockHost::new(None);
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
    assert_eq!(phase(&supervisor), Phase::Cleaning);
    let requests = lock(&host.requests);
    assert_eq!(requests[1]["method"], "capture.cleanup.unprepared");
    assert_fenced(&supervisor, &fixture);
}

/// Prepare failures after the host record exists, and the success that must keep the normal path.
#[test]
fn capture_cleanup_after_failed_prepare_with_a_recorded_host_takes_the_unprepared_path() {
    // A record left by an earlier daemon: a host was recorded, its native prepare never completed.
    let fixture = Fixture::new();
    persist(
        &fixture.paths.state,
        &Lease {
            binding: fixture.binding.clone(),
            owner: fixture.owner,
            phase: Phase::Preparing,
            host: Some(mock_record()),
            native_prepared: Some(false),
        },
    )
    .unwrap();
    let supervisor = fixture.supervisor();
    let host = MockHost::new(None);
    let (result, _, _) = run_capture(
        &fixture,
        &supervisor,
        "capture.cleanup",
        fixture.binding.clone(),
        fixture.owner,
        &host,
        None,
    );
    assert_eq!(result.unwrap()["code"], "remote_cleaned");
    assert_eq!(lock(&host.requests)[1]["method"], "capture.cleanup.unprepared");

    // The same state reached causally: the host refused prepare, then the app relaunched.
    let fixture = Fixture::new();
    let supervisor = fixture.supervisor();
    let refused = MockHost::new(Some(("lease_bound", json!(false))));
    let (result, ensured, drained) = run_capture(
        &fixture,
        &supervisor,
        "capture.prepare",
        fixture.binding.clone(),
        fixture.owner,
        &refused,
        None,
    );
    assert_eq!(result.unwrap_err(), "remote_capture_proof_unverified");
    assert_eq!((ensured, drained), (1, 0));
    assert_eq!(phase(&supervisor), Phase::Preparing);
    let relaunched = Stamp { start_sec: fixture.owner.start_sec + 1, ..fixture.owner };
    let host = MockHost::new(None);
    let (result, _, _) = run_capture(
        &fixture,
        &supervisor,
        "capture.cleanup",
        fixture.binding.clone(),
        relaunched,
        &host,
        None,
    );
    assert_eq!(result.unwrap()["code"], "remote_cleaned");
    assert_eq!(lock(&host.requests)[1]["method"], "capture.cleanup.unprepared");
    assert_fenced(&fixture.supervisor(), &fixture);

    // A native prepare that completed wrote the host's marker: a failed exit proof keeps
    // the normal cleanup path, after a daemon restart and on a cleanup retry too.
    let fixture = Fixture::new();
    let supervisor = fixture.supervisor();
    let prepared = MockHost::new(None);
    let (result, _, drained) = run_capture(
        &fixture,
        &supervisor,
        "capture.prepare",
        fixture.binding.clone(),
        fixture.owner,
        &prepared,
        Some("remote_exit_timeout"),
    );
    assert_eq!(result.unwrap_err(), "remote_exit_timeout");
    assert_eq!(drained, 1);
    for retry in [false, true] {
        let restored = fixture.supervisor();
        let host = MockHost::new(None);
        let (result, _, _) = run_capture(
            &fixture,
            &restored,
            "capture.cleanup",
            fixture.binding.clone(),
            relaunched,
            &host,
            retry.then_some("remote_exit_timeout"),
        );
        assert_eq!(result.is_ok(), !retry);
        assert_eq!(lock(&host.requests)[1]["method"], "capture.cleanup");
    }
}

/// A host connection whose answers the test writes by hand.
fn manual_host() -> (Arc<Connection>, BufReader<UnixStream>, JoinHandle<()>) {
    let (client, server) = UnixStream::pair().unwrap();
    let reader = BufReader::new(client.try_clone().unwrap());
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
        quit: std::sync::atomic::AtomicBool::new(false),
    });
    let reading = Arc::clone(&connection);
    let thread = std::thread::spawn(move || Inner::read(&Weak::new(), &reading, reader));
    (connection, BufReader::new(server), thread)
}

#[test]
fn capture_start_lock_is_not_held_across_an_ordinary_host_request() {
    let fixture = Fixture::new();
    let supervisor = fixture.supervisor();
    lock(&supervisor.inner.config).computer_use = true;
    let (connection, mut host, reader) = manual_host();
    *lock(&supervisor.inner.state) = State::Running(Arc::clone(&connection));
    let caller = RemoteHostSupervisor { inner: Arc::clone(&supervisor.inner) };
    let call = std::thread::spawn(move || caller.call("status", json!({})));
    let mut line = String::new();
    // The request reached the host and now waits for its answer.
    host.read_line(&mut line).unwrap();
    let free = supervisor.inner.starting.try_lock().is_ok();
    let request: Value = serde_json::from_str(&line).unwrap();
    let answer = json!({"id": request["id"], "ok": true, "result": {"busy": false}});
    writeln!(host.get_mut(), "{answer}").unwrap();
    let answer = call.join().unwrap();
    drop(host);
    let _ = lock(&connection.writer).shutdown(Shutdown::Both);
    reader.join().unwrap();
    assert!(free, "an ordinary host request held the start lock while it waited for the host");
    assert_eq!(answer.unwrap()["busy"], false);
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
        native_prepared: Some(false),
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

#[cfg(target_os = "macos")]
#[test]
fn capture_reused_group_id_after_recorded_host_exit_does_not_block_cleanup() {
    use cmux_process::{Command, Stdio};
    let fixture = Fixture::new();
    let supervisor = fixture.hold(Phase::Cleaning);
    // An unrelated live group leader now has the exited host's PID, so also its group ID.
    let mut unrelated = Command::new("/bin/sh")
        .args(["-c", "read line"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .unwrap();
    let pid = unrelated.id();
    let live = platform::process_start(pid).unwrap();
    let exited = HostRecord { pid, ..mock_record() };
    let reused = capture::may_remove_record(&supervisor.inner, &exited);
    let current = HostRecord { pid, start_sec: live.0, start_usec: live.1, ..mock_record() };
    let running = capture::may_remove_record(&supervisor.inner, &current);
    drop(unrelated.stdin.take());
    unrelated.wait().unwrap();
    assert!(reused, "a group ID reused by an unrelated leader is not the exited host's group");
    assert!(!running, "the recorded host itself still runs");

    // A surviving group without its leader may be the host's orphaned writers: still refused.
    let mut leader = Command::new("/bin/sh")
        .args(["-c", "sleep 30 & exit 0"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
        .unwrap();
    let group = leader.id();
    leader.wait().unwrap();
    let orphaned = HostRecord { pid: group, ..mock_record() };
    let removable = capture::may_remove_record(&supervisor.inner, &orphaned);
    // SAFETY: this signals only the process group this test itself just created.
    unsafe { libc::kill(-(group as i32), libc::SIGKILL) };
    assert!(!removable, "a leaderless surviving group can still hold the host's writers");
}

#[test]
fn capture_group_reuse_needs_one_live_differently_stamped_leader() {
    let recorded = (654, 987);
    let other = Some((700, 1));
    assert!(capture::group_reused(other, other, recorded));
    // The recorded host itself, no leader, or a leader that changed during the query.
    assert!(!capture::group_reused(Some(recorded), Some(recorded), recorded));
    assert!(!capture::group_reused(None, None, recorded));
    assert!(!capture::group_reused(other, None, recorded));
    assert!(!capture::group_reused(None, other, recorded));
    assert!(!capture::group_reused(other, Some((701, 1)), recorded));
}

fn native_prepared(fixture: &Fixture) -> Option<bool> {
    match Admission::load(&fixture.paths.state) {
        Admission::Held(lease) => lease.native_prepared,
        _ => panic!("expected a durable capture lease"),
    }
}

fn native_methods(host: &MockHost) -> Vec<Value> {
    lock(&host.requests)
        .iter()
        .filter(|request| request["method"] != "app_grant")
        .map(|request| request["method"].clone())
        .collect()
}

#[test]
fn capture_cleanup_falls_back_when_the_host_disagrees_about_its_marker() {
    // The host wrote its marker, then the prepare answer was lost (a daemon crash or the call
    // timeout) before the daemon persisted it. The host refuses the markerless path.
    let fixture = Fixture::new();
    persist(
        &fixture.paths.state,
        &Lease {
            binding: fixture.binding.clone(),
            owner: fixture.owner,
            phase: Phase::Preparing,
            host: Some(mock_record()),
            native_prepared: Some(false),
        },
    )
    .unwrap();
    let host = MockHost::refusing(None, &["capture.cleanup.unprepared"]);
    let (result, _, drained) = run_capture(
        &fixture,
        &fixture.supervisor(),
        "capture.cleanup",
        fixture.binding.clone(),
        fixture.owner,
        &host,
        None,
    );
    assert_eq!(result.unwrap()["code"], "remote_cleaned");
    assert_eq!(drained, 1);
    assert_eq!(
        native_methods(&host),
        [json!("capture.cleanup.unprepared"), json!("capture.cleanup")]
    );
    // The host's answer is now durable: a retry goes straight to the marker path.
    assert_eq!(native_prepared(&fixture), Some(true));
    let retry = MockHost::refusing(None, &["capture.cleanup.unprepared"]);
    let (result, _, _) = run_capture(
        &fixture,
        &fixture.supervisor(),
        "capture.cleanup",
        fixture.binding.clone(),
        fixture.owner,
        &retry,
        None,
    );
    assert!(result.is_ok());
    assert_eq!(native_methods(&retry), [json!("capture.cleanup")]);

    // The other direction: the record says prepared, the host has no marker.
    let fixture = Fixture::new();
    persist(
        &fixture.paths.state,
        &Lease {
            binding: fixture.binding.clone(),
            owner: fixture.owner,
            phase: Phase::Cleaning,
            host: Some(mock_record()),
            native_prepared: Some(true),
        },
    )
    .unwrap();
    let host = MockHost::refusing(None, &["capture.cleanup"]);
    let (result, _, _) = run_capture(
        &fixture,
        &fixture.supervisor(),
        "capture.cleanup",
        fixture.binding.clone(),
        fixture.owner,
        &host,
        None,
    );
    assert_eq!(result.unwrap()["code"], "remote_cleaned");
    assert_eq!(
        native_methods(&host),
        [json!("capture.cleanup"), json!("capture.cleanup.unprepared")]
    );
    assert_eq!(native_prepared(&fixture), Some(false));

    // Both refused: one fallback only, no exit proof, and the fence stays.
    let fixture = Fixture::new();
    let supervisor = fixture.hold(Phase::Active);
    let host = MockHost::refusing(None, &["capture.cleanup", "capture.cleanup.unprepared"]);
    let (result, _, drained) = run_capture(
        &fixture,
        &supervisor,
        "capture.cleanup",
        fixture.binding.clone(),
        fixture.owner,
        &host,
        None,
    );
    assert_eq!(result.unwrap_err(), "remote_capture_proof_unverified");
    assert_eq!(drained, 0);
    assert_eq!(
        native_methods(&host),
        [json!("capture.cleanup"), json!("capture.cleanup.unprepared")]
    );
    assert_eq!(phase(&supervisor), Phase::Cleaning);
    assert_fenced(&fixture.supervisor(), &fixture);
}

#[test]
fn capture_record_from_before_native_prepared_keeps_its_recorded_host_choice() {
    for (host, expected) in
        [(Some(mock_record()), "capture.cleanup"), (None, "capture.cleanup.unprepared")]
    {
        let fixture = Fixture::new();
        let lease = Lease {
            binding: fixture.binding.clone(),
            owner: fixture.owner,
            phase: Phase::Cleaning,
            host,
            native_prepared: None,
        };
        // Exactly the bytes an older daemon wrote: no native_prepared key at all.
        let mut value = serde_json::to_value(&lease).unwrap();
        value.as_object_mut().unwrap().remove("native_prepared");
        write_private(
            &fixture.paths.state.join("capture-supervisor.json"),
            &serde_json::to_vec(&value).unwrap(),
        );
        let restored = fixture.supervisor();
        assert_eq!(phase(&restored), Phase::Cleaning);
        let mock = MockHost::new(None);
        let (result, _, _) = run_capture(
            &fixture,
            &restored,
            "capture.cleanup",
            fixture.binding.clone(),
            fixture.owner,
            &mock,
            None,
        );
        assert_eq!(result.unwrap()["code"], "remote_cleaned");
        assert_eq!(native_methods(&mock), [json!(expected)]);
    }
}
