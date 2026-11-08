//! A failed first connect is a recovery, not an exit (cmuxterm-hq#7766): a headless link
//! keeps its own socket up, says where it is, redials within its budget and at once on a
//! network change, and becomes ready without a restart once the daemon answers. A permanent
//! error still ends it.

use super::*;
use cmux_remote::admin::{AdminRequest, LinkStatus, call_admin, link_admin_socket};
use cmux_remote::network_watch::NetworkWatch;

/// Bounds a step that waits for an event; a passing run never waits this long.
const HANG_GUARD: Duration = Duration::from_secs(20);

/// Fails every connect with a retryable transport error until `up`, then dials the Unix
/// daemon at `unix_path`.
struct WhenUpProvider {
    calls: Arc<AtomicUsize>,
    up: Arc<AtomicBool>,
    unix_path: PathBuf,
    unix: UnixProvider,
}

#[async_trait]
impl TransportProvider for WhenUpProvider {
    fn name(&self) -> &'static str {
        "when-up"
    }

    fn schemes(&self) -> &'static [&'static str] {
        &["when-up"]
    }

    fn supported_client_auth(&self) -> SupportedClientAuthModes {
        SupportedClientAuthModes::DeviceOrCarrier
    }

    async fn connect(
        &self,
        mut request: ConnectRequest,
    ) -> Result<Arc<dyn LinkGroup>, ProviderError> {
        self.calls.fetch_add(1, Ordering::AcqRel);
        if !self.up.load(Ordering::Acquire) {
            return Err(ProviderError::Link(cmux_remote::link::LinkError::Transport(
                "nothing answers at the daemon yet".into(),
            )));
        }
        request.endpoint = unix_test_route(&self.unix_path);
        self.unix.connect(request).await
    }
}

struct Fixture {
    directory: tempfile::TempDir,
    calls: Arc<AtomicUsize>,
    up: Arc<AtomicBool>,
    options: ClientRuntimeOptions,
}

impl Fixture {
    fn unix_path(&self) -> PathBuf {
        self.directory.path().join("daemon.sock")
    }

    fn local_socket(&self) -> PathBuf {
        self.directory.path().join("client.sock")
    }

    async fn serve(&self) -> cmux_remote::daemon::UnixServer {
        let auth = AuthDatabase::load_or_create(
            self.directory.path().join("daemon"),
            "first-connect-recovery",
            true,
        )
        .unwrap();
        let (daemon, _clients) = RemoteDaemon::new(auth, SessionLimits::default());
        let server = serve_unix(daemon, &self.unix_path(), MAX_CARRIER_FRAME_BYTES).await.unwrap();
        self.up.store(true, Ordering::Release);
        server
    }
}

/// A link whose daemon is not there yet. Its startup timeout is far shorter than the wait for
/// the daemon, so a link that still ended its first connect at the startup timeout fails.
fn fixture(reconnect: ReconnectPolicy) -> Fixture {
    let directory = tempfile::tempdir().unwrap();
    let calls = Arc::new(AtomicUsize::new(0));
    let up = Arc::new(AtomicBool::new(false));
    let mut providers = cmux_remote::provider::ProviderRegistry::default();
    providers
        .register(Arc::new(WhenUpProvider {
            calls: calls.clone(),
            up: up.clone(),
            unix_path: directory.path().join("daemon.sock"),
            unix: UnixProvider::new(MAX_CARRIER_FRAME_BYTES),
        }))
        .unwrap();
    let providers = Arc::new(providers);
    let route = ResolvedRouteCandidate::resolve(
        Url::parse("when-up://daemon").unwrap(),
        BTreeMap::new(),
        &providers,
    )
    .unwrap();
    let mut options = reconnect_test_options(vec![route]);
    options.providers = providers;
    options.auth = ClientAuthMode::Carrier;
    options.reconnect = reconnect;
    options.startup_timeout = Duration::from_millis(300);
    options.state_dir = directory.path().join("client");
    options.local_socket = Some(directory.path().join("client.sock"));
    Fixture { directory, calls, up, options }
}

/// Redials fast, on a real clock, with a budget that never runs dry.
fn fast_policy() -> ReconnectPolicy {
    ReconnectPolicy {
        initial_delay: Duration::from_millis(10),
        maximum_delay: Duration::from_millis(100),
        attempt_timeout: Duration::from_secs(2),
        full_jitter: false,
        heartbeat_interval: None,
        redial_budget: cmux_remote::connection::RedialBudget {
            capacity: 1_000,
            refill_interval: Duration::from_millis(1),
        },
        ..ReconnectPolicy::default()
    }
}

async fn link_call(path: &Path, request: AdminRequest) -> LinkStatus {
    let response = call_admin(path, &request).await.unwrap();
    assert!(response.ok, "{:?}", response.error);
    serde_json::from_value(response.result.unwrap()).unwrap()
}

