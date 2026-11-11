use std::collections::BTreeMap;
use std::sync::Mutex as StdMutex;
use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};

use bytes::Bytes;
use cmux_remote_protocol::{Lane, LanePolicy, SessionId};
use tokio::io::AsyncWriteExt;
use tokio::net::TcpListener;
use tokio::sync::oneshot;
use tokio_tungstenite::accept_hdr_async;
use tokio_tungstenite::tungstenite::handshake::server::Request;
use tokio_tungstenite::tungstenite::protocol::frame::Frame;
use tokio_tungstenite::tungstenite::protocol::frame::coding::{Data, OpCode};

use super::*;

/// The wall clock of [`a_pause_longer_than_the_backoff_resets_the_counters_whichever_wakeup_fires`]:
/// seconds added to a fixed start.
static WALL_AHEAD_S: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

fn test_wall() -> std::time::SystemTime {
    std::time::SystemTime::UNIX_EPOCH
        + Duration::from_secs(1_800_000_000 + WALL_AHEAD_S.load(AtomicOrdering::SeqCst))
}

/// A pause longer than the backoff: at the wakeup the sleep and the clock
/// check are both ready. Whichever `select!` picks, the jump is seen, the
/// counters start over and the next failure waits the first backoff (1 s),
/// not the 60 s from before the pause.
#[tokio::test(start_paused = true)]
async fn a_pause_longer_than_the_backoff_resets_the_counters_whichever_wakeup_fires() {
    use super::liveness::{FIRST_CREDENTIAL_BACKOFF, MAX_CREDENTIAL_BACKOFF};
    // `select!` picks among ready branches at random: many rounds make
    // the sleep branch win at least once.
    for round in 0..32 {
        let mut retry = Retry::new();
        let mut wait = Duration::ZERO;
        while wait < MAX_CREDENTIAL_BACKOFF {
            wait = retry.wait(Ended::Credential, 1.0);
        }
        let (_shutdown_tx, mut shutdown) = watch::channel(false);
        let task = tokio::spawn(async move {
            let waited = back_off(&mut retry, wait, &mut shutdown, test_wall).await;
            (waited, retry)
        });
        // The wait starts and takes its first (immediate) clock check.
        for _ in 0..8 {
            tokio::task::yield_now().await;
        }
        // The machine pauses for ten minutes; its monotonic clock moves
        // past the whole backoff at once, the wall clock ten minutes.
        WALL_AHEAD_S.fetch_add(600, AtomicOrdering::SeqCst);
        tokio::time::advance(wait + CHECK_INTERVAL).await;
        let (waited, mut retry) = task.await.unwrap();
        assert_eq!(waited, Waited::Resumed, "round {round}");
        assert_eq!(
            retry.wait(Ended::Credential, 1.0),
            FIRST_CREDENTIAL_BACKOFF,
            "round {round}: the next failure waits the first backoff"
        );
    }
}

async fn receive_test_control(socket: &mut WebSocketStream<TcpStream>) -> RelayControl {
    let message = socket.next().await.unwrap().unwrap();
    let Message::Text(text) = message else {
        panic!("expected relay control text, got {message:?}");
    };
    serde_json::from_str(&text).unwrap()
}

async fn send_test_control(socket: &mut WebSocketStream<TcpStream>, control: &RelayControl) {
    socket.send(Message::Text(serde_json::to_string(control).unwrap().into())).await.unwrap();
}

#[allow(clippy::result_large_err)] // Required by tungstenite's handshake callback signature.
async fn accept_with_authorization(stream: TcpStream) -> (WebSocketStream<TcpStream>, String) {
    let authorization = Arc::new(StdMutex::new(None));
    let observed = authorization.clone();
    let socket = accept_hdr_async(stream, move |request: &Request, response| {
        let value = request
            .headers()
            .get(AUTHORIZATION)
            .and_then(|value| value.to_str().ok())
            .map(str::to_owned);
        *observed.lock().unwrap() = value;
        Ok(response)
    })
    .await
    .unwrap();
    let authorization = authorization.lock().unwrap().take().unwrap();
    (socket, authorization)
}

/// A relay that takes the TCP connection and never answers the upgrade (a
/// socket that died silently mid-open): the open fails within
/// [`RELAY_CONNECT_TIMEOUT`] as a retryable carrier failure, so a daemon's
/// registration logs it and registers again instead of waiting forever.
#[tokio::test(start_paused = true)]
async fn a_relay_open_with_no_answer_fails_retryably_within_the_connect_timeout() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = Url::parse(&format!("ws://{}", listener.local_addr().unwrap())).unwrap();
    let (held_tx, held_rx) = oneshot::channel();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        // Hold the stream open, unanswered, until the test ends.
        let _ = held_rx.await;
        drop(stream);
    });

    let started = Instant::now();
    let error =
        match connect_relay_socket_once(&endpoint, None, MAX_RELAY_CONTROL_MESSAGE_BYTES).await {
            Ok(_) => panic!("an unanswered relay upgrade opened"),
            Err(error) => error.into_provider_error(),
        };
    assert!(started.elapsed() <= RELAY_CONNECT_TIMEOUT + Duration::from_millis(100));
    assert!(error.to_string().contains("no answer within 10000 ms"), "{error}");
    assert!(error.is_retryable_carrier_failure(), "{error}");
    let _ = held_tx.send(());
    server.await.unwrap();
}

