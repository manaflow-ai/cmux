#[cfg(unix)]
use crate::test_exec::write_executable;
use std::fs;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::sync::{Arc, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use cmux_tui_machine_protocol::{
    ConnectExternalMachineParams, ConnectExternalMachineResult, ConnectionClosedEvent,
    EventEnvelope, ExternalMachineSpecifier, HelloResult, NoticeLevel, OpenMachineResult,
    ProviderErrorCode, ProviderNotice, ResponseEnvelope, SnapshotChangedEvent, TransportDescriptor,
    TransportHandshake,
};

use cmux_tui_machine_protocol as protocol;

use super::*;

static NEXT_SOCKET_ID: AtomicU64 = AtomicU64::new(1);

pub(super) struct TestSocket {
    pub(super) path: PathBuf,
    listener: UnixListener,
}

impl TestSocket {
    pub(super) fn bind() -> Self {
        let id = NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir()
            .join(format!("cmux-machine-provider-client-{}-{id}.sock", std::process::id()));
        let _ = fs::remove_file(&path);
        let listener = UnixListener::bind(&path).expect("bind fake provider socket");
        Self { path, listener }
    }

    pub(super) fn listener(&self) -> UnixListener {
        self.listener.try_clone().expect("clone fake provider listener")
    }
}

impl Drop for TestSocket {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
    }
}

pub(super) fn id(value: &str) -> OpaqueId {
    OpaqueId::new(value).expect("valid test id")
}

pub(super) fn token(value: &str) -> BearerToken {
    BearerToken::new(value).expect("valid test token")
}

fn received(event: ProviderEvent) -> ReceivedProviderEvent {
    ReceivedProviderEvent { event, delivery: None }
}

fn durable_notice(notice_id: &str, sequence: u64, message: &str) -> ReceivedProviderEvent {
    ReceivedProviderEvent {
        event: ProviderEvent::Notice(ProviderNotice {
            level: NoticeLevel::Warning,
            message: message.to_string(),
        }),
        delivery: Some(NoticeDelivery { notice_id: id(notice_id), sequence }),
    }
}

pub(super) fn client_descriptor() -> ClientDescriptor {
    ClientDescriptor {
        name: "cmux-test".to_string(),
        version: "0.1.0".to_string(),
        supported_versions: vec![1],
    }
}

pub(super) fn read_test_frame<T: DeserializeOwned>(reader: &mut BufReader<UnixStream>) -> T {
    let frame = read_bounded_frame(reader, MAX_CONTROL_FRAME_BYTES)
        .expect("read fake provider frame")
        .expect("fake provider peer disconnected");
    serde_json::from_slice(&frame).expect("decode fake provider frame")
}

pub(super) fn write_test_frame<T: Serialize>(stream: &mut UnixStream, frame: &T) {
    write_json_frame(stream, frame, MAX_CONTROL_FRAME_BYTES).expect("write fake provider frame");
}

fn accept_hello(stream: &mut UnixStream, reader: &mut BufReader<UnixStream>, expected_token: &str) {
    accept_hello_with_capabilities(stream, reader, expected_token, &[]);
}

pub(super) fn accept_hello_with_capabilities(
    stream: &mut UnixStream,
    reader: &mut BufReader<UnixStream>,
    expected_token: &str,
    capabilities: &[&str],
) {
    let request: RequestEnvelope = read_test_frame(reader);
    let ProviderRequest::Hello(params) = request.request else {
        panic!("first request was not hello");
    };
    assert_eq!(params.token.expose(), expected_token);
    assert_eq!(params.client, client_descriptor());
    write_test_frame(
        stream,
        &ResponseEnvelope::success(
            request.id,
            HelloResult {
                provider_id: id("fake-provider"),
                provider_name: "Fake Provider".to_string(),
                negotiated_version: Version,
            },
        )
        .with_capabilities(capabilities.iter().copied()),
    );
}

#[test]
fn hello_capabilities_enable_only_advertised_lifecycle_requests() {
    let socket = TestSocket::bind();
    let listener = socket.listener();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept control socket");
        let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
        accept_hello_with_capabilities(
            &mut stream,
            &mut reader,
            "provider-secret",
            &[MACHINE_LIFECYCLE_CAPABILITY],
        );

        let request: RequestEnvelope = read_test_frame(&mut reader);
        assert!(matches!(
            &request.request,
            ProviderRequest::MachineLifecycleSnapshot(params)
                if params.scope_id == id("personal")
        ));
        write_test_frame(
            &mut stream,
            &ResponseEnvelope::success(
                request.id,
                MachineLifecycleSnapshotResult {
                    revision: 1,
                    scope_id: id("personal"),
                    machines: Vec::new(),
                },
            ),
        );

        stream.set_read_timeout(Some(Duration::from_millis(250))).unwrap();
        let mut unexpected = String::new();
        match reader.read_line(&mut unexpected) {
            Err(error)
                if matches!(error.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) => {}
            Ok(0) => panic!("provider client disconnected while authenticated"),
            Ok(_) => panic!("provider received an unadvertised request: {unexpected}"),
            Err(error) => panic!("provider read failed: {error}"),
        }
    });

    let (provider, _) = ProviderClient::connect_authenticated(
        &socket.path,
        token("provider-secret"),
        client_descriptor(),
    )
    .expect("authenticate provider");
    assert!(provider.supports_capability(MACHINE_LIFECYCLE_CAPABILITY).unwrap());
    assert!(!provider.supports_capability(WORKSPACE_LIFECYCLE_CAPABILITY).unwrap());
    provider
        .machine_lifecycle_snapshot(id("personal"), None)
        .expect("advertised machine lifecycle request");
    let error = provider
        .workspace_snapshot(id("machine-1"), None)
        .expect_err("unadvertised workspace lifecycle must be rejected locally");
    assert!(matches!(
        error,
        ProviderClientError::UnsupportedCapability(WORKSPACE_LIFECYCLE_CAPABILITY)
    ));
    let error = provider
        .mutate::<ConnectExternalMachineResult>(external_connect_request())
        .expect_err("unadvertised external-machine connect must be rejected locally");
    assert!(matches!(
        error,
        ProviderClientError::UnsupportedCapability(EXTERNAL_MACHINE_CONNECT_CAPABILITY)
    ));

    server.join().expect("join fake provider");
}

