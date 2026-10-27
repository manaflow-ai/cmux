//! `terminal-async-start-v1` (p05-ipc-130): a `create-terminal` with
//! `async_start` is admitted (replay, CAS, reservation) and replies before
//! its launch, and its start reports after the reply.

use super::*;
use crate::server::terminal_async_start::TERMINAL_ASYNC_START_CAPABILITY as ASYNC_START_CAPABILITY;

/// A connection of `mux` with the async start feature on or off.
struct Connection {
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
    next_id: u64,
}

impl Connection {
    fn new(async_start: bool) -> Self {
        let mux = test_mux();
        mux.set_terminal_async_start_for_test(async_start);
        mux.new_workspace(None, Some((80, 24))).unwrap();
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        Self { mux, client, writer, outbound, scheduler, next_id: 0 }
    }

    fn workspace_key(&self) -> String {
        self.mux.with_state(|state| state.workspaces[0].key.clone())
    }

    /// Send `request` with a fresh id and return the id.
    fn send(&mut self, mut request: Value) -> u64 {
        self.next_id += 1;
        request["id"] = json!(self.next_id);
        let line = request.to_string();
        assert!(handle_connection_message(
            &self.mux,
            self.client,
            &line,
            &self.writer,
            &self.scheduler
        ));
        self.next_id
    }

    fn create_request(&self, terminal_id: &str, mutation_id: &str, async_start: bool) -> Value {
        json!({
            "cmd": "create-terminal",
            "key": self.workspace_key(),
            "cols": 80,
            "rows": 24,
            "terminal_id": terminal_id,
            "origin": "async-start-test",
            "mutation_id": mutation_id,
            "async_start": async_start,
        })
    }

    fn create(&mut self, terminal_id: &str, mutation_id: &str, async_start: bool) -> u64 {
        let request = self.create_request(terminal_id, mutation_id, async_start);
        self.send(request)
    }

    /// The next message the connection got, without sleeping between polls
    /// so a reply's arrival time is exact.
    fn next(&self) -> Value {
        let deadline = Instant::now() + Duration::from_secs(10);
        loop {
            if let Some(message) = self.outbound.try_pop() {
                return serde_json::from_str(&message).expect("outbound JSON");
            }
            assert!(Instant::now() < deadline, "timed out waiting for the connection");
            std::thread::yield_now();
        }
    }

    /// Messages up to and including the reply to `id`.
    fn until_reply(&self, id: u64) -> Vec<Value> {
        let mut messages = Vec::new();
        loop {
            let message = self.next();
            let done = message["id"] == id;
            messages.push(message);
            if done {
                return messages;
            }
        }
    }

    /// Nothing reaches the connection for a while.
    fn assert_quiet(&self, what: &str) {
        let deadline = Instant::now() + Duration::from_millis(100);
        while Instant::now() < deadline {
            if let Some(message) = self.outbound.try_pop() {
                panic!("{what}: got {message}");
            }
            std::thread::yield_now();
        }
    }

    fn active_tabs(&self) -> Vec<SurfaceId> {
        self.mux.with_state(|state| {
            let pane = state.active_pane().unwrap();
            state.panes[&pane].tabs.clone()
        })
    }
}

const TERMINAL_A: &str = "00000000000040008000000000000a01";
const TERMINAL_B: &str = "00000000000040008000000000000b02";

/// Holds every admitted create's launch until released.
struct StartGate {
    entered: std::sync::mpsc::Receiver<()>,
    release: std::sync::mpsc::Sender<()>,
}

impl StartGate {
    fn install(mux: &Mux) -> Self {
        let (entered_tx, entered) = std::sync::mpsc::channel();
        let (release, release_rx) = std::sync::mpsc::channel::<()>();
        let entered_tx = Mutex::new(entered_tx);
        let release_rx = Mutex::new(release_rx);
        mux.set_terminal_start_hook_for_test(Some(Arc::new(move || {
            let _ = entered_tx.lock().unwrap().send(());
            let _ = release_rx.lock().unwrap().recv_timeout(Duration::from_secs(10));
        })));
        Self { entered, release }
    }

    fn wait_entered(&self) {
        self.entered.recv_timeout(Duration::from_secs(10)).expect("the start began");
    }

    fn release(&self) {
        self.release.send(()).unwrap();
    }
}