#[tokio::test]
async fn relay_dial_bounds_fragmented_messages_and_disables_nagle() {
    const MAXIMUM: usize = 8;

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = Url::parse(&format!("ws://{}", listener.local_addr().unwrap())).unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
        socket
            .send(Message::Frame(Frame::message(
                Bytes::from_static(b"12345"),
                OpCode::Data(Data::Binary),
                false,
            )))
            .await
            .unwrap();
        socket
            .send(Message::Frame(Frame::message(
                Bytes::from_static(b"67890"),
                OpCode::Data(Data::Continue),
                true,
            )))
            .await
            .unwrap();
    });

    let mut socket = match connect_relay_socket_once(&endpoint, None, MAXIMUM).await {
        Ok(socket) => socket,
        Err(_) => panic!("bounded relay WebSocket dial failed"),
    };
    let MaybeTlsStream::Plain(stream) = socket.get_ref() else {
        panic!("test relay did not use a plain TCP stream");
    };
    assert!(stream.nodelay().unwrap(), "relay dial left Nagle enabled");
    let error = socket
        .next()
        .await
        .expect("relay WebSocket closed before the oversize message")
        .expect_err("relay WebSocket accepted an oversize fragmented message");
    assert!(
        error.to_string().contains("Message too long: 10 > 8"),
        "relay limit was not enforced by the WebSocket codec: {error}"
    );
    server.await.unwrap();
}

#[tokio::test]
async fn established_relay_circuit_treats_retryable_error_as_carrier_loss() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = Url::parse(&format!("ws://{}", listener.local_addr().unwrap())).unwrap();
    let circuit = CircuitId("retryable-error-circuit".into());
    let lane = LaneToken("retryable-error-lane".into());
    let server_circuit = circuit.clone();
    let server_lane = lane.clone();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (mut socket, authorization) = accept_with_authorization(stream).await;
        assert_eq!(authorization, "Bearer join-ticket");
        assert_eq!(
            receive_test_control(&mut socket).await,
            RelayControl::Join {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: "test-slot".into(),
                circuit: server_circuit.clone(),
                lane: server_lane.clone(),
                generation: 4,
                ticket: "join-ticket".into(),
                role: RelayRole::Client,
            }
        );
        send_test_control(
            &mut socket,
            &RelayControl::Ready { circuit: server_circuit, lane: server_lane, generation: 4 },
        )
        .await;
        send_test_control(
            &mut socket,
            &RelayControl::Error {
                code: "peer-disconnected".into(),
                message: "peer disconnected".into(),
                retryable: true,
            },
        )
        .await;
    });

    let link = join_circuit(
        &endpoint,
        "test-slot",
        RelayRole::Client,
        RelayCircuitFraming::Single,
        circuit,
        lane,
        4,
        "join-ticket".into(),
        64,
        Duration::from_secs(1),
    )
    .await
    .unwrap();
    assert!(matches!(link.receive().await, Err(LinkError::Transport(_))));
    server.await.unwrap();
}

#[tokio::test]
async fn relay_circuit_join_timeout_is_retryable_carrier_failure() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = Url::parse(&format!("ws://{}", listener.local_addr().unwrap())).unwrap();
    let circuit = CircuitId("join-timeout-circuit".into());
    let lane = LaneToken("join-timeout-lane".into());
    let server_circuit = circuit.clone();
    let server_lane = lane.clone();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (mut socket, authorization) = accept_with_authorization(stream).await;
        assert_eq!(authorization, "Bearer join-ticket");
        assert_eq!(
            receive_test_control(&mut socket).await,
            RelayControl::Join {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: "test-slot".into(),
                circuit: server_circuit,
                lane: server_lane,
                generation: 5,
                ticket: "join-ticket".into(),
                role: RelayRole::Client,
            }
        );
        let _ = socket.next().await;
    });

    let result = join_circuit(
        &endpoint,
        "test-slot",
        RelayRole::Client,
        RelayCircuitFraming::Single,
        circuit,
        lane,
        5,
        "join-ticket".into(),
        64,
        Duration::from_millis(20),
    )
    .await;
    let error = match result {
        Ok(_) => panic!("relay circuit unexpectedly became ready"),
        Err(error) => error,
    };
    assert!(error.is_retryable_carrier_failure(), "{error}");
    server.await.unwrap();
}

#[tokio::test]
async fn retryable_relay_circuit_rejection_is_retryable_carrier_failure() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = Url::parse(&format!("ws://{}", listener.local_addr().unwrap())).unwrap();
    let circuit = CircuitId("join-rejection-circuit".into());
    let lane = LaneToken("join-rejection-lane".into());
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (mut socket, _) = accept_with_authorization(stream).await;
        assert!(matches!(
            receive_test_control(&mut socket).await,
            RelayControl::Join { generation: 6, .. }
        ));
        send_test_control(
            &mut socket,
            &RelayControl::Error {
                code: "peer-unavailable".into(),
                message: "peer is not ready".into(),
                retryable: true,
            },
        )
        .await;
    });

    let result = join_circuit(
        &endpoint,
        "test-slot",
        RelayRole::Client,
        RelayCircuitFraming::Single,
        circuit,
        lane,
        6,
        "join-ticket".into(),
        64,
        Duration::from_secs(1),
    )
    .await;
    let error = match result {
        Ok(_) => panic!("relay circuit unexpectedly became ready"),
        Err(error) => error,
    };
    assert!(error.is_retryable_carrier_failure(), "{error}");
    server.await.unwrap();
}

#[tokio::test]
async fn retryable_allocation_rejection_is_retryable_carrier_failure() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = Url::parse(&format!("ws://{}", listener.local_addr().unwrap())).unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
        send_test_control(
            &mut socket,
            &RelayControl::Error {
                code: "edge-unavailable".into(),
                message: "try another edge".into(),
                retryable: true,
            },
        )
        .await;
    });

    let mut socket =
        connect_relay_socket(&endpoint, None, MAX_RELAY_CONTROL_MESSAGE_BYTES).await.unwrap();
    let lane = LaneToken("allocation-rejection-lane".into());
    let error = match read_until_allocation(&mut socket, &lane, 7).await {
        Ok(_) => panic!("relay allocation unexpectedly succeeded"),
        Err(error) => error.into_provider_error(),
    };
    assert!(error.is_retryable_carrier_failure(), "{error}");
    server.await.unwrap();
}

