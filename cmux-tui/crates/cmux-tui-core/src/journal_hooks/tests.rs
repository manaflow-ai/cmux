use super::*;
use crate::{
    JournalClass, JournalEventSchema, JournalHookDeliveryPolicy, JournalHookExec,
    JournalHookFilter, JournalHookRetry, JournalIngress, JournalProducer, JournalProducerManifest,
    JournalReplayPolicy, JournalSubject, SessionJournalRecord,
};
use serde_json::Value;
use sha2::Digest;

fn document(kind: &str, payload: Value) -> JournalDocument {
    JournalDocument::new(SessionJournalRecord {
        sequence: 1,
        event_id: "event_test".into(),
        schema_version: 1,
        kind: kind.into(),
        class: JournalClass::State,
        replay: JournalReplayPolicy::Required,
        occurred_at_ms: 1,
        committed_at_ms: 1,
        producer: JournalProducer { kind: "test".into(), id: "test".into() },
        authority: None,
        causation_id: None,
        correlation_id: None,
        causation_depth: 0,
        subjects: vec![JournalSubject { kind: "workspace".into(), id: "ws_1".into() }],
        sensitivity: JournalSensitivity::Metadata,
        payload,
        resource_revision: None,
        previous_resource_revision: None,
        terminal_output: None,
    })
}

fn terminal_document(bytes: &[u8]) -> JournalDocument {
    let digest = sha2::Sha256::digest(bytes);
    JournalDocument::new(SessionJournalRecord {
        sequence: 1,
        event_id: "event_terminal_test".into(),
        schema_version: 1,
        kind: "terminal.output".into(),
        class: JournalClass::Observation,
        replay: JournalReplayPolicy::Required,
        occurred_at_ms: 1,
        committed_at_ms: 1,
        producer: JournalProducer { kind: "terminal_runtime".into(), id: "term_test".into() },
        authority: None,
        causation_id: None,
        correlation_id: None,
        causation_depth: 0,
        subjects: vec![JournalSubject { kind: "terminal".into(), id: "term_test".into() }],
        sensitivity: JournalSensitivity::Sensitive,
        payload: json!({
            "format":"cmux.terminal-output.v1",
            "encoding":"raw",
            "byte_count":bytes.len().to_string(),
            "sha256":format!("{digest:x}"),
            "stream_offset_start":"0",
            "stream_offset_end":bytes.len().to_string(),
        }),
        resource_revision: None,
        previous_resource_revision: None,
        terminal_output: Some(Arc::from(bytes)),
    })
}

fn manifest() -> JournalHookManifest {
    JournalHookManifest {
        hook_id: "test_hook".into(),
        manifest_version: 1,
        filter: JournalHookFilter::default(),
        exec: JournalHookExec {
            argv: vec!["/usr/bin/true".into()],
            timeout_ms: 1000,
            max_parallel: 1,
        },
        delivery: JournalHookDeliveryPolicy {
            start: "tail".into(),
            retry: JournalHookRetry { max_attempts: 1, backoff_ms: 0 },
        },
        permissions: vec!["journal.read".into()],
    }
}

#[test]
fn hook_delivery_workers_are_strictly_bounded() {
    assert_eq!(delivery_worker_count(1), 4);
    assert_eq!(delivery_worker_count(8), 16);
    assert_eq!(delivery_worker_count(usize::MAX), 32);
}

