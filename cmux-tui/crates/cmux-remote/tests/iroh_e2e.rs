#![cfg(all(unix, feature = "iroh-transport"))]

//! Full-stack coverage for the Iroh carrier.
//!
//! Every other provider has an end-to-end test that drives the real daemon
//! through invitation enrollment, Noise, and the service layer: `direct_ws_e2e`,
//! `direct_wss_e2e`, `relay_e2e`, `pty_reconnect_e2e`. Iroh had none. Its inline
//! tests cover the carrier mechanics well, but all of them bind with
//! `RelayMode::Disabled` on loopback and stop at raw frames, so the two things a
//! phone depends on were never exercised: a relayed path, and a PTY driven
//! across one.
//!
//! Both tests here run against a relay server spawned in-process over plaintext
//! HTTP, so they need no network and no certificate handling.

use std::collections::BTreeMap;
use std::net::Ipv4Addr;
use std::time::Duration;

use cmux_remote::client::{ProcessEventStream, WorkspaceClient};
use cmux_remote::connection::{ClientConnection, ClientConnectionConfig, ReconnectPolicy};
use cmux_remote::crypto::{ClientAuthMode, StaticIdentity};
use cmux_remote::daemon::RemoteDaemon;
use cmux_remote::identity::AuthDatabase;
use cmux_remote::observability::{ConnectionState, TransportPathKind};
use cmux_remote::provider::{
    ConnectRequest, IrohListener, IrohPathMode, IrohProvider, IrohProviderConfig, TransportProvider,
};
use cmux_remote::service::{EndpointRole, ServiceMultiplexer};
use cmux_remote::services::DaemonServices;
use cmux_remote::session::SessionLimits;
use cmux_remote::workspace::WorkspaceService;
use cmux_remote_protocol::{
    ByteString, LanePolicy, ProcessEnvironment, ProcessEvent, ProcessIo, ProcessLifetime,
    PtyEofPolicy, SessionId, WorkspaceRequest, WorkspaceResponse,
};
use iroh::{RelayMode, RelayUrl, SecretKey};
use iroh_relay::server::{RelayConfig as RelayServerConfig, Server, ServerConfig};
use tempfile::tempdir;
use url::Url;
use zeroize::Zeroizing;

const TEST_TIMEOUT: Duration = Duration::from_secs(60);

/// A relay server without TLS. The iroh relay client maps an `http` relay URL to
/// a plaintext `ws` upgrade, which keeps this test free of certificate setup.
async fn spawn_plaintext_relay() -> (Server, RelayUrl) {
    let mut config = ServerConfig::default();
    config.relay = Some(RelayServerConfig::new((Ipv4Addr::LOCALHOST, 0)));
    config.quic = None;
    let server = Server::spawn(config).await.expect("could not spawn the test relay server");
    let address = server.http_addr().expect("the test relay server has no HTTP address");
    let url: RelayUrl = format!("http://{address}").parse().expect("invalid test relay URL");
    (server, url)
}

