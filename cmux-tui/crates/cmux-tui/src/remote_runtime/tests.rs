#[cfg(unix)]
use crate::test_exec::write_executable;
use cmux_remote::daemon::RemoteDaemon;

use super::*;

#[cfg(unix)]
mod initial_route_budget;

fn instrumented_test_timeout(timeout: Duration) -> Duration {
    let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
        .ok()
        .and_then(|value| value.parse::<u32>().ok())
        .filter(|scale| *scale > 0)
        .unwrap_or(1);
    timeout.saturating_mul(scale)
}

fn resolved_test_route(
    route: &str,
    supported_auth: SupportedClientAuthModes,
) -> ResolvedRouteCandidate {
    resolved_test_route_with_routing(route, BTreeMap::new(), supported_auth)
}

fn resolved_test_route_with_routing(
    route: &str,
    routing: BTreeMap<String, String>,
    supported_auth: SupportedClientAuthModes,
) -> ResolvedRouteCandidate {
    ResolvedRouteCandidate::with_supported_client_auth_for_test(
        Url::parse(route).unwrap(),
        routing,
        supported_auth,
    )
}

fn test_route(route: &str) -> ResolvedRouteCandidate {
    let endpoint = Url::parse(route).unwrap();
    let supported_auth = if matches!(endpoint.scheme(), "ssh" | "unix") {
        SupportedClientAuthModes::DeviceOrCarrier
    } else {
        SupportedClientAuthModes::DeviceOnly
    };
    ResolvedRouteCandidate::with_supported_client_auth_for_test(
        endpoint,
        BTreeMap::new(),
        supported_auth,
    )
}

fn unix_test_route(path: &Path) -> Url {
    let mut endpoint = Url::parse("unix:///").unwrap();
    endpoint.set_path(path.to_str().unwrap());
    endpoint
}

#[tokio::test]
async fn unmatched_relay_route_never_fetches_fallback_credentials() {
    let fetches = Arc::new(AtomicUsize::new(0));
    let credentials = RelayCredentialSource::callback({
        let fetches = Arc::clone(&fetches);
        move || {
            fetches.fetch_add(1, Ordering::SeqCst);
            async { Ok::<_, ()>("ticket".to_string()) }
        }
    });
    let provider = RoutedRelayProvider {
        routes: BTreeMap::from([(
            Url::parse("relay+ws://configured.example").unwrap().to_string(),
            RelayClientOptions { slot: "slot".into(), credentials },
        )]),
    };

    let result = tokio::time::timeout(
        Duration::from_secs(1),
        provider.connect(ConnectRequest {
            endpoint: Url::parse("relay+ws://127.0.0.1:9").unwrap(),
            session: SessionId([88; 16]),
            lane_policy: LanePolicy::Single,
            routing: BTreeMap::new(),
        }),
    )
    .await
    .expect("unmatched relay lookup reached a network timeout");

    assert!(matches!(result, Err(ProviderError::Configuration(_))));
    assert_eq!(fetches.load(Ordering::SeqCst), 0);
}

fn test_providers(ssh: SshProviderConfig) -> Arc<cmux_remote::provider::ProviderRegistry> {
    Arc::new(
        client_provider_registry(ssh, BTreeMap::new(), IrohPathMode::Auto, None, false).unwrap(),
    )
}

#[derive(Debug, PartialEq, Eq)]
enum FakeInitialRouteEvent {
    Bootstrap { endpoint: String, upgrade: bool },
    Provider(ConnectRequest),
}

struct FakeInitialRouteAttempt {
    fail_ssh_bootstrap: bool,
    fail_provider_index: Option<usize>,
    events: Vec<FakeInitialRouteEvent>,
}

#[async_trait]
impl InitialRouteAttempt<String> for FakeInitialRouteAttempt {
    async fn bootstrap_ssh(
        &mut self,
        endpoint: &Url,
        upgrade: bool,
    ) -> Result<(), InitialRouteAttemptError> {
        self.events
            .push(FakeInitialRouteEvent::Bootstrap { endpoint: endpoint.to_string(), upgrade });
        if self.fail_ssh_bootstrap {
            Err(InitialRouteAttemptError::Route {
                error: anyhow!("fake SSH is unreachable"),
                retryable: true,
            })
        } else {
            Ok(())
        }
    }

    async fn connect(
        &mut self,
        index: usize,
        request: ConnectRequest,
    ) -> Result<String, InitialRouteAttemptError> {
        let endpoint = request.endpoint.to_string();
        self.events.push(FakeInitialRouteEvent::Provider(request));
        if self.fail_provider_index == Some(index) {
            Err(InitialRouteAttemptError::Route {
                error: anyhow!("fake provider is unreachable"),
                retryable: true,
            })
        } else {
            Ok(endpoint)
        }
    }
}

struct TransientStartupProvider {
    calls: Arc<AtomicUsize>,
    transient_failures: usize,
    unix_path: PathBuf,
    unix: UnixProvider,
}

#[async_trait]
impl TransportProvider for TransientStartupProvider {
    fn name(&self) -> &'static str {
        "transient-startup"
    }

    fn schemes(&self) -> &'static [&'static str] {
        &["transient-startup"]
    }

    fn supported_client_auth(&self) -> SupportedClientAuthModes {
        SupportedClientAuthModes::DeviceOrCarrier
    }

    async fn connect(
        &self,
        mut request: ConnectRequest,
    ) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        if self.calls.fetch_add(1, Ordering::AcqRel) < self.transient_failures {
            return Err(ProviderError::Link(cmux_remote::link::LinkError::Transport(
                "transient startup carrier failure".into(),
            )));
        }
        let mut endpoint = Url::parse("unix:///").unwrap();
        endpoint.set_path(self.unix_path.to_str().unwrap());
        request.endpoint = endpoint;
        self.unix.connect(request).await
    }
}

struct HangingStartupProvider {
    calls: Arc<AtomicUsize>,
}

#[async_trait]
impl TransportProvider for HangingStartupProvider {
    fn name(&self) -> &'static str {
        "hanging-startup"
    }

    fn schemes(&self) -> &'static [&'static str] {
        &["hanging-startup"]
    }

    fn supported_client_auth(&self) -> SupportedClientAuthModes {
        SupportedClientAuthModes::DeviceOrCarrier
    }

    async fn connect(&self, _request: ConnectRequest) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        self.calls.fetch_add(1, Ordering::AcqRel);
        std::future::pending().await
    }
}

struct HangingOpenProvider {
    close_calls: Arc<AtomicUsize>,
}

#[async_trait]
impl TransportProvider for HangingOpenProvider {
    fn name(&self) -> &'static str {
        "hanging-open"
    }

    fn schemes(&self) -> &'static [&'static str] {
        &["hanging-open"]
    }

    fn supported_client_auth(&self) -> SupportedClientAuthModes {
        SupportedClientAuthModes::DeviceOrCarrier
    }

    async fn connect(&self, _request: ConnectRequest) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        Ok(Arc::new(HangingOpenGroup { close_calls: self.close_calls.clone() }))
    }
}

struct HangingOpenGroup {
    close_calls: Arc<AtomicUsize>,
}

#[async_trait]
impl LinkGroup for HangingOpenGroup {
    fn description(&self) -> &str {
        "hanging-open://daemon"
    }

    fn capabilities(&self) -> cmux_remote::provider::ProviderCapabilities {
        cmux_remote::provider::ProviderCapabilities::STREAM
    }

    fn evidence(&self) -> &cmux_remote::provider::CarrierEvidence {
        &cmux_remote::provider::CarrierEvidence::None
    }

    async fn open(
        &self,
        _request: cmux_remote::provider::LinkRequest,
    ) -> Result<Box<dyn cmux_remote::link::FrameLink>, ProviderError> {
        std::future::pending().await
    }

    async fn close(&self) -> Result<(), ProviderError> {
        self.close_calls.fetch_add(1, Ordering::AcqRel);
        Ok(())
    }
}

#[derive(Default)]
struct FakeReconnectRouteAttempt {
    requests: std::sync::Mutex<Vec<ConnectRequest>>,
}

#[async_trait]
impl ReconnectRouteAttempt<String> for FakeReconnectRouteAttempt {
    async fn connect(
        &self,
        _index: usize,
        request: ConnectRequest,
        _auth: AuthKind,
    ) -> Result<String, ProviderError> {
        let endpoint = request.endpoint.to_string();
        self.requests.lock().unwrap().push(request);
        Ok(endpoint)
    }
}

struct RejectingReconnectRouteAttempt;

#[async_trait]
impl ReconnectRouteAttempt<String> for RejectingReconnectRouteAttempt {
    async fn connect(
        &self,
        _index: usize,
        _request: ConnectRequest,
        _auth: AuthKind,
    ) -> Result<String, ProviderError> {
        Err(ProviderError::Transport("fake provider is unreachable".into()))
    }
}

struct DebugEchoingReconnectRouteAttempt;

#[async_trait]
impl ReconnectRouteAttempt<String> for DebugEchoingReconnectRouteAttempt {
    async fn connect(
        &self,
        _index: usize,
        request: ConnectRequest,
        _auth: AuthKind,
    ) -> Result<String, ProviderError> {
        Err(ProviderError::Transport(format!("provider rejected {request:?}")))
    }
}

#[derive(Default)]
struct AuthRecordingReconnectRouteAttempt {
    auth: std::sync::Mutex<Vec<AuthKind>>,
}

#[async_trait]
impl ReconnectRouteAttempt<String> for AuthRecordingReconnectRouteAttempt {
    async fn connect(
        &self,
        _index: usize,
        request: ConnectRequest,
        auth: AuthKind,
    ) -> Result<String, ProviderError> {
        self.auth.lock().unwrap().push(auth);
        Ok(request.endpoint.to_string())
    }
}

#[tokio::test]
async fn invitation_reconnect_dials_with_enrolled_auth() {
    let routes = vec![resolved_test_route(
        "wss://network.example/v1/link",
        SupportedClientAuthModes::DeviceOnly,
    )];
    let invitation = ClientAuthMode::Invitation {
        id: "invitation".into(),
        secret: zeroize::Zeroizing::new([17; 32]),
    };
    let attempt = AuthRecordingReconnectRouteAttempt::default();

    select_reconnect_route(
        &routes,
        0,
        SessionId([16; 16]),
        LanePolicy::Single,
        followup_auth_kind(&invitation),
        &attempt,
    )
    .await
    .unwrap();

    assert_eq!(attempt.auth.into_inner().unwrap(), [AuthKind::Enrolled]);
}

#[test]
fn route_auth_capability_is_derived_from_the_local_provider_registry() {
    let providers = test_providers(SshProviderConfig::default());
    let candidate = ResolvedRouteCandidate::resolve(
        Url::parse("wss://daemon.example/v1/link?client_auth=device-or-carrier#untrusted-claim")
            .unwrap(),
        BTreeMap::new(),
        &providers,
    )
    .unwrap();

    assert_eq!(candidate.supported_client_auth(), SupportedClientAuthModes::DeviceOnly);
    for scheme in ["ws", "wss", "relay+ws", "relay+wss", "relay+https", "relay+do"] {
        assert_eq!(
            providers.supported_client_auth(scheme).unwrap(),
            SupportedClientAuthModes::DeviceOnly,
            "{scheme}"
        );
    }
    #[cfg(feature = "iroh-transport")]
    assert_eq!(
        providers.supported_client_auth("iroh").unwrap(),
        SupportedClientAuthModes::DeviceOnly
    );
    #[cfg(not(feature = "iroh-transport"))]
    assert!(matches!(
        providers.supported_client_auth("iroh"),
        Err(ProviderError::UnsupportedScheme(scheme)) if scheme == "iroh"
    ));
    assert_eq!(
        providers.supported_client_auth("ssh").unwrap(),
        SupportedClientAuthModes::DeviceOrCarrier
    );
    #[cfg(unix)]
    assert_eq!(
        providers.supported_client_auth("unix").unwrap(),
        SupportedClientAuthModes::DeviceOrCarrier
    );
}

#[tokio::test]
async fn daemon_shutdown_finalizes_authorization_after_transport_failure() {
    let finalized = Arc::new(AtomicBool::new(false));
    let observed = finalized.clone();
    let result =
        finish_daemon_shutdown(vec![anyhow!("injected transport shutdown failure")], async move {
            observed.store(true, Ordering::SeqCst);
            Err(IdentityError::Invalid("injected authorization failure".into()))
        })
        .await;

    assert!(finalized.load(Ordering::SeqCst));
    let error = result.expect_err("shutdown failures were discarded").to_string();
    assert!(error.contains("transport shutdown failure"), "{error}");
    assert!(error.contains("authorization finalization failed"), "{error}");
}

#[test]
fn shutdown_recovery_preserves_lifecycle_evidence_when_its_snapshot_changes() {
    let directory = tempfile::tempdir().unwrap();
    let runtime_path = directory.path().join("runtime.json");
    let outcome_path = directory.path().join("shutdown.json");
    fs::write(&runtime_path, b"runtime-before").unwrap();
    fs::write(&outcome_path, b"outcome-before").unwrap();
    let runtime_snapshot = read_optional_file(&runtime_path).unwrap();
    let outcome_snapshot = read_optional_file(&outcome_path).unwrap();
    fs::write(&runtime_path, b"runtime-after").unwrap();

    let error =
        remove_shutdown_recovery_evidence(directory.path(), runtime_snapshot, outcome_snapshot)
            .expect_err("changed lifecycle evidence was removed");

    assert!(error.to_string().contains("changed"), "{error}");
    assert_eq!(fs::read(&runtime_path).unwrap(), b"runtime-after");
    assert_eq!(fs::read(&outcome_path).unwrap(), b"outcome-before");
}