#[test]
fn durable_notice_subscription_retains_pre_receiver_delivery_and_acknowledges_it() {
    let socket = TestSocket::bind();
    let listener = socket.listener();
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept control socket");
        let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
        accept_hello_with_capabilities(
            &mut stream,
            &mut reader,
            "provider-secret",
            &[DURABLE_NOTICES_CAPABILITY],
        );

        let subscribe: RequestEnvelope = read_test_frame(&mut reader);
        assert!(matches!(
            subscribe.request,
            ProviderRequest::SubscribeNotices(SubscribeNoticesParams {
                ref consumer_id
            }) if consumer_id == &id("cmux-process-1")
        ));
        let delivery = NoticeDelivery { notice_id: id("usage-warning-80"), sequence: 1 };
        let notice = ProviderNotice {
            level: NoticeLevel::Warning,
            message: "trial has one hour remaining".to_string(),
        };
        write_test_frame(
            &mut stream,
            &EventEnvelope::with_delivery(ProviderEvent::Notice(notice.clone()), delivery.clone()),
        );
        // A replay before ACK has the same stable identity and must not
        // create a second local delivery.
        write_test_frame(
            &mut stream,
            &EventEnvelope::with_delivery(ProviderEvent::Notice(notice), delivery),
        );
        write_test_frame(
            &mut stream,
            &ResponseEnvelope::success(subscribe.id, SubscribeNoticesResult { sequence: 0 }),
        );

        let acknowledge: RequestEnvelope = read_test_frame(&mut reader);
        assert!(matches!(
            acknowledge.request,
            ProviderRequest::AcknowledgeNotice(AcknowledgeNoticeParams {
                ref notice_id,
                sequence: 1,
            }) if notice_id == &id("usage-warning-80")
        ));
        write_test_frame(
            &mut stream,
            &ResponseEnvelope::success(acknowledge.id, AcknowledgeNoticeResult { sequence: 1 }),
        );
        finished.recv().expect("hold provider connection open");
    });

    let (provider, _) = ProviderClient::connect_authenticated(
        &socket.path,
        token("provider-secret"),
        client_descriptor(),
    )
    .expect("authenticate provider");
    assert_eq!(
        provider.subscribe_notices(id("cmux-process-1")).unwrap(),
        SubscribeNoticesResult { sequence: 0 }
    );
    assert!(
        provider.has_retained_durable_notices().unwrap(),
        "replayed durable notice was not retained before the local receiver subscribed"
    );

    let events = provider.subscribe_events().expect("subscribe to retained events");
    let received =
        events.recv_timeout(Duration::from_secs(2)).expect("receive retained durable notice");
    assert_eq!(
        received.delivery,
        Some(NoticeDelivery { notice_id: id("usage-warning-80"), sequence: 1 })
    );
    assert!(matches!(
        received.event,
        ProviderEvent::Notice(ProviderNotice {
            level: NoticeLevel::Warning,
            ref message,
        }) if message == "trial has one hour remaining"
    ));
    assert_eq!(
        events.recv_timeout(Duration::from_millis(20)),
        Err(RecvTimeoutError::Timeout),
        "duplicate replay was delivered twice"
    );

    provider
        .acknowledge_notice(received.delivery.expect("durable metadata"))
        .expect("acknowledge durable notice");
    assert!(
        !provider.has_retained_durable_notices().unwrap(),
        "acknowledged durable notice still appeared in the retained-notice query"
    );
    let after_ack = provider.subscribe_events().expect("resubscribe after ACK");
    assert_eq!(
        after_ack.recv_timeout(Duration::from_millis(20)),
        Err(RecvTimeoutError::Timeout),
        "acknowledged notice remained in the retained backlog"
    );

    finish.send(()).expect("finish provider server");
    drop(provider);
    server.join().expect("join fake provider");
}

#[test]
fn durable_notice_replay_waits_for_the_resumed_subscription_cursor() {
    let socket = TestSocket::bind();
    let listener = socket.listener();
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept control socket");
        let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
        accept_hello_with_capabilities(
            &mut stream,
            &mut reader,
            "provider-secret",
            &[DURABLE_NOTICES_CAPABILITY],
        );

        let subscribe: RequestEnvelope = read_test_frame(&mut reader);
        assert!(matches!(
            subscribe.request,
            ProviderRequest::SubscribeNotices(SubscribeNoticesParams {
                ref consumer_id
            }) if consumer_id == &id("cmux-process-1")
        ));
        for (notice_id, sequence) in [("usage-warning-90", 42), ("usage-warning-91", 43)] {
            write_test_frame(
                &mut stream,
                &EventEnvelope::with_delivery(
                    ProviderEvent::Notice(ProviderNotice {
                        level: NoticeLevel::Warning,
                        message: format!("trial warning {sequence}"),
                    }),
                    NoticeDelivery { notice_id: id(notice_id), sequence },
                ),
            );
        }
        write_test_frame(
            &mut stream,
            &ResponseEnvelope::success(subscribe.id, SubscribeNoticesResult { sequence: 41 }),
        );
        finished.recv().expect("hold provider connection open");
    });

    let (provider, _) = ProviderClient::connect_authenticated(
        &socket.path,
        token("provider-secret"),
        client_descriptor(),
    )
    .expect("authenticate provider");
    // Install the receiver before the cursor response so this assertion
    // exercises complete_notice_subscription's ordered replay path.
    let events = provider.subscribe_events().expect("subscribe to replay events");
    assert_eq!(
        provider.subscribe_notices(id("cmux-process-1")).expect("resume durable subscription"),
        SubscribeNoticesResult { sequence: 41 }
    );
    assert!(provider.is_live(), "valid replay closed the provider connection");
    let first = events
        .recv_timeout(Duration::from_secs(2))
        .expect("receive first replay after cursor initialization");
    assert_eq!(
        first.delivery,
        Some(NoticeDelivery { notice_id: id("usage-warning-90"), sequence: 42 })
    );
    assert!(matches!(
        first.event,
        ProviderEvent::Notice(ProviderNotice { ref message, .. }) if message == "trial warning 42"
    ));
    let second = events
        .recv_timeout(Duration::from_secs(2))
        .expect("receive second replay after cursor initialization");
    assert_eq!(
        second.delivery,
        Some(NoticeDelivery { notice_id: id("usage-warning-91"), sequence: 43 })
    );
    assert!(matches!(
        second.event,
        ProviderEvent::Notice(ProviderNotice { ref message, .. }) if message == "trial warning 43"
    ));

    finish.send(()).expect("finish provider server");
    drop(provider);
    server.join().expect("join fake provider");
}