#[tokio::test]
async fn relay_registration_timeout_is_retryable_carrier_failure() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (mut socket, authorization) = accept_with_authorization(stream).await;
        assert_eq!(authorization, "Bearer registration-ticket");
        assert!(matches!(receive_test_control(&mut socket).await, RelayControl::Register { .. }));
        let _ = socket.next().await;
    });
    let config = RelayDaemonConfig {
        endpoint: Url::parse(&format!("ws://{address}/v1/relay")).unwrap(),
        slot: "test-slot".into(),
        ticket: String::new(),
        maximum_frame_bytes: 64,
        control_timeout: Duration::from_millis(20),
    };
    let credentials = RelayCredentialSource::static_ticket("registration-ticket").unwrap();

    let result = authenticate_daemon_control(&config, &credentials).await;
    let error = match result {
        Ok(_) => panic!("relay registration unexpectedly succeeded"),
        Err(error) => error,
    };
    assert!(error.is_retryable_carrier_failure(), "{error}");
    server.await.unwrap();
}

#[tokio::test]
async fn closed_relay_control_socket_is_retryable_carrier_failure() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = Url::parse(&format!("ws://{}", listener.local_addr().unwrap())).unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let mut socket = tokio_tungstenite::accept_async(stream).await.unwrap();
        socket.close(None).await.unwrap();
    });

    let mut socket =
        connect_relay_socket(&endpoint, None, MAX_RELAY_CONTROL_MESSAGE_BYTES).await.unwrap();
    let error = read_control(&mut socket).await.unwrap_err();
    assert!(error.is_retryable_carrier_failure(), "{error}");
    server.await.unwrap();
}

#[tokio::test]
async fn cancelling_registration_startup_closes_its_spawned_control_loop() {
    use crate::identity::AuthDatabase;
    use crate::session::SessionLimits;

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = Url::parse(&format!("relay+ws://{}", listener.local_addr().unwrap())).unwrap();
    let (registered_tx, registered_rx) = oneshot::channel();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (mut socket, _) = accept_with_authorization(stream).await;
        assert!(matches!(receive_test_control(&mut socket).await, RelayControl::Register { .. }));
        let _ = registered_tx.send(());
        let closed = tokio::time::timeout(Duration::from_secs(1), socket.next())
            .await
            .expect("cancelled registration left its control socket open");
        matches!(closed, None | Some(Err(_)))
    });

    let directory = tempfile::tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(directory.path(), "relay-cancel", true).unwrap();
    let (daemon, _clients) = RemoteDaemon::new(auth, SessionLimits::default());
    let registration = tokio::spawn(register_relay_daemon(
        daemon,
        RelayDaemonConfig {
            endpoint,
            slot: "cancelled-slot".into(),
            ticket: "registration-ticket".into(),
            maximum_frame_bytes: 65_535,
            control_timeout: Duration::from_secs(5),
        },
    ));
    registered_rx.await.unwrap();
    registration.abort();
    assert!(registration.await.unwrap_err().is_cancelled());
    assert!(server.await.unwrap());
}

#[cfg(unix)]
#[tokio::test]
async fn failed_credential_command_reports_its_status_and_stderr_codes_only() {
    // What `cmux host cloud carrier-ticket` prints for a platform 404.
    let line = "cmux host cloud carrier-ticket: carrier.unavailable: cmux has no carrier \
                    route here yet.";
    let source = RelayCredentialSource::command(
        "/bin/sh",
        ["-c".to_owned(), format!("echo '{line}' >&2; exit 3")],
    );
    let error = source.fetch().await.unwrap_err();
    assert!(is_credential_source_error(&error), "{error}");
    assert_eq!(
        error.to_string(),
        format!(
            "transport provider failed: relay credential source command was unsuccessful (exit status: 3); \
                 stderr: {} bytes, codes carrier.unavailable",
            line.len() + 1
        )
    );
}

#[cfg(unix)]
#[tokio::test]
async fn failed_credential_command_keeps_only_a_bounded_tail() {
    let source = RelayCredentialSource::command(
        "/bin/sh",
        [
            "-c",
            "echo 'auth.refused: early' >&2; head -c 5000 /dev/zero | tr '\\0' x >&2; \
                 echo ' carrier.unreachable: late' >&2; exit 1",
        ],
    );
    let message = source.fetch().await.unwrap_err().to_string();
    assert!(
        message.ends_with(&format!(
            "; stderr: {CREDENTIAL_COMMAND_STDERR_TAIL_BYTES} bytes, codes carrier.unreachable"
        )),
        "{message}"
    );
    assert!(!message.contains("auth.refused"), "the tail is unbounded: {message}");
}

#[cfg(unix)]
#[tokio::test]
async fn oversized_credential_answer_reports_its_stderr_code() {
    // #37670 review 4 F3: a bad answer on stdout keeps stderr's code.
    let script = format!(
        "echo carrier.bad_answer: too long >&2; head -c {} /dev/zero | tr '\\0' a",
        MAX_RELAY_CREDENTIAL_BYTES + 10
    );
    let source = RelayCredentialSource::command_with_timeout(
        "/bin/sh",
        ["-c".to_owned(), script],
        Duration::from_secs(10),
    );
    let message = source.fetch().await.unwrap_err().to_string();
    assert!(message.contains("was too large"), "{message}");
    assert!(message.ends_with("codes carrier.bad_answer"), "{message}");
}

#[cfg(unix)]
#[tokio::test]
async fn timed_out_credential_command_reports_its_stderr_length() {
    let source = RelayCredentialSource::command_with_timeout(
        "/bin/sh",
        ["-c", "echo stuck on the agent >&2; exec sleep 30"],
        Duration::from_millis(200),
    );
    let started = Instant::now();
    let message = source.fetch().await.unwrap_err().to_string();
    assert!(started.elapsed() < Duration::from_secs(5), "the command was not stopped");
    assert!(message.ends_with("timed out after 200 ms; stderr: 19 bytes"), "{message}");
}

