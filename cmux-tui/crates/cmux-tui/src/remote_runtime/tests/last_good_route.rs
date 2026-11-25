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
    /// Routes in the order they started.
    dialed: std::sync::Mutex<Vec<usize>>,
    /// Routes whose dial ran to its answer (a raced loser that was dropped never gets here).
    answered: std::sync::Mutex<Vec<usize>>,
}

impl TimedAttempt {
    fn new(delays: Vec<Duration>, ok: Vec<bool>) -> Self {
        Self { delays, ok, dialed: Default::default(), answered: Default::default() }
    }

    fn dialed(&self) -> Vec<usize> {
        self.dialed.lock().unwrap().clone()
    }

    fn answered(&self) -> Vec<usize> {
        self.answered.lock().unwrap().clone()
    }
}

#[async_trait]
impl InitialRouteAttempt<usize> for TimedAttempt {
    async fn bootstrap_ssh(
        &self,
        _endpoint: &Url,
        _upgrade: bool,
    ) -> Result<(), InitialRouteAttemptError> {
        Ok(())
    }

    async fn connect(
        &self,
        index: usize,
        _request: ConnectRequest,
    ) -> Result<usize, InitialRouteAttemptError> {
        self.dialed.lock().unwrap().push(index);
        tokio::time::sleep(self.delays[index]).await;
        self.answered.lock().unwrap().push(index);
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
    attempt: &TimedAttempt,
) -> (Duration, usize) {
    let memory = LastGoodRoute::open(Some(state), Some(DAEMON)).unwrap();
    let started = tokio::time::Instant::now();
    let selected = select_initial_route_from(
        routes,
        RouteOrder::serial(memory.first(routes, false)),
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
    let fresh = || TimedAttempt::new(vec![budget, Duration::from_millis(30)], vec![false, true]);

    // Before: the candidates' own order on every launch (`select_initial_route`, the code
    // feat-cmux-next runs).
    let mut before = Vec::new();
    for _ in 0..2 {
        let attempt = fresh();
        let started = tokio::time::Instant::now();
        let selected = select_initial_route(
            &routes,
            SessionId([21; 16]),
            LanePolicy::Single,
            AuthKind::Enrolled,
            false,
            &attempt,
        )
        .await
        .unwrap();
        assert_eq!((selected, attempt.dialed()), (1, vec![0, 1]));
        before.push(started.elapsed());
    }

    let first = fresh();
    let (first_launch, selected) = timed_launch(&routes, state.path(), &first).await;
    assert_eq!(selected, 1);
    assert_eq!(first.dialed(), [0, 1]);

    let repeat = fresh();
    let (repeat_launch, selected) = timed_launch(&routes, state.path(), &repeat).await;
    assert_eq!(selected, 1);
    assert_eq!(repeat.dialed(), [1], "the remembered route was not dialed first");

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
    let attempt = TimedAttempt::new(
        vec![Duration::from_millis(10), Duration::from_millis(10), budget],
        vec![true, true, false],
    );
    let memory = LastGoodRoute::open(Some(state.path()), Some(DAEMON)).unwrap();
    assert_eq!(memory.first(&routes, false), Some(2));
    memory.failed(&routes[2].endpoint);
    assert_eq!(memory.first(&routes, false), None, "a failed memory is forgotten at once");
    assert_eq!(
        LastGoodRoute::open(Some(state.path()), Some(DAEMON)).unwrap().first(&routes, false),
        None,
        "and on disk"
    );
    let (_, selected) = timed_launch(&routes, state.path(), &attempt).await;
    assert_eq!(selected, 0);
    assert_eq!(attempt.dialed(), [0]);
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
    let attempt = FakeInitialRouteAttempt {
        fail_ssh_bootstrap: false,
        fail_provider_index: None,
        events: Default::default(),
    };
    let selected = select_initial_route_from(
        &routes,
        RouteOrder::raced(Some(1), RouteRace::after(None)),
        SessionId([22; 16]),
        LanePolicy::Single,
        AuthKind::Enrolled,
        true,
        &attempt,
    )
    .await
    .unwrap();
    assert_eq!(selected, "ssh://upgrade.example");
    assert_eq!(
        attempt.events.lock().unwrap().first(),
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
    let attempt = TimedAttempt::new(vec![Duration::from_millis(1); 2], vec![false, false]);
    let error = select_initial_route_from(
        &routes,
        RouteOrder::serial(Some(1)),
        SessionId([23; 16]),
        LanePolicy::Single,
        AuthKind::Enrolled,
        false,
        &attempt,
    )
    .await
    .unwrap_err();
    assert_eq!(attempt.dialed(), [1, 0]);
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
        let attempt = RuntimeInitialRouteAttempt {
            options: &options,
            shutdown: shutdown_rx,
            last_good: Some(&memory),
        };
        let (connection, selected) = tokio::time::timeout(
            Duration::from_secs(30),
            select_initial_route_from(
                &options.routes,
                RouteOrder::serial(first),
                options.session,
                options.lane_policy,
                client_auth_kind(&options.auth),
                false,
                &attempt,
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

/// Raced over `routes` with `first` leading: time to connected and the route.
async fn raced_launch(
    routes: &[ResolvedRouteCandidate],
    first: Option<usize>,
    race: RouteRace,
    attempt: &TimedAttempt,
) -> Result<(Duration, usize), String> {
    let started = tokio::time::Instant::now();
    select_initial_route_from(
        routes,
        RouteOrder::raced(first, race),
        SessionId([24; 16]),
        LanePolicy::Single,
        AuthKind::Enrolled,
        false,
        attempt,
    )
    .await
    .map(|selected| (started.elapsed(), selected))
    .map_err(|error| error.to_string())
}

/// The duress number for the first launch, which the memory cannot help: route 0 black-holed
/// (it answers only when its whole budget is up), route 1 connects in 30 ms. Serial, the first
/// launch waits out route 0; raced, route 1 starts after the 250 ms stagger and wins, and
/// route 0's dial is dropped unanswered. Virtual (paused) time.
#[tokio::test(start_paused = true)]
async fn a_raced_first_launch_never_waits_out_a_black_holed_route() {
    let routes = vec![
        test_route("wss://stale-lan.example/v1/link"),
        test_route("wss://working.example/v1/link"),
    ];
    let budget = default_attempt_budget();
    let fresh = || TimedAttempt::new(vec![budget, Duration::from_millis(30)], vec![false, true]);

    let serial = fresh();
    let state = tempfile::tempdir().unwrap();
    let (before, selected) = timed_launch(&routes, state.path(), &serial).await;
    assert_eq!(selected, 1);

    let raced = fresh();
    let (after, selected) =
        raced_launch(&routes, None, RouteRace::after(None), &raced).await.unwrap();
    assert_eq!(selected, 1);
    assert_eq!(raced.dialed(), [0, 1]);
    assert_eq!(raced.answered(), [1], "the black-holed loser was not dropped");
    eprintln!(
        "route 0 black-holed, budget {budget:?}: first launch serial {before:?}, raced {after:?}"
    );
    assert_eq!(before, budget + Duration::from_millis(30));
    assert_eq!(after, RouteRace::FLOOR + Duration::from_millis(30));
    assert!(after <= Duration::from_secs(1));
}

/// The first route to connect wins even when it started later, and a route that connects
/// within the stagger never starts the next.
#[tokio::test(start_paused = true)]
async fn the_first_to_connect_wins_and_a_fast_route_races_nobody() {
    let routes = vec![
        test_route("wss://slow.example/v1/link"),
        test_route("wss://fast.example/v1/link"),
        test_route("wss://unused.example/v1/link"),
    ];
    let ms = Duration::from_millis;
    // Route 0 connects at 600 ms; route 1 starts at 250 ms and connects at 350 ms; route 2
    // starts at 500 ms and is dropped.
    let attempt = TimedAttempt::new(vec![ms(600), ms(100), ms(400)], vec![true; 3]);
    let (took, selected) =
        raced_launch(&routes, None, RouteRace::after(None), &attempt).await.unwrap();
    assert_eq!((took, selected), (ms(350), 1));
    assert_eq!(attempt.dialed(), [0, 1]);
    assert_eq!(attempt.answered(), [1]);

    let attempt = TimedAttempt::new(vec![ms(40), ms(1), ms(1)], vec![true; 3]);
    let (took, selected) =
        raced_launch(&routes, None, RouteRace::after(None), &attempt).await.unwrap();
    assert_eq!((took, selected), (ms(40), 0));
    assert_eq!(attempt.dialed(), [0], "a route that connected within the stagger raced");
}

/// A route that fails starts the next at once, not after the stagger.
#[tokio::test(start_paused = true)]
async fn a_failed_route_starts_the_next_at_once() {
    let routes = vec![
        test_route("wss://refused.example/v1/link"),
        test_route("wss://working.example/v1/link"),
    ];
    let ms = Duration::from_millis;
    let attempt = TimedAttempt::new(vec![ms(5), ms(30)], vec![false, true]);
    let (took, selected) =
        raced_launch(&routes, None, RouteRace::after(None), &attempt).await.unwrap();
    assert_eq!((took, selected), (ms(35), 1));
}

/// The stagger follows the leading route's remembered connect time: `max(250 ms, 1.5 ×)`, at
/// most 2 s; the memory keeps the time across launches.
#[tokio::test(start_paused = true)]
async fn the_stagger_follows_the_remembered_connect_time() {
    let ms = Duration::from_millis;
    assert_eq!(RouteRace::after(None).stagger, ms(250));
    assert_eq!(RouteRace::after(Some(ms(20))).stagger, ms(250));
    assert_eq!(RouteRace::after(Some(ms(400))).stagger, ms(600));
    assert_eq!(RouteRace::after(Some(ms(9_000))).stagger, Duration::from_secs(2));

    let state = tempfile::tempdir().unwrap();
    let routes = vec![test_route("wss://a.example/v1/link"), test_route("wss://b.example/v1/link")];
    let memory = LastGoodRoute::open(Some(state.path()), Some(DAEMON)).unwrap();
    memory.connected_in(&routes[1].endpoint, ms(400));
    let memory = LastGoodRoute::open(Some(state.path()), Some(DAEMON)).unwrap();
    assert_eq!(memory.first(&routes, false), Some(1));
    assert_eq!(memory.connect_time(), Some(ms(400)));
    // Within a quarter: kept as is. Further: rewritten.
    memory.connected_in(&routes[1].endpoint, ms(450));
    assert_eq!(memory.connect_time(), Some(ms(400)));
    memory.connected_in(&routes[1].endpoint, ms(100));
    assert_eq!(
        LastGoodRoute::open(Some(state.path()), Some(DAEMON)).unwrap().connect_time(),
        Some(ms(100))
    );

    // Leading route 1 remembered at 400 ms: route 0 starts beside it only at 600 ms.
    let attempt = TimedAttempt::new(vec![ms(10), ms(700)], vec![true, true]);
    let (took, selected) =
        raced_launch(&routes, Some(1), RouteRace::after(Some(ms(400))), &attempt).await.unwrap();
    assert_eq!((took, selected), (ms(610), 0));
    assert_eq!(attempt.dialed(), [1, 0]);
}

/// Every raced route failing lists each failure in dial order, whichever answered first.
#[tokio::test(start_paused = true)]
async fn a_raced_pass_that_fails_lists_failures_in_dial_order() {
    let routes = vec![test_route("wss://a.example/v1/link"), test_route("wss://b.example/v1/link")];
    let ms = Duration::from_millis;
    // Route 0 fails at 900 ms, route 1 (started at 250 ms) at 260 ms.
    let attempt = TimedAttempt::new(vec![ms(900), ms(10)], vec![false, false]);
    let text = raced_launch(&routes, None, RouteRace::after(None), &attempt).await.unwrap_err();
    let a = text.find("wss://a.example/: route 0 timed out").expect(&text);
    let b = text.find("wss://b.example/: route 1 timed out").expect(&text);
    assert!(a < b, "{text}");
}

/// Reconnect route `index` answers with a group after `delays[index]`, or fails.
struct TimedReconnect {
    delays: Vec<Duration>,
    ok: Vec<bool>,
    answered: std::sync::Mutex<Vec<usize>>,
}

#[async_trait]
impl ReconnectRouteAttempt<usize> for TimedReconnect {
    async fn connect(
        &self,
        index: usize,
        _request: ConnectRequest,
        _auth: AuthKind,
    ) -> Result<usize, ProviderError> {
        tokio::time::sleep(self.delays[index]).await;
        self.answered.lock().unwrap().push(index);
        if self.ok[index] {
            Ok(index)
        } else {
            Err(ProviderError::Transport(format!("route {index} timed out")))
        }
    }
}

/// An established link whose route failed: the reconnect pass starts one past it, at a
/// black-holed route. Serial, it waits that route's whole budget; raced, the next route starts
/// after the stagger and wins. Virtual (paused) time.
#[tokio::test(start_paused = true)]
async fn a_raced_reconnect_never_waits_out_a_black_holed_route() {
    let routes = vec![
        test_route("wss://failed.example/v1/link"),
        test_route("wss://black-holed.example/v1/link"),
        test_route("wss://working.example/v1/link"),
    ];
    let budget = default_attempt_budget();
    let ms = Duration::from_millis;
    let mut took = Vec::new();
    for race in [None, Some(RouteRace::after(None))] {
        let attempt = TimedReconnect {
            delays: vec![ms(1), budget, ms(30)],
            ok: vec![false, false, true],
            answered: Default::default(),
        };
        let started = tokio::time::Instant::now();
        let (index, group) = route_race::select_reconnect_routes(
            &routes,
            1,
            race,
            SessionId([25; 16]),
            LanePolicy::Single,
            AuthKind::Enrolled,
            &attempt,
        )
        .await
        .unwrap();
        assert_eq!((index, group), (2, 2));
        took.push(started.elapsed());
    }
    eprintln!("reconnect, route 1 black-holed: serial {:?}, raced {:?}", took[0], took[1]);
    assert_eq!(took, [budget + ms(30), RouteRace::FLOOR + ms(30)]);
}