#[cfg(unix)]
#[test]
fn daemon_runtime_shutdown_removes_only_its_owned_lifecycle_paths() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let runtime = start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: "owned-shutdown".into(),
            state_dir: Some(directory.path().join("state")),
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    )
    .unwrap();
    let info = runtime.info().clone();
    let lifecycle_id =
        info.lifecycle_id.clone().expect("new daemon omitted its lifecycle identity");
    let metadata = info.state_dir.join("runtime.json");
    assert!(info.link_socket.exists());
    assert!(info.admin_socket.exists());
    assert!(metadata.exists());

    runtime.shutdown().unwrap();

    assert!(!info.link_socket.exists());
    assert!(!info.admin_socket.exists());
    assert!(!metadata.exists());
    assert_eq!(
        load_shutdown_outcome(&info.state_dir).unwrap(),
        DaemonShutdownOutcome {
            version: DAEMON_SHUTDOWN_OUTCOME_VERSION,
            lifecycle_id,
            status: DaemonShutdownStatus::Succeeded,
        }
    );
}

/// A daemon whose relay ticket command fails in `script` way: it starts,
/// serves a local admin request while the relay retries, and stops.
#[cfg(unix)]
fn assert_daemon_serves_while_relay_ticket_fails(script: &str, timeout: Duration) {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let attempts = directory.path().join("attempts");
    let command = directory.path().join("ticket");
    write_executable(
        &command,
        format!("#!/bin/sh\necho attempt >> '{}'\n{script}\n", attempts.display()),
    );
    let runtime = start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: "relay-ticket-fails".into(),
            state_dir: Some(directory.path().join("state")),
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: vec![RelayDaemonOptions {
                endpoint: Url::parse("relay+ws://127.0.0.1:9").unwrap(),
                slot: "relay-ticket-fails".into(),
                credentials: RelayCredentialSource::command_with_timeout(
                    &command,
                    Vec::<String>::new(),
                    timeout,
                ),
            }],
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    )
    .expect("a failing relay ticket command stopped the daemon from starting");
    let info = runtime.info().clone();
    let requests = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let status = requests.block_on(cmux_remote::admin::call_admin(
        &info.admin_socket,
        &cmux_remote::admin::AdminRequest::Status,
    ));
    assert!(status.is_ok(), "the daemon did not serve a local request: {status:?}");

    // The credential backoff starts at 1 s and doubles: a second attempt
    // comes within about 3 s.
    let deadline = std::time::Instant::now() + instrumented_test_timeout(Duration::from_secs(15));
    let count = || fs::read_to_string(&attempts).map(|text| text.lines().count()).unwrap_or(0);
    while count() < 2 {
        assert!(
            std::time::Instant::now() < deadline,
            "the relay registration did not retry the ticket command ({} attempts)",
            count()
        );
        thread::sleep(Duration::from_millis(50));
    }
    assert!(!runtime.is_finished(), "the daemon stopped while the relay ticket failed");
    let status = requests.block_on(cmux_remote::admin::call_admin(
        &info.admin_socket,
        &cmux_remote::admin::AdminRequest::Status,
    ));
    assert!(status.is_ok(), "the daemon stopped serving local requests: {status:?}");

    runtime.shutdown().unwrap();
    assert!(!info.admin_socket.exists());
}

#[cfg(unix)]
#[test]
fn daemon_serves_locally_and_retries_when_relay_ticket_command_exits_1() {
    assert_daemon_serves_while_relay_ticket_fails(
        "echo 'carrier ticket: agent answered 503' >&2\nexit 1",
        Duration::from_secs(10),
    );
}

#[cfg(unix)]
#[test]
fn daemon_serves_locally_and_retries_when_relay_ticket_command_hangs() {
    assert_daemon_serves_while_relay_ticket_fails(
        "echo 'waiting on the agent' >&2\nexec sleep 30",
        Duration::from_millis(200),
    );
}

#[cfg(unix)]
#[test]
fn daemon_startup_refuses_failed_authorization_finalization() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "failed-predecessor";
    let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
    fs::create_dir_all(&state_dir).unwrap();
    persist_shutdown_outcome(
        &state_dir,
        &DaemonShutdownOutcome {
            version: DAEMON_SHUTDOWN_OUTCOME_VERSION,
            lifecycle_id: "failed-predecessor".into(),
            status: DaemonShutdownStatus::Failed,
        },
    )
    .unwrap();

    let result = start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: session.into(),
            state_dir: Some(state_root),
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    );
    let error = match result {
        Err(error) => error,
        Ok(runtime) => {
            runtime.shutdown().unwrap();
            panic!("daemon started after failed authorization finalization");
        }
    };
    assert!(error.to_string().contains("authorization finalization"), "{error:#}");
}

#[cfg(unix)]
#[test]
fn daemon_startup_refuses_malformed_authorization_finalization() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "malformed-predecessor";
    let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
    fs::create_dir_all(&state_dir).unwrap();
    fs::write(state_dir.join("shutdown.json"), b"{not-json").unwrap();

    let result = start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: session.into(),
            state_dir: Some(state_root),
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    );
    let error = match result {
        Err(error) => error,
        Ok(runtime) => {
            runtime.shutdown().unwrap();
            panic!("daemon started after malformed authorization finalization");
        }
    };
    assert!(error.to_string().contains("authorization finalization"), "{error:#}");
}

#[cfg(unix)]
#[test]
fn daemon_startup_refuses_unfenced_legacy_state_after_runtime_cleanup() {
    for case in ["missing-outcome", "stale-success"] {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_root = directory.path().join("state");
        let session = format!("unfenced-legacy-cleanup-{case}");
        let (state_dir, _, _) = daemon_paths(&session, Some(&state_root)).unwrap();
        drop(
            AuthDatabase::load_or_create(state_dir.join("auth"), &session, true)
                .expect("could not seed legacy authorization state"),
        );
        if case == "stale-success" {
            persist_shutdown_outcome(
                &state_dir,
                &DaemonShutdownOutcome {
                    version: DAEMON_SHUTDOWN_OUTCOME_VERSION,
                    lifecycle_id: "earlier-modern-lifecycle".into(),
                    status: DaemonShutdownStatus::Succeeded,
                },
            )
            .unwrap();
        }

        let result = start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session,
                state_dir: Some(state_root),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                trusted_carrier_websocket: false,
                workspace_http: None,
                relays: Vec::new(),
                carrier_grant_config: None,
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
                local_sockets: Vec::new(),
            },
        );
        let error = match result {
            Err(error) => error,
            Ok(runtime) => {
                runtime.shutdown().unwrap();
                panic!("{case}: daemon started without a lifecycle fence");
            }
        };
        assert!(error.to_string().contains("lifecycle fence"), "{case}: {error:#}");
    }
}

#[cfg(unix)]
#[test]
fn daemon_startup_does_not_treat_lifecycle_marker_as_an_auth_rollback_fence() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "marker-with-legacy-auth";
    let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
    let auth_state_dir = state_dir.join("auth");
    fs::create_dir_all(&auth_state_dir).unwrap();
    fs::write(
        auth_state_dir.join("devices.json"),
        serde_json::to_vec_pretty(&serde_json::json!({
            "version": 1,
            "revision": 0,
            "revocation_generation": 0,
            "devices": [],
            "invitations": [],
        }))
        .unwrap(),
    )
    .unwrap();
    persist_daemon_lifecycle_fence(&state_dir).unwrap();

    let error = match start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: session.into(),
            state_dir: Some(state_root),
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    ) {
        Err(error) => error,
        Ok(runtime) => {
            runtime.shutdown().unwrap();
            panic!("lifecycle marker bypassed authorization-state migration");
        }
    };

    assert!(error.to_string().contains("explicit migration"), "{error:#}");
    assert_eq!(
        cmux_remote::identity::persisted_auth_state_version(&auth_state_dir).unwrap(),
        Some(1),
        "rejected startup rewrote legacy authorization state"
    );
}

#[cfg(unix)]
#[test]
fn daemon_startup_refuses_lifecycle_marker_without_authorization_state() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "marker-without-auth";
    let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
    fs::create_dir_all(&state_dir).unwrap();
    persist_daemon_lifecycle_fence(&state_dir).unwrap();

    let error = match start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: session.into(),
            state_dir: Some(state_root),
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    ) {
        Err(error) => error,
        Ok(runtime) => {
            runtime.shutdown().unwrap();
            panic!("lifecycle marker created missing authorization state");
        }
    };

    assert!(error.to_string().contains("explicit migration"), "{error:#}");
    assert_eq!(
        cmux_remote::identity::persisted_auth_state_version(&state_dir.join("auth")).unwrap(),
        None,
        "rejected marker-only state created authorization state"
    );
}

#[cfg(unix)]
#[test]
fn daemon_startup_refuses_lifecycle_fenced_lock_only_auth_initialization() {
    use std::os::unix::fs::OpenOptionsExt as _;

    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "reject-lock-only-auth";
    let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
    let auth_state_dir = state_dir.join("auth");
    fs::create_dir_all(&auth_state_dir).unwrap();
    OpenOptions::new()
        .read(true)
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(auth_state_dir.join("devices.json.lock"))
        .unwrap();
    persist_daemon_lifecycle_fence(&state_dir).unwrap();

    let error = match start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: session.into(),
            state_dir: Some(state_root),
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    ) {
        Err(error) => error,
        Ok(runtime) => {
            runtime.shutdown().unwrap();
            panic!("lifecycle marker was trusted as an authorization rollback fence");
        }
    };

    assert!(error.to_string().contains("explicit migration"), "{error:#}");
    assert_eq!(
        cmux_remote::identity::persisted_auth_state_version(&auth_state_dir).unwrap(),
        None,
        "rejected startup created rollback-fenced authorization state"
    );
}

#[cfg(unix)]
#[test]
fn daemon_startup_persists_auth_rollback_fence_before_lifecycle_marker() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "auth-fence-before-lifecycle-marker";
    let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
    let auth_state_dir = state_dir.join("auth");
    let mut pause =
        DaemonCleanupPauseHandle::install(state_dir, DaemonCleanupPausePhase::BeforeLifecycleFence);

    let mux_socket = directory.path().join("missing-mux.sock");
    let startup = thread::spawn(move || {
        start_daemon_runtime(
            mux_socket,
            DaemonRuntimeOptions {
                session: session.into(),
                state_dir: Some(state_root),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                trusted_carrier_websocket: false,
                workspace_http: None,
                relays: Vec::new(),
                carrier_grant_config: None,
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
                local_sockets: Vec::new(),
            },
        )
    });

    pause.wait_until_reached();
    let auth_version =
        cmux_remote::identity::persisted_auth_state_version(&auth_state_dir).unwrap();
    pause.resume();
    let runtime = startup.join().unwrap().unwrap();
    runtime.shutdown().unwrap();

    assert_eq!(
        auth_version,
        Some(cmux_remote::identity::AUTH_STATE_VERSION),
        "lifecycle marker publication preceded the versioned authorization rollback fence"
    );
}

#[cfg(unix)]
#[test]
fn daemon_startup_resyncs_visible_fence_before_initializing_auth() {
    use std::os::unix::fs::PermissionsExt as _;

    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "resync-visible-fence";
    let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
    fs::create_dir_all(&state_dir).unwrap();
    persist_daemon_lifecycle_fence(&state_dir).unwrap();

    fs::set_permissions(&state_dir, fs::Permissions::from_mode(0o300)).unwrap();
    let result = start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: session.into(),
            state_dir: Some(state_root),
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    );
    fs::set_permissions(&state_dir, fs::Permissions::from_mode(0o700)).unwrap();

    let error = match result {
        Err(error) => error,
        Ok(runtime) => {
            runtime.shutdown().unwrap();
            panic!("startup trusted a visible lifecycle fence without re-syncing it");
        }
    };
    assert!(error.to_string().contains("lifecycle fence"), "{error:#}");
    assert!(
        !state_dir.join("auth").exists(),
        "startup initialized authorization state before confirming fence durability"
    );
}

#[cfg(unix)]
#[test]
fn daemon_startup_does_not_publish_marker_without_auth_rollback_fence() {
    use std::os::unix::fs::symlink;

    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "fence-before-auth-failure";
    let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
    fs::create_dir_all(&state_dir).unwrap();
    symlink("missing-auth-target", state_dir.join("auth")).unwrap();

    let result = start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: session.into(),
            state_dir: Some(state_root),
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    );

    assert!(result.is_err(), "daemon accepted a dangling authorization-state symlink");
    assert!(
        !read_daemon_lifecycle_fence(&state_dir).unwrap(),
        "auth initialization failure left a marker that older binaries ignore"
    );
}

#[cfg(unix)]
#[test]
fn daemon_startup_migrates_verified_modern_state_to_a_lifecycle_fence() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "migrate-modern-lifecycle";
    let (state_dir, link_socket, admin_socket) = daemon_paths(session, Some(&state_root)).unwrap();
    drop(
        AuthDatabase::load_or_create(state_dir.join("auth"), session, true)
            .expect("could not seed authorization state"),
    );
    persist_runtime_info(
        &state_dir,
        &DaemonRuntimeInfo {
            session: session.into(),
            state_dir: state_dir.clone(),
            link_socket,
            admin_socket,
            daemon_fingerprint: "completed-modern-daemon".into(),
            routes: Vec::new(),
            direct_websocket: None,
            iroh_node_id: None,
            lifecycle_id: Some("completed-modern-lifecycle".into()),
            replaceable_sidecar: true,
        },
    )
    .unwrap();
    persist_shutdown_outcome(
        &state_dir,
        &DaemonShutdownOutcome {
            version: DAEMON_SHUTDOWN_OUTCOME_VERSION,
            lifecycle_id: "completed-modern-lifecycle".into(),
            status: DaemonShutdownStatus::Succeeded,
        },
    )
    .unwrap();

    let runtime = start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: session.into(),
            state_dir: Some(state_root),
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    )
    .expect("verified modern state did not migrate");

    assert!(read_daemon_lifecycle_fence(&state_dir).unwrap());
    runtime.shutdown().unwrap();
}

#[cfg(unix)]
#[test]
fn existing_lifecycle_fence_retry_resyncs_parent_directory() {
    use std::os::unix::fs::PermissionsExt as _;

    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_dir = directory.path().join("state");
    fs::create_dir_all(&state_dir).unwrap();
    persist_daemon_lifecycle_fence(&state_dir).unwrap();

    fs::set_permissions(&state_dir, fs::Permissions::from_mode(0o100)).unwrap();
    let result = persist_daemon_lifecycle_fence(&state_dir);
    fs::set_permissions(&state_dir, fs::Permissions::from_mode(0o700)).unwrap();

    let error = result.expect_err("existing lifecycle fence skipped its directory sync");
    assert!(
        matches!(
            error,
            IdentityError::Io(ref error)
                if error.kind() == std::io::ErrorKind::PermissionDenied
        ),
        "{error}"
    );
}