/// Red first: without the feature the reply waits for the start; with it the
/// reply comes while the start is still held, and `terminal-started` follows.
#[test]
fn terminal_async_start_replies_while_the_start_is_held_and_started_follows() {
    let mut connection = Connection::new(true);
    let gate = StartGate::install(&connection.mux);
    let id = connection.create(TERMINAL_A, "async-a", true);
    gate.wait_entered();

    let reply = connection.next();
    assert_eq!(reply["id"], id, "{reply}");
    assert_eq!(reply["ok"], true, "{reply}");
    let data = &reply["data"];
    assert_eq!(data["starting"], true, "{reply}");
    assert_eq!(data["terminal_id"], TERMINAL_A);
    assert_eq!(data["lifecycle"], "launching");
    assert_eq!(data["replayed"], false);
    assert!(data["surface"].is_null(), "no placement before the start: {reply}");
    assert_eq!(data["key"], connection.workspace_key());
    let reserved =
        connection.mux.workspace_registry.lock().unwrap().terminal_record(TERMINAL_A).unwrap();
    assert_eq!(
        reserved.map(|terminal| terminal.lifecycle),
        Some(TerminalLifecycle::Launching),
        "the reply follows the reservation"
    );
    connection.assert_quiet("nothing follows until the start ends");

    gate.release();
    let started = connection.next();
    assert_eq!(started["event"], "terminal-started", "{started}");
    assert_eq!(started["terminal_id"], TERMINAL_A);
    assert_eq!(started["mutation_id"], "async-a");
    let result = &started["result"];
    assert_eq!(result["terminal_id"], TERMINAL_A);
    assert_eq!(result["lifecycle"], "running", "{started}");
    assert!(result["surface"].is_u64(), "{started}");
    assert!(result["pane"].is_u64(), "{started}");
    assert_eq!(result["replayed"], false);
    assert!(result.get("starting").is_none(), "{started}");
    let surface = result["surface"].as_u64().unwrap();
    assert!(connection.mux.surface(surface).is_some(), "the started terminal is placed");
}

/// The feature off: the same request creates synchronously, as before.
#[test]
fn terminal_async_start_off_replies_after_the_start() {
    let mut connection = Connection::new(false);
    let id = connection.create(TERMINAL_A, "sync-a", true);
    let reply = connection.next();
    assert_eq!(reply["id"], id, "{reply}");
    assert_eq!(reply["ok"], true, "{reply}");
    assert!(reply["data"].get("starting").is_none(), "{reply}");
    assert!(reply["data"]["surface"].is_u64(), "{reply}");
    assert!(!identify_capabilities(&connection.mux).contains(&ASYNC_START_CAPABILITY));
}

/// The capability follows the feature.
#[test]
fn terminal_async_start_capability_follows_the_feature() {
    let connection = Connection::new(true);
    assert!(identify_capabilities(&connection.mux).contains(&ASYNC_START_CAPABILITY));
}

/// A create with no `mutation_id` of its own has nothing to roll back by:
/// it replies after its start, without `starting`.
#[test]
fn terminal_async_start_without_a_mutation_id_replies_after_the_start() {
    let mut connection = Connection::new(true);
    let gate = StartGate::install(&connection.mux);
    let key = connection.workspace_key();
    let id = connection.send(json!({
        "cmd": "create-terminal",
        "key": key,
        "cols": 80,
        "rows": 24,
        "terminal_id": TERMINAL_A,
        "async_start": true,
    }));
    let reply = connection.next();
    assert_eq!(reply["id"], id, "{reply}");
    assert!(reply["data"].get("starting").is_none(), "{reply}");
    assert!(gate.entered.try_recv().is_err(), "no start ran after the reply");
    connection.assert_quiet("no start event follows a synchronous create");
}

