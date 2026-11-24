//! The last-known-good route goes first on the next launch, a stale memory costs at most one
//! attempt, and `--upgrade` keeps SSH first.

use super::*;

/// The default attempt budget: what a black-holed route costs before the next is tried.
fn default_attempt_budget() -> Duration {
    ReconnectPolicy::default().attempt_timeout
}

/// A daemon key for the memory's file.
const DAEMON: [u8; 32] = [7; 32];

/// Route `index` answers after `delays[index]`, with `ok[index]`; on paused time.
struct TimedAttempt {
    delays: Vec<Duration>,
    ok: Vec<bool>,
    dialed: Vec<usize>,
}

#[async_trait]
impl InitialRouteAttempt<usize> for TimedAttempt {
    async fn bootstrap_ssh(
        &mut self,
        _endpoint: &Url,
        _upgrade: bool,
    ) -> Result<(), InitialRouteAttemptError> {
        Ok(())
    }

    async fn connect(
        &mut self,
        index: usize,
        _request: ConnectRequest,
    ) -> Result<usize, InitialRouteAttemptError> {
        self.dialed.push(index);
        tokio::time::sleep(self.delays[index]).await;
        if self.ok[index] {
            Ok(index)
        } else {
            Err(InitialRouteAttemptError::Route {
                error: anyhow!("route {index} timed out"),
                retryable: true,
            })
        }
    }
}

/// One launch over `routes` with the memory in `state`: time to connected and the route.
async fn timed_launch(
    routes: &[ResolvedRouteCandidate],
    state: &Path,
    attempt: &mut TimedAttempt,
) -> (Duration, usize) {
    let memory = LastGoodRoute::open(Some(state), Some(DAEMON)).unwrap();
    let started = tokio::time::Instant::now();
    let selected = select_initial_route_from(
        routes,
        memory.first(routes, false),
        SessionId([21; 16]),
        LanePolicy::Single,
        AuthKind::Enrolled,
        false,
        attempt,
    )
    .await
    .unwrap();
    memory.connected(&routes[selected].endpoint);
    (started.elapsed(), selected)
}

/// The duress number: route 0 black-holed (it answers only when its whole attempt budget is
/// up), route 1 connects in 30 ms. Before, every launch waited out route 0; now the first does
/// and the repeat dials route 1 first. Virtual (paused) time.
#[tokio::test(start_paused = true)]
async fn a_black_holed_first_route_costs_only_the_first_launch() {
    let state = tempfile::tempdir().unwrap();
    let routes = vec![
        test_route("wss://stale-lan.example/v1/link"),
        test_route("wss://working.example/v1/link"),
    ];
    let budget = default_attempt_budget();
    let fresh = || TimedAttempt {
        delays: vec![budget, Duration::from_millis(30)],
        ok: vec![false, true],
        dialed: Vec::new(),
    };

    // Before: the candidates' own order on every launch (`select_initial_route`, the code
    // feat-cmux-next runs).
    let mut before = Vec::new();
    for _ in 0..2 {
        let mut attempt = fresh();
        let started = tokio::time::Instant::now();
        let selected = select_initial_route(
            &routes,
            SessionId([21; 16]),
            LanePolicy::Single,
            AuthKind::Enrolled,
            false,
            &mut attempt,
        )
        .await
        .unwrap();
        assert_eq!((selected, attempt.dialed.as_slice()), (1, [0, 1].as_slice()));
        before.push(started.elapsed());
    }

    let mut first = fresh();
    let (first_launch, selected) = timed_launch(&routes, state.path(), &mut first).await;
    assert_eq!(selected, 1);
    assert_eq!(first.dialed, [0, 1]);

    let mut repeat = fresh();
    let (repeat_launch, selected) = timed_launch(&routes, state.path(), &mut repeat).await;
    assert_eq!(selected, 1);
    assert_eq!(repeat.dialed, [1], "the remembered route was not dialed first");

    eprintln!(
        "route 0 black-holed, budget {budget:?}: before: first {:?}, repeat {:?}; \
         after: first {first_launch:?}, repeat {repeat_launch:?}",
        before[0], before[1]
    );
    assert_eq!(before, [budget + Duration::from_millis(30); 2]);
    assert_eq!(first_launch, budget + Duration::from_millis(30));
    assert_eq!(repeat_launch, Duration::from_millis(30));
}