#[cfg(unix)]
#[test]
fn lifecycle_fence_allows_retry_before_runtime_metadata_is_published() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "fenced-startup-retry";
    let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
    drop(
        AuthDatabase::load_or_create(state_dir.join("auth"), session, true)
            .expect("could not seed authorization state"),
    );
    persist_daemon_lifecycle_fence(&state_dir).unwrap();

    let runtime = start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: session.into(),
            state_dir: Some(state_root),
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    )
    .expect("lifecycle-fenced startup retry was rejected");

    runtime.shutdown().unwrap();
}

#[cfg(unix)]
#[tokio::test]
async fn legacy_recovery_makes_marker_only_state_safe_to_restart() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "recover-marker-only-state";
    let (state_dir, link_socket, admin_socket) = daemon_paths(session, Some(&state_root)).unwrap();
    fs::create_dir_all(&state_dir).unwrap();
    persist_daemon_lifecycle_fence(&state_dir).unwrap();

    assert!(inactive_daemon_needs_legacy_acknowledgement(&state_dir).unwrap());
    acknowledge_legacy_shutdown_state(&state_dir, session, &link_socket, &admin_socket)
        .await
        .unwrap();
    assert_eq!(
        cmux_remote::identity::persisted_auth_state_version(&state_dir.join("auth")).unwrap(),
        Some(cmux_remote::identity::AUTH_STATE_VERSION)
    );
    assert!(!inactive_daemon_needs_legacy_acknowledgement(&state_dir).unwrap());

    let runtime = start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: session.into(),
            state_dir: Some(state_root),
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    )
    .expect("explicit marker-only recovery did not make startup safe");
    runtime.shutdown().unwrap();
}

#[cfg(unix)]
#[tokio::test]
async fn verified_stop_creates_current_authorization_when_state_is_missing() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_dir = directory.path().join("missing-state");

    complete_verified_daemon_stop(&state_dir, "verified-missing-state")
        .await
        .expect("verified stop did not initialize rollback-fenced authorization state");

    assert_eq!(
        cmux_remote::identity::persisted_auth_state_version(&state_dir.join("auth")).unwrap(),
        Some(cmux_remote::identity::AUTH_STATE_VERSION)
    );
    assert!(read_daemon_lifecycle_fence(&state_dir).unwrap());
}

#[cfg(unix)]
#[test]
fn daemon_startup_recovers_inactive_modern_predecessor_state() {
    for (case, outcome) in [
        ("missing", None),
        (
            "stale",
            Some(DaemonShutdownOutcome {
                version: DAEMON_SHUTDOWN_OUTCOME_VERSION,
                lifecycle_id: "different-lifecycle".into(),
                status: DaemonShutdownStatus::Succeeded,
            }),
        ),
    ] {
        let directory = tempfile::tempdir_in("/tmp").unwrap();
        let state_root = directory.path().join("state");
        let session = format!("modern-predecessor-{case}");
        let (state_dir, link_socket, admin_socket) =
            daemon_paths(&session, Some(&state_root)).unwrap();
        fs::create_dir_all(&state_dir).unwrap();
        drop(
            AuthDatabase::load_or_create(state_dir.join("auth"), &session, true)
                .expect("could not seed authorization state"),
        );
        persist_daemon_lifecycle_fence(&state_dir).unwrap();
        persist_runtime_info(
            &state_dir,
            &DaemonRuntimeInfo {
                session: session.clone(),
                state_dir: state_dir.clone(),
                link_socket,
                admin_socket,
                daemon_fingerprint: "predecessor".into(),
                routes: Vec::new(),
                direct_websocket: None,
                iroh_node_id: None,
                lifecycle_id: Some("expected-lifecycle".into()),
                replaceable_sidecar: true,
            },
        )
        .unwrap();
        if let Some(outcome) = outcome {
            persist_shutdown_outcome(&state_dir, &outcome).unwrap();
        }

        let runtime = start_daemon_runtime(
            directory.path().join("missing-mux.sock"),
            DaemonRuntimeOptions {
                session,
                state_dir: Some(state_root),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                trusted_carrier_websocket: false,
                workspace_http: None,
                relays: Vec::new(),
                carrier_grant_config: None,
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
                local_sockets: Vec::new(),
            },
        )
        .unwrap_or_else(|error| panic!("{case}: daemon did not recover stale evidence: {error:#}"));
        runtime.shutdown().unwrap();
        assert_eq!(
            load_shutdown_outcome(&state_dir)
                .expect("replacement daemon did not finalize authorization")
                .status,
            DaemonShutdownStatus::Succeeded,
            "{case}: replacement daemon did not publish a successful finalization"
        );
    }
}

#[cfg(unix)]
#[test]
fn daemon_persists_active_lifecycle_before_opening_listener() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "active-before-listener";
    let (state_dir, link_socket, _) = daemon_paths(session, Some(&state_root)).unwrap();
    let mut pause = DaemonCleanupPauseHandle::install(
        state_dir.clone(),
        DaemonCleanupPausePhase::BeforeListenerStartup,
    );
    let mux_socket = directory.path().join("missing-mux.sock");
    let caller = thread::spawn(move || {
        start_daemon_runtime(
            mux_socket,
            DaemonRuntimeOptions {
                session: session.into(),
                state_dir: Some(state_root),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                trusted_carrier_websocket: false,
                workspace_http: None,
                relays: Vec::new(),
                carrier_grant_config: None,
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
                local_sockets: Vec::new(),
            },
        )
    });
    pause.wait_until_reached();

    let active = read_runtime_info(&state_dir).unwrap();
    let listener_opened = link_socket.exists();
    pause.resume();
    let runtime = caller.join().unwrap().unwrap();
    let final_lifecycle_id =
        runtime.info().lifecycle_id.clone().expect("ready daemon omitted its lifecycle id");
    runtime.shutdown().unwrap();

    assert!(!listener_opened, "link listener opened before the lifecycle checkpoint");
    let active = active.expect("active lifecycle was not persisted before listener startup");
    assert_eq!(active.lifecycle_id.as_deref(), Some(final_lifecycle_id.as_str()));
}

#[cfg(unix)]
#[test]
fn daemon_runtime_metadata_remains_until_auth_finalization() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let runtime = start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: "durable-cleanup".into(),
            state_dir: Some(directory.path().join("state")),
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    )
    .unwrap();
    let state_dir = runtime.info().state_dir.clone();
    let lifecycle_id =
        runtime.info().lifecycle_id.clone().expect("new daemon omitted its lifecycle identity");
    let metadata = state_dir.join("runtime.json");
    let outcome = state_dir.join("shutdown.json");
    let mut pause = DaemonCleanupPauseHandle::install(
        state_dir.clone(),
        DaemonCleanupPausePhase::BeforeAuthRelease,
    );
    let shutdown = thread::spawn(move || runtime.shutdown());
    pause.wait_until_reached();

    assert!(metadata.exists(), "daemon published lifecycle completion before auth finalization");
    assert!(!outcome.exists(), "daemon published its outcome before auth finalization");
    pause.resume();
    shutdown.join().unwrap().unwrap();
    assert!(!metadata.exists());
    assert_eq!(load_shutdown_outcome(&state_dir).unwrap().lifecycle_id, lifecycle_id);
}

#[cfg(unix)]
#[test]
fn exiting_daemon_never_removes_successor_runtime_metadata() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let runtime = start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: "successor-metadata".into(),
            state_dir: Some(directory.path().join("state")),
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    )
    .unwrap();
    let info = runtime.info().clone();
    let mut pause = DaemonCleanupPauseHandle::install(
        info.state_dir.clone(),
        DaemonCleanupPausePhase::AfterAuthShutdown,
    );

    let unrelated_directory = tempfile::tempdir_in("/tmp").unwrap();
    let unrelated = start_daemon_runtime(
        unrelated_directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: "unrelated-cleanup".into(),
            state_dir: Some(unrelated_directory.path().join("state")),
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    )
    .unwrap();
    let unrelated_shutdown = thread::spawn(move || unrelated.shutdown());
    pause.assert_not_reached_before(&unrelated_shutdown);
    unrelated_shutdown.join().unwrap().unwrap();

    let shutdown = thread::spawn(move || runtime.shutdown());
    pause.wait_until_reached();

    let successor = AuthDatabase::load_or_create(info.state_dir.join("auth"), "successor", true)
        .expect("predecessor retained its authorization state lease after shutdown");
    let metadata = info.state_dir.join("runtime.json");
    fs::write(&metadata, b"successor-runtime").unwrap();
    pause.resume();
    shutdown.join().unwrap().unwrap();

    assert_eq!(fs::read(&metadata).unwrap(), b"successor-runtime");
    drop(successor);
}

#[cfg(unix)]
#[test]
fn daemon_runtime_rejects_an_intermediate_state_symlink_before_creating_state() {
    use std::os::unix::fs::symlink;

    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let target = directory.path().join("target");
    let alias = directory.path().join("alias");
    fs::create_dir(&target).unwrap();
    symlink(&target, &alias).unwrap();

    let result = start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: "symlinked-state".into(),
            state_dir: Some(alias),
            link_socket: Some(directory.path().join("sockets/link.sock")),
            admin_socket: Some(directory.path().join("sockets/admin.sock")),
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    );
    if let Ok(runtime) = result {
        runtime.shutdown().unwrap();
        panic!("intermediate state symlink was accepted");
    }
    assert!(!target.join("sessions").exists());
}

#[cfg(unix)]
#[test]
fn client_startup_timeout_returns_while_the_socket_path_lock_is_held() {
    use std::fs::OpenOptions;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;

    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let daemon_root = directory.path().join("daemon");
    let daemon = start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: "client-startup-lock".into(),
            state_dir: Some(daemon_root),
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    )
    .unwrap();
    let providers = test_providers(SshProviderConfig::default());
    let route = ResolvedRouteCandidate::resolve(
        unix_test_route(&daemon.info().link_socket),
        BTreeMap::new(),
        &providers,
    )
    .unwrap();
    let local_socket = directory.path().join("client/mux.sock");
    fs::create_dir_all(local_socket.parent().unwrap()).unwrap();
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(client_socket_lock_path(&local_socket).unwrap())
        .unwrap();
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);

    let ssh = SshProviderConfig::default();
    let client_state = directory.path().join("client-state");
    let (done_tx, done_rx) = mpsc::sync_channel(1);
    let caller = thread::spawn(move || {
        let result = start_client_runtime(ClientRuntimeOptions {
            routes: vec![route],
            providers,
            identity: StaticIdentity::generate().unwrap(),
            expected_daemon: None,
            auth: ClientAuthMode::Carrier,
            device_name: "client-startup-lock-test".into(),
            session: SessionId([31; 16]),
            lane_policy: LanePolicy::Single,
            reconnect: ReconnectPolicy {
                maximum_attempts: Some(1),
                heartbeat_interval: None,
                ..ReconnectPolicy::default()
            },
            startup_timeout: Duration::from_millis(100),
            state_dir: client_state,
            local_socket: Some(local_socket),
            ssh,
            ssh_bootstrap: SshBootstrapOptions {
                auto_install: false,
                upgrade: false,
                attempt_timeout: Duration::from_secs(1),
            },
        });
        let _ = done_tx.send(result.map(|runtime| runtime.shutdown()));
    });

    let completed_while_locked = done_rx.recv_timeout(Duration::from_millis(500)).is_ok();
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) }, 0);
    if !completed_while_locked {
        done_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("client startup stayed blocked after releasing the socket lock")
            .unwrap_err();
    }
    caller.join().unwrap();
    daemon.shutdown().unwrap();

    assert!(
        completed_while_locked,
        "client startup timeout joined a worker blocked on the socket path lock"
    );
}

#[cfg(unix)]
#[test]
fn daemon_startup_timeout_returns_while_the_identity_path_lock_is_held() {
    use std::fs::OpenOptions;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;

    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let (session_state, link_socket, _) =
        daemon_paths("daemon-startup-lock", Some(&state_root)).unwrap();
    let auth_state = session_state.join("auth");
    fs::create_dir_all(&auth_state).unwrap();
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(auth_state.join("identity.json.lock"))
        .unwrap();
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);

    let mux_socket = directory.path().join("missing-mux.sock");
    let (done_tx, done_rx) = mpsc::sync_channel(1);
    let caller = thread::spawn(move || {
        let result = start_daemon_runtime_with_timeout(
            mux_socket,
            DaemonRuntimeOptions {
                session: "daemon-startup-lock".into(),
                state_dir: Some(state_root),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                trusted_carrier_websocket: false,
                workspace_http: None,
                relays: Vec::new(),
                carrier_grant_config: None,
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
                local_sockets: Vec::new(),
            },
            Duration::from_millis(100),
        );
        let _ = done_tx.send(result.map(|runtime| runtime.shutdown()));
    });

    let completed_while_locked = done_rx.recv_timeout(Duration::from_millis(500)).is_ok();
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) }, 0);
    if !completed_while_locked {
        done_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("daemon startup stayed blocked after releasing the identity lock")
            .unwrap_err();
    }
    caller.join().unwrap();
    let cleanup_deadline = std::time::Instant::now() + Duration::from_secs(3);
    while link_socket.exists() && std::time::Instant::now() < cleanup_deadline {
        thread::sleep(Duration::from_millis(10));
    }

    assert!(
        completed_while_locked,
        "daemon startup timeout joined a worker blocked on the identity path lock"
    );
    assert!(!link_socket.exists(), "timed-out daemon left its link socket behind");
}