async fn wait_for_path(path: &Path) {
    tokio::time::timeout(HANG_GUARD, async {
        while !path.exists() {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap_or_else(|_| panic!("{} never appeared", path.display()));
}

/// The first connect fails while the daemon is not there; the link's socket says so (not
/// connected, with the reason) and a short await-ready answers `down` by its deadline. Past the
/// startup timeout the daemon appears, and the same process becomes ready: await-ready answers
/// `connected` and the runtime starts, with no restart.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_failed_first_connect_becomes_ready_once_the_daemon_appears() {
    let fixture = fixture(fast_policy());
    let options = fixture.options.clone();
    let started = thread::spawn(move || start_recovering_client_runtime(options, || true));
    let admin = link_admin_socket(&fixture.local_socket());
    wait_for_path(&admin).await;

    tokio::time::timeout(HANG_GUARD, async {
        while fixture.calls.load(Ordering::Acquire) < 2 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the first connect was not redialed");
    let status = link_call(&admin, AdminRequest::LinkState).await;
    assert!(matches!(status.state.as_str(), "connecting" | "disconnected"), "{status:?}");
    let status = link_call(&admin, AdminRequest::AwaitReady { within_ms: 200 }).await;
    assert_eq!(status.state, "down", "{status:?}");
    assert!(
        status.reason.as_deref().is_some_and(|reason| reason.contains("nothing answers")),
        "{status:?}"
    );

    // Well past the startup timeout: the link is still there, and still redialing.
    tokio::time::sleep(Duration::from_millis(600)).await;
    assert!(!started.is_finished(), "the link ended before its daemon appeared");
    let server = fixture.serve().await;
    let status = link_call(&admin, AdminRequest::AwaitReady { within_ms: 10_000 }).await;
    assert_eq!(status, LinkStatus { state: "connected".into(), reason: None });

    let runtime = tokio::task::spawn_blocking(move || started.join().unwrap())
        .await
        .unwrap()
        .expect("the link did not start once its daemon appeared");
    assert!(runtime.info().local_socket.exists());
    let status = link_call(&admin, AdminRequest::LinkState).await;
    assert_eq!(status, LinkStatus { state: "connected".into(), reason: None });
    tokio::task::spawn_blocking(move || runtime.shutdown()).await.unwrap().unwrap();
    server.shutdown().await.unwrap();
}

/// A first connect parked after its burst dials again as soon as the network changes, not
/// after its backoff (30 s here).
#[tokio::test]
async fn a_network_change_redials_a_parked_first_connect_at_once() {
    let mut fixture = fixture(ReconnectPolicy {
        initial_delay: Duration::from_secs(30),
        maximum_delay: Duration::from_secs(30),
        attempts_per_recovery: 1,
        ..fast_policy()
    });
    fixture.options.reconnect.maximum_attempts = None;
    let watch = NetworkWatch::manual();
    let (_shutdown_tx, shutdown_rx) = watch::channel(false);
    let options = fixture.options.clone();
    let network = watch.subscribe();
    let dial = tokio::spawn(async move {
        connect_first_available_watching(&options, shutdown_rx, network).await
    });

    tokio::time::timeout(HANG_GUARD, async {
        while fixture.calls.load(Ordering::Acquire) < 1 {
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .expect("the first connect never dialed");
    // Let the failed dial park.
    tokio::time::sleep(Duration::from_millis(100)).await;
    assert_eq!(fixture.calls.load(Ordering::Acquire), 1);

    let server = fixture.serve().await;
    let changed = std::time::Instant::now();
    watch.signal();
    let (connection, _) = tokio::time::timeout(HANG_GUARD, dial)
        .await
        .expect("the network change did not redial the parked first connect")
        .unwrap()
        .unwrap();
    let took = changed.elapsed();
    assert!(took < Duration::from_secs(5), "redialed {took:?} after the network change");
    assert_eq!(fixture.calls.load(Ordering::Acquire), 2);
    connection.close().await.unwrap();
    server.shutdown().await.unwrap();
}

/// A permanent error (the daemon's key is not the pinned one) still ends a recovering link at
/// once, with the reason, instead of redialing it.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_permanent_first_connect_error_still_ends_the_link() {
    let mut fixture = fixture(fast_policy());
    fixture.options.expected_daemon = Some([7; 32]);
    let server = fixture.serve().await;
    let options = fixture.options.clone();
    let result = tokio::time::timeout(
        HANG_GUARD,
        tokio::task::spawn_blocking(move || start_recovering_client_runtime(options, || true)),
    )
    .await
    .expect("a permanent error did not end the link")
    .unwrap();
    let error = match result {
        Ok(_) => panic!("a link with the wrong daemon key started"),
        Err(error) => error,
    };
    assert!(format!("{error:#}").to_lowercase().contains("key"), "{error:#}");
    assert_eq!(fixture.calls.load(Ordering::Acquire), 1, "a permanent error was redialed");
    server.shutdown().await.unwrap();
}

/// A recovering link whose owner is gone stops waiting for its first connect.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn a_recovering_link_ends_when_its_owner_goes() {
    let fixture = fixture(fast_policy());
    let owner = Arc::new(AtomicBool::new(true));
    let alive = owner.clone();
    let options = fixture.options.clone();
    let started = tokio::task::spawn_blocking(move || {
        start_recovering_client_runtime(options, move || alive.load(Ordering::Acquire))
    });
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(!started.is_finished(), "the link ended while its owner was there");
    owner.store(false, Ordering::Release);
    let result = tokio::time::timeout(HANG_GUARD, started)
        .await
        .expect("the link outlived its owner")
        .unwrap();
    assert!(result.is_err(), "the link started without a daemon");
}