#[cfg(unix)]
#[tokio::test]
async fn background_registration_retries_a_failing_ticket_command_until_shutdown() {
    use crate::identity::AuthDatabase;
    use crate::session::SessionLimits;

    let directory = tempfile::tempdir().unwrap();
    let attempts = directory.path().join("attempts");
    let auth = AuthDatabase::load_or_create(directory.path(), "relay-ticket-retry", true).unwrap();
    let (daemon, _clients) = RemoteDaemon::new(auth, SessionLimits::default());
    let registration = spawn_relay_daemon_registration(
        daemon,
        RelayDaemonConfig {
            endpoint: Url::parse("relay+ws://127.0.0.1:9").unwrap(),
            slot: "ticket-retry-slot".into(),
            ticket: String::new(),
            maximum_frame_bytes: 65_535,
            control_timeout: Duration::from_secs(1),
        },
        RelayCredentialSource::command(
            "/bin/sh",
            [
                "-c".to_owned(),
                format!("echo attempt >> '{}'; echo refused >&2; exit 1", attempts.display()),
            ],
        ),
        "test",
    )
    .expect("a failing ticket command is not a configuration error");
    let count = || std::fs::read_to_string(&attempts).map(|text| text.lines().count()).unwrap_or(0);
    tokio::time::timeout(Duration::from_secs(10), async {
        while count() < 2 {
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    })
    .await
    .expect("the registration did not retry the ticket command");
    tokio::time::timeout(Duration::from_secs(1), registration.shutdown())
        .await
        .expect("the registration did not stop at shutdown");
    let stopped = count();
    tokio::time::sleep(Duration::from_millis(1500)).await;
    assert_eq!(count(), stopped, "the registration kept running after shutdown");
}

#[test]
fn a_register_is_logged_with_its_slot_and_time_first_and_after_a_drop() {
    let started = Instant::now();
    let at = |ms| started + Duration::from_millis(ms);
    let mut log =
        RegisterLog::new(Some("cmux-tui: relay registration on relay+wss://r".into()), started);
    assert_eq!(
        log.registered_line("slot-a", at(812)).as_deref(),
        Some(
            "cmux-tui: relay registration on relay+wss://r: registered on slot slot-a after 812 ms"
        )
    );
    log.dropped(at(5_000));
    log.failures = 2;
    assert_eq!(
        log.registered_line("slot-a", at(7_250)).as_deref(),
        Some(
            "cmux-tui: relay registration on relay+wss://r: registered again, 2250 ms after \
                 the drop, on slot slot-a after 7250 ms and 2 failed attempts"
        )
    );
    // A registration with no label (the foreground one) writes nothing.
    assert_eq!(RegisterLog::new(None, started).registered_line("slot-a", at(1)), None);
}

#[test]
fn stderr_summary_names_only_known_codes() {
    // #37670 review 4 F1: a code-shaped secret is not a code.
    let stderr = b"carrier.unavailable: no route; dead.beef password.secret v1.abc.def\n";
    assert_eq!(
        stderr_summary(stderr),
        format!("; stderr: {} bytes, codes carrier.unavailable", stderr.len())
    );
    let stderr = b"dead.beef\n";
    assert_eq!(stderr_summary(stderr), format!("; stderr: {} bytes", stderr.len()));
}

#[test]
fn stderr_summary_keeps_our_ticket_error_codes() {
    // carrier_ticket.rs (cmux-host): every refusal `host cloud
    // carrier-ticket` prints leads with its code.
    for (line, code) in [
        ("carrier.unavailable: cmux has no carrier route here yet.", "carrier.unavailable"),
        ("auth.refused: cmux refused this machine's carrier ticket.", "auth.refused"),
        ("carrier.rate_limited: cmux is rate limited.", "carrier.rate_limited"),
        ("carrier.unreachable: Check this machine's connection.", "carrier.unreachable"),
        ("carrier.bad_answer: cmux did not return a carrier ticket.", "carrier.bad_answer"),
        ("vm.unbound: this machine is not bound to cmux Cloud yet", "vm.unbound"),
        ("vm.agent_unreachable: /run/cmux-vm-agent/agent.sock (refused)", "vm.agent_unreachable"),
        ("carrier.busy: too many asks are waiting; retry", "carrier.busy"),
        // #37670 review F1 (98b5502a): the agent socket's own refusals.
        ("vm.agent_stopping: the Cloud agent is stopping", "vm.agent_stopping"),
        ("vm.agent_bad_answer: the Cloud agent's answer was not JSON", "vm.agent_bad_answer"),
    ] {
        let stderr = format!("cmux host cloud carrier-ticket: {line}\n");
        assert_eq!(
            stderr_summary(stderr.as_bytes()),
            format!("; stderr: {} bytes, codes {code}", stderr.len())
        );
    }
    assert_eq!(
        stderr_summary(b"carrier.unavailable: owner.unreachable carrier.unavailable HTTP/1.1 503"),
        "; stderr: 71 bytes, codes carrier.unavailable, owner.unreachable, HTTP 503"
    );
    let five =
        b"auth.refused carrier.busy vm.unbound carrier.unreachable carrier.bad_answer HTTP 500";
    assert_eq!(
        stderr_summary(five),
        format!(
            "; stderr: {} bytes, codes auth.refused, carrier.busy, vm.unbound, \
                 carrier.unreachable, HTTP 500",
            five.len()
        )
    );
    assert_eq!(stderr_summary(b""), "");
}

#[test]
fn stderr_summary_never_carries_a_secret() {
    let secrets = [
        ("ticket: abcdefgh", "abcdefgh"),
        ("password: abc", "abc"),
        ("Authorization: Bearer abc", "abc"),
        ("token /9j4AAQSkZJRgABAQ1Ab3c+x/YZ answered", "9j4AAQ"),
        ("/abcdefghijklmnopqrst/1234567890", "abcdefghijklmnopqrst"),
        ("/abcdefghijklmnopqrst/1234567890", "1234567890"),
        (r#"{"password": "hunter2"}"#, "hunter2"),
        ("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOjF9.c2lnbmF0dXJl", "eyJ"),
        ("ticket v1.0af3.9c2e", "0af3"),
        ("ticket v1.abc.def", "abc"),
    ];
    for (stderr, secret) in secrets {
        let summary = stderr_summary(stderr.as_bytes());
        assert_eq!(summary, format!("; stderr: {} bytes", stderr.len()), "{stderr}");
        assert!(!summary.contains(secret), "{secret} leaked: {summary}");
    }
}

#[tokio::test]
async fn daemon_registration_retries_transient_initial_carrier_failure() {
    use crate::identity::AuthDatabase;
    use crate::session::SessionLimits;

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let endpoint = Url::parse(&format!("relay+ws://{}", listener.local_addr().unwrap())).unwrap();
    let server = tokio::spawn(async move {
        let (mut failed, _) = listener.accept().await.unwrap();
        failed
            .write_all(
                b"HTTP/1.1 500 Internal Server Error\r\n\
                      Content-Length: 0\r\n\
                      Connection: close\r\n\r\n",
            )
            .await
            .unwrap();
        failed.shutdown().await.unwrap();

        let (stream, _) = tokio::time::timeout(Duration::from_secs(2), listener.accept())
            .await
            .expect("relay daemon did not retry its initial carrier failure")
            .unwrap();
        let (mut socket, authorization) = accept_with_authorization(stream).await;
        assert_eq!(authorization, "Bearer registration-ticket");
        assert!(matches!(receive_test_control(&mut socket).await, RelayControl::Register { .. }));
        send_test_control(&mut socket, &RelayControl::Registered { lease_seconds: 30 }).await;
        while socket.next().await.is_some() {}
    });

    let directory = tempfile::tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(directory.path(), "relay-startup-retry", true).unwrap();
    let (daemon, _clients) = RemoteDaemon::new(auth, SessionLimits::default());
    let registration = tokio::time::timeout(
        Duration::from_secs(2),
        register_relay_daemon(
            daemon,
            RelayDaemonConfig {
                endpoint,
                slot: "startup-retry-slot".into(),
                ticket: "registration-ticket".into(),
                maximum_frame_bytes: 65_535,
                control_timeout: Duration::from_secs(1),
            },
        ),
    )
    .await
    .expect("relay registration did not become ready")
    .expect("transient initial carrier failure stopped relay registration");

    tokio::time::timeout(Duration::from_secs(1), registration.shutdown())
        .await
        .expect("relay registration shutdown did not complete");
    server.await.unwrap();
}

/// A relay that stops answering (a machine resumed after the relay retired
/// its control) is registered with again within seconds, with a fresh
/// ticket from the credential source.
#[tokio::test]
async fn daemon_registers_again_when_the_relay_stops_answering_pings() {
    use crate::identity::AuthDatabase;
    use crate::session::SessionLimits;

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (mut silent, authorization) = accept_with_authorization(stream).await;
        assert_eq!(authorization, "Bearer ticket-1");
        assert!(matches!(receive_test_control(&mut silent).await, RelayControl::Register { .. }));
        // A 3 s lease pings every second; this relay never answers.
        send_test_control(&mut silent, &RelayControl::Registered { lease_seconds: 3 }).await;
        let (stream, _) = tokio::time::timeout(Duration::from_secs(8), listener.accept())
            .await
            .expect("the daemon did not register again after its pings went unanswered")
            .unwrap();
        let (mut second, authorization) = accept_with_authorization(stream).await;
        assert_eq!(authorization, "Bearer ticket-2");
        assert!(matches!(receive_test_control(&mut second).await, RelayControl::Register { .. }));
        send_test_control(&mut second, &RelayControl::Registered { lease_seconds: 30 }).await;
        drop(silent);
        while second.next().await.is_some() {}
    });
    let calls = Arc::new(AtomicUsize::new(0));
    let credentials = RelayCredentialSource::callback({
        let calls = calls.clone();
        move || {
            let value = calls.fetch_add(1, AtomicOrdering::SeqCst) + 1;
            async move { Ok::<_, ()>(format!("ticket-{value}")) }
        }
    });
    let directory = tempfile::tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(directory.path(), "relay-silent", true).unwrap();
    let (daemon, _clients) = RemoteDaemon::new(auth, SessionLimits::default());
    let registration = register_relay_daemon_with_credentials(
        daemon,
        RelayDaemonConfig {
            endpoint: Url::parse(&format!("relay+ws://{address}")).unwrap(),
            slot: "silent-relay-slot".into(),
            ticket: String::new(),
            maximum_frame_bytes: 65_535,
            control_timeout: Duration::from_secs(2),
        },
        credentials,
    )
    .await
    .unwrap();
    tokio::time::timeout(Duration::from_secs(10), async {
        while calls.load(AtomicOrdering::SeqCst) < 2 {
            tokio::task::yield_now().await;
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
    })
    .await
    .expect("no second ticket was asked for");
    tokio::time::timeout(Duration::from_secs(1), registration.shutdown())
        .await
        .expect("relay registration shutdown did not complete");
    server.await.unwrap();
}

#[tokio::test]
async fn provider_description_redacts_relay_capabilities_and_slot() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (mut socket, authorization) = accept_with_authorization(stream).await;
        assert_eq!(authorization, "Bearer provider-ticket");
        let _ = socket.next().await;
    });
    let endpoint =
        Url::parse(&format!("relay+ws://{address}/capability-path?ticket=query-secret#fragment"))
            .unwrap();
    let provider = RelayProvider::new(RelayClientConfig {
        slot: "secret-slot".into(),
        ticket: "provider-ticket".into(),
        maximum_frame_bytes: 65_535,
        control_timeout: Duration::from_secs(1),
    })
    .unwrap();

    let group = provider
        .connect(ConnectRequest {
            endpoint: endpoint.clone(),
            session: SessionId::ZERO,
            lane_policy: LanePolicy::Single,
            routing: BTreeMap::new(),
        })
        .await
        .unwrap();

    assert_eq!(group.description(), sanitized_route(&endpoint));
    group.close().await.unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn daemon_registration_refreshes_after_authentication_rejection() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (mut first, authorization) = accept_with_authorization(stream).await;
        assert_eq!(authorization, "Bearer register-ticket-1");
        assert!(matches!(
            receive_test_control(&mut first).await,
            RelayControl::Register { ticket, .. } if ticket == "register-ticket-1"
        ));
        send_test_control(
            &mut first,
            &RelayControl::Error {
                code: "invalid-ticket".into(),
                message: "rejected".into(),
                retryable: false,
            },
        )
        .await;

        let (stream, _) = listener.accept().await.unwrap();
        let (mut second, authorization) = accept_with_authorization(stream).await;
        assert_eq!(authorization, "Bearer register-ticket-2");
        assert!(matches!(
            receive_test_control(&mut second).await,
            RelayControl::Register { ticket, .. } if ticket == "register-ticket-2"
        ));
        send_test_control(&mut second, &RelayControl::Registered { lease_seconds: 30 }).await;
    });
    let calls = Arc::new(AtomicUsize::new(0));
    let credentials = RelayCredentialSource::callback({
        let calls = calls.clone();
        move || {
            let value = calls.fetch_add(1, AtomicOrdering::SeqCst) + 1;
            async move { Ok::<_, ()>(format!("register-ticket-{value}")) }
        }
    });
    let config = RelayDaemonConfig {
        endpoint: Url::parse(&format!("ws://{address}/v1/relay")).unwrap(),
        slot: "test-slot".into(),
        ticket: String::new(),
        maximum_frame_bytes: 64,
        control_timeout: Duration::from_secs(2),
    };
    let (mut socket, lease) = authenticate_daemon_control(&config, &credentials).await.unwrap();
    assert_eq!(lease, 30);
    assert_eq!(calls.load(AtomicOrdering::SeqCst), 2);
    let _ = socket.close(None).await;
    server.await.unwrap();
}

