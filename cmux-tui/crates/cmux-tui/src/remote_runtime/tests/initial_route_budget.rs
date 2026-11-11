//! A stalled first route must not monopolize initial route selection.
//!
//! The runtime gives every route the same attempt budget. These tests give
//! the stalled route a short budget, so only the runtime's attempt timer can
//! move selection on, and give the real Unix route a hang guard, so its
//! connect and handshake never race that short timer. A shared 20 ms budget
//! made the Unix handshake miss it under full-suite load.

use super::*;

/// Bounds a step that waits for an event (a real handshake, a selection
/// result). A passing run never waits this long; the bound only turns a hang
/// into a loud failure.
const ROUTE_HANG_GUARD: Duration = Duration::from_secs(30);

/// The budget of the stalled route: the runtime's own attempt timer.
const STALLED_ROUTE_BUDGET: Duration = Duration::from_millis(20);

/// The runtime route attempt, with one attempt budget per route index.
struct PerRouteBudgetAttempt<'a> {
    attempts: Vec<RuntimeInitialRouteAttempt<'a>>,
}

#[async_trait]
impl InitialRouteAttempt<(Arc<ClientConnection>, String)> for PerRouteBudgetAttempt<'_> {
    async fn bootstrap_ssh(
        &mut self,
        endpoint: &Url,
        upgrade: bool,
    ) -> Result<(), InitialRouteAttemptError> {
        self.attempts[0].bootstrap_ssh(endpoint, upgrade).await
    }

    async fn connect(
        &mut self,
        index: usize,
        request: ConnectRequest,
    ) -> Result<(Arc<ClientConnection>, String), InitialRouteAttemptError> {
        self.attempts[index].connect(index, request).await
    }
}

/// Selects among `[stalled route, Unix route]` with the stalled route on
/// [`STALLED_ROUTE_BUDGET`] and the Unix route on [`ROUTE_HANG_GUARD`].
async fn select_stalled_then_unix(
    stalled_route: &str,
    providers: cmux_remote::provider::ProviderRegistry,
    unix_path: &Path,
) -> (Arc<ClientConnection>, String) {
    let providers = Arc::new(providers);
    let routes = [Url::parse(stalled_route).unwrap(), unix_test_route(unix_path)]
        .into_iter()
        .map(|route| ResolvedRouteCandidate::resolve(route, BTreeMap::new(), &providers).unwrap())
        .collect();
    let mut stalled = reconnect_test_options(routes);
    stalled.providers = providers;
    stalled.auth = ClientAuthMode::Carrier;
    stalled.reconnect.maximum_attempts = Some(1);
    stalled.reconnect.full_jitter = false;
    stalled.reconnect.attempt_timeout = STALLED_ROUTE_BUDGET;
    let mut unix = stalled.clone();
    unix.reconnect.attempt_timeout = ROUTE_HANG_GUARD;
    let (_shutdown_tx, shutdown_rx) = watch::channel(false);
    let mut attempt = PerRouteBudgetAttempt {
        attempts: vec![
            RuntimeInitialRouteAttempt { options: &stalled, shutdown: shutdown_rx.clone() },
            RuntimeInitialRouteAttempt { options: &unix, shutdown: shutdown_rx },
        ],
    };
    tokio::time::timeout(
        ROUTE_HANG_GUARD,
        select_initial_route(
            &stalled.routes,
            stalled.session,
            stalled.lane_policy,
            client_auth_kind(&stalled.auth),
            false,
            &mut attempt,
        ),
    )
    .await
    .expect("a stalled route monopolized initial route selection")
    .expect("the next initial route did not connect")
}

#[tokio::test]
async fn initial_provider_timeout_falls_back_to_next_route() {
    let directory = tempfile::tempdir().unwrap();
    let daemon_auth =
        AuthDatabase::load_or_create(directory.path().join("daemon"), "dial-timeout", true)
            .unwrap();
    let (daemon, _clients) = RemoteDaemon::new(daemon_auth, SessionLimits::default());
    let unix_path = directory.path().join("daemon.sock");
    let server = serve_unix(daemon, &unix_path, MAX_CARRIER_FRAME_BYTES).await.unwrap();

    let calls = Arc::new(AtomicUsize::new(0));
    let mut providers = cmux_remote::provider::ProviderRegistry::default();
    providers.register(Arc::new(HangingStartupProvider { calls: calls.clone() })).unwrap();
    providers.register(Arc::new(UnixProvider::new(MAX_CARRIER_FRAME_BYTES))).unwrap();

    let (connection, selected) =
        select_stalled_then_unix("hanging-startup://daemon", providers, &unix_path).await;

    assert_eq!(calls.load(Ordering::Acquire), 1);
    assert_eq!(selected, format!("unix://{}", unix_path.display()));
    connection.close().await.unwrap();
    server.shutdown().await.unwrap();
}

#[tokio::test]
async fn initial_link_timeout_closes_group_and_falls_back_to_next_route() {
    let directory = tempfile::tempdir().unwrap();
    let daemon_auth =
        AuthDatabase::load_or_create(directory.path().join("daemon"), "link-timeout", true)
            .unwrap();
    let (daemon, _clients) = RemoteDaemon::new(daemon_auth, SessionLimits::default());
    let unix_path = directory.path().join("daemon.sock");
    let server = serve_unix(daemon, &unix_path, MAX_CARRIER_FRAME_BYTES).await.unwrap();

    let close_calls = Arc::new(AtomicUsize::new(0));
    let mut providers = cmux_remote::provider::ProviderRegistry::default();
    providers.register(Arc::new(HangingOpenProvider { close_calls: close_calls.clone() })).unwrap();
    providers.register(Arc::new(UnixProvider::new(MAX_CARRIER_FRAME_BYTES))).unwrap();

    let (connection, selected) =
        select_stalled_then_unix("hanging-open://daemon", providers, &unix_path).await;

    assert_eq!(close_calls.load(Ordering::Acquire), 1);
    assert_eq!(selected, format!("unix://{}", unix_path.display()));
    connection.close().await.unwrap();
    server.shutdown().await.unwrap();
}