/// Acceptance: with a 200 ms host delay, the reply p95 is < 2 ms (measured
/// here on the test runtime, the bench measures it on the fleet) and every
/// `terminal-started` comes after its reply.
#[test]
fn terminal_async_start_reply_excludes_a_200_ms_host_delay() {
    const HOST_DELAY: Duration = Duration::from_millis(200);
    const REPLY_P95_BUDGET: Duration = Duration::from_millis(2);
    // Enough that p95 is not the max: one scheduling outlier on a busy
    // runner does not decide it.
    const CREATES: usize = 40;
    let mut connection = Connection::new(true);
    connection.mux.set_terminal_start_hook_for_test(Some(Arc::new(|| {
        crate::request_path::sleep(HOST_DELAY);
    })));
    let mut replies = Vec::new();
    for index in 0..CREATES {
        let terminal_id = format!("000000000000400080000000000{index:05x}");
        let request = connection.create_request(&terminal_id, &format!("delay-{index}"), true);
        let started_at = Instant::now();
        let id = connection.send(request);
        let reply = connection.next();
        replies.push(started_at.elapsed());
        assert_eq!(reply["id"], id, "the reply comes first: {reply}");
        assert_eq!(reply["data"]["starting"], true, "{reply}");
        let started = connection.next();
        assert_eq!(started["event"], "terminal-started", "{started}");
        assert_eq!(started["terminal_id"], terminal_id.as_str());
    }
    replies.sort();
    let p95 = replies[(replies.len() * 95).div_ceil(100) - 1];
    eprintln!(
        "terminal_async_start reply with a 200 ms host delay: p50 {:?} p95 {p95:?} max {:?}",
        replies[replies.len() / 2],
        replies[replies.len() - 1]
    );
    assert!(p95 < REPLY_P95_BUDGET, "reply p95 {p95:?} is over {REPLY_P95_BUDGET:?}");
}

/// A launch that fails after the reply reports `terminal-start-failed` with
/// the create's mutation id, places nothing, gives input sent meanwhile
/// back, and a retry of the mutation replays the failure.
#[test]
fn terminal_async_start_failure_rolls_back_by_mutation_id() {
    let mut connection = Connection::new(true);
    let gate = StartGate::install(&connection.mux);
    let tabs_before = connection.active_tabs();
    let id = connection.create(TERMINAL_B, "async-fails", true);
    gate.wait_entered();
    let reply = connection.next();
    assert_eq!(reply["id"], id, "{reply}");
    assert_eq!(reply["data"]["starting"], true, "{reply}");

    let send = connection.send(json!({"cmd": "send", "terminal_id": TERMINAL_B, "text": "ls\r"}));
    let queued = connection.next();
    assert_eq!(queued["id"], send, "{queued}");
    assert_eq!(queued["data"]["queued"], true, "input waits for the start: {queued}");

    connection.mux.fail_next_terminal_launch_for_test();
    gate.release();
    let mut failed = None;
    let mut unclaimed = None;
    while failed.is_none() || unclaimed.is_none() {
        let event = connection.next();
        match event["event"].as_str() {
            Some("terminal-start-failed") => failed = Some(event),
            Some("terminal-input-unclaimed") => unclaimed = Some(event),
            _ => panic!("unexpected message {event}"),
        }
    }
    let failed = failed.unwrap();
    assert_eq!(failed["terminal_id"], TERMINAL_B);
    assert_eq!(failed["mutation_id"], "async-fails");
    assert_eq!(failed["key"], connection.workspace_key());
    assert!(failed["error"].as_str().unwrap().contains("master resize"), "{failed}");
    let unclaimed = unclaimed.unwrap();
    assert_eq!(unclaimed["terminal_id"], TERMINAL_B);
    assert_eq!(unclaimed["reason"], "failed");
    assert_eq!(connection.active_tabs(), tabs_before, "the failed start placed no tab");
    let resolved = connection.mux.resolve_terminal(TERMINAL_B).unwrap();
    assert!(
        resolved.is_none_or(|resolution| resolution.surface.is_none()
            && resolution.terminal.lifecycle != TerminalLifecycle::Running),
        "the failed start left no running terminal"
    );

    let retry = connection.create(TERMINAL_B, "async-fails", true);
    let replayed = connection.next();
    assert_eq!(replayed["id"], retry, "{replayed}");
    assert!(replayed["data"].get("starting").is_none(), "a retry replays: {replayed}");
    assert_eq!(replayed["data"]["replayed"], true, "{replayed}");
    assert_eq!(replayed["data"]["lifecycle"], "exited", "{replayed}");
}

/// The CAS runs before the reply: a stale `expected_generation` is the
/// create's error reply, and no start runs.
#[test]
fn terminal_async_start_refuses_a_stale_generation_before_the_reply() {
    let mut connection = Connection::new(true);
    let gate = StartGate::install(&connection.mux);
    let mut request = connection.create_request(TERMINAL_B, "stale", true);
    request["expected_generation"] = json!("not-this-generation");
    let id = connection.send(request);
    let reply = connection.next();
    assert_eq!(reply["id"], id, "{reply}");
    assert_eq!(reply["ok"], false, "{reply}");
    assert!(reply.to_string().contains("generation conflict"), "{reply}");
    assert!(gate.entered.try_recv().is_err(), "no start ran");
    connection.assert_quiet("a refused create sends no start event");
}