#[tokio::test]
async fn cancelled_allocation_discards_the_shared_control_socket() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let (first_seen_tx, first_seen_rx) = oneshot::channel();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (mut abandoned_control, authorization) = accept_with_authorization(stream).await;
        assert_eq!(authorization, "Bearer client-ticket");
        assert!(matches!(
            receive_test_control(&mut abandoned_control).await,
            RelayControl::Connect { generation: 1, .. }
        ));
        first_seen_tx.send(()).unwrap();

        let (stream, _) = tokio::time::timeout(Duration::from_secs(10), listener.accept())
            .await
            .expect("retry reused the cancellation-contaminated control socket")
            .unwrap();
        let (mut replacement_control, authorization) = accept_with_authorization(stream).await;
        assert_eq!(authorization, "Bearer client-ticket");
        let RelayControl::Connect { lane, generation, .. } =
            receive_test_control(&mut replacement_control).await
        else {
            panic!("expected retried relay allocation");
        };
        assert_eq!(generation, 2);
        let circuit = CircuitId("after-cancellation".into());
        send_test_control(
            &mut replacement_control,
            &RelayControl::Allocated {
                circuit: circuit.clone(),
                lane: lane.clone(),
                generation,
                join_ticket: "replacement-join-ticket".into(),
            },
        )
        .await;

        let (stream, _) = listener.accept().await.unwrap();
        let (mut circuit_socket, authorization) = accept_with_authorization(stream).await;
        assert_eq!(authorization, "Bearer replacement-join-ticket");
        assert_eq!(
            receive_test_control(&mut circuit_socket).await,
            RelayControl::Join {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: "test-slot".into(),
                circuit: circuit.clone(),
                lane: lane.clone(),
                generation,
                ticket: "replacement-join-ticket".into(),
                role: RelayRole::Client,
            }
        );
        send_test_control(&mut circuit_socket, &RelayControl::Ready { circuit, lane, generation })
            .await;
        let message = circuit_socket.next().await.unwrap().unwrap();
        let Message::Binary(payload) = message else {
            panic!("expected circuit payload, got {message:?}");
        };
        circuit_socket.send(Message::Binary(payload)).await.unwrap();
    });

    let provider = RelayProvider::new(RelayClientConfig {
        slot: "test-slot".into(),
        ticket: "client-ticket".into(),
        maximum_frame_bytes: 64,
        control_timeout: Duration::from_secs(5),
    })
    .unwrap();
    let group = provider
        .connect(ConnectRequest {
            endpoint: Url::parse(&format!("relay+ws://{address}/v1/relay")).unwrap(),
            session: SessionId::ZERO,
            lane_policy: LanePolicy::Single,
            routing: BTreeMap::new(),
        })
        .await
        .unwrap();
    let abandoned = tokio::spawn({
        let group = group.clone();
        async move { group.open(LinkRequest { lane: Lane::Interactive, generation: 1 }).await }
    });
    first_seen_rx.await.unwrap();
    abandoned.abort();
    assert!(matches!(abandoned.await, Err(error) if error.is_cancelled()));

    let link = tokio::time::timeout(
        Duration::from_secs(10),
        group.open(LinkRequest { lane: Lane::Interactive, generation: 2 }),
    )
    .await
    .expect("relay allocation did not recover after cancellation")
    .unwrap();
    assert_eq!(link.maximum_frame_bytes(), 64);
    assert!(matches!(
        link.send(Bytes::from(vec![0_u8; 65])).await,
        Err(LinkError::FrameTooLarge { actual: 65, maximum: 64 })
    ));
    link.send(Bytes::from_static(b"after cancellation")).await.unwrap();
    assert_eq!(link.receive().await.unwrap().unwrap(), b"after cancellation".as_slice());
    link.close().await.unwrap();
    group.close().await.unwrap();
    server.await.unwrap();
}