/// A remembered route that fails is forgotten: the launch after it pays it once, falls back
/// in order, and the next launch remembers the route that connected instead.
#[tokio::test(start_paused = true)]
async fn a_remembered_route_that_fails_costs_one_attempt_and_is_forgotten() {
    let state = tempfile::tempdir().unwrap();
    let routes = vec![
        test_route("wss://a.example/v1/link"),
        test_route("wss://b.example/v1/link"),
        test_route("wss://c.example/v1/link"),
    ];
    let memory = LastGoodRoute::open(Some(state.path()), Some(DAEMON)).unwrap();
    memory.connected(&routes[2].endpoint);
    drop(memory);

    // Route 2 went dead; route 0 works.
    let budget = default_attempt_budget();
    let mut attempt = TimedAttempt {
        delays: vec![Duration::from_millis(10), Duration::from_millis(10), budget],
        ok: vec![true, true, false],
        dialed: Vec::new(),
    };
    let memory = LastGoodRoute::open(Some(state.path()), Some(DAEMON)).unwrap();
    assert_eq!(memory.first(&routes, false), Some(2));
    memory.failed(&routes[2].endpoint);
    assert_eq!(memory.first(&routes, false), None, "a failed memory is forgotten at once");
    assert_eq!(
        LastGoodRoute::open(Some(state.path()), Some(DAEMON)).unwrap().first(&routes, false),
        None,
        "and on disk"
    );
    let (_, selected) = timed_launch(&routes, state.path(), &mut attempt).await;
    assert_eq!(selected, 0);
    assert_eq!(attempt.dialed, [0]);
    assert_eq!(
        LastGoodRoute::open(Some(state.path()), Some(DAEMON)).unwrap().first(&routes, false),
        Some(0)
    );
}

#[test]
fn a_remembered_route_no_longer_a_candidate_or_stale_is_ignored() {
    let state = tempfile::tempdir().unwrap();
    let gone = test_route("wss://gone.example/v1/link");
    let routes = vec![test_route("wss://a.example/v1/link"), test_route("wss://b.example/v1/link")];
    LastGoodRoute::open(Some(state.path()), Some(DAEMON)).unwrap().connected(&gone.endpoint);
    let memory = LastGoodRoute::open(Some(state.path()), Some(DAEMON)).unwrap();
    assert_eq!(memory.first(&routes, false), None);

    // Another daemon's memory is its own.
    LastGoodRoute::open(Some(state.path()), Some([8; 32])).unwrap().connected(&routes[1].endpoint);
    assert_eq!(memory.first(&routes, false), None);
    assert_eq!(
        LastGoodRoute::open(Some(state.path()), Some([8; 32])).unwrap().first(&routes, false),
        Some(1)
    );

    // An entry older than the staleness bound reads as none.
    let path = state.path().join(route_last_good::FILE_NAME);
    let text = fs::read_to_string(&path).unwrap();
    let mut file: serde_json::Value = serde_json::from_str(&text).unwrap();
    for entry in file["daemons"].as_object_mut().unwrap().values_mut() {
        entry["at"] = serde_json::json!(1_000);
    }
    fs::write(&path, serde_json::to_vec(&file).unwrap()).unwrap();
    assert_eq!(
        LastGoodRoute::open(Some(state.path()), Some([8; 32])).unwrap().first(&routes, false),
        None
    );

    // No pinned daemon key: nothing is kept. Garbage reads as empty.
    assert!(LastGoodRoute::open(Some(state.path()), None).is_none());
    fs::write(&path, b"not json").unwrap();
    assert_eq!(
        LastGoodRoute::open(Some(state.path()), Some([8; 32])).unwrap().first(&routes, false),
        None
    );

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        LastGoodRoute::open(Some(state.path()), Some(DAEMON))
            .unwrap()
            .connected(&routes[0].endpoint);
        let mode = fs::metadata(&path).unwrap().permissions().mode();
        assert_eq!(mode & 0o777, 0o600);
    }
}

#[tokio::test]
async fn upgrade_keeps_ssh_first_over_a_remembered_route() {
    let state = tempfile::tempdir().unwrap();
    let routes =
        vec![test_route("ssh://upgrade.example"), test_route("wss://fallback.example/v1/link")];
    let memory = LastGoodRoute::open(Some(state.path()), Some(DAEMON)).unwrap();
    memory.connected(&routes[1].endpoint);
    assert_eq!(memory.first(&routes, false), Some(1));
    assert_eq!(memory.first(&routes, true), None, "--upgrade never reorders");

    // Even handed a first route, an upgrade dials SSH at 0 first.
    let mut attempt = FakeInitialRouteAttempt {
        fail_ssh_bootstrap: false,
        fail_provider_index: None,
        events: Vec::new(),
    };
    let selected = select_initial_route_from(
        &routes,
        Some(1),
        SessionId([22; 16]),
        LanePolicy::Single,
        AuthKind::Enrolled,
        true,
        &mut attempt,
    )
    .await
    .unwrap();
    assert_eq!(selected, "ssh://upgrade.example");
    assert_eq!(
        attempt.events.first(),
        Some(&FakeInitialRouteEvent::Bootstrap {
            endpoint: "ssh://upgrade.example".into(),
            upgrade: true
        })
    );
}