#[test]
fn durable_notice_methods_are_rejected_without_the_capability() {
    let socket = TestSocket::bind();
    let listener = socket.listener();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept control socket");
        let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
        accept_hello(&mut stream, &mut reader, "provider-secret");
        stream.set_read_timeout(Some(Duration::from_millis(250))).unwrap();
        let mut unexpected = String::new();
        match reader.read_line(&mut unexpected) {
            Err(error)
                if matches!(error.kind(), io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut) => {}
            Ok(0) => {}
            Ok(_) => panic!("provider received an unadvertised request: {unexpected}"),
            Err(error) => panic!("provider read failed: {error}"),
        }
    });

    let (provider, _) = ProviderClient::connect_authenticated(
        &socket.path,
        token("provider-secret"),
        client_descriptor(),
    )
    .expect("authenticate provider");
    assert!(matches!(
        provider.subscribe_notices(id("cmux-process-1")),
        Err(ProviderClientError::UnsupportedCapability(DURABLE_NOTICES_CAPABILITY))
    ));
    assert!(matches!(
        provider
            .acknowledge_notice(NoticeDelivery { notice_id: id("usage-warning-80"), sequence: 1 }),
        Err(ProviderClientError::UnsupportedCapability(DURABLE_NOTICES_CAPABILITY))
    ));

    drop(provider);
    server.join().expect("join fake provider");
}

#[test]
fn unnegotiated_durable_delivery_fails_the_control_connection_closed() {
    let socket = TestSocket::bind();
    let listener = socket.listener();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept control socket");
        let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
        accept_hello(&mut stream, &mut reader, "provider-secret");
        write_test_frame(
            &mut stream,
            &EventEnvelope::with_delivery(
                ProviderEvent::Notice(ProviderNotice {
                    level: NoticeLevel::Warning,
                    message: "unnegotiated".into(),
                }),
                NoticeDelivery { notice_id: id("usage-warning-80"), sequence: 1 },
            ),
        );
    });

    let (provider, _) = ProviderClient::connect_authenticated(
        &socket.path,
        token("provider-secret"),
        client_descriptor(),
    )
    .expect("authenticate provider");
    let deadline = Instant::now() + Duration::from_secs(1);
    while provider.is_live() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(5));
    }
    assert!(!provider.is_live(), "unnegotiated durable delivery remained connected");
    assert!(provider.subscribe_events().is_err());
    drop(provider);
    server.join().expect("join fake provider");
}

#[test]
fn durable_notice_sequences_must_be_contiguous() {
    let socket = TestSocket::bind();
    let listener = socket.listener();
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept control socket");
        let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
        accept_hello_with_capabilities(
            &mut stream,
            &mut reader,
            "provider-secret",
            &[DURABLE_NOTICES_CAPABILITY],
        );
        let subscribe: RequestEnvelope = read_test_frame(&mut reader);
        assert!(matches!(subscribe.request, ProviderRequest::SubscribeNotices(_)));
        write_test_frame(
            &mut stream,
            &EventEnvelope::with_delivery(
                ProviderEvent::Notice(ProviderNotice {
                    level: NoticeLevel::Warning,
                    message: "skipped".into(),
                }),
                NoticeDelivery { notice_id: id("usage-warning-skipped"), sequence: 2 },
            ),
        );
        write_test_frame(
            &mut stream,
            &ResponseEnvelope::success(subscribe.id, SubscribeNoticesResult { sequence: 0 }),
        );
        finished.recv().expect("hold provider connection open");
    });

    let (provider, _) = ProviderClient::connect_authenticated(
        &socket.path,
        token("provider-secret"),
        client_descriptor(),
    )
    .expect("authenticate provider");
    assert!(provider.subscribe_notices(id("cmux-process-1")).is_err());
    assert!(!provider.is_live());
    finish.send(()).expect("finish provider server");
    drop(provider);
    server.join().expect("join fake provider");
}

#[test]
fn acknowledge_notice_requires_the_exact_provider_cursor() {
    let socket = TestSocket::bind();
    let listener = socket.listener();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept control socket");
        let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
        accept_hello_with_capabilities(
            &mut stream,
            &mut reader,
            "provider-secret",
            &[DURABLE_NOTICES_CAPABILITY],
        );
        let subscribe: RequestEnvelope = read_test_frame(&mut reader);
        write_test_frame(
            &mut stream,
            &ResponseEnvelope::success(subscribe.id, SubscribeNoticesResult { sequence: 0 }),
        );
        let acknowledge: RequestEnvelope = read_test_frame(&mut reader);
        assert!(matches!(
            acknowledge.request,
            ProviderRequest::AcknowledgeNotice(AcknowledgeNoticeParams { sequence: 1, .. })
        ));
        write_test_frame(
            &mut stream,
            &ResponseEnvelope::success(acknowledge.id, AcknowledgeNoticeResult { sequence: 2 }),
        );
    });

    let (provider, _) = ProviderClient::connect_authenticated(
        &socket.path,
        token("provider-secret"),
        client_descriptor(),
    )
    .expect("authenticate provider");
    provider.subscribe_notices(id("cmux-process-1")).expect("subscribe notices");
    let error = provider
        .acknowledge_notice(NoticeDelivery { notice_id: id("usage-warning-80"), sequence: 1 })
        .expect_err("provider advanced past the requested notice");
    assert!(matches!(
        error,
        ProviderClientError::Protocol(ref message)
            if message.contains("returned 2 for sequence 1")
    ));
    drop(provider);
    server.join().expect("join fake provider");
}

#[test]
fn external_machine_connect_replays_one_idempotent_provider_result() {
    let socket = TestSocket::bind();
    let listener = socket.listener();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept control socket");
        let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
        accept_hello_with_capabilities(
            &mut stream,
            &mut reader,
            "provider-secret",
            &[EXTERNAL_MACHINE_CONNECT_CAPABILITY],
        );

        for _ in 0..2 {
            let request: RequestEnvelope = read_test_frame(&mut reader);
            let ProviderRequest::ConnectExternalMachine(params) = request.request else {
                panic!("expected connect_external_machine request");
            };
            assert_eq!(params.scope_id, id("team"));
            assert_eq!(params.specifier.expose(), "PAIR 4J7K");
            assert_eq!(params.mutation_id, id("connect-mutation"));
            write_test_frame(
                &mut stream,
                &ResponseEnvelope::success(
                    request.id,
                    ConnectExternalMachineResult {
                        machine_id: id("paired-machine"),
                        revision: 8,
                        notice: Some(ProviderNotice {
                            level: NoticeLevel::Info,
                            message: "Machine connected".into(),
                        }),
                    },
                ),
            );
        }
    });

    let (provider, _) = ProviderClient::connect_authenticated(
        &socket.path,
        token("provider-secret"),
        client_descriptor(),
    )
    .expect("authenticate provider");
    let connect = || provider.mutate::<ConnectExternalMachineResult>(external_connect_request());
    let first = connect().expect("connect external machine");
    let replay = connect().expect("replay external-machine mutation");

    assert_eq!(replay, first);
    assert_eq!(first.machine_id, id("paired-machine"));
    assert_eq!(first.revision, 8);
    drop(provider);
    server.join().expect("join fake provider");
}