#[cfg(unix)]
#[test]
fn daemon_finalizes_lifecycle_when_ready_receiver_disappears() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "ready-receiver-disappears";
    let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
    let mut pause = DaemonCleanupPauseHandle::install(
        state_dir.clone(),
        DaemonCleanupPausePhase::BeforeReadySend,
    );
    let mux_socket = directory.path().join("missing-mux.sock");
    let caller = thread::spawn(move || {
        start_daemon_runtime_with_timeout(
            mux_socket,
            DaemonRuntimeOptions {
                session: session.into(),
                state_dir: Some(state_root),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                trusted_carrier_websocket: false,
                workspace_http: None,
                relays: Vec::new(),
                carrier_grant_config: None,
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
                local_sockets: Vec::new(),
            },
            Duration::from_millis(500),
        )
    });
    pause.wait_until_reached();

    let lifecycle_id = read_runtime_info(&state_dir)
        .unwrap()
        .expect("starting daemon did not persist runtime metadata")
        .lifecycle_id
        .expect("starting daemon omitted its lifecycle id");
    let startup = caller.join().unwrap();
    let error = match startup {
        Err(error) => error,
        Ok(runtime) => {
            runtime.shutdown().unwrap();
            panic!("paused daemon became ready after its owner timed out");
        }
    };
    assert!(error.to_string().contains("did not become ready"), "{error:#}");
    pause.resume();

    let runtime_path = state_dir.join("runtime.json");
    let outcome_path = state_dir.join("shutdown.json");
    let deadline = std::time::Instant::now() + Duration::from_secs(3);
    while (runtime_path.exists() || !outcome_path.exists()) && std::time::Instant::now() < deadline
    {
        thread::sleep(Duration::from_millis(10));
    }

    assert!(!runtime_path.exists(), "orphaned startup retained active runtime metadata");
    let outcome = load_shutdown_outcome(&state_dir)
        .expect("orphaned startup did not publish authorization finalization");
    assert_eq!(outcome.lifecycle_id, lifecycle_id);
    assert_eq!(outcome.status, DaemonShutdownStatus::Succeeded);
}

#[cfg(unix)]
#[test]
fn daemon_startup_retries_a_predecessors_auth_state_lease() {
    use std::fs::OpenOptions;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;

    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let (session_state, _, _) = daemon_paths("daemon-handoff-retry", Some(&state_root)).unwrap();
    let auth_state = session_state.join("auth");
    drop(
        AuthDatabase::load_or_create(&auth_state, "daemon-handoff-retry", true)
            .expect("could not seed current authorization state"),
    );
    persist_daemon_lifecycle_fence(&session_state).unwrap();
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(auth_state.join("devices.json.lock"))
        .unwrap();
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);

    let mux_socket = directory.path().join("missing-mux.sock");
    let (done_tx, done_rx) = mpsc::sync_channel(1);
    let caller = thread::spawn(move || {
        let result = start_daemon_runtime_with_timeout(
            mux_socket,
            DaemonRuntimeOptions {
                session: "daemon-handoff-retry".into(),
                state_dir: Some(state_root),
                link_socket: None,
                admin_socket: None,
                direct_websocket: None,
                allow_insecure_non_loopback: false,
                trusted_carrier_websocket: false,
                workspace_http: None,
                relays: Vec::new(),
                carrier_grant_config: None,
                iroh: false,
                advertised_routes: Vec::new(),
                resume_lease: Duration::from_secs(2),
                replaceable_sidecar: true,
                local_sockets: Vec::new(),
            },
            Duration::from_secs(3),
        );
        let _ = done_tx.send(result.map(DaemonRuntimeHandle::shutdown));
    });

    let early = done_rx.recv_timeout(Duration::from_millis(200));
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) }, 0);
    let finished_while_locked = early.is_ok();
    let result = match early {
        Ok(result) => result,
        Err(mpsc::RecvTimeoutError::Timeout) => done_rx
            .recv_timeout(Duration::from_secs(3))
            .expect("daemon startup did not finish after its predecessor released state"),
        Err(mpsc::RecvTimeoutError::Disconnected) => {
            panic!("daemon startup caller disconnected")
        }
    };
    caller.join().unwrap();

    assert!(
        !finished_while_locked,
        "daemon startup failed instead of waiting for its predecessor's state lease"
    );
    result
        .expect("daemon startup failed after its predecessor released state")
        .expect("daemon shutdown failed after a successful handoff");
}

#[cfg(unix)]
#[tokio::test]
async fn daemon_auth_handoff_retry_stops_at_its_deadline() {
    use std::fs::OpenOptions;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;

    let directory = tempfile::tempdir().unwrap();
    let auth_state = directory.path().join("auth");
    fs::create_dir_all(&auth_state).unwrap();
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(auth_state.join("devices.json.lock"))
        .unwrap();
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);
    let (_shutdown_tx, mut shutdown_rx) = watch::channel(false);
    let started = tokio::time::Instant::now();

    let error = load_daemon_auth_during_handoff(
        &auth_state,
        "bounded-handoff",
        &mut shutdown_rx,
        Duration::from_millis(50),
    )
    .await
    .unwrap_err()
    .to_string();

    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) }, 0);
    assert!(error.contains("still owned"), "{error}");
    assert!(
        started.elapsed() < Duration::from_secs(1),
        "authorization state handoff retry exceeded its deadline"
    );
}

#[cfg(unix)]
#[tokio::test]
async fn daemon_auth_handoff_retry_observes_startup_cancellation() {
    use std::fs::OpenOptions;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;

    let directory = tempfile::tempdir().unwrap();
    let auth_state = directory.path().join("auth");
    fs::create_dir_all(&auth_state).unwrap();
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(auth_state.join("devices.json.lock"))
        .unwrap();
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);
    let (shutdown_tx, mut shutdown_rx) = watch::channel(false);
    let retry = tokio::spawn(async move {
        load_daemon_auth_during_handoff(
            &auth_state,
            "cancelled-handoff",
            &mut shutdown_rx,
            Duration::from_secs(5),
        )
        .await
    });
    tokio::time::sleep(Duration::from_millis(30)).await;
    assert!(!retry.is_finished(), "authorization state handoff did not retry");

    shutdown_tx.send_replace(true);
    let error = tokio::time::timeout(Duration::from_secs(1), retry)
        .await
        .expect("authorization state handoff ignored startup cancellation")
        .unwrap()
        .unwrap_err()
        .to_string();

    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) }, 0);
    assert!(error.contains("cancelled"), "{error}");
}

#[cfg(unix)]
#[test]
fn daemon_paths_bound_session_components_and_unix_socket_names() {
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    let root = PathBuf::from("/tmp").join("long-root-a".repeat(6)).join("long-root-b".repeat(6));
    let session = "long-session".repeat(128);
    let first = daemon_paths(&session, Some(&root)).unwrap();
    let second = daemon_paths(&session, Some(&root)).unwrap();

    assert_eq!(first, second, "daemon path fallback was not deterministic");
    assert!(first.0.starts_with(root.join("sessions")));
    assert!(
        first.0.file_name().unwrap().as_bytes().len() <= 255,
        "encoded session exceeded NAME_MAX: {}",
        first.0.display()
    );
    assert!(
        unix_socket_path_fits(&first.1),
        "link socket path was too long: {}",
        first.1.display()
    );
    assert!(
        unix_socket_path_fits(&first.2),
        "admin socket path was too long: {}",
        first.2.display()
    );
    assert_ne!(first.1, first.2);
    for parent in [first.1.parent().unwrap(), first.2.parent().unwrap()] {
        let metadata = fs::symlink_metadata(parent).unwrap();
        assert_eq!(metadata.uid(), unsafe { libc::geteuid() });
        assert_eq!(metadata.permissions().mode() & 0o077, 0);
    }
}

#[test]
fn runtime_route_debug_redacts_raw_urls_slots_and_routing_hints() {
    let candidate = resolved_test_route_with_routing(
        "wss://candidate-user-marker:candidate-password-marker@candidate.example/\
             candidate-path-marker?ticket=candidate-query-marker#candidate-fragment-marker",
        BTreeMap::from([
            (cmux_remote::provider::ROUTING_DIRECT_ADDRS.into(), "direct-hint-marker:4242".into()),
            (
                cmux_remote::provider::ROUTING_RELAY_URL.into(),
                "https://hint-user-marker:hint-password-marker@hint.example/\
                     hint-path-marker?ticket=hint-query-marker#hint-fragment-marker"
                    .into(),
            ),
        ]),
        SupportedClientAuthModes::DeviceOnly,
    );
    let relay_options = RelayDaemonOptions {
        endpoint: Url::parse(
            "relay+wss://daemon-user-marker:daemon-password-marker@daemon.example/\
                 daemon-path-marker?ticket=daemon-query-marker#daemon-fragment-marker",
        )
        .unwrap(),
        slot: "daemon-slot-marker".into(),
        credentials: RelayCredentialSource::static_ticket("daemon-ticket-marker").unwrap(),
    };
    let routed_provider = RoutedRelayProvider {
        routes: BTreeMap::from([(
            "relay+wss://map-user-marker:map-password-marker@map.example/\
                 map-path-marker?ticket=map-query-marker#map-fragment-marker"
                .into(),
            RelayClientOptions {
                slot: "route-slot-marker".into(),
                credentials: RelayCredentialSource::static_ticket("route-ticket-marker").unwrap(),
            },
        )]),
    };
    let daemon_options = DaemonRuntimeOptions {
        session: "debug-control".into(),
        state_dir: None,
        link_socket: None,
        admin_socket: None,
        direct_websocket: None,
        allow_insecure_non_loopback: false,
        trusted_carrier_websocket: false,
        workspace_http: None,
        relays: vec![relay_options],
        carrier_grant_config: None,
        iroh: false,
        advertised_routes: vec!["%%% malformed-route-marker %%%".into()],
        resume_lease: Duration::from_secs(1),
        replaceable_sidecar: false,
        local_sockets: Vec::new(),
    };
    let daemon_info = DaemonRuntimeInfo {
        session: "debug-control".into(),
        state_dir: PathBuf::from("/tmp/state"),
        link_socket: PathBuf::from("/tmp/link"),
        admin_socket: PathBuf::from("/tmp/admin"),
        daemon_fingerprint: "public-fingerprint".into(),
        routes: vec!["%%% malformed-info-route-marker %%%".into()],
        direct_websocket: None,
        iroh_node_id: None,
        lifecycle_id: None,
        replaceable_sidecar: false,
    };
    let client_options = reconnect_test_options(vec![candidate.clone()]);
    let client_info = ClientRuntimeInfo {
        local_socket: PathBuf::from("/tmp/client"),
        daemon_public_key: [7; 32],
        route: "wss://client-info-user-marker:client-info-password-marker@client-info.example/\
                    client-info-path-marker?ticket=client-info-query-marker#\
                    client-info-fragment-marker"
            .into(),
    };

    let diagnostic = format!(
        "candidate={candidate:?} provider={routed_provider:?} \
             daemon_options={daemon_options:?} daemon_info={daemon_info:?} \
             client_options={client_options:?} client_info={client_info:?}"
    );

    for secret in [
        "candidate-user-marker",
        "candidate-password-marker",
        "candidate-path-marker",
        "candidate-query-marker",
        "candidate-fragment-marker",
        "direct-hint-marker",
        "hint-user-marker",
        "hint-password-marker",
        "hint-path-marker",
        "hint-query-marker",
        "hint-fragment-marker",
        "daemon-user-marker",
        "daemon-password-marker",
        "daemon-path-marker",
        "daemon-query-marker",
        "daemon-fragment-marker",
        "daemon-slot-marker",
        "daemon-ticket-marker",
        "map-user-marker",
        "map-password-marker",
        "map-path-marker",
        "map-query-marker",
        "map-fragment-marker",
        "route-slot-marker",
        "route-ticket-marker",
        "malformed-route-marker",
        "malformed-info-route-marker",
        "client-info-user-marker",
        "client-info-password-marker",
        "client-info-path-marker",
        "client-info-query-marker",
        "client-info-fragment-marker",
    ] {
        assert!(
            !diagnostic.contains(secret),
            "remote runtime Debug leaked {secret:?}: {diagnostic}"
        );
    }
    assert!(diagnostic.contains("wss://candidate.example"), "{diagnostic}");
    assert!(diagnostic.contains("relay+wss://daemon.example"), "{diagnostic}");
    assert!(diagnostic.contains("relay+wss://map.example"), "{diagnostic}");
    assert!(diagnostic.contains("wss://client-info.example"), "{diagnostic}");
    assert!(diagnostic.contains("invalid route"), "{diagnostic}");
    assert!(diagnostic.contains(cmux_remote::provider::ROUTING_DIRECT_ADDRS), "{diagnostic}");
    assert!(diagnostic.contains(cmux_remote::provider::ROUTING_RELAY_URL), "{diagnostic}");
}

#[tokio::test]
async fn carrier_initial_fallback_skips_network_route_before_any_dial() {
    let routes = vec![
        resolved_test_route("wss://network.example/v1/link", SupportedClientAuthModes::DeviceOnly),
        resolved_test_route("ssh://carrier.example", SupportedClientAuthModes::DeviceOrCarrier),
    ];
    let mut attempt = FakeInitialRouteAttempt {
        fail_ssh_bootstrap: false,
        fail_provider_index: None,
        events: Vec::new(),
    };

    let selected = select_initial_route(
        &routes,
        SessionId([13; 16]),
        LanePolicy::Single,
        AuthKind::Carrier,
        false,
        &mut attempt,
    )
    .await
    .unwrap();

    assert_eq!(selected, "ssh://carrier.example");
    assert_eq!(
        attempt.events,
        [
            FakeInitialRouteEvent::Bootstrap {
                endpoint: "ssh://carrier.example".into(),
                upgrade: false,
            },
            FakeInitialRouteEvent::Provider(ConnectRequest {
                endpoint: Url::parse("ssh://carrier.example").unwrap(),
                session: SessionId([13; 16]),
                lane_policy: LanePolicy::Single,
                routing: BTreeMap::new(),
            }),
        ],
        "the device-only WebSocket provider was invoked before carrier fallback"
    );
}