#[tokio::test]
async fn rotating_credentials_refresh_on_connect_authentication_retry() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (mut failed_control, authorization) = accept_with_authorization(stream).await;
        assert_eq!(authorization, "Bearer client-ticket-1");
        assert!(matches!(
            receive_test_control(&mut failed_control).await,
            RelayControl::Connect { generation: 7, ticket, .. }
                if ticket == "client-ticket-2"
        ));
        send_test_control(
            &mut failed_control,
            &RelayControl::Error {
                code: "unauthorized".into(),
                message: "expired".into(),
                retryable: false,
            },
        )
        .await;

        let (stream, _) = listener.accept().await.unwrap();
        let (mut replacement_control, authorization) = accept_with_authorization(stream).await;
        assert_eq!(authorization, "Bearer client-ticket-3");
        let RelayControl::Connect { lane, generation, ticket, .. } =
            receive_test_control(&mut replacement_control).await
        else {
            panic!("expected client connect on replacement control socket");
        };
        assert_eq!(ticket, "client-ticket-4");
        let circuit = CircuitId("reconnected-circuit".into());
        send_test_control(
            &mut replacement_control,
            &RelayControl::Allocated {
                circuit: circuit.clone(),
                lane: lane.clone(),
                generation,
                join_ticket: "replacement-join-ticket".into(),
            },
        )
        .await;

        let (stream, _) = listener.accept().await.unwrap();
        let (mut circuit_socket, authorization) = accept_with_authorization(stream).await;
        assert_eq!(authorization, "Bearer replacement-join-ticket");
        assert_eq!(
            receive_test_control(&mut circuit_socket).await,
            RelayControl::Join {
                protocol: REMOTE_PROTOCOL_VERSION,
                slot: "test-slot".into(),
                circuit: circuit.clone(),
                lane: lane.clone(),
                generation,
                ticket: "replacement-join-ticket".into(),
                role: RelayRole::Client,
            }
        );
        send_test_control(&mut circuit_socket, &RelayControl::Ready { circuit, lane, generation })
            .await;
        let message = circuit_socket.next().await.unwrap().unwrap();
        let Message::Binary(payload) = message else {
            panic!("expected circuit payload, got {message:?}");
        };
        circuit_socket.send(Message::Binary(payload)).await.unwrap();
        let _ = circuit_socket.next().await;
        let _ = replacement_control.next().await;
    });

    let calls = Arc::new(AtomicUsize::new(0));
    let credentials = RelayCredentialSource::callback({
        let calls = calls.clone();
        move || {
            let value = calls.fetch_add(1, AtomicOrdering::SeqCst) + 1;
            async move { Ok::<_, ()>(format!("client-ticket-{value}")) }
        }
    });
    let provider = RelayProvider::with_credentials(
        RelayClientConfig {
            slot: "test-slot".into(),
            ticket: "legacy-ticket-must-not-be-used".into(),
            maximum_frame_bytes: 64,
            control_timeout: Duration::from_secs(10),
        },
        credentials,
    )
    .unwrap();
    let group = provider
        .connect(ConnectRequest {
            endpoint: Url::parse(&format!("relay+ws://{address}/v1/relay")).unwrap(),
            session: SessionId::ZERO,
            lane_policy: LanePolicy::Isolated,
            routing: BTreeMap::new(),
        })
        .await
        .unwrap();
    let link = tokio::time::timeout(
        Duration::from_secs(10),
        group.open(LinkRequest { lane: Lane::Interactive, generation: 7 }),
    )
    .await
    .unwrap()
    .unwrap();
    link.send(Bytes::from_static(b"after-reconnect")).await.unwrap();
    assert_eq!(link.receive().await.unwrap().unwrap(), &b"after-reconnect"[..]);
    assert_eq!(calls.load(AtomicOrdering::SeqCst), 4);
    link.close().await.unwrap();
    group.close().await.unwrap();
    tokio::time::timeout(Duration::from_secs(10), server).await.unwrap().unwrap();
}