#[test]
fn authenticates_once_and_delivers_general_and_snapshot_events() {
    let socket = TestSocket::bind();
    let listener = socket.listener();
    let (send_event, receive_event) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept control socket");
        let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
        accept_hello(&mut stream, &mut reader, "provider-secret");
        receive_event.recv().expect("wait for subscriber");
        write_test_frame(
            &mut stream,
            &EventEnvelope::new(ProviderEvent::SnapshotChanged(SnapshotChangedEvent {
                revision: 42,
            })),
        );
        write_test_frame(
            &mut stream,
            &EventEnvelope::new(ProviderEvent::Notice(ProviderNotice {
                level: NoticeLevel::Warning,
                message: "trial has one day remaining".to_string(),
            })),
        );
        write_test_frame(
            &mut stream,
            &EventEnvelope::new(ProviderEvent::ConnectionClosed(ConnectionClosedEvent {
                connection_id: id("connection-1"),
                machine_id: id("machine-1"),
                reason: "machine suspended".to_string(),
            })),
        );
    });

    let (provider, hello) = ProviderClient::connect_authenticated(
        &socket.path,
        token("provider-secret"),
        client_descriptor(),
    )
    .expect("authenticate provider");
    assert_eq!(hello.provider_id, id("fake-provider"));
    assert!(format!("{:?}", token("provider-secret")).contains("[redacted]"));
    assert!(matches!(
        provider.hello(token("do-not-replay"), client_descriptor()),
        Err(ProviderClientError::AlreadyAuthenticated)
    ));

    let events = provider.subscribe_events().expect("subscribe to all events");
    let revisions = provider.subscribe_snapshot_changes().expect("subscribe to snapshot changes");
    send_event.send(()).expect("trigger provider event");
    let event = events.recv_timeout(Duration::from_secs(2)).expect("receive provider event");
    assert!(matches!(
        event.event,
        ProviderEvent::SnapshotChanged(SnapshotChangedEvent { revision: 42 })
    ));
    let event = events.recv_timeout(Duration::from_secs(2)).expect("receive provider notice");
    assert!(matches!(
        event.event,
        ProviderEvent::Notice(ProviderNotice {
            level: NoticeLevel::Warning,
            ref message,
        }) if message == "trial has one day remaining"
    ));
    let event = events.recv_timeout(Duration::from_secs(2)).expect("receive connection closure");
    assert!(matches!(
        event.event,
        ProviderEvent::ConnectionClosed(ConnectionClosedEvent {
            ref connection_id,
            ref machine_id,
            ref reason,
        }) if connection_id == &id("connection-1")
            && machine_id == &id("machine-1")
            && reason == "machine suspended"
    ));
    assert_eq!(revisions.recv_timeout(Duration::from_secs(2)).expect("receive revision"), 42);
    drop(provider);
    server.join().expect("join fake provider");
}

#[test]
fn full_event_queue_preserves_connection_closed_control_state() {
    let socket = TestSocket::bind();
    let listener = socket.listener();
    let (send_events, receive_events) = mpsc::channel();
    let (finish, finished) = mpsc::channel();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept control socket");
        let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
        accept_hello(&mut stream, &mut reader, "provider-secret");
        receive_events.recv().expect("wait for subscriber");
        for index in 0..PROVIDER_EVENT_QUEUE_CAPACITY {
            write_test_frame(
                &mut stream,
                &EventEnvelope::new(ProviderEvent::Notice(ProviderNotice {
                    level: NoticeLevel::Info,
                    message: format!("queued notice {index}"),
                })),
            );
        }
        write_test_frame(
            &mut stream,
            &EventEnvelope::new(ProviderEvent::ConnectionClosed(ConnectionClosedEvent {
                connection_id: id("revoked-connection"),
                machine_id: id("machine-1"),
                reason: "machine access revoked".to_string(),
            })),
        );

        // The response is ordered after every event on the provider stream.
        // Receiving it proves the client reader has handled the saturated burst.
        let request: RequestEnvelope = read_test_frame(&mut reader);
        assert!(matches!(request.request, ProviderRequest::Snapshot(_)));
        write_test_frame(
            &mut stream,
            &ResponseEnvelope::success(
                request.id,
                SnapshotResult {
                    revision: 1,
                    scopes: Vec::new(),
                    selected_scope_id: id("personal"),
                    machines: Vec::new(),
                    selected_machine_id: None,
                    capabilities: cmux_tui_machine_protocol::ProviderCapabilities {
                        create_machine: false,
                        connect_external_machine: false,
                    },
                    actions: Vec::new(),
                    notice: None,
                },
            ),
        );
        finished.recv().expect("hold provider connection open");
    });

    let (provider, _) = ProviderClient::connect_authenticated(
        &socket.path,
        token("provider-secret"),
        client_descriptor(),
    )
    .expect("authenticate provider");
    let events = provider.subscribe_events().expect("subscribe to all events");
    send_events.send(()).expect("trigger provider events");
    provider.snapshot(None).expect("synchronize after event burst");

    let mut saw_closure = false;
    while let Ok(event) = events.recv_timeout(Duration::from_millis(20)) {
        if matches!(
            event.event,
            ProviderEvent::ConnectionClosed(ConnectionClosedEvent {
                ref connection_id,
                ref machine_id,
                ..
            }) if connection_id == &id("revoked-connection")
                && machine_id == &id("machine-1")
        ) {
            saw_closure = true;
            break;
        }
    }
    finish.send(()).expect("finish provider server");
    drop(provider);
    server.join().expect("join fake provider");

    assert!(saw_closure, "connection closure was dropped behind best-effort events");
}