/// A retry of a create that started replies with its placement, as a
/// synchronous retry does, and starts nothing.
#[test]
fn terminal_async_start_retry_of_a_started_create_replays_its_placement() {
    let mut connection = Connection::new(true);
    connection.create(TERMINAL_A, "retried", true);
    let _reply = connection.next();
    let started = connection.next();
    assert_eq!(started["event"], "terminal-started", "{started}");
    let retry = connection.create(TERMINAL_A, "retried", true);
    let replayed = connection.next();
    assert_eq!(replayed["id"], retry, "{replayed}");
    assert!(replayed["data"].get("starting").is_none(), "{replayed}");
    assert_eq!(replayed["data"]["replayed"], true, "{replayed}");
    assert_eq!(replayed["data"]["surface"], started["result"]["surface"], "{replayed}");
    connection.assert_quiet("a replay starts nothing");
}

/// Two starts of one connection run, and report, in request order.
#[test]
fn terminal_async_start_starts_of_one_connection_keep_request_order() {
    let mut connection = Connection::new(true);
    let gate = StartGate::install(&connection.mux);
    let first = connection.create(TERMINAL_A, "order-a", true);
    gate.wait_entered();
    let second = connection.create(TERMINAL_B, "order-b", true);
    let replies = [connection.next(), connection.next()];
    assert_eq!(replies[0]["id"], first);
    assert_eq!(replies[1]["id"], second);
    assert!(gate.entered.recv_timeout(Duration::from_millis(100)).is_err(), "one at a time");
    gate.release();
    gate.wait_entered();
    gate.release();
    let started = [connection.next(), connection.next()];
    assert_eq!(started[0]["terminal_id"], TERMINAL_A, "{started:?}");
    assert_eq!(started[1]["terminal_id"], TERMINAL_B, "{started:?}");
    let tabs = connection.active_tabs();
    let placed: Vec<u64> =
        started.iter().map(|s| s["result"]["surface"].as_u64().unwrap()).collect();
    assert_eq!(&tabs[tabs.len() - 2..], placed.as_slice(), "tabs land in request order");
}

/// A synchronous create sent while an earlier async start is held commits
/// after that start: its tab lands after the async terminal's tab.
#[test]
fn terminal_async_start_a_later_sync_create_lands_after_the_held_start() {
    let mut connection = Connection::new(true);
    let gate = StartGate::install(&connection.mux);
    let first = connection.create(TERMINAL_A, "held", true);
    gate.wait_entered();
    let reply = connection.next();
    assert_eq!(reply["id"], first, "{reply}");
    let second = connection.create(TERMINAL_B, "sync-after", false);
    connection.assert_quiet("the synchronous create waits for the held start");
    gate.release();
    let started = connection.next();
    assert_eq!(started["event"], "terminal-started", "{started}");
    let sync_reply = connection.next();
    assert_eq!(sync_reply["id"], second, "{sync_reply}");
    assert!(sync_reply["data"].get("starting").is_none(), "{sync_reply}");
    let tabs = connection.active_tabs();
    let placed = [
        started["result"]["surface"].as_u64().unwrap(),
        sync_reply["data"]["surface"].as_u64().unwrap(),
    ];
    assert_eq!(&tabs[tabs.len() - 2..], placed.as_slice(), "tabs land in request order");
}

/// An `attach-surface` that names a starting terminal by the host id its
/// create replied with waits for the start, then attaches: its replay and
/// reply follow `terminal-started`.
#[test]
fn terminal_async_start_attach_of_a_starting_terminal_waits_for_the_start() {
    let mut connection = Connection::new(true);
    let gate = StartGate::install(&connection.mux);
    let create = connection.create(TERMINAL_A, "attach-a", true);
    gate.wait_entered();
    let reply = connection.next();
    assert_eq!(reply["id"], create, "{reply}");
    let attach = connection.send(json!({
        "cmd": "attach-surface",
        "expected_generation": reply["data"]["generation"],
        "expected_terminal_id": TERMINAL_A,
    }));
    connection.assert_quiet("the attach waits for the start");
    gate.release();
    let messages = connection.until_reply(attach);
    assert_eq!(messages[0]["event"], "terminal-started", "{messages:?}");
    let surface = messages[0]["result"]["surface"].clone();
    let attached = messages.last().unwrap();
    assert_eq!(attached["ok"], true, "{attached}");
    assert!(
        messages[1..]
            .iter()
            .any(|message| message["event"] == "vt-state" && message["surface"] == surface),
        "the attach replays the started terminal: {messages:?}"
    );
}