#[tokio::test]
async fn parked_connect_is_answered_on_the_same_request() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (mut control, _) = accept_with_authorization(stream).await;
        let RelayControl::Connect { lane, generation, accepts_parked, .. } =
            receive_test_control(&mut control).await
        else {
            panic!("expected client connect");
        };
        assert!(accepts_parked, "the client must ask for Parked before a relay sends it");
        send_test_control(&mut control, &RelayControl::Parked { lane: lane.clone(), generation })
            .await;
        let circuit = CircuitId("parked-circuit".into());
        send_test_control(
            &mut control,
            &RelayControl::Allocated {
                circuit: circuit.clone(),
                lane: lane.clone(),
                generation,
                join_ticket: "parked-join-ticket".into(),
            },
        )
        .await;

        let (stream, _) = tokio::time::timeout(Duration::from_secs(10), listener.accept())
            .await
            .expect("the client opened no circuit after Parked")
            .unwrap();
        let (mut circuit_socket, authorization) = accept_with_authorization(stream).await;
        assert_eq!(authorization, "Bearer parked-join-ticket");
        assert!(matches!(
            receive_test_control(&mut circuit_socket).await,
            RelayControl::Join { .. }
        ));
        send_test_control(&mut circuit_socket, &RelayControl::Ready { circuit, lane, generation })
            .await;
        let message = circuit_socket.next().await.unwrap().unwrap();
        let Message::Binary(payload) = message else {
            panic!("expected circuit payload, got {message:?}");
        };
        circuit_socket.send(Message::Binary(payload)).await.unwrap();
        let _ = circuit_socket.next().await;
        let _ = control.next().await;
    });

    let provider = RelayProvider::new(RelayClientConfig {
        slot: "test-slot".into(),
        ticket: "client-ticket".into(),
        maximum_frame_bytes: 64,
        control_timeout: Duration::from_secs(5),
    })
    .unwrap();
    let group = provider
        .connect(ConnectRequest {
            endpoint: Url::parse(&format!("relay+ws://{address}/v1/relay")).unwrap(),
            session: SessionId::ZERO,
            lane_policy: LanePolicy::Isolated,
            routing: BTreeMap::new(),
        })
        .await
        .unwrap();
    let link = tokio::time::timeout(
        Duration::from_secs(10),
        group.open(LinkRequest { lane: Lane::Interactive, generation: 3 }),
    )
    .await
    .unwrap()
    .unwrap();
    link.send(Bytes::from_static(b"after-park")).await.unwrap();
    assert_eq!(link.receive().await.unwrap().unwrap(), &b"after-park"[..]);
    link.close().await.unwrap();
    group.close().await.unwrap();
    tokio::time::timeout(Duration::from_secs(10), server).await.unwrap().unwrap();
}