#[test]
fn repeated_connection_closed_events_coalesce_the_latest_reason() {
    let queue = Arc::new(ProviderEventQueue::new());
    let events = ProviderEventReceiver { queue: Arc::clone(&queue) };
    for index in 0..(PROVIDER_EVENT_QUEUE_CAPACITY * 2) {
        queue
            .publish(received(ProviderEvent::ConnectionClosed(ConnectionClosedEvent {
                connection_id: id("connection-1"),
                machine_id: id("machine-1"),
                reason: format!("revision {index}"),
            })))
            .unwrap();
    }

    let event = events
        .recv_timeout(Duration::from_millis(20))
        .expect("receive coalesced connection closure");
    assert!(matches!(
        event.event,
        ProviderEvent::ConnectionClosed(ConnectionClosedEvent { ref reason, .. })
            if reason == &format!("revision {}", PROVIDER_EVENT_QUEUE_CAPACITY * 2 - 1)
    ));
    assert_eq!(events.recv_timeout(Duration::from_millis(1)), Err(RecvTimeoutError::Timeout));
}

#[test]
fn durable_notices_displace_best_effort_events_and_coalesce_by_notice_id() {
    let queue = Arc::new(ProviderEventQueue::new());
    let events = ProviderEventReceiver { queue: Arc::clone(&queue) };
    for index in 0..PROVIDER_EVENT_QUEUE_CAPACITY {
        queue
            .publish(received(ProviderEvent::Notice(ProviderNotice {
                level: NoticeLevel::Info,
                message: format!("best effort {index}"),
            })))
            .unwrap();
    }

    queue.publish(durable_notice("usage-warning-80", 1, "stable message")).unwrap();
    queue.publish(durable_notice("usage-warning-80", 1, "stable message")).unwrap();

    let mut received_count = 0;
    let mut durable_messages = Vec::new();
    while let Ok(event) = events.recv_timeout(Duration::from_millis(1)) {
        received_count += 1;
        if event.delivery.is_some()
            && let ProviderEvent::Notice(notice) = event.event
        {
            durable_messages.push(notice.message);
        }
    }
    assert_eq!(received_count, PROVIDER_EVENT_QUEUE_CAPACITY);
    assert_eq!(durable_messages, vec!["stable message"]);
}

#[test]
fn distinct_durable_notice_burst_fails_closed_at_priority_capacity() {
    let queue = Arc::new(ProviderEventQueue::new());
    let events = ProviderEventReceiver { queue: Arc::clone(&queue) };
    for index in 0..PROVIDER_EVENT_QUEUE_CAPACITY {
        queue
            .publish(durable_notice(
                &format!("usage-warning-{index}"),
                index as u64 + 1,
                "usage warning",
            ))
            .unwrap();
    }
    assert!(
        queue
            .publish(durable_notice(
                "usage-warning-overflow",
                PROVIDER_EVENT_QUEUE_CAPACITY as u64 + 1,
                "overflow",
            ))
            .is_err()
    );

    let state = queue.state.lock().unwrap();
    assert!(state.events.is_empty());
    assert!(state.disconnected, "durable overflow must force a provider resync");
    drop(state);
    assert_eq!(events.recv_timeout(Duration::from_millis(1)), Err(RecvTimeoutError::Disconnected));
}

#[test]
fn durable_notice_id_cannot_change_sequence() {
    let queue = Arc::new(ProviderEventQueue::new());
    let events = ProviderEventReceiver { queue: Arc::clone(&queue) };
    queue.publish(durable_notice("usage-warning-80", 1, "first")).unwrap();
    assert!(queue.publish(durable_notice("usage-warning-80", 2, "changed")).is_err());
    assert_eq!(events.recv_timeout(Duration::from_millis(1)), Err(RecvTimeoutError::Disconnected));
}

#[test]
fn durable_notice_replay_cannot_change_content() {
    let queue = Arc::new(ProviderEventQueue::new());
    let events = ProviderEventReceiver { queue: Arc::clone(&queue) };
    queue.publish(durable_notice("usage-warning-80", 1, "first")).unwrap();
    assert!(queue.publish(durable_notice("usage-warning-80", 1, "changed")).is_err());
    assert_eq!(events.recv_timeout(Duration::from_millis(1)), Err(RecvTimeoutError::Disconnected));
}

#[test]
fn distinct_connection_closed_burst_fails_closed_at_priority_capacity() {
    let queue = Arc::new(ProviderEventQueue::new());
    let events = ProviderEventReceiver { queue: Arc::clone(&queue) };
    for index in 0..=PROVIDER_EVENT_QUEUE_CAPACITY {
        let _ = queue.publish(received(ProviderEvent::ConnectionClosed(ConnectionClosedEvent {
            connection_id: id(&format!("connection-{index}")),
            machine_id: id(&format!("machine-{index}")),
            reason: "connection revoked".into(),
        })));
    }

    let state = queue.state.lock().unwrap();
    assert!(state.events.len() <= PROVIDER_EVENT_QUEUE_CAPACITY);
    assert!(state.disconnected, "priority overflow must force a provider resync");
    drop(state);
    assert_eq!(events.recv_timeout(Duration::from_millis(1)), Err(RecvTimeoutError::Disconnected));
}

#[test]
fn preserves_typed_provider_errors() {
    let socket = TestSocket::bind();
    let listener = socket.listener();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept control socket");
        let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
        accept_hello(&mut stream, &mut reader, "provider-secret");
        let request: RequestEnvelope = read_test_frame(&mut reader);
        assert!(matches!(request.request, ProviderRequest::Snapshot(_)));
        write_test_frame(
            &mut stream,
            &ResponseEnvelope::<SnapshotResult>::failure(
                request.id,
                ProviderError {
                    code: ProviderErrorCode::PermissionDenied,
                    message: "team access was revoked".to_string(),
                    retryable: false,
                },
            ),
        );
    });

    let (provider, _) = ProviderClient::connect_authenticated(
        &socket.path,
        token("provider-secret"),
        client_descriptor(),
    )
    .expect("authenticate provider");
    let error = provider.snapshot(None).expect_err("snapshot should be rejected");
    let ProviderClientError::Provider(error) = error else {
        panic!("expected typed provider error, got {error:?}");
    };
    assert_eq!(error.code, ProviderErrorCode::PermissionDenied);
    assert_eq!(error.message, "team access was revoked");
    assert!(!error.retryable);
    drop(provider);
    server.join().expect("join fake provider");
}