/// Every route failing still lists each route's failure, in the order dialed.
#[tokio::test(start_paused = true)]
async fn every_route_failing_still_lists_each_failure() {
    let routes = vec![test_route("wss://a.example/v1/link"), test_route("wss://b.example/v1/link")];
    let mut attempt = TimedAttempt {
        delays: vec![Duration::from_millis(1); 2],
        ok: vec![false, false],
        dialed: Vec::new(),
    };
    let error = select_initial_route_from(
        &routes,
        Some(1),
        SessionId([23; 16]),
        LanePolicy::Single,
        AuthKind::Enrolled,
        false,
        &mut attempt,
    )
    .await
    .unwrap_err();
    assert_eq!(attempt.dialed, [1, 0]);
    let text = error.to_string();
    assert!(text.contains("wss://b.example/: route 1 timed out"), "{text}");
    assert!(text.contains("wss://a.example/: route 0 timed out"), "{text}");
}

/// The runtime's own attempt over a real Unix daemon: the first launch waits out the stalled
/// route and remembers the Unix one; the repeat dials the Unix route first and never touches
/// the stalled provider.
#[tokio::test]
async fn the_runtime_attempt_remembers_the_route_that_connected() {
    let directory = tempfile::tempdir().unwrap();
    let daemon_auth =
        AuthDatabase::load_or_create(directory.path().join("daemon"), "last-good", true).unwrap();
    let (daemon, _clients) = RemoteDaemon::new(daemon_auth, SessionLimits::default());
    let unix_path = directory.path().join("daemon.sock");
    let server = serve_unix(daemon, &unix_path, MAX_CARRIER_FRAME_BYTES).await.unwrap();

    let calls = Arc::new(AtomicUsize::new(0));
    let mut providers = cmux_remote::provider::ProviderRegistry::default();
    providers.register(Arc::new(HangingStartupProvider { calls: calls.clone() })).unwrap();
    providers.register(Arc::new(UnixProvider::new(MAX_CARRIER_FRAME_BYTES))).unwrap();
    let providers = Arc::new(providers);
    let routes = [Url::parse("hanging-startup://daemon").unwrap(), unix_test_route(&unix_path)]
        .into_iter()
        .map(|route| ResolvedRouteCandidate::resolve(route, BTreeMap::new(), &providers).unwrap())
        .collect();
    let mut options = reconnect_test_options(routes);
    options.providers = providers;
    options.auth = ClientAuthMode::Carrier;
    options.reconnect.full_jitter = false;
    options.reconnect.attempt_timeout = Duration::from_millis(200);
    options.state_dir = directory.path().join("client");

    for launch in 0..2u8 {
        // Each launch is a new client process: a fresh session (the daemon refuses a closed
        // session's generation 0 again).
        options.session = SessionId([40 + launch; 16]);
        let memory = LastGoodRoute::open(Some(&options.state_dir), Some(DAEMON)).unwrap();
        let first = memory.first(&options.routes, false);
        assert_eq!(first, (launch == 1).then_some(1));
        let (_shutdown_tx, shutdown_rx) = watch::channel(false);
        let mut attempt = RuntimeInitialRouteAttempt {
            options: &options,
            shutdown: shutdown_rx,
            last_good: Some(&memory),
        };
        let (connection, selected) = tokio::time::timeout(
            Duration::from_secs(30),
            select_initial_route_from(
                &options.routes,
                first,
                options.session,
                options.lane_policy,
                client_auth_kind(&options.auth),
                false,
                &mut attempt,
            ),
        )
        .await
        .expect("selection hung")
        .expect("the Unix route did not connect");
        assert_eq!(selected, format!("unix://{}", unix_path.display()));
        connection.close().await.unwrap();
    }
    assert_eq!(calls.load(Ordering::Acquire), 1, "the repeat launch dialed the stalled route");
    server.shutdown().await.unwrap();
}