#[tokio::test]
async fn carrier_reconnect_skips_network_route_before_any_dial() {
    let routes = vec![
        resolved_test_route("wss://network.example/v1/link", SupportedClientAuthModes::DeviceOnly),
        resolved_test_route("ssh://carrier.example", SupportedClientAuthModes::DeviceOrCarrier),
    ];
    let attempt = FakeReconnectRouteAttempt::default();

    let (index, selected) = select_reconnect_route(
        &routes,
        0,
        SessionId([14; 16]),
        LanePolicy::Single,
        AuthKind::Carrier,
        &attempt,
    )
    .await
    .unwrap();

    assert_eq!(index, 1);
    assert_eq!(selected, "ssh://carrier.example");
    assert_eq!(
        attempt.requests.into_inner().unwrap(),
        [ConnectRequest {
            endpoint: Url::parse("ssh://carrier.example").unwrap(),
            session: SessionId([14; 16]),
            lane_policy: LanePolicy::Single,
            routing: BTreeMap::new(),
        }],
        "the device-only WebSocket provider was invoked during reconnect"
    );
}

#[tokio::test]
async fn carrier_route_selection_fails_without_dialing_when_every_route_is_device_only() {
    let routes = vec![resolved_test_route(
        "wss://network.example/v1/link",
        SupportedClientAuthModes::DeviceOnly,
    )];
    let mut attempt = FakeInitialRouteAttempt {
        fail_ssh_bootstrap: false,
        fail_provider_index: None,
        events: Vec::new(),
    };

    let error = select_initial_route(
        &routes,
        SessionId([15; 16]),
        LanePolicy::Single,
        AuthKind::Carrier,
        false,
        &mut attempt,
    )
    .await
    .unwrap_err()
    .to_string();

    assert!(error.contains("carrier"), "{error}");
    assert!(attempt.events.is_empty(), "an incompatible route was dialed");
}

fn reconnect_test_options(routes: Vec<ResolvedRouteCandidate>) -> ClientRuntimeOptions {
    let ssh = SshProviderConfig::default();
    ClientRuntimeOptions {
        routes,
        providers: test_providers(ssh.clone()),
        identity: StaticIdentity::generate().unwrap(),
        expected_daemon: None,
        auth: ClientAuthMode::Enrolled,
        device_name: "test".into(),
        session: SessionId([10; 16]),
        lane_policy: LanePolicy::Single,
        reconnect: ReconnectPolicy {
            attempt_timeout: Duration::from_millis(20),
            heartbeat_interval: None,
            ..ReconnectPolicy::default()
        },
        startup_timeout: Duration::from_millis(500),
        state_dir: PathBuf::from("/tmp/cmux-reconnect-budget-test"),
        local_socket: None,
        ssh,
        ssh_bootstrap: SshBootstrapOptions {
            auto_install: true,
            upgrade: false,
            attempt_timeout: Duration::from_millis(500),
        },
    }
}

#[test]
fn reconnect_resolution_budget_covers_the_whole_candidate_cycle() {
    let source = RuntimeReconnectGroups::new(
        reconnect_test_options(vec![
            test_route("wss://first.example/v1/link"),
            test_route("ssh://first-ssh.example"),
            test_route("iroh://fallback"),
            test_route("ssh://second-ssh.example"),
        ]),
        0,
    );

    assert_eq!(
        source.resolution_timeout(Duration::from_millis(20)),
        Duration::from_millis(1_080),
        "four provider attempts and two first-use SSH bootstraps need one aggregate deadline"
    );
    source.prepared_ssh[1].store(true, Ordering::Release);
    assert_eq!(source.resolution_timeout(Duration::from_millis(20)), Duration::from_millis(580));
    source.prepared_ssh[3].store(true, Ordering::Release);
    assert_eq!(source.resolution_timeout(Duration::from_millis(20)), Duration::from_millis(80));

    let ordinary = RuntimeReconnectGroups::new(
        reconnect_test_options(vec![test_route("wss://only.example/v1/link")]),
        0,
    );
    assert_eq!(
        ordinary.resolution_timeout(Duration::from_millis(20)),
        Duration::from_millis(20),
        "an ordinary single-route reconnect must retain its configured deadline"
    );

    let mut no_install_options = reconnect_test_options(vec![
        test_route("wss://selected.example/v1/link"),
        test_route("ssh://no-install.example"),
    ]);
    no_install_options.ssh_bootstrap.auto_install = false;
    let probe_timeout = no_install_options.ssh_bootstrap.attempt_timeout;
    let no_install = RuntimeReconnectGroups::new(no_install_options, 0);
    assert_eq!(
        no_install.resolution_timeout(Duration::from_millis(20)),
        probe_timeout + Duration::from_millis(40),
        "an unprepared no-install SSH route still needs time for remote-probe"
    );
}

#[cfg(unix)]
#[test]
fn client_shutdown_cancels_reconnect_ssh_bootstrap_and_kills_child() {
    let directory = tempfile::tempdir().unwrap();
    let daemon_root = directory.path().join("daemon");
    let daemon_link = daemon_root.join("link.sock");
    let proxy_link = directory.path().join("proxy-link.sock");
    let daemon = start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: "shutdown-cancel".into(),
            state_dir: Some(daemon_root.clone()),
            link_socket: Some(daemon_link.clone()),
            admin_socket: Some(daemon_root.join("admin.sock")),
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: false,
            local_sockets: Vec::new(),
        },
    )
    .unwrap();
    let proxy_listener = std::os::unix::net::UnixListener::bind(&proxy_link).unwrap();
    proxy_listener.set_nonblocking(true).unwrap();
    let (cut_tx, cut_rx) = tokio::sync::oneshot::channel();
    let proxy = thread::spawn(move || {
        let runtime = build_remote_runtime("cmux-remote-carrier-cut-test").unwrap();
        runtime.block_on(async move {
            let listener = tokio::net::UnixListener::from_std(proxy_listener).unwrap();
            let (mut client_stream, _) = listener.accept().await.unwrap();
            let mut daemon_stream = tokio::net::UnixStream::connect(daemon_link).await.unwrap();
            tokio::select! {
                _ = cut_rx => {}
                result = tokio::io::copy_bidirectional(
                    &mut client_stream,
                    &mut daemon_stream,
                ) => {
                    result.unwrap();
                }
            }
        });
    });

    let script = directory.path().join("ssh");
    let pid_file = directory.path().join("ssh.pid");
    write_executable(
        &script,
        format!("#!/bin/sh\nprintf '%s' \"$$\" > '{}'\nexec /bin/sleep 30\n", pid_file.display()),
    );
    let ssh = SshProviderConfig {
        ssh_binary: script.to_string_lossy().into_owned(),
        ..SshProviderConfig::default()
    };
    let providers = Arc::new(
        client_provider_registry(ssh.clone(), BTreeMap::new(), IrohPathMode::Auto, None, false)
            .unwrap(),
    );
    let mut unix_route = Url::parse("unix:///").unwrap();
    unix_route.set_path(proxy_link.to_str().unwrap());
    let routes = [unix_route, Url::parse("ssh://fallback.example").unwrap()]
        .into_iter()
        .map(|endpoint| {
            ResolvedRouteCandidate::resolve(endpoint, BTreeMap::new(), &providers).unwrap()
        })
        .collect();
    let client = start_client_runtime(ClientRuntimeOptions {
        routes,
        providers,
        identity: StaticIdentity::generate().unwrap(),
        expected_daemon: None,
        auth: ClientAuthMode::Carrier,
        device_name: "shutdown-cancel-test".into(),
        session: SessionId([21; 16]),
        lane_policy: LanePolicy::Single,
        reconnect: ReconnectPolicy {
            initial_delay: Duration::from_millis(10),
            maximum_delay: Duration::from_millis(10),
            // This fixture injects carrier EOF directly and asserts prompt
            // shutdown during SSH bootstrap. Give setup handshakes their
            // own budget and keep heartbeat timing out of that invariant.
            attempt_timeout: instrumented_test_timeout(Duration::from_secs(1)),
            full_jitter: false,
            heartbeat_interval: None,
            heartbeat_timeout: Duration::from_secs(1),
            maximum_attempts: None,
            maximum_duration: None,
            attempts_per_recovery: 3,
            // Real-clock fixture: redial as fast as its delays allow.
            redial_budget: cmux_remote::connection::RedialBudget {
                capacity: 1_000,
                refill_interval: Duration::from_millis(1),
            },
        },
        startup_timeout: instrumented_test_timeout(Duration::from_secs(5)),
        state_dir: directory.path().join("client"),
        local_socket: Some(directory.path().join("client.sock")),
        ssh,
        ssh_bootstrap: SshBootstrapOptions {
            auto_install: true,
            upgrade: false,
            attempt_timeout: Duration::from_secs(10),
        },
    })
    .unwrap();

    cut_tx.send(()).unwrap();
    proxy.join().unwrap();
    let deadline = std::time::Instant::now() + instrumented_test_timeout(Duration::from_secs(3));
    let pid = loop {
        if let Ok(value) = fs::read_to_string(&pid_file)
            && let Ok(pid) = value.parse::<libc::pid_t>()
        {
            break pid;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "client did not enter reconnect SSH bootstrap"
        );
        thread::sleep(Duration::from_millis(10));
    };

    let (done_tx, done_rx) = mpsc::sync_channel(1);
    thread::spawn(move || {
        let _ = done_tx.send(client.shutdown());
    });
    let completed_promptly =
        match done_rx.recv_timeout(instrumented_test_timeout(Duration::from_millis(500))) {
            Ok(result) => {
                result.unwrap();
                true
            }
            Err(_) => {
                unsafe {
                    libc::kill(pid, libc::SIGKILL);
                }
                done_rx
                    .recv_timeout(instrumented_test_timeout(Duration::from_secs(3)))
                    .expect("client shutdown stayed blocked after SSH cleanup")
                    .unwrap();
                false
            }
        };
    assert!(completed_promptly, "client shutdown waited for the reconnect SSH bootstrap timeout");

    let deadline = std::time::Instant::now() + instrumented_test_timeout(Duration::from_secs(2));
    while unsafe { libc::kill(pid, 0) } == 0 && std::time::Instant::now() < deadline {
        thread::sleep(Duration::from_millis(10));
    }
    assert_eq!(unsafe { libc::kill(pid, 0) }, -1, "cancelled SSH child is still alive");
    assert_eq!(std::io::Error::last_os_error().raw_os_error(), Some(libc::ESRCH));
    daemon.shutdown().unwrap();
}

#[tokio::test]
async fn failed_ssh_bootstrap_falls_back_to_next_initial_provider() {
    let routes = vec![
        test_route("ssh://unreachable.example"),
        resolved_test_route_with_routing(
            "iroh://next",
            BTreeMap::from([(
                cmux_remote::provider::ROUTING_DIRECT_ADDRS.into(),
                "127.0.0.1:4242".into(),
            )]),
            SupportedClientAuthModes::DeviceOnly,
        ),
    ];
    let mut attempt = FakeInitialRouteAttempt {
        fail_ssh_bootstrap: true,
        fail_provider_index: None,
        events: Vec::new(),
    };

    let selected = select_initial_route(
        &routes,
        SessionId([5; 16]),
        LanePolicy::Single,
        AuthKind::Enrolled,
        false,
        &mut attempt,
    )
    .await
    .unwrap();

    assert_eq!(selected, "iroh://next");
    assert_eq!(
        attempt.events,
        [
            FakeInitialRouteEvent::Bootstrap {
                endpoint: "ssh://unreachable.example".into(),
                upgrade: false,
            },
            FakeInitialRouteEvent::Provider(ConnectRequest {
                endpoint: Url::parse("iroh://next").unwrap(),
                session: SessionId([5; 16]),
                lane_policy: LanePolicy::Single,
                routing: BTreeMap::from([(
                    cmux_remote::provider::ROUTING_DIRECT_ADDRS.into(),
                    "127.0.0.1:4242".into(),
                )]),
            }),
        ]
    );
}

#[cfg(unix)]
#[tokio::test]
async fn initial_client_connection_retries_transient_carrier_failure() {
    let directory = tempfile::tempdir().unwrap();
    let daemon_auth =
        AuthDatabase::load_or_create(directory.path().join("daemon"), "startup-retry", true)
            .unwrap();
    let (daemon, _clients) = RemoteDaemon::new(daemon_auth, SessionLimits::default());
    let unix_path = directory.path().join("daemon.sock");
    let server = serve_unix(daemon, &unix_path, MAX_CARRIER_FRAME_BYTES).await.unwrap();

    let calls = Arc::new(AtomicUsize::new(0));
    let mut providers = cmux_remote::provider::ProviderRegistry::default();
    providers
        .register(Arc::new(TransientStartupProvider {
            calls: calls.clone(),
            transient_failures: 1,
            unix_path,
            unix: UnixProvider::new(MAX_CARRIER_FRAME_BYTES),
        }))
        .unwrap();
    let providers = Arc::new(providers);
    let route = ResolvedRouteCandidate::resolve(
        Url::parse("transient-startup://daemon").unwrap(),
        BTreeMap::new(),
        &providers,
    )
    .unwrap();
    let ssh = SshProviderConfig::default();
    let options = ClientRuntimeOptions {
        routes: vec![route],
        providers,
        identity: StaticIdentity::generate().unwrap(),
        expected_daemon: None,
        auth: ClientAuthMode::Carrier,
        device_name: "startup-retry-test".into(),
        session: SessionId([22; 16]),
        lane_policy: LanePolicy::Single,
        reconnect: ReconnectPolicy {
            initial_delay: Duration::from_millis(1),
            maximum_delay: Duration::from_millis(1),
            attempt_timeout: Duration::from_secs(1),
            full_jitter: false,
            heartbeat_interval: None,
            heartbeat_timeout: Duration::from_secs(1),
            maximum_attempts: Some(2),
            maximum_duration: None,
            attempts_per_recovery: 3,
            // Real-clock fixture: redial as fast as its delays allow.
            redial_budget: cmux_remote::connection::RedialBudget {
                capacity: 1_000,
                refill_interval: Duration::from_millis(1),
            },
        },
        startup_timeout: Duration::from_secs(2),
        state_dir: directory.path().join("client"),
        local_socket: None,
        ssh,
        ssh_bootstrap: SshBootstrapOptions {
            auto_install: false,
            upgrade: false,
            attempt_timeout: Duration::from_secs(1),
        },
    };
    let (_shutdown_tx, shutdown_rx) = watch::channel(false);

    let (connection, _) = tokio::time::timeout(
        Duration::from_secs(2),
        connect_first_available(&options, shutdown_rx),
    )
    .await
    .expect("initial client connection retry timed out")
    .expect("transient initial carrier failure stopped the client");

    assert_eq!(calls.load(Ordering::Acquire), 2);
    connection.close().await.unwrap();
    server.shutdown().await.unwrap();
}