#[test]
fn rejects_oversized_control_frame_without_waiting_for_timeout() {
    let socket = TestSocket::bind();
    let listener = socket.listener();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept control socket");
        let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
        accept_hello(&mut stream, &mut reader, "provider-secret");
        let request: RequestEnvelope = read_test_frame(&mut reader);
        assert!(matches!(request.request, ProviderRequest::Snapshot(_)));
        let accept_rejection_close = |result: io::Result<()>| {
            if let Err(error) = result {
                assert!(
                    matches!(
                        error.kind(),
                        io::ErrorKind::BrokenPipe
                            | io::ErrorKind::ConnectionAborted
                            | io::ErrorKind::ConnectionReset
                    ),
                    "write oversized frame: {error}"
                );
            }
        };
        accept_rejection_close(stream.write_all(&vec![b'x'; MAX_CONTROL_FRAME_BYTES + 1]));
        accept_rejection_close(stream.write_all(b"\n"));
        accept_rejection_close(stream.flush());
    });

    let (provider, _) = ProviderClient::connect_authenticated(
        &socket.path,
        token("provider-secret"),
        client_descriptor(),
    )
    .expect("authenticate provider");
    let started = Instant::now();
    let error = provider.snapshot(None).expect_err("oversized response must fail");
    assert!(matches!(error, ProviderClientError::FrameTooLarge { limit: MAX_CONTROL_FRAME_BYTES }));
    assert!(started.elapsed() < Duration::from_secs(2));
    drop(provider);
    server.join().expect("join fake provider");
}

#[test]
fn consumes_transport_ticket_in_exactly_one_handshake() {
    let socket = TestSocket::bind();
    let listener = socket.listener();
    let handshakes = Arc::new(AtomicUsize::new(0));
    let server_handshakes = handshakes.clone();
    let server = thread::spawn(move || {
        let (mut control, _) = listener.accept().expect("accept control socket");
        let mut control_reader = BufReader::new(control.try_clone().expect("clone control socket"));
        accept_hello(&mut control, &mut control_reader, "provider-secret");

        let request: RequestEnvelope = read_test_frame(&mut control_reader);
        let ProviderRequest::OpenMachine(params) = request.request else {
            panic!("expected open_machine request");
        };
        assert_eq!(params.machine_id, id("machine-1"));
        write_test_frame(
            &mut control,
            &ResponseEnvelope::success(
                request.id,
                OpenMachineResult {
                    connection_id: id("connection-1"),
                    transport: TransportDescriptor::ProviderStream {
                        ticket: token("one-use-ticket"),
                        expires_at: "2026-07-21T12:00:00Z".to_string(),
                    },
                    workspace_mirror_authority: None,
                },
            ),
        );

        let (mut transport, _) = listener.accept().expect("accept transport socket");
        let mut transport_reader =
            BufReader::new(transport.try_clone().expect("clone transport socket"));
        let mut handshake_frame = String::new();
        transport_reader.read_line(&mut handshake_frame).expect("read exact transport handshake");
        assert_eq!(
            handshake_frame,
            concat!(
                r#"{"protocol":"cmux.machine-provider","version":1,"role":"transport","token":"provider-secret","ticket":"one-use-ticket"}"#,
                "\n"
            ),
            "transport-neutral connectors must preserve the v1 handshake bytes"
        );
        let handshake: TransportHandshake =
            serde_json::from_str(handshake_frame.trim_end()).expect("decode handshake");
        server_handshakes.fetch_add(1, Ordering::Relaxed);
        assert_eq!(handshake.role, TransportRole::Transport);
        assert_eq!(handshake.token.expose(), "provider-secret");
        assert_eq!(handshake.ticket.expose(), "one-use-ticket");
        write_test_frame(&mut transport, &TransportHandshakeResult { accepted: true });
    });

    let (provider, _) = ProviderClient::connect_authenticated(
        &socket.path,
        token("provider-secret"),
        client_descriptor(),
    )
    .expect("authenticate provider");
    let opened = provider.open_machine(id("machine-1"), false).expect("open machine");
    let transport =
        provider.consume_transport(opened.transport).expect("consume one-use transport ticket");
    drop(transport);
    drop(provider);
    server.join().expect("join fake provider");
    assert_eq!(handshakes.load(Ordering::Relaxed), 1);
}

#[test]
fn redacts_transport_ticket_from_command_stream_diagnostics() {
    let script_path = std::env::temp_dir().join(format!(
        "cmux-machine-provider-ticket-redaction-{}-{}.sh",
        std::process::id(),
        NEXT_SOCKET_ID.fetch_add(1, Ordering::Relaxed)
    ));
    write_executable(
        &script_path,
        concat!(
            "#!/bin/sh\n",
            "set -eu\n",
            "role=$1\n",
            "if [ \"$role\" = control ]; then\n",
            "  IFS= read -r _hello\n",
            "  printf '%s\\n' '{\"protocol\":\"cmux.machine-provider\",\"version\":1,\"id\":\"cmux-1\",\"result\":{\"provider_id\":\"fake-provider\",\"provider_name\":\"Fake Provider\",\"negotiated_version\":1}}'\n",
            "  IFS= read -r _open\n",
            "  printf '%s\\n' '{\"protocol\":\"cmux.machine-provider\",\"version\":1,\"id\":\"cmux-2\",\"result\":{\"connection_id\":\"connection-1\",\"transport\":{\"kind\":\"provider_stream\",\"ticket\":\"one-use-ticket\",\"expires_at\":\"2026-07-21T12:00:00Z\"}}}'\n",
            "  while IFS= read -r _line; do :; done\n",
            "else\n",
            "  IFS= read -r handshake\n",
            "  printf '%s\\n' \"$handshake\" >&2\n",
            // Fill more than the stderr pipe so the diagnostic worker must
            // consume the handshake before the process can close stdout.
            "  i=0\n",
            "  while [ \"$i\" -lt 20000 ]; do\n",
            "    printf ' diagnostic-padding' >&2\n",
            "    i=$((i + 1))\n",
            "  done\n",
            "fi\n",
        ),
    );

    let connector = Arc::new(
        CommandProviderConnector::new([script_path.clone().into_os_string()])
            .expect("create command connector"),
    );
    let (provider, _) = ProviderClient::connect_authenticated_with(connector, client_descriptor())
        .expect("authenticate command provider");
    let opened = provider.open_machine(id("machine-1"), false).expect("open machine");
    let Err(error) = provider.consume_transport(opened.transport) else {
        panic!("stream command must disconnect during its handshake");
    };
    let diagnostic = error.to_string();

    drop(provider);
    let _ = fs::remove_file(script_path);
    assert!(diagnostic.contains("[redacted]"), "credential was not redacted: {diagnostic}");
    assert!(
        !diagnostic.contains("one-use-ticket"),
        "one-use transport ticket leaked through diagnostics"
    );
}