/// The selected path is published once the carrier settles, which for a relayed
/// connection happens after the first frames move. Polling keeps the assertion
/// meaningful without making it a race.
async fn wait_for_path_kind(client: &ClientConnection, expected: TransportPathKind) {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    let mut last = None;
    while tokio::time::Instant::now() < deadline {
        let snapshot = client.snapshot().await;
        last = snapshot.transport.selected_path.clone();
        if last.as_ref().is_some_and(|path| path.kind == expected) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("Iroh never selected a {expected:?} path; last published path was {last:?}");
}

async fn wait_for_output(events: &ProcessEventStream, transcript: &mut Vec<u8>, expected: &str) {
    tokio::time::timeout(Duration::from_secs(15), async {
        loop {
            if String::from_utf8_lossy(transcript).contains(expected) {
                return;
            }
            let event = events
                .receive()
                .await
                .expect("the process event stream failed")
                .expect("the process event stream closed before the expected output");
            match event.event {
                ProcessEvent::Stdout { data, .. } | ProcessEvent::Stderr { data, .. } => {
                    transcript.extend(data.decode().unwrap());
                }
                ProcessEvent::Exit { code, signal, .. } => {
                    panic!("the PTY exited before producing {expected:?}: {code:?} {signal:?}");
                }
                other => panic!("unexpected process event before {expected:?}: {other:?}"),
            }
        }
    })
    .await
    .unwrap_or_else(|_| {
        panic!(
            "timed out waiting for {expected:?}; transcript so far: {:?}",
            String::from_utf8_lossy(transcript)
        )
    });
}

/// Enrolls a client over Iroh and drives a real PTY through the daemon's
/// workspace service, asserting the carrier took the expected path.
async fn pty_over_iroh(path_mode: IrohPathMode, expected_path: TransportPathKind) {
    let relay = match path_mode {
        IrohPathMode::DirectOnly => None,
        _ => Some(spawn_plaintext_relay().await),
    };
    let relay_mode = match &relay {
        Some((_, url)) => RelayMode::custom([url.clone()]),
        None => RelayMode::Disabled,
    };

    let state = tempdir().unwrap();
    let root = tempdir().unwrap();
    let auth = AuthDatabase::load_or_create(state.path(), "iroh-e2e", false).unwrap();
    let (daemon, mut accepted) = RemoteDaemon::new(auth.clone(), SessionLimits::default());

    let listener = IrohListener::bind(
        daemon,
        IrohProviderConfig {
            secret_key: Some(SecretKey::from_bytes(&[21; 32])),
            relay_mode: relay_mode.clone(),
            path_mode,
            discovery_n0: false,
            ..IrohProviderConfig::default()
        },
    )
    .await
    .unwrap();
    let route = listener.route().await.unwrap();
    if !matches!(path_mode, IrohPathMode::DirectOnly) {
        assert!(
            route.node_addr().relay_urls().next().is_some(),
            "the daemon endpoint came online without a home relay, so a relayed \
             client would have no route to publish"
        );
    }

    // The invitation carries the daemon's own address as a route hint, which is
    // what a phone scans. Enrollment is separate from the carrier: the endpoint
    // identity is a route credential, not daemon authorization.
    let invitation = auth
        .create_invitation(Duration::from_secs(60), vec![format!("iroh://{}", route.node_id())])
        .await
        .unwrap();
    let approver = tokio::spawn({
        let auth = auth.clone();
        async move {
            let pending = auth.wait_for_pending(Duration::from_secs(15)).await.unwrap();
            auth.approve(&pending[0].invitation_id).await.unwrap();
        }
    });

    let provider = IrohProvider::new(IrohProviderConfig {
        secret_key: Some(SecretKey::from_bytes(&[22; 32])),
        relay_mode,
        path_mode,
        discovery_n0: false,
        ..IrohProviderConfig::default()
    })
    .unwrap();
    let session = SessionId([23; 16]);
    let group = provider
        .connect(ConnectRequest {
            endpoint: Url::parse(&format!("iroh://{}", route.node_id())).unwrap(),
            session,
            lane_policy: LanePolicy::Isolated,
            routing: route.routing_hints(),
        })
        .await
        .unwrap();

    let invitation_secret = invitation.secret_bytes().unwrap();
    let client = ClientConnection::connect(
        group,
        ClientConnectionConfig {
            identity: StaticIdentity::generate().unwrap(),
            expected_daemon: Some(auth.identity().public_key()),
            auth: ClientAuthMode::Invitation {
                id: invitation.id,
                secret: Zeroizing::new(invitation_secret),
            },
            device_name: "iroh-e2e-client".into(),
            session,
            lane_policy: LanePolicy::Isolated,
            limits: SessionLimits::default(),
            reconnect: ReconnectPolicy { maximum_attempts: Some(3), ..ReconnectPolicy::default() },
        },
    )
    .await
    .unwrap();
    approver.await.unwrap();
    let server =
        tokio::time::timeout(Duration::from_secs(15), accepted.recv()).await.unwrap().unwrap();

    let snapshot = client.snapshot().await;
    assert_eq!(snapshot.state, ConnectionState::Connected);
    assert_eq!(snapshot.transport.provider, "iroh");
    assert!(snapshot.transport.route.starts_with("iroh://"), "{}", snapshot.transport.route);

    let services = DaemonServices::new(WorkspaceService::new(), None);
    let service_task = tokio::task::spawn_local({
        let services = services.clone();
        let server = server.clone();
        async move { services.serve_client(server).await }
    });

    let multiplexer = ServiceMultiplexer::new(client.clone(), EndpointRole::Client);
    let workspace = WorkspaceClient::connect(multiplexer.clone()).await.unwrap();
    let opened = workspace
        .request(WorkspaceRequest::OpenWorkspace {
            root: root.path().to_string_lossy().into_owned(),
        })
        .await
        .unwrap();
    let WorkspaceResponse::Workspace { id: workspace_id, .. } = opened else {
        panic!("open-workspace returned the wrong response: {opened:?}");
    };

    // A shell on a PTY that reports its own size, so a resize is observable in
    // the byte stream rather than only in the response.
    let process = workspace.allocate_process_handle();
    let started = workspace
        .spawn_process_with_events(
            process,
            WorkspaceRequest::SpawnProcess {
                workspace: workspace_id,
                argv: vec![
                    "/bin/sh".into(),
                    "-c".into(),
                    concat!(
                        "stty -echo; ",
                        "printf 'READY PID=%s\\n' \"$$\"; ",
                        "while IFS= read -r line; do ",
                        "set -- $(stty size); ",
                        "printf 'PID=%s ROWS=%s COLS=%s INPUT=%s\\n' ",
                        "\"$$\" \"$1\" \"$2\" \"$line\"; ",
                        "done"
                    )
                    .into(),
                ],
                cwd: None,
                env: BTreeMap::new(),
                io: ProcessIo::Pty {
                    cols: 80,
                    rows: 24,
                    term: "xterm-256color".into(),
                    eof: PtyEofPolicy::Reject,
                },
                lifetime: ProcessLifetime::Workspace,
                operation: None,
                timeout_ms: Some(60_000),
                retained_output_bytes: Some(64 * 1024),
                environment: ProcessEnvironment::Inherit,
            },
        )
        .await
        .unwrap();
    let pid = started.pid.expect("the PTY process did not report its operating-system PID");
    let events = started.events;

    let mut transcript = Vec::new();
    wait_for_output(&events, &mut transcript, &format!("READY PID={pid}")).await;

    // Path selection is asserted after real traffic has moved, because that is
    // when a relayed carrier has published one.
    wait_for_path_kind(&client, expected_path).await;

    assert_eq!(
        workspace
            .request(WorkspaceRequest::ResizeProcess { process, cols: 101, rows: 37 })
            .await
            .unwrap(),
        WorkspaceResponse::ProcessResized { process, cols: 101, rows: 37 }
    );
    assert_eq!(
        workspace
            .request(WorkspaceRequest::WriteProcess {
                process,
                write_id: 1,
                data: ByteString::from_bytes(b"hello\n"),
                eof: false,
            })
            .await
            .unwrap(),
        WorkspaceResponse::ProcessWriteAccepted { process, write_id: 1 }
    );
    wait_for_output(&events, &mut transcript, &format!("PID={pid} ROWS=37 COLS=101 INPUT=hello"))
        .await;

    events.close().await.unwrap();
    client.close().await.unwrap();
    service_task.abort();
    listener.shutdown().await.unwrap();
    drop(relay);
}

#[tokio::test]
async fn iroh_relay_path_drives_a_real_daemon_pty() {
    tokio::task::LocalSet::new()
        .run_until(async {
            tokio::time::timeout(
                TEST_TIMEOUT,
                pty_over_iroh(IrohPathMode::RelayOnly, TransportPathKind::Relay),
            )
            .await
            .expect("the relayed Iroh PTY test timed out");
        })
        .await;
}

#[tokio::test]
async fn iroh_direct_path_drives_a_real_daemon_pty() {
    tokio::task::LocalSet::new()
        .run_until(async {
            tokio::time::timeout(
                TEST_TIMEOUT,
                pty_over_iroh(IrohPathMode::DirectOnly, TransportPathKind::Direct),
            )
            .await
            .expect("the direct Iroh PTY test timed out");
        })
        .await;
}