#[cfg(unix)]
#[tokio::test]
async fn invitation_approval_outlives_the_route_attempt_timeout() {
    let directory = tempfile::tempdir().unwrap();
    let daemon_auth = AuthDatabase::load_or_create(
        directory.path().join("daemon"),
        "delayed-invitation-approval",
        true,
    )
    .unwrap();
    let unix_path = directory.path().join("daemon.sock");
    let route = unix_test_route(&unix_path);
    let invitation = daemon_auth
        .create_invitation(Duration::from_secs(60), vec![route.to_string()])
        .await
        .unwrap();
    let daemon_key: [u8; 32] = base64::engine::general_purpose::URL_SAFE_NO_PAD
        .decode(&invitation.daemon_public_key)
        .unwrap()
        .try_into()
        .unwrap();
    let (daemon, _clients) = RemoteDaemon::new(daemon_auth.clone(), SessionLimits::default());
    let server = serve_unix(daemon, &unix_path, MAX_CARRIER_FRAME_BYTES).await.unwrap();

    let mut providers = cmux_remote::provider::ProviderRegistry::default();
    providers.register(Arc::new(UnixProvider::new(MAX_CARRIER_FRAME_BYTES))).unwrap();
    let providers = Arc::new(providers);
    let route = ResolvedRouteCandidate::resolve(route, BTreeMap::new(), &providers).unwrap();
    let ssh = SshProviderConfig::default();
    let options = ClientRuntimeOptions {
        routes: vec![route],
        providers,
        identity: StaticIdentity::generate().unwrap(),
        expected_daemon: Some(daemon_key),
        auth: ClientAuthMode::Invitation {
            id: invitation.id.clone(),
            secret: zeroize::Zeroizing::new(invitation.secret_bytes().unwrap()),
        },
        device_name: "delayed-approval-client".into(),
        session: SessionId([24; 16]),
        lane_policy: LanePolicy::Single,
        reconnect: ReconnectPolicy {
            initial_delay: Duration::from_millis(1),
            maximum_delay: Duration::from_millis(1),
            attempt_timeout: Duration::from_millis(20),
            full_jitter: false,
            heartbeat_interval: None,
            heartbeat_timeout: Duration::from_secs(1),
            maximum_attempts: Some(2),
            maximum_duration: None,
            attempts_per_recovery: 3,
            // Real-clock fixture: redial as fast as its delays allow.
            redial_budget: cmux_remote::connection::RedialBudget {
                capacity: 1_000,
                refill_interval: Duration::from_millis(1),
            },
        },
        startup_timeout: Duration::from_secs(1),
        state_dir: directory.path().join("client"),
        local_socket: None,
        ssh,
        ssh_bootstrap: SshBootstrapOptions {
            auto_install: false,
            upgrade: false,
            attempt_timeout: Duration::from_secs(1),
        },
    };
    let (_shutdown_tx, shutdown_rx) = watch::channel(false);
    let connection =
        tokio::spawn(async move { connect_first_available(&options, shutdown_rx).await });

    let pending = daemon_auth.wait_for_pending(Duration::from_millis(200)).await.unwrap();
    tokio::time::sleep(Duration::from_millis(60)).await;
    daemon_auth.approve(&pending[0].invitation_id).await.unwrap();

    let (connection, _) = tokio::time::timeout(Duration::from_secs(1), connection)
        .await
        .expect("delayed invitation approval timed out")
        .unwrap()
        .expect("the route timer abandoned a pending invitation approval");
    connection.close().await.unwrap();
    server.shutdown().await.unwrap();
}

#[cfg(unix)]
#[tokio::test]
async fn initial_client_connection_respects_one_attempt_policy() {
    let directory = tempfile::tempdir().unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let mut providers = cmux_remote::provider::ProviderRegistry::default();
    providers
        .register(Arc::new(TransientStartupProvider {
            calls: calls.clone(),
            transient_failures: usize::MAX,
            unix_path: directory.path().join("unused.sock"),
            unix: UnixProvider::new(MAX_CARRIER_FRAME_BYTES),
        }))
        .unwrap();
    let providers = Arc::new(providers);
    let route = ResolvedRouteCandidate::resolve(
        Url::parse("transient-startup://daemon").unwrap(),
        BTreeMap::new(),
        &providers,
    )
    .unwrap();
    let mut options = reconnect_test_options(vec![route]);
    options.providers = providers;
    options.auth = ClientAuthMode::Carrier;
    options.reconnect.maximum_attempts = Some(1);
    options.reconnect.full_jitter = false;
    let (_shutdown_tx, shutdown_rx) = watch::channel(false);

    let error = connect_first_available(&options, shutdown_rx).await.unwrap_err();

    assert!(error.to_string().contains("transient startup carrier failure"), "{error:#}");
    assert_eq!(calls.load(Ordering::Acquire), 1);
}

#[tokio::test]
async fn initial_route_failures_redact_ssh_and_relay_endpoint_secrets() {
    let routes = vec![
        test_route("ssh://ssh-user:ssh-password-marker@ssh.example:2222"),
        test_route(
            "relay+wss://relay-user:relay-password-marker@relay.example/\
                     capability-marker?ticket=query-marker#fragment-marker",
        ),
    ];
    let mut attempt = FakeInitialRouteAttempt {
        fail_ssh_bootstrap: true,
        fail_provider_index: Some(1),
        events: Vec::new(),
    };

    let error = select_initial_route(
        &routes,
        SessionId([11; 16]),
        LanePolicy::Single,
        AuthKind::Enrolled,
        false,
        &mut attempt,
    )
    .await
    .unwrap_err()
    .to_string();

    for secret in [
        "ssh-user",
        "ssh-password-marker",
        "relay-user",
        "relay-password-marker",
        "capability-marker",
        "query-marker",
        "fragment-marker",
    ] {
        assert!(!error.contains(secret), "route failure leaked {secret:?}: {error}");
    }
    assert!(error.contains("ssh://ssh.example:2222"), "{error}");
    assert!(error.contains("relay+wss://relay.example"), "{error}");
}

#[tokio::test]
async fn upgrade_bootstrap_failure_is_fatal_without_provider_fallback() {
    let routes = vec![
        test_route("ssh://upgrade-user@upgrade.example"),
        test_route("wss://fallback.example/v1/link"),
    ];
    let mut attempt = FakeInitialRouteAttempt {
        fail_ssh_bootstrap: true,
        fail_provider_index: None,
        events: Vec::new(),
    };

    let error = select_initial_route(
        &routes,
        SessionId([6; 16]),
        LanePolicy::Single,
        AuthKind::Enrolled,
        true,
        &mut attempt,
    )
    .await
    .unwrap_err();

    assert!(error.to_string().contains("fake SSH is unreachable"));
    assert!(!error.to_string().contains("upgrade-user"));
    assert!(error.to_string().contains("ssh://upgrade.example"));
    assert_eq!(
        attempt.events,
        [FakeInitialRouteEvent::Bootstrap {
            endpoint: "ssh://upgrade-user@upgrade.example".into(),
            upgrade: true,
        }]
    );
}

#[tokio::test]
async fn upgrade_provider_failure_is_fatal_without_route_fallback() {
    let routes = vec![
        test_route("ssh://upgrade-user@upgrade.example"),
        test_route("wss://fallback.example/v1/link"),
    ];
    let mut attempt = FakeInitialRouteAttempt {
        fail_ssh_bootstrap: false,
        fail_provider_index: Some(0),
        events: Vec::new(),
    };

    let error = select_initial_route(
        &routes,
        SessionId([8; 16]),
        LanePolicy::Single,
        AuthKind::Enrolled,
        true,
        &mut attempt,
    )
    .await
    .unwrap_err();

    assert!(error.to_string().contains("fake provider is unreachable"));
    assert!(!error.to_string().contains("upgrade-user"));
    assert!(error.to_string().contains("ssh://upgrade.example"));
    assert_eq!(
        attempt.events,
        [
            FakeInitialRouteEvent::Bootstrap {
                endpoint: "ssh://upgrade-user@upgrade.example".into(),
                upgrade: true,
            },
            FakeInitialRouteEvent::Provider(ConnectRequest {
                endpoint: Url::parse("ssh://upgrade-user@upgrade.example").unwrap(),
                session: SessionId([8; 16]),
                lane_policy: LanePolicy::Single,
                routing: BTreeMap::new(),
            }),
        ]
    );
}

#[cfg(unix)]
#[tokio::test]
async fn reconnect_bootstraps_an_ssh_candidate_not_attempted_initially() {
    let directory = tempfile::tempdir().unwrap();
    let script = directory.path().join("ssh");
    let log = directory.path().join("ssh.log");
    let probe = cmux_remote::ssh_bootstrap::RemoteProbe {
        app: "cmux-tui".into(),
        version: crate::distribution::DISTRIBUTION_VERSION.into(),
        distribution_version: Some(crate::distribution::DISTRIBUTION_VERSION.into()),
        npm_bootstrap_version: crate::distribution::NPM_BOOTSTRAP_VERSION.map(str::to_owned),
        build_identity: Some(cmux_build_identity::BUILD_IDENTITY.into()),
        remote_protocol: cmux_remote_protocol::REMOTE_PROTOCOL_VERSION,
        os: "test".into(),
        arch: "test".into(),
        capabilities: Vec::new(),
    };
    write_executable(
        &script,
        format!(
            "#!/bin/sh\nprintf '%s\\n' \"$*\" >> '{}'\nprintf '%s\\n' '{}'\n",
            log.display(),
            serde_json::to_string(&probe).unwrap()
        ),
    );
    let ssh = SshProviderConfig {
        ssh_binary: script.to_string_lossy().into_owned(),
        ..SshProviderConfig::default()
    };
    let options = ClientRuntimeOptions {
        routes: vec![
            test_route("wss://initial.example/v1/link"),
            test_route("ssh://fallback.example"),
        ],
        providers: test_providers(ssh.clone()),
        identity: StaticIdentity::generate().unwrap(),
        expected_daemon: None,
        auth: ClientAuthMode::Enrolled,
        device_name: "test".into(),
        session: SessionId([9; 16]),
        lane_policy: LanePolicy::Single,
        reconnect: ReconnectPolicy {
            attempt_timeout: Duration::from_millis(20),
            heartbeat_interval: None,
            ..ReconnectPolicy::default()
        },
        startup_timeout: Duration::from_millis(500),
        state_dir: directory.path().join("state"),
        local_socket: None,
        ssh,
        ssh_bootstrap: SshBootstrapOptions {
            auto_install: true,
            upgrade: false,
            // This launches a real subprocess while hundreds of TUI tests
            // run concurrently. Keep the watchdog independent of host
            // scheduler latency; the reconnect budget remains 20 ms.
            attempt_timeout: Duration::from_secs(30),
        },
    };
    let source = RuntimeReconnectGroups::new(options, 0);

    assert_eq!(source.resolution_timeout(Duration::from_millis(20)), Duration::from_millis(30_040));
    assert_eq!(source.next_group().await.unwrap().description(), "ssh://fallback.example");
    assert_eq!(
        source.resolution_timeout(Duration::from_millis(20)),
        Duration::from_millis(40),
        "prepared SSH routes must retain only the per-provider reconnect budgets"
    );
    source.next.store(1, Ordering::Relaxed);
    assert_eq!(source.next_group().await.unwrap().description(), "ssh://fallback.example");
    let probes = fs::read_to_string(&log)
        .unwrap_or_default()
        .lines()
        .filter(|line| line.contains(" remote-probe --json"))
        .count();
    assert_eq!(probes, 1, "a prepared SSH reconnect route was probed again");
}

#[tokio::test]
async fn reconnect_provider_receives_the_exact_route_candidate_hints() {
    let routes = vec![
        resolved_test_route_with_routing(
            "iroh://first",
            BTreeMap::from([(
                cmux_remote::provider::ROUTING_RELAY_URL.into(),
                "https://first-relay.example".into(),
            )]),
            SupportedClientAuthModes::DeviceOnly,
        ),
        resolved_test_route_with_routing(
            "iroh://second",
            BTreeMap::from([(
                cmux_remote::provider::ROUTING_RELAY_URL.into(),
                "https://second-relay.example".into(),
            )]),
            SupportedClientAuthModes::DeviceOnly,
        ),
    ];
    let attempt = FakeReconnectRouteAttempt::default();

    let (index, selected) = select_reconnect_route(
        &routes,
        1,
        SessionId([7; 16]),
        LanePolicy::Single,
        AuthKind::Enrolled,
        &attempt,
    )
    .await
    .unwrap();

    assert_eq!(index, 1);
    assert_eq!(selected, "iroh://second");
    assert_eq!(
        attempt.requests.into_inner().unwrap(),
        [ConnectRequest {
            endpoint: Url::parse("iroh://second").unwrap(),
            session: SessionId([7; 16]),
            lane_policy: LanePolicy::Single,
            routing: BTreeMap::from([(
                cmux_remote::provider::ROUTING_RELAY_URL.into(),
                "https://second-relay.example".into(),
            )]),
        }]
    );
}