#[test]
fn cancels_pending_request_when_provider_reaches_eof() {
    let socket = TestSocket::bind();
    let listener = socket.listener();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().expect("accept control socket");
        let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
        accept_hello(&mut stream, &mut reader, "provider-secret");
        let request: RequestEnvelope = read_test_frame(&mut reader);
        assert!(matches!(request.request, ProviderRequest::Snapshot(_)));
        // Dropping the stream produces EOF while the request is pending.
    });

    let (provider, _) = ProviderClient::connect_authenticated(
        &socket.path,
        token("provider-secret"),
        client_descriptor(),
    )
    .expect("authenticate provider");
    let started = Instant::now();
    let error = provider.snapshot(None).expect_err("EOF must cancel the request");
    assert!(matches!(error, ProviderClientError::Disconnected));
    assert!(started.elapsed() < Duration::from_secs(2));
    drop(provider);
    server.join().expect("join fake provider");
}

/// Ten milliseconds of test time per production second.
fn scaled(seconds: u64) -> Duration {
    Duration::from_millis(seconds * 10)
}

fn scaled_deadlines() -> ProviderRequestDeadlines {
    let production = ProviderRequestDeadlines::PRODUCTION;
    ProviderRequestDeadlines {
        control: scaled(production.control.as_secs()),
        create: scaled(production.create.as_secs()),
        open: scaled(production.open.as_secs()),
    }
}

#[test]
fn a_create_slower_than_the_control_bound_is_not_a_timeout() {
    let socket = TestSocket::bind();
    let listener = socket.listener();
    // A scoped thread: the scope owns the fake provider, joins it on exit,
    // and re-raises its panic.
    thread::scope(|scope| {
        scope.spawn(move || {
            let (mut stream, _) = listener.accept().expect("accept control socket");
            let mut reader = BufReader::new(stream.try_clone().expect("clone control socket"));
            accept_hello(&mut stream, &mut reader, "provider-secret");

            // The control request is never answered, proving the scaled
            // control bound is shorter than the create's answer below.
            let snapshot: RequestEnvelope = read_test_frame(&mut reader);
            assert!(matches!(snapshot.request, ProviderRequest::Snapshot(_)));

            // Measured server creates take up to 28 s and the carrier wait can
            // reach 35 s; answer at 35 scaled seconds.
            let create: RequestEnvelope = read_test_frame(&mut reader);
            assert!(matches!(create.request, ProviderRequest::CreateMachine(_)));
            thread::sleep(scaled(35));
            write_test_frame(
                &mut stream,
                &ResponseEnvelope::success(
                    create.id,
                    protocol::CreateMachineResult {
                        machine_id: id("machine-1"),
                        revision: 2,
                        notice: None,
                    },
                ),
            );
        });

        let (provider, _) = ProviderClient::connect_authenticated(
            &socket.path,
            token("provider-secret"),
            client_descriptor(),
        )
        .expect("authenticate provider");
        provider.set_request_deadlines(scaled_deadlines());
        let error = provider.snapshot(None).expect_err("an unanswered control request times out");
        assert!(matches!(error, ProviderClientError::Timeout));

        let created: protocol::CreateMachineResult = provider
            .mutate(ProviderRequest::CreateMachine(protocol::CreateMachineParams {
                scope_id: id("personal"),
                mutation_id: id("create-1"),
            }))
            .expect("a create slower than the control bound must not time out");
        assert_eq!(created.machine_id, id("machine-1"));
        drop(provider);
    });
}

/// Mutations allowed on the 30 second control bound, each with the reason
/// a slow answer there can neither show an error for a machine that is
/// still coming up nor make a duplicate. A mutation missing from this
/// list must take a longer bound in `ProviderRequestDeadlines`.
const CONTROL_BOUND_MUTATIONS: &[(&str, &str)] = &[
    (
        "connect_external_machine",
        "enrollment only checks a pairing code; PendingExternalConnect replays its mutation_id",
    ),
    ("rename_machine", "metadata write; the runtime replays its mutation_id after a timeout"),
    (
        "delete_machine",
        "marks the machine deleted and tears down after answering; replayed after a timeout",
    ),
    (
        "restore_machine",
        "clears the deleted mark; the machine wakes on open; replayed after a timeout",
    ),
    (
        "purge_machine",
        "teardown runs after the answer; the runtime replays its mutation_id after a timeout",
    ),
    ("rename_workspace", "metadata write; the runtime replays its mutation_id after a timeout"),
    (
        "delete_workspace",
        "marks the workspace deleted; the runtime replays its mutation_id after a timeout",
    ),
    (
        "restore_workspace",
        "clears the deleted mark; the runtime replays its mutation_id after a timeout",
    ),
    (
        "purge_workspace",
        "teardown runs after the answer; the runtime replays its mutation_id after a timeout",
    ),
    (
        "invoke_action",
        "provider actions answer with a notice or URL, not a machine; replayed after a timeout",
    ),
];