#[cfg(target_os = "linux")]
#[test]
fn unix_hook_tree_kills_a_descendant_that_created_a_new_session() {
    const HELPER: &str = "CMUX_TEST_DETACHED_JOURNAL_HOOK";
    const SIGNAL_PATH: &str = "CMUX_TEST_DETACHED_JOURNAL_HOOK_SIGNAL";
    if let Some(mode) = std::env::var_os(HELPER) {
        let signal_path = std::env::var_os(SIGNAL_PATH).unwrap();
        match mode.to_str().unwrap() {
            "close-fds" => {
                // A normal daemon closes inherited descriptors before it
                // creates a new session.
                for fd in 3..1024 {
                    unsafe {
                        libc::close(fd);
                    }
                }
            }
            "clear-environment" => unsafe {
                // A daemon can replace its environment after exec. The
                // scope must retain an independent ownership marker.
                std::env::remove_var("CMUX_TUI_PROCESS_SCOPE");
            },
            "close-fds-and-clear-environment" => {
                for fd in 3..1024 {
                    unsafe {
                        libc::close(fd);
                    }
                }
                unsafe {
                    std::env::remove_var("CMUX_TUI_PROCESS_SCOPE");
                }
            }
            "fork-during-cleanup" => {}
            other => panic!("unexpected detached hook helper mode {other}"),
        }
        let session = unsafe { libc::setsid() };
        if mode == "fork-during-cleanup" {
            assert!(session > 0, "the test-only tracker path could not create a session");
        } else {
            assert_eq!(session, -1, "the Linux process-group fence allowed setsid");
            assert_eq!(std::io::Error::last_os_error().raw_os_error(), Some(libc::EPERM));
        }
        let mut signal = std::os::unix::net::UnixStream::connect(signal_path).unwrap();
        signal.write_all(&std::process::id().to_ne_bytes()).unwrap();
        let mut release = [0_u8; 1];
        let _ = signal.read_exact(&mut release);
        if mode == "fork-during-cleanup" {
            let input = signal.try_clone().unwrap();
            let mut child = Command::new("/bin/sh")
                .args(["-c", "read _"])
                .stdin(Stdio::from(std::os::fd::OwnedFd::from(input)))
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap();
            signal.write_all(&child.id().to_ne_bytes()).unwrap();
            let _ = child.wait();
        }
        return;
    }

    for mode in ["close-fds", "clear-environment", "close-fds-and-clear-environment"] {
        let root = std::env::temp_dir().join(format!(
            "cmux-jh-{}-{:x}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        std::fs::create_dir_all(&root).unwrap();
        let signal_path = root.join("detached.sock");
        let listener = std::os::unix::net::UnixListener::bind(&signal_path).unwrap();
        let (accepted, accepted_receiver) = mpsc::sync_channel(1);
        let acceptor = std::thread::spawn(move || {
            accepted.send(listener.accept().map(|(signal, _)| signal)).unwrap();
        });
        let executable = std::env::current_exe().unwrap();
        let test_name =
            "journal_hooks::tests::unix_hook_tree_kills_a_descendant_that_created_a_new_session";
        let mut command = UnixProcessScope::suspended_command("/bin/sh");
        // Exit the intermediate shell immediately. The detached child is
        // reparented before cleanup, so no launching ancestor waits for
        // tracker admission.
        let launch = "\"$1\" --exact \"$2\" --nocapture &";
        command
            .args(["-c", launch, "cmux-journal-hook-test"])
            .arg(&executable)
            .arg(test_name)
            .env(HELPER, mode)
            .env(SIGNAL_PATH, &signal_path)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .process_group(0);
        let mut tree = UnixProcessScope::prepare().unwrap();
        tree.configure(&mut command);
        let mut child = command.spawn().unwrap();
        tree.bind(child.id()).unwrap();
        let mut signal = accepted_receiver
            .recv_timeout(Duration::from_secs(5))
            .expect("detached hook did not connect its lifecycle signal")
            .unwrap();
        acceptor.join().unwrap();
        let mut detached = [0_u8; size_of::<u32>()];
        signal.read_exact(&mut detached).unwrap();
        let detached = u32::from_ne_bytes(detached);
        tree.terminate();
        let _ = child.kill();
        let _ = child.wait();
        signal.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let mut trailing = [0_u8; 1];
        assert_eq!(
            signal.read(&mut trailing).unwrap(),
            0,
            "detached hook {detached} sent unexpected lifecycle data"
        );
        let _ = std::fs::remove_dir_all(root);
    }
}

#[cfg(target_os = "linux")]
#[test]
fn journal_hook_shutdown_cancels_an_active_detached_process_scope() {
    let root = std::env::temp_dir().join(format!(
        "cmux-jh-shutdown-{}-{:x}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    std::fs::create_dir_all(&root).unwrap();
    let signal_path = root.join("detached.sock");
    let listener = std::os::unix::net::UnixListener::bind(&signal_path).unwrap();
    let executable = std::env::current_exe().unwrap();
    let test_name =
        "journal_hooks::tests::unix_hook_tree_kills_a_descendant_that_created_a_new_session";
    let mut hook = manifest();
    hook.exec.argv = vec![
        "/bin/sh".into(),
        "-c".into(),
        "CMUX_TEST_DETACHED_JOURNAL_HOOK=close-fds \
             CMUX_TEST_DETACHED_JOURNAL_HOOK_SIGNAL=\"$3\" \
             \"$1\" --exact \"$2\" --nocapture & wait"
            .into(),
        "cmux-journal-hook-shutdown".into(),
        executable.to_string_lossy().into_owned(),
        test_name.into(),
        signal_path.to_string_lossy().into_owned(),
    ];
    hook.exec.timeout_ms = 30_000;
    let delivery = JournalHookDelivery {
        manifest: hook,
        event: document("plugin.test.shutdown", json!({})).record,
        attempt: 0,
    };
    let attempt = JournalHookAttempt { attempt: 1, causation_id: "event_started".into() };
    let runtime = Arc::new(JournalHookRuntime::default());
    assert!(runtime.begin());
    let worker_runtime = runtime.clone();
    let worker = std::thread::spawn(move || {
        let _guard = JournalHookRuntimeGuard(worker_runtime.clone());
        execute_delivery_with_shutdown(&delivery, &attempt, &worker_runtime.cancelled)
    });
    let (mut signal, _) = listener.accept().unwrap();
    let mut detached = [0_u8; size_of::<u32>()];
    signal.read_exact(&mut detached).unwrap();

    assert!(runtime.shutdown_until(Instant::now() + SHUTDOWN_WAIT));
    let (status, error) = worker.join().unwrap();
    assert_eq!(status, None);
    assert!(error.unwrap().contains("daemon shutdown"));
    signal.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    let mut trailing = [0_u8; 1];
    assert_eq!(signal.read(&mut trailing).unwrap(), 0);
    let _ = std::fs::remove_dir_all(root);
}

#[cfg(windows)]
#[test]
fn portable_hook_stdin_write_obeys_the_execution_timeout() {
    let mut command = Command::new("cmd");
    command
        .args(["/C", "ping -n 30 127.0.0.1 >NUL"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .creation_flags(CREATE_SUSPENDED);
    let mut child = command.spawn().unwrap();
    assert_eq!(child.try_wait().unwrap(), None);
    let process_group = child.id();
    let job = WindowsHookJob::assign(&child).unwrap();
    resume_suspended_hook_child(&child).unwrap();
    let stdin = child.stdin.take().unwrap();
    let timeout = Duration::from_millis(100);
    let started = Instant::now();

    let (status, error) = execute_hook_child_portable(
        &mut child,
        stdin,
        &vec![b'x'; 1024 * 1024],
        process_group,
        timeout,
        &job,
        &AtomicBool::new(false),
    );

    assert_eq!(status, None);
    assert!(error.unwrap().contains("hook timed out"));
    assert!(started.elapsed() < Duration::from_secs(2));
}

#[test]
fn compiled_hook_regex_matches_cached_payload_bytes() {
    let mut manifest = manifest();
    manifest.filter.regex = Some(crate::JournalHookRegex {
        pattern: "needle-[0-9]+".into(),
        field: "payload".into(),
        case_sensitive: true,
    });
    let filter = CompiledHookFilter::new(&manifest).unwrap();
    assert!(filter.matches(&manifest, &document("resource.changed", json!({"v":"needle-42"}))));
    assert!(!filter.matches(&manifest, &document("resource.changed", json!({"v":"other"}))));
}

#[test]
fn compiled_hook_regex_matches_exact_terminal_output_bytes() {
    let mut manifest = manifest();
    manifest.permissions.push("journal.read.sensitive".into());
    manifest.filter.max_sensitivity = Some(JournalSensitivity::Sensitive);
    manifest.filter.regex = Some(crate::JournalHookRegex {
        pattern: "error-[0-9]+".into(),
        field: "terminal_output".into(),
        case_sensitive: true,
    });
    let filter = CompiledHookFilter::new(&manifest).unwrap();
    assert!(filter.matches(&manifest, &terminal_document(b"prompt> error-42\r\n")));
    assert!(!filter.matches(&manifest, &terminal_document(b"prompt> ready\r\n")));
}

#[test]
fn hooks_do_not_reconsume_delivery_events_by_default() {
    let manifest = manifest();
    let filter = CompiledHookFilter::new(&manifest).unwrap();
    assert!(!filter.matches(&manifest, &document("hook.delivery.completed", json!({}))));
}

#[cfg(unix)]
#[test]
fn hook_exit_is_not_blocked_by_a_descendant_holding_stdin_open() {
    let mut manifest = manifest();
    manifest.exec.argv =
        vec!["/bin/sh".into(), "-c".into(), "exec 3<&0; (/bin/sleep 3 <&3) & exit 0".into()];
    let delivery = JournalHookDelivery {
        manifest,
        event: document("plugin.test.large", json!({"value":"x".repeat(1024 * 1024)})).record,
        attempt: 0,
    };
    let attempt = JournalHookAttempt { attempt: 1, causation_id: "event_started".into() };
    let started = Instant::now();
    let (exit_code, error) = execute_delivery(&delivery, &attempt);

    #[cfg(target_os = "macos")]
    {
        assert!(exit_code.is_some_and(|code| code != 0), "{error:?}");
        assert!(error.is_some(), "the macOS process sandbox allowed a hook descendant");
    }
    #[cfg(not(target_os = "macos"))]
    {
        assert_eq!(exit_code, Some(0), "{error:?}");
        assert_eq!(error, None);
    }
    assert!(started.elapsed() < Duration::from_secs(1));
}

#[test]
fn persistent_hook_delivery_records_started_and_completed_receipts() {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-hook-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux =
        Mux::open_persistent("hook-delivery", crate::SurfaceOptions::default(), &root).unwrap();
    let mut hook = manifest();
    hook.filter.kinds = vec!["journal.checkpoint.created".into()];
    mux.put_journal_hook(&hook, "client_test", "hook_manifest_1").unwrap();
    mux.create_journal_checkpoint("client_test", "checkpoint_1").unwrap();

    let deadline = Instant::now() + Duration::from_secs(10);
    let mut cursor = 0;
    let mut epoch = mux.journal_event_epoch();
    let mut started = false;
    let mut completed = false;
    while Instant::now() < deadline && !completed {
        let page = mux.session_journal_after(cursor, 1024).unwrap();
        for record in page.records {
            cursor = record.sequence;
            started |= record.kind == "hook.delivery.started";
            completed |= record.kind == "hook.delivery.completed";
        }
        if !completed {
            epoch = mux.wait_for_journal_event(epoch, Duration::from_secs(1));
        }
    }
    assert!(started, "hook start receipt was not journaled");
    assert!(completed, "hook completion receipt was not journaled");
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
fn hook_causal_descendants_are_not_rescheduled_by_default() {
    let root = std::env::temp_dir().join(format!(
        "cmux-journal-hook-causation-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux =
        Mux::open_persistent("hook-causation", crate::SurfaceOptions::default(), &root).unwrap();
    let producer = JournalProducerManifest {
        producer_id: "loop_test".into(),
        namespace: "plugin.loop_test".into(),
        manifest_version: 1,
        max_sensitivity: JournalSensitivity::Metadata,
        permissions: vec!["journal.append.plugin.loop_test".into()],
        events: vec![JournalEventSchema {
            kind: "plugin.loop_test.event".into(),
            schema_version: 1,
            class: JournalClass::Observation,
            replay: JournalReplayPolicy::Advisory,
            sensitivity: JournalSensitivity::Metadata,
            payload_schema: json!({"type":"object"}),
        }],
    };
    mux.put_journal_producer(&producer, "client_test", "producer_1").unwrap();
    let mut hook = manifest();
    hook.filter.kinds = vec!["plugin.loop_test.event".into()];
    mux.put_journal_hook(&hook, "client_test", "hook_manifest_1").unwrap();

    let source = mux
        .append_journal_ingress(
            &JournalIngress {
                producer_id: "loop_test".into(),
                manifest_version: 1,
                kind: "plugin.loop_test.event".into(),
                schema_version: 1,
                occurred_at_ms: None,
                subjects: Vec::new(),
                sensitivity: None,
                payload: json!({"generation":"source"}),
                causation_id: None,
                correlation_id: None,
            },
            "client_test",
            "source_1",
        )
        .unwrap();
    let deadline = Instant::now() + Duration::from_secs(10);
    let started_event_id = loop {
        let page = mux.session_journal_after(0, 1024).unwrap();
        if let Some(record) = page.records.into_iter().find(|record| {
            record.kind == "hook.delivery.started"
                && record.payload["source_event_id"].as_str() == Some(&source.event_id)
        }) {
            break record.event_id;
        }
        assert!(Instant::now() < deadline, "source delivery did not start");
        let epoch = mux.journal_event_epoch();
        mux.wait_for_journal_event(epoch, Duration::from_millis(100));
    };

    let child = mux
        .append_journal_ingress(
            &JournalIngress {
                producer_id: "loop_test".into(),
                manifest_version: 1,
                kind: "plugin.loop_test.event".into(),
                schema_version: 1,
                occurred_at_ms: None,
                subjects: Vec::new(),
                sensitivity: None,
                payload: json!({"generation":"child"}),
                causation_id: Some(started_event_id),
                correlation_id: None,
            },
            "client_test",
            "child_1",
        )
        .unwrap();
    let causal = mux
        .journal_events_caused_by_hooks(
            &["test_hook".into()],
            std::slice::from_ref(&child.event_id),
        )
        .unwrap();
    assert!(causal.contains(&("test_hook".into(), child.event_id.clone())));

    loop {
        let cursor = mux
            .journal_hook_states()
            .unwrap()
            .into_iter()
            .find(|state| state.enabled && state.manifest.hook_id == "test_hook")
            .unwrap()
            .cursor_sequence;
        if cursor >= child.sequence {
            break;
        }
        assert!(Instant::now() < deadline, "hook cursor did not scan child event");
        let epoch = mux.shared_journal_epoch();
        mux.wait_for_shared_journal(epoch, Duration::from_millis(100));
    }
    let child_starts = mux
        .session_journal_after(0, 1024)
        .unwrap()
        .records
        .into_iter()
        .filter(|record| {
            record.kind == "hook.delivery.started"
                && record.payload["source_event_id"].as_str() == Some(&child.event_id)
        })
        .count();
    assert_eq!(child_starts, 0);
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}

#[test]
#[ignore = "manual release-mode multi-agent hook saturation probe"]
fn multi_agent_hook_saturation_does_not_stall_terminal_ingress() {
    const AGENTS: usize = 64;
    const EVENTS_PER_AGENT: usize = 32;
    const TERMINAL_CHUNKS: usize = 512;
    const TERMINAL_CHUNK_BYTES: usize = 64 * 1024;

    let root = std::env::temp_dir().join(format!(
        "cmux-journal-hook-saturation-{}-{}",
        std::process::id(),
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
    ));
    let mux =
        Mux::open_persistent("hook-saturation", crate::SurfaceOptions::default(), &root).unwrap();
    let mut hook = manifest();
    hook.hook_id = "agent_completion_probe".into();
    hook.filter.kinds = vec!["agent.child.completed".into()];
    hook.filter.max_sensitivity = Some(JournalSensitivity::Sensitive);
    hook.exec.argv = vec!["/bin/sleep".into(), "0.005".into()];
    hook.exec.timeout_ms = 10_000;
    hook.exec.max_parallel = u16::try_from(MAX_DELIVERY_WORKERS).unwrap();
    hook.delivery.retry = JournalHookRetry { max_attempts: 3, backoff_ms: 10 };
    hook.permissions = vec!["journal.read.sensitive".into()];
    mux.put_journal_hook(&hook, "client_probe", "hook_probe_v1").unwrap();

    let barrier = Arc::new(std::sync::Barrier::new(AGENTS + 1));
    let handles = (0..AGENTS)
        .map(|agent| {
            let mux = mux.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                (0..EVENTS_PER_AGENT)
                    .map(|event| {
                        let started = Instant::now();
                        // Include lossless normalization and stable nested
                        // topology hashing in the measured ingress path.
                        let ingress = crate::agent_hook_journal_ingress(
                            "codex",
                            "SubagentStop",
                            None,
                            json!({
                                "session_id":format!("agent-{agent}"),
                                "root_session_id":format!("root-session-{agent}"),
                                "root_agent_id":format!("root-{agent}"),
                                "parent_agent_id":format!("parent-{agent}"),
                                "child_agent_id":format!("child-{agent}-{event}"),
                                "agent_depth":2,
                                "message":"done"
                            }),
                        )
                        .unwrap();
                        mux.append_journal_ingress(
                            &ingress,
                            "client_probe",
                            &format!("agent_{agent}_{event}"),
                        )
                        .unwrap();
                        started.elapsed()
                    })
                    .collect::<Vec<_>>()
            })
        })
        .collect::<Vec<_>>();
    let terminal_id = Arc::new(
        crate::resource::TerminalPublicId::parse("term_00000000000000000000000000000077").unwrap(),
    );
    let generation: Arc<str> = Arc::from("hook-saturation-generation");
    let terminal_chunk = vec![b'x'; TERMINAL_CHUNK_BYTES];
    let append_started = Instant::now();
    barrier.wait();
    let terminal_started = Instant::now();
    let mut maximum_enqueue = Duration::ZERO;
    for _ in 0..TERMINAL_CHUNKS {
        let started = Instant::now();
        mux.journal_terminal_output(
            terminal_id.clone(),
            generation.clone(),
            terminal_chunk.clone(),
        );
        maximum_enqueue = maximum_enqueue.max(started.elapsed());
    }
    mux.flush_terminal_journal().unwrap();
    let terminal_elapsed = terminal_started.elapsed();
    let mut append_latencies =
        handles.into_iter().flat_map(|handle| handle.join().unwrap()).collect::<Vec<_>>();
    let append_elapsed = append_started.elapsed();
    append_latencies.sort_unstable();
    let event_count = append_latencies.len();

    let deadline = Instant::now() + Duration::from_secs(60);
    let mut cursor = 0;
    let mut completed = 0;
    let mut failed_attempts = Vec::new();
    let mut abandoned = Vec::new();
    let mut epoch = mux.journal_event_epoch();
    while completed + abandoned.len() < event_count && Instant::now() < deadline {
        let page = mux.session_journal_after(cursor, 1024).unwrap();
        for record in page.records {
            cursor = record.sequence;
            completed += usize::from(record.kind == "hook.delivery.completed");
            if record.kind == "hook.delivery.failed" {
                failed_attempts.push(record.payload.clone());
            } else if record.kind == "hook.delivery.abandoned" {
                abandoned.push(record.payload.clone());
            }
        }
        if completed + abandoned.len() < event_count {
            epoch = mux.wait_for_journal_event(epoch, Duration::from_millis(100));
        }
    }

    let percentile =
        |percent: usize| append_latencies[(append_latencies.len() - 1) * percent / 100];
    let appends_per_second = event_count as f64 / append_elapsed.as_secs_f64();
    let terminal_mib = TERMINAL_CHUNKS * TERMINAL_CHUNK_BYTES / (1024 * 1024);
    let terminal_mib_per_second = terminal_mib as f64 / terminal_elapsed.as_secs_f64();
    eprintln!(
        "multi-agent hook saturation: {event_count} events from {AGENTS} agents in \
             {append_elapsed:?} ({appends_per_second:.0}/s), ingress p50={:?} p95={:?} \
             p99={:?} max={:?}; terminal {terminal_mib} MiB durable in \
             {terminal_elapsed:?} ({terminal_mib_per_second:.1} MiB/s), max enqueue \
             {maximum_enqueue:?}; {completed} hook children completed, {} attempts retried, \
             {} deliveries abandoned",
        percentile(50),
        percentile(95),
        percentile(99),
        append_latencies.last().unwrap(),
        failed_attempts.len(),
        abandoned.len(),
    );
    assert!(abandoned.is_empty(), "hook deliveries were abandoned: {abandoned:#?}");
    assert_eq!(completed, event_count, "hook deliveries did not drain before the deadline");
    assert!(
        percentile(99) < Duration::from_millis(100),
        "agent ingress p99 regressed to {:?}",
        percentile(99)
    );
    assert!(
        maximum_enqueue < Duration::from_millis(100),
        "terminal enqueue stalled for {maximum_enqueue:?}"
    );
    assert!(
        terminal_mib_per_second >= 10.0,
        "terminal ingress regressed to {terminal_mib_per_second:.1} MiB/s"
    );
    drop(mux);
    std::fs::remove_dir_all(root).unwrap();
}