#[tokio::test]
async fn reconnect_failures_redact_endpoint_secrets() {
    let routes = vec![
        test_route(
            "wss://ws-user:ws-password-marker@ws.example/\
                     capability-marker?ticket=query-marker#fragment-marker",
        ),
        test_route(
            "relay+wss://relay-user:relay-password-marker@relay.example/\
                     relay-capability?ticket=relay-query#relay-fragment",
        ),
    ];

    let error = select_reconnect_route(
        &routes,
        0,
        SessionId([12; 16]),
        LanePolicy::Single,
        AuthKind::Enrolled,
        &RejectingReconnectRouteAttempt,
    )
    .await
    .unwrap_err()
    .to_string();

    for secret in [
        "ws-user",
        "ws-password-marker",
        "capability-marker",
        "query-marker",
        "fragment-marker",
        "relay-user",
        "relay-password-marker",
        "relay-capability",
        "relay-query",
        "relay-fragment",
    ] {
        assert!(!error.contains(secret), "reconnect failure leaked {secret:?}: {error}");
    }
    assert!(error.contains("wss://ws.example/"), "{error}");
    assert!(error.contains("relay+wss://relay.example"), "{error}");
}

#[tokio::test]
async fn reconnect_provider_debug_error_redacts_request_route_and_hints() {
    let routes = vec![resolved_test_route_with_routing(
        "wss://reconnect-user-marker:reconnect-password-marker@reconnect.example/\
             reconnect-path-marker?ticket=reconnect-query-marker#reconnect-fragment-marker",
        BTreeMap::from([(
            cmux_remote::provider::ROUTING_RELAY_URL.into(),
            "https://routing-user-marker:routing-password-marker@routing.example/\
                 routing-path-marker?ticket=routing-query-marker#routing-fragment-marker"
                .into(),
        )]),
        SupportedClientAuthModes::DeviceOnly,
    )];

    let error = select_reconnect_route(
        &routes,
        0,
        SessionId([18; 16]),
        LanePolicy::Single,
        AuthKind::Enrolled,
        &DebugEchoingReconnectRouteAttempt,
    )
    .await
    .unwrap_err()
    .to_string();

    for secret in [
        "reconnect-user-marker",
        "reconnect-password-marker",
        "reconnect-path-marker",
        "reconnect-query-marker",
        "reconnect-fragment-marker",
        "routing-user-marker",
        "routing-password-marker",
        "routing-path-marker",
        "routing-query-marker",
        "routing-fragment-marker",
    ] {
        assert!(!error.contains(secret), "reconnect diagnostic leaked {secret:?}: {error}");
    }
    assert!(error.contains("wss://reconnect.example"), "{error}");
    assert!(error.contains(cmux_remote::provider::ROUTING_RELAY_URL), "{error}");
}

#[tokio::test]
async fn reconnect_ssh_bootstrap_failure_redacts_dial_userinfo() {
    let routes = vec![test_route("ssh://ssh-user:ssh-password-marker@ssh.example:2222")];
    let options = reconnect_test_options(routes.clone());
    let prepared_ssh = [AtomicBool::new(false)];
    let attempt = RuntimeReconnectRouteAttempt {
        options: &options,
        prepared_ssh: &prepared_ssh,
        shutdown: None,
    };
    let request = connect_request(&routes[0], options.session, options.lane_policy).unwrap();

    let error = match attempt.connect(0, request, AuthKind::Enrolled).await {
        Err(error) => error.to_string(),
        Ok(_) => panic!("SSH reconnect unexpectedly succeeded"),
    };

    assert!(!error.contains("ssh-user"), "{error}");
    assert!(!error.contains("ssh-password-marker"), "{error}");
    assert!(error.contains("ssh://ssh.example:2222"), "{error}");
}

#[test]
fn ssh_bootstrap_normalizes_ipv6_and_preserves_port() {
    let endpoint = Url::parse("ssh://alice@[2001:db8::1]:2222").unwrap();
    assert_eq!(
        ssh_bootstrap_destination(&endpoint).unwrap(),
        ("alice@2001:db8::1".into(), Some(2222))
    );
}

#[test]
fn ssh_bootstrap_rejects_option_like_destination() {
    let endpoint = Url::parse("ssh://-Fvalidation@localhost").unwrap();
    assert!(ssh_bootstrap_destination(&endpoint).is_err());
}

#[cfg(unix)]
#[tokio::test]
async fn connection_timeout_bounds_initial_ssh_bootstrap() {
    let directory = tempfile::tempdir().unwrap();
    let script = directory.path().join("ssh");
    write_executable(&script, "#!/bin/sh\nexec /bin/sleep 30\n");
    let ssh = SshProviderConfig {
        ssh_binary: script.to_string_lossy().into_owned(),
        ..SshProviderConfig::default()
    };
    let options = SshBootstrapOptions {
        auto_install: true,
        upgrade: false,
        attempt_timeout: Duration::from_millis(100),
    };

    let error = bootstrap_initial_ssh_route(
        &Url::parse("ssh://example.com").unwrap(),
        &ssh,
        options,
        false,
        None,
    )
    .await
    .unwrap_err();
    assert!(error.to_string().contains("timed out"));
}

#[test]
fn remote_runtime_worker_pool_is_bounded() {
    assert!(
        (MIN_REMOTE_RUNTIME_WORKERS..=MAX_REMOTE_RUNTIME_WORKERS)
            .contains(&remote_runtime_worker_count())
    );
    build_remote_runtime("cmux-remote-runtime-test").unwrap();
}

#[tokio::test]
async fn reconnect_source_cycles_candidates_with_sanitized_descriptions() {
    let ssh = SshProviderConfig::default();
    let options = ClientRuntimeOptions {
        routes: vec![test_route("ws://first.invalid"), test_route("ws://second.invalid")],
        providers: test_providers(ssh.clone()),
        identity: StaticIdentity::generate().unwrap(),
        expected_daemon: None,
        auth: ClientAuthMode::Enrolled,
        device_name: "test".into(),
        session: SessionId([3; 16]),
        lane_policy: LanePolicy::Single,
        reconnect: ReconnectPolicy::default(),
        startup_timeout: Duration::from_secs(1),
        state_dir: PathBuf::from("/tmp/cmux-remote-route-test"),
        local_socket: None,
        ssh,
        ssh_bootstrap: SshBootstrapOptions {
            auto_install: true,
            upgrade: false,
            attempt_timeout: Duration::from_secs(1),
        },
    };
    let source = RuntimeReconnectGroups::new(options, 0);
    assert_eq!(source.next_group().await.unwrap().description(), "ws://second.invalid/");
    assert_eq!(source.next_group().await.unwrap().description(), "ws://first.invalid/");
}

#[test]
fn persisted_runtime_metadata_redacts_route_credentials() {
    let directory = tempfile::tempdir().unwrap();
    let info = DaemonRuntimeInfo {
        session: "persist-redaction".into(),
        state_dir: directory.path().into(),
        link_socket: directory.path().join("link.sock"),
        admin_socket: directory.path().join("admin.sock"),
        daemon_fingerprint: "public-fingerprint".into(),
        routes: vec![
            "wss://persist-user-marker:persist-password-marker@persist.example/\
                 persist-path-marker?ticket=persist-query-marker#persist-fragment-marker"
                .into(),
        ],
        direct_websocket: None,
        iroh_node_id: None,
        lifecycle_id: None,
        replaceable_sidecar: false,
    };

    persist_runtime_info(directory.path(), &info).unwrap();

    let persisted = fs::read_to_string(directory.path().join("runtime.json")).unwrap();
    for secret in [
        "persist-user-marker",
        "persist-password-marker",
        "persist-path-marker",
        "persist-query-marker",
        "persist-fragment-marker",
    ] {
        assert!(!persisted.contains(secret), "runtime metadata leaked {secret:?}: {persisted}");
    }
    let persisted: DaemonRuntimeInfo = serde_json::from_str(&persisted).unwrap();
    assert_eq!(persisted.routes, ["wss://persist.example/"]);
    assert_eq!(persisted.session, info.session);
}

#[test]
fn persisted_runtime_metadata_keeps_dialable_iroh_hints() {
    let directory = tempfile::tempdir().unwrap();
    let node_id = "a".repeat(64);
    let mut iroh_route = Url::parse(&format!("iroh://{node_id}")).unwrap();
    iroh_route
        .query_pairs_mut()
        .append_pair(
            "relay_url",
            "https://persist-user:persist-password@relay.example/private?token=persist-token",
        )
        .append_pair("direct_addrs", "127.0.0.1:7777")
        .append_pair("ticket", "drop-me");
    let info = DaemonRuntimeInfo {
        session: "persist-iroh-routing".into(),
        state_dir: directory.path().into(),
        link_socket: directory.path().join("link.sock"),
        admin_socket: directory.path().join("admin.sock"),
        daemon_fingerprint: "public-fingerprint".into(),
        routes: vec![iroh_route.to_string()],
        direct_websocket: None,
        iroh_node_id: Some(node_id.clone()),
        lifecycle_id: None,
        replaceable_sidecar: false,
    };

    persist_runtime_info(directory.path(), &info).unwrap();

    let persisted = fs::read_to_string(directory.path().join("runtime.json")).unwrap();
    for secret in ["persist-user", "persist-password", "persist-token", "drop-me"] {
        assert!(!persisted.contains(secret), "runtime metadata leaked {secret:?}: {persisted}");
    }
    let persisted: DaemonRuntimeInfo = serde_json::from_str(&persisted).unwrap();
    let route = Url::parse(&persisted.routes[0]).unwrap();
    let routing = route.query_pairs().into_owned().collect::<BTreeMap<_, _>>();
    assert_eq!(route.host_str(), Some(node_id.as_str()));
    assert_eq!(routing["relay_url"], "https://relay.example/");
    assert_eq!(routing["direct_addrs"], "127.0.0.1:7777");
    assert!(!routing.contains_key("ticket"));
}

#[cfg(unix)]
#[test]
fn persisted_runtime_metadata_propagates_parent_directory_sync_failure() {
    use std::os::unix::fs::PermissionsExt as _;

    let directory = tempfile::tempdir().unwrap();
    let info = DaemonRuntimeInfo {
        session: "persist-runtime-sync".into(),
        state_dir: directory.path().into(),
        link_socket: directory.path().join("link.sock"),
        admin_socket: directory.path().join("admin.sock"),
        daemon_fingerprint: "public-fingerprint".into(),
        routes: Vec::new(),
        direct_websocket: None,
        iroh_node_id: None,
        lifecycle_id: Some("durable-active-lifecycle".into()),
        replaceable_sidecar: false,
    };

    fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o300)).unwrap();
    let result = persist_runtime_info(directory.path(), &info);
    fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();

    result.expect_err("runtime persistence skipped its parent-directory sync");
}

#[cfg(unix)]
#[test]
fn daemon_finalizes_preliminary_lifecycle_after_committed_runtime_sync_failure() {
    let directory = tempfile::tempdir_in("/tmp").unwrap();
    let state_root = directory.path().join("state");
    let session = "committed-preliminary-runtime";
    let (state_dir, _, _) = daemon_paths(session, Some(&state_root)).unwrap();
    fail_state_directory_sync_after(&state_dir, 1);

    let error = match start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: session.into(),
            state_dir: Some(state_root.clone()),
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    ) {
        Err(error) => error,
        Ok(runtime) => {
            runtime.shutdown().unwrap();
            panic!("daemon ignored a preliminary runtime durability failure");
        }
    };
    assert!(error.to_string().contains("injected state-directory sync failure"), "{error:#}");
    assert!(
        !state_dir.join("runtime.json").exists(),
        "committed preliminary runtime was left without lifecycle finalization"
    );
    let outcome = load_shutdown_outcome(&state_dir)
        .expect("committed preliminary runtime did not publish a shutdown outcome");
    assert_eq!(outcome.status, DaemonShutdownStatus::Succeeded);

    let retry = start_daemon_runtime(
        directory.path().join("missing-mux.sock"),
        DaemonRuntimeOptions {
            session: session.into(),
            state_dir: Some(state_root),
            link_socket: None,
            admin_socket: None,
            direct_websocket: None,
            allow_insecure_non_loopback: false,
            trusted_carrier_websocket: false,
            workspace_http: None,
            relays: Vec::new(),
            carrier_grant_config: None,
            iroh: false,
            advertised_routes: Vec::new(),
            resume_lease: Duration::from_secs(2),
            replaceable_sidecar: true,
            local_sockets: Vec::new(),
        },
    )
    .expect("finalized preliminary lifecycle blocked the next startup");
    retry.shutdown().unwrap();
}

#[test]
fn persisted_runtime_metadata_rejects_malformed_routes_without_echoing_them() {
    let directory = tempfile::tempdir().unwrap();
    let info = DaemonRuntimeInfo {
        session: "persist-malformed".into(),
        state_dir: directory.path().into(),
        link_socket: directory.path().join("link.sock"),
        admin_socket: directory.path().join("admin.sock"),
        daemon_fingerprint: "public-fingerprint".into(),
        routes: vec!["%%% malformed-persisted-route-marker %%%".into()],
        direct_websocket: None,
        iroh_node_id: None,
        lifecycle_id: None,
        replaceable_sidecar: false,
    };

    let error = persist_runtime_info(directory.path(), &info).unwrap_err().to_string();

    assert!(!error.contains("malformed-persisted-route-marker"), "{error}");
    assert!(!directory.path().join("runtime.json").exists());
}

#[cfg(unix)]
#[tokio::test]
async fn client_socket_rejects_a_symlinked_parent_directory() {
    use std::os::unix::fs::symlink;

    let directory = tempfile::tempdir().unwrap();
    let real_parent = directory.path().join("real");
    let symlinked_parent = directory.path().join("alias");
    fs::create_dir(&real_parent).unwrap();
    symlink(&real_parent, &symlinked_parent).unwrap();

    let error =
        prepare_client_socket(&symlinked_parent.join("mux.sock")).await.unwrap_err().to_string();
    assert!(error.contains("symlink"), "{error}");
}

#[cfg(unix)]
#[tokio::test]
async fn client_socket_rejects_an_intermediate_symlink_before_creating_the_parent() {
    use std::os::unix::fs::symlink;

    let directory = tempfile::tempdir().unwrap();
    let target = directory.path().join("target");
    let alias = directory.path().join("alias");
    fs::create_dir(&target).unwrap();
    symlink(&target, &alias).unwrap();

    let result = prepare_client_socket(&alias.join("missing/mux.sock")).await;

    assert!(result.is_err(), "intermediate symlink was accepted");
    assert!(!target.join("missing").exists());
}