/// One request per `ProviderRequest` kind. `request_kind_index` names
/// every kind, so adding one fails to compile until it has a sample here.
fn every_provider_request() -> Vec<ProviderRequest> {
    let machine_mutation = || protocol::MachineMutationParams {
        scope_id: id("personal"),
        machine_id: id("machine-1"),
        expected_version: 1,
        mutation_id: id("mutation-1"),
    };
    let workspace_mutation = || protocol::WorkspaceMutationParams {
        machine_id: id("machine-1"),
        workspace_id: id("workspace-1"),
        expected_version: 1,
        mutation_id: id("mutation-1"),
    };
    let requests = vec![
        ProviderRequest::Hello(HelloParams {
            token: token("provider-secret"),
            client: client_descriptor(),
        }),
        ProviderRequest::NegotiateClientCapabilities(NegotiateClientCapabilitiesParams {
            capabilities: Vec::new(),
        }),
        ProviderRequest::SubscribeNotices(SubscribeNoticesParams { consumer_id: id("consumer-1") }),
        ProviderRequest::AcknowledgeNotice(AcknowledgeNoticeParams {
            notice_id: id("notice-1"),
            sequence: 1,
        }),
        ProviderRequest::Snapshot(SnapshotParams { known_revision: None }),
        ProviderRequest::OpenMachine(OpenMachineParams {
            machine_id: id("machine-1"),
            workspace_mirror_authority: false,
        }),
        ProviderRequest::SelectScope(SelectScopeParams { scope_id: id("personal") }),
        ProviderRequest::CreateMachine(protocol::CreateMachineParams {
            scope_id: id("personal"),
            mutation_id: id("mutation-1"),
        }),
        ProviderRequest::ConnectExternalMachine(ConnectExternalMachineParams {
            scope_id: id("personal"),
            specifier: ExternalMachineSpecifier::new("PAIR 4J7K").unwrap(),
            mutation_id: id("mutation-1"),
        }),
        ProviderRequest::MachineLifecycleSnapshot(MachineLifecycleSnapshotParams {
            scope_id: id("personal"),
            known_revision: None,
        }),
        ProviderRequest::RenameMachine(protocol::RenameMachineParams {
            scope_id: id("personal"),
            machine_id: id("machine-1"),
            expected_version: 1,
            display_name: "Renamed".into(),
            mutation_id: id("mutation-1"),
        }),
        ProviderRequest::DeleteMachine(machine_mutation()),
        ProviderRequest::RestoreMachine(machine_mutation()),
        ProviderRequest::PurgeMachine(machine_mutation()),
        ProviderRequest::CreateWorkspace(protocol::CreateWorkspaceParams {
            machine_id: id("machine-1"),
            mode: protocol::WorkspaceCreateMode::Isolated,
            mutation_id: id("mutation-1"),
        }),
        ProviderRequest::WorkspaceSnapshot(WorkspaceSnapshotParams {
            machine_id: id("machine-1"),
            known_revision: None,
        }),
        ProviderRequest::RenameWorkspace(protocol::RenameWorkspaceParams {
            machine_id: id("machine-1"),
            workspace_id: id("workspace-1"),
            expected_version: 1,
            display_name: "Renamed".into(),
            mutation_id: id("mutation-1"),
        }),
        ProviderRequest::DeleteWorkspace(workspace_mutation()),
        ProviderRequest::RestoreWorkspace(workspace_mutation()),
        ProviderRequest::PurgeWorkspace(workspace_mutation()),
        ProviderRequest::InvokeAction(protocol::InvokeActionParams {
            action_id: id("action-1"),
            values: std::collections::BTreeMap::new(),
            machine_id: None,
            workspace_id: None,
            mutation_id: id("mutation-1"),
        }),
        ProviderRequest::CloseMachine(CloseMachineParams { connection_id: id("connection-1") }),
    ];
    let kinds: std::collections::BTreeSet<usize> =
        requests.iter().map(request_kind_index).collect();
    assert_eq!(kinds.len(), PROVIDER_REQUEST_KINDS, "every request kind needs one sample");
    requests
}

const PROVIDER_REQUEST_KINDS: usize = 22;

fn request_kind_index(request: &ProviderRequest) -> usize {
    match request {
        ProviderRequest::Hello(_) => 0,
        ProviderRequest::NegotiateClientCapabilities(_) => 1,
        ProviderRequest::SubscribeNotices(_) => 2,
        ProviderRequest::AcknowledgeNotice(_) => 3,
        ProviderRequest::Snapshot(_) => 4,
        ProviderRequest::OpenMachine(_) => 5,
        ProviderRequest::SelectScope(_) => 6,
        ProviderRequest::CreateMachine(_) => 7,
        ProviderRequest::ConnectExternalMachine(_) => 8,
        ProviderRequest::MachineLifecycleSnapshot(_) => 9,
        ProviderRequest::RenameMachine(_) => 10,
        ProviderRequest::DeleteMachine(_) => 11,
        ProviderRequest::RestoreMachine(_) => 12,
        ProviderRequest::PurgeMachine(_) => 13,
        ProviderRequest::CreateWorkspace(_) => 14,
        ProviderRequest::WorkspaceSnapshot(_) => 15,
        ProviderRequest::RenameWorkspace(_) => 16,
        ProviderRequest::DeleteWorkspace(_) => 17,
        ProviderRequest::RestoreWorkspace(_) => 18,
        ProviderRequest::PurgeWorkspace(_) => 19,
        ProviderRequest::InvokeAction(_) => 20,
        ProviderRequest::CloseMachine(_) => 21,
    }
}

/// Detector: a request carrying a `mutation_id` must not sit on the 30 s
/// control bound unless `CONTROL_BOUND_MUTATIONS` says why that is safe.
#[test]
fn no_mutation_is_bounded_by_the_control_timeout_without_a_listed_reason() {
    let deadlines = ProviderRequestDeadlines::PRODUCTION;
    let mut control_bound = Vec::new();
    for request in every_provider_request() {
        let wire = serde_json::to_value(&request).expect("encode request");
        let method = wire["method"].as_str().expect("request method").to_string();
        let carries_mutation_id = wire["params"].get("mutation_id").is_some();
        let mut probe = request.clone();
        assert_eq!(
            request_mutation_id_mut(&mut probe).is_some(),
            carries_mutation_id,
            "{method}: request_mutation_id_mut disagrees with the wire shape"
        );
        let reason = CONTROL_BOUND_MUTATIONS
            .iter()
            .find(|(listed, _)| *listed == method)
            .map(|(_, reason)| *reason);
        if carries_mutation_id && deadlines.for_request(&request) == PROVIDER_REQUEST_TIMEOUT {
            assert!(
                reason.is_some_and(|reason| !reason.trim().is_empty()),
                "{method} carries a mutation_id but is bounded by the 30 s control timeout \
                 with no reason in CONTROL_BOUND_MUTATIONS; give it a longer bound in \
                 ProviderRequestDeadlines::for_request or list why 30 s is safe"
            );
            control_bound.push(method);
        } else {
            assert!(
                reason.is_none(),
                "{method} is listed in CONTROL_BOUND_MUTATIONS but is not a control-bound mutation"
            );
        }
    }
    assert_eq!(control_bound.len(), CONTROL_BOUND_MUTATIONS.len());
    // The server holds a create reservation for 120 s.
    assert!(PROVIDER_CREATE_TIMEOUT > Duration::from_secs(120));
    assert_eq!(
        deadlines.for_request(&ProviderRequest::CreateMachine(protocol::CreateMachineParams {
            scope_id: id("personal"),
            mutation_id: id("mutation-1"),
        })),
        PROVIDER_CREATE_TIMEOUT
    );
}

fn external_connect_request() -> ProviderRequest {
    ProviderRequest::ConnectExternalMachine(ConnectExternalMachineParams {
        scope_id: id("team"),
        specifier: ExternalMachineSpecifier::new("PAIR 4J7K").unwrap(),
        mutation_id: id("connect-mutation"),
    })
}