/// A relay that answers one Connect after `delay`, then serves its circuit.
async fn answer_connect_after(
    delay: Duration,
) -> (std::net::SocketAddr, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let (mut control, _) = accept_with_authorization(stream).await;
        let RelayControl::Connect { lane, generation, .. } =
            receive_test_control(&mut control).await
        else {
            panic!("expected client connect");
        };
        tokio::time::sleep(delay).await;
        let circuit = CircuitId("late-circuit".into());
        send_test_control(
            &mut control,
            &RelayControl::Allocated {
                circuit: circuit.clone(),
                lane: lane.clone(),
                generation,
                join_ticket: "late-join-ticket".into(),
            },
        )
        .await;
        let (stream, _) = listener.accept().await.unwrap();
        let (mut circuit_socket, _) = accept_with_authorization(stream).await;
        assert!(matches!(
            receive_test_control(&mut circuit_socket).await,
            RelayControl::Join { .. }
        ));
        send_test_control(&mut circuit_socket, &RelayControl::Ready { circuit, lane, generation })
            .await;
        let _ = circuit_socket.next().await;
        let _ = control.next().await;
    });
    (address, server)
}

/// A relay that holds the first Connect past `control_timeout` (as it
/// parks one until the daemon registers) still answers it inside the
/// provider's allocation deadline, and a hold that outlives the deadline
/// fails as an allocation timeout. A resume (a later generation) keeps
/// `control_timeout`, even once the first connect's deadline has passed.
#[tokio::test]
async fn a_parked_allocation_waits_until_the_allocation_deadline() {
    let config = RelayClientConfig {
        slot: "test-slot".into(),
        ticket: "client-ticket".into(),
        maximum_frame_bytes: 64,
        control_timeout: Duration::from_millis(100),
    };
    let request = |address: std::net::SocketAddr| ConnectRequest {
        endpoint: Url::parse(&format!("relay+ws://{address}/v1/relay")).unwrap(),
        session: SessionId::ZERO,
        lane_policy: LanePolicy::Isolated,
        routing: BTreeMap::new(),
    };
    // Past the 100 ms control timeout, inside the 5 s deadline.
    let (address, server) = answer_connect_after(Duration::from_millis(400)).await;
    let provider = RelayProvider::new(config.clone())
        .unwrap()
        .with_allocation_deadline(Instant::now() + Duration::from_secs(5));
    let group = provider.connect(request(address)).await.unwrap();
    let link = group
        .open(LinkRequest { lane: Lane::Interactive, generation: 0 })
        .await
        .expect("a park inside the deadline is answered");
    link.close().await.unwrap();
    group.close().await.unwrap();
    tokio::time::timeout(Duration::from_secs(10), server).await.unwrap().unwrap();

    // A resume after the deadline passed waits control_timeout, not zero.
    let (address, server) = answer_connect_after(Duration::from_millis(20)).await;
    let provider =
        RelayProvider::new(config.clone()).unwrap().with_allocation_deadline(Instant::now());
    let group = provider.connect(request(address)).await.unwrap();
    let link = group
        .open(LinkRequest { lane: Lane::Interactive, generation: 1 })
        .await
        .expect("a resume keeps control_timeout after the dial's deadline");
    link.close().await.unwrap();
    group.close().await.unwrap();
    tokio::time::timeout(Duration::from_secs(10), server).await.unwrap().unwrap();

    // A park that never ends fails at the deadline, not at control_timeout.
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        // The client's reconnect after the timeout is refused at once.
        drop(listener);
        let (mut control, _) = accept_with_authorization(stream).await;
        let RelayControl::Connect { .. } = receive_test_control(&mut control).await else {
            panic!("expected client connect");
        };
        while control.next().await.is_some() {}
    });
    let started = Instant::now();
    let provider = RelayProvider::new(config)
        .unwrap()
        .with_allocation_deadline(started + Duration::from_millis(600));
    let group = provider.connect(request(address)).await.unwrap();
    let error = group
        .open(LinkRequest { lane: Lane::Interactive, generation: 0 })
        .await
        .err()
        .expect("a park past the deadline fails");
    let waited = started.elapsed();
    assert!(error.to_string().contains("allocation timed out"), "{error}");
    assert!(waited >= Duration::from_millis(500), "gave up after {waited:?}, before the deadline");
    assert!(waited < Duration::from_secs(5), "waited {waited:?}, past the deadline");
    let _ = group.close().await;
    server.abort();
}