#[cfg(unix)]
#[tokio::test]
async fn client_socket_rejects_a_symlinked_path_lock() {
    use std::os::unix::fs::symlink;

    let directory = tempfile::tempdir().unwrap();
    let target = directory.path().join("target");
    fs::write(&target, b"do not lock").unwrap();
    symlink(&target, directory.path().join("mux.sock.lock")).unwrap();

    let error =
        prepare_client_socket(&directory.path().join("mux.sock")).await.unwrap_err().to_string();

    assert!(
        error.contains("lock") || error.contains("symlink"),
        "unexpected lock-file rejection: {error}"
    );
    assert_eq!(fs::read(target).unwrap(), b"do not lock");
}

#[cfg(unix)]
#[tokio::test]
async fn client_socket_creates_a_private_owned_parent_directory() {
    use std::os::unix::fs::{MetadataExt, PermissionsExt};

    let directory = tempfile::tempdir().unwrap();
    let parent = directory.path().join("private");
    prepare_client_socket(&parent.join("mux.sock")).await.unwrap();

    let metadata = fs::symlink_metadata(parent).unwrap();
    assert_eq!(metadata.uid(), unsafe { libc::geteuid() });
    assert_eq!(metadata.permissions().mode() & 0o077, 0);

    let lock_metadata = fs::symlink_metadata(directory.path().join("private/mux.sock.lock"))
        .expect("client socket preparation did not persist its ownership lock");
    assert!(lock_metadata.is_file());
    assert_eq!(lock_metadata.uid(), unsafe { libc::geteuid() });
    assert_eq!(lock_metadata.permissions().mode() & 0o077, 0);
    assert_eq!(lock_metadata.nlink(), 1);
}

#[cfg(unix)]
#[tokio::test]
async fn recovery_socket_probe_bounds_a_stalled_connect() {
    let stalled = std::future::pending::<std::io::Result<()>>();

    let error = tokio::time::timeout(Duration::from_secs(1), bounded_unix_socket_connect(stalled))
        .await
        .expect("recovery socket probe ignored its internal deadline")
        .expect_err("a permanently pending socket probe unexpectedly connected");

    assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
}

#[cfg(unix)]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn stale_client_socket_takeover_waits_for_the_path_lock() {
    use std::fs::OpenOptions;
    use std::os::fd::AsRawFd;
    use std::os::unix::fs::OpenOptionsExt;

    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("mux.sock");
    let stale = tokio::net::UnixListener::bind(&path).unwrap();
    drop(stale);

    let lock_path = directory.path().join("mux.sock.lock");
    let lock = OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(lock_path)
        .unwrap();
    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX) }, 0);

    let contender_path = path.clone();
    let mut contender = tokio::spawn(async move {
        prepare_client_socket(&contender_path).await.unwrap().bind().unwrap()
    });
    assert!(
        tokio::time::timeout(Duration::from_millis(100), &mut contender).await.is_err(),
        "stale-socket takeover ignored the per-path ownership lock"
    );

    assert_eq!(unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_UN) }, 0);
    let lease = tokio::time::timeout(Duration::from_secs(1), contender)
        .await
        .expect("client socket takeover stayed blocked after the path lock was released")
        .unwrap();
    assert!(path.exists());
    drop(lease);
}

#[cfg(unix)]
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn concurrent_stale_client_socket_takeover_has_one_owner() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("mux.sock");
    let stale = tokio::net::UnixListener::bind(&path).unwrap();
    drop(stale);

    let start = Arc::new(tokio::sync::Barrier::new(2));
    let spawn_contender = |path: PathBuf, start: Arc<tokio::sync::Barrier>| {
        tokio::spawn(async move {
            start.wait().await;
            prepare_client_socket(&path).await?.bind()
        })
    };
    let first = spawn_contender(path.clone(), Arc::clone(&start));
    let second = spawn_contender(path.clone(), start);
    let (first, second) =
        tokio::time::timeout(Duration::from_secs(2), async { tokio::join!(first, second) })
            .await
            .expect("concurrent stale-socket takeover did not settle");
    let first = first.unwrap();
    let second = second.unwrap();

    let (lease, rejected) = match (first, second) {
        (Ok(lease), Err(error)) | (Err(error), Ok(lease)) => (lease, error),
        (Ok(_), Ok(_)) => panic!("two clients acquired the same local socket"),
        (Err(first), Err(second)) => {
            panic!("both clients failed stale-socket takeover: {first:#}; {second:#}")
        }
    };
    assert!(rejected.to_string().contains("another client owns"), "{rejected:#}");
    tokio::time::timeout(Duration::from_secs(1), tokio::net::UnixStream::connect(&path))
        .await
        .expect("winning client socket was unreachable")
        .unwrap();
    drop(lease);
    assert!(!path.exists());
}

#[cfg(unix)]
#[tokio::test]
async fn client_socket_lease_never_unlinks_a_bound_successor() {
    let directory = tempfile::tempdir().unwrap();
    let path = directory.path().join("mux.sock");
    let mut previous = prepare_client_socket(&path).await.unwrap().bind().unwrap();

    previous.unlink().unwrap();
    let successor = tokio::net::UnixListener::bind(&path).unwrap();
    drop(previous);

    assert!(path.exists(), "old client lease unlinked the successor socket");
    let connect = tokio::net::UnixStream::connect(&path);
    let accept = successor.accept();
    let (connected, accepted) =
        tokio::time::timeout(Duration::from_secs(1), async { tokio::join!(connect, accept) })
            .await
            .expect("successor socket was unreachable");
    connected.unwrap();
    accepted.unwrap();
}

#[cfg(unix)]
#[test]
fn client_socket_rejects_a_parent_owned_by_another_user() {
    use std::os::unix::fs::MetadataExt;

    let directory = tempfile::tempdir().unwrap();
    let metadata = fs::symlink_metadata(directory.path()).unwrap();
    let other_uid = metadata.uid() ^ 1;

    let error =
        validate_client_socket_directory(directory.path(), &metadata, other_uid).unwrap_err();
    assert!(error.to_string().contains("not owned by the effective user"));
}

#[cfg(unix)]
#[test]
fn long_state_path_uses_a_short_runtime_socket() {
    let state = PathBuf::from("/tmp").join("x".repeat(256));
    let socket = default_client_socket(&state, SessionId([4; 16])).unwrap();
    assert!(unix_socket_path_fits(&socket));
    assert!(!socket.starts_with(state));
}

/// Another local user can create `/tmp/cmux-r-<uid>` first. The ownership
/// checks must still reject it, and the client must still start in a
/// fresh private directory that a second resolution finds again.
#[cfg(unix)]
#[tokio::test]
async fn squatted_shared_client_socket_directory_falls_back_to_a_private_directory() {
    use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};

    // A short root keeps the fallback socket paths inside sun_path, as
    // they are under the real /tmp.
    let root = tempfile::Builder::new().prefix("r").rand_bytes(2).tempdir_in("/tmp").unwrap();
    let shared_tmp = root.path().to_path_buf();
    let decoy = root.path().join("decoy");
    fs::create_dir(&decoy).unwrap();
    let squatted = shared_tmp.join(format!("cmux-r-{}", unsafe { libc::geteuid() }));
    symlink(&decoy, &squatted).unwrap();
    let state = root.path().join("x".repeat(160));
    let session = SessionId([7; 16]);

    let socket = client_socket_path_in(&state, session, None, &shared_tmp).unwrap();
    let prepared = prepare_client_socket(&socket).await;
    assert!(
        prepared.is_ok(),
        "a squatted shared directory blocked the client socket {}: {:?}",
        socket.display(),
        prepared.err()
    );
    let directory = socket.parent().unwrap();
    assert_ne!(directory, squatted);
    assert!(directory.starts_with(&shared_tmp));
    let metadata = fs::symlink_metadata(directory).unwrap();
    assert!(metadata.is_dir());
    assert_eq!(metadata.uid(), unsafe { libc::geteuid() });
    assert_eq!(metadata.permissions().mode() & 0o777, 0o700);
    assert_eq!(client_socket_path_in(&state, session, None, &shared_tmp).unwrap(), socket);
    assert!(fs::read_dir(&decoy).unwrap().next().is_none());
}

/// The daemon's link and admin sockets fall back the same way, and every
/// later `remote-link`, `remote-stop` or status call resolves the same
/// directory from the session state.
#[cfg(unix)]
#[test]
fn squatted_shared_daemon_runtime_directory_falls_back_to_a_private_directory() {
    use std::os::unix::fs::{MetadataExt, PermissionsExt, symlink};

    // A short root keeps the fallback socket paths inside sun_path, as
    // they are under the real /tmp.
    let root = tempfile::Builder::new().prefix("r").rand_bytes(2).tempdir_in("/tmp").unwrap();
    let shared_tmp = root.path().to_path_buf();
    let decoy = root.path().join("decoy");
    fs::create_dir(&decoy).unwrap();
    let squatted = shared_tmp.join(format!("cmux-rd-{}", unsafe { libc::geteuid() }));
    symlink(&decoy, &squatted).unwrap();
    let state = root.path().join("state").join("sessions").join("session");

    let resolved = daemon_runtime_socket_paths_in(&state, None, &shared_tmp);
    assert!(resolved.is_ok(), "a squatted shared directory blocked the daemon: {resolved:?}");
    let (link, admin) = resolved.unwrap();
    let directory = link.parent().unwrap();
    assert_eq!(admin.parent().unwrap(), directory);
    assert_ne!(directory, squatted);
    assert!(directory.starts_with(&shared_tmp));
    assert!(unix_socket_path_fits(&link) && unix_socket_path_fits(&admin));
    let metadata = fs::symlink_metadata(directory).unwrap();
    assert!(metadata.is_dir());
    assert_eq!(metadata.uid(), unsafe { libc::geteuid() });
    assert_eq!(metadata.permissions().mode() & 0o777, 0o700);
    assert_eq!(daemon_runtime_socket_paths_in(&state, None, &shared_tmp).unwrap(), (link, admin));
    assert!(fs::read_dir(&decoy).unwrap().next().is_none());
}

/// Two processes for one session find the same unusable record. The
/// first to replace it publishes its own directory; the second, delayed
/// on its way to replace the record, must adopt that directory instead
/// of deleting the fresh record and publishing another one.
#[cfg(unix)]
#[test]
fn a_delayed_publisher_keeps_the_socket_directory_another_process_recorded() {
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::DirBuilderExt;
    use std::sync::mpsc;

    const PREFIX: &str = "cmux-t";
    fn validate(path: &Path) -> anyhow::Result<()> {
        if path.file_name() == Some(std::ffi::OsStr::new(PREFIX)) {
            return Err(anyhow!("the shared directory is squatted"));
        }
        if !path.is_dir() {
            return Err(anyhow!("{} is missing", path.display()));
        }
        Ok(())
    }

    let root = tempfile::tempdir().unwrap();
    let base = root.path().join("tmp");
    fs::create_dir(&base).unwrap();
    let state = root.path().join("state");
    fs::DirBuilder::new().mode(0o700).create(&state).unwrap();
    let record = state.join(SOCKET_DIRECTORY_RECORD);
    // The recorded directory was removed, for example by a reboot.
    fs::write(&record, base.join(format!("{PREFIX}-stale")).as_os_str().as_bytes()).unwrap();

    let (paused_sender, paused) = mpsc::channel();
    let (resume, resume_receiver) = mpsc::channel::<()>();
    let delayed = {
        let (base, record) = (base.clone(), record.clone());
        thread::spawn(move || {
            let mut pause = Some((paused_sender, resume_receiver));
            BEFORE_SOCKET_DIRECTORY_RECORD_REPLACE.with(|hook| {
                *hook.borrow_mut() = Some(Box::new(move || {
                    if let Some((paused, resume)) = pause.take() {
                        paused.send(()).unwrap();
                        resume.recv().unwrap();
                    }
                }));
            });
            private_socket_directory(&base, PREFIX, &record, validate)
        })
    };
    paused.recv_timeout(Duration::from_secs(30)).unwrap();
    let first = private_socket_directory(&base, PREFIX, &record, validate).unwrap();
    resume.send(()).unwrap();
    let second = delayed.join().unwrap().unwrap();

    assert_eq!(second, first, "two processes for one session use different socket directories");
    assert_eq!(fs::read(&record).unwrap(), first.as_os_str().as_bytes());
}

/// A stale record is replaced under an owner-only lock beside it, and a
/// lock another user could open stops the replacement.
#[cfg(unix)]
#[test]
fn a_stale_socket_directory_record_is_replaced_under_an_owner_only_lock() {
    use std::os::unix::ffi::OsStrExt;
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};

    fn validate(path: &Path) -> anyhow::Result<()> {
        if path.file_name() == Some(std::ffi::OsStr::new("cmux-t")) || !path.is_dir() {
            return Err(anyhow!("{} is unusable", path.display()));
        }
        Ok(())
    }

    let root = tempfile::tempdir().unwrap();
    let base = root.path().join("tmp");
    fs::create_dir(&base).unwrap();
    let state = root.path().join("state");
    fs::DirBuilder::new().mode(0o700).create(&state).unwrap();
    let record = state.join(SOCKET_DIRECTORY_RECORD);
    let lock = state.join(format!("{SOCKET_DIRECTORY_RECORD}.lock"));
    let stale = base.join("cmux-t-stale");
    fs::write(&record, stale.as_os_str().as_bytes()).unwrap();

    let directory = private_socket_directory(&base, "cmux-t", &record, validate).unwrap();
    assert_ne!(directory, stale);
    assert_eq!(fs::read(&record).unwrap(), directory.as_os_str().as_bytes());
    assert_eq!(fs::metadata(&lock).unwrap().permissions().mode() & 0o777, 0o600);

    fs::write(&record, stale.as_os_str().as_bytes()).unwrap();
    fs::set_permissions(&lock, fs::Permissions::from_mode(0o644)).unwrap();
    let error = private_socket_directory(&base, "cmux-t", &record, validate).unwrap_err();
    assert!(format!("{error:#}").contains("accessible by another user"), "{error:#}");
    assert_eq!(fs::read(&record).unwrap(), stale.as_os_str().as_bytes());
}
