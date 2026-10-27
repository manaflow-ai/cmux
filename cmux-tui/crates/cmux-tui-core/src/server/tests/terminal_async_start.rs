//! `terminal-async-start-v1` (p05-ipc-130): a `create-terminal` with
//! `async_start` replies once admitted and its start reports after the reply.

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

    fn create(&mut self, terminal_id: &str, mutation_id: &str, async_start: bool) -> u64 {
        let key = self.workspace_key();
        self.send(json!({
            "cmd": "create-terminal",
            "key": key,
            "cols": 80,
            "rows": 24,
            "terminal_id": terminal_id,
            "origin": "async-start-test",
            "mutation_id": mutation_id,
            "async_start": async_start,
        }))
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
}

const TERMINAL_A: &str = "00000000000040008000000000000a01";
const TERMINAL_B: &str = "00000000000040008000000000000b02";

/// Holds every create's start until released.
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
        mux.set_terminal_create_launch_hook_for_test(Some(Arc::new(move || {
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
    assert!(data["surface"].is_null(), "no placement before the start: {reply}");
    assert_eq!(data["key"], connection.workspace_key());
    assert!(connection.outbound.try_pop().is_none(), "nothing follows until the start ends");

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

/// Acceptance: with a 200 ms host delay, the reply p95 stays far below the
/// delay (the bench measures the < 2 ms target on the fleet) and every
/// `terminal-started` comes after its reply.
#[test]
fn terminal_async_start_reply_excludes_a_200_ms_host_delay() {
    const HOST_DELAY: Duration = Duration::from_millis(200);
    const CREATES: usize = 12;
    let mut connection = Connection::new(true);
    connection.mux.set_terminal_create_launch_hook_for_test(Some(Arc::new(|| {
        crate::request_path::sleep(HOST_DELAY);
    })));
    let mut replies = Vec::new();
    for index in 0..CREATES {
        let terminal_id = format!("000000000000400080000000000{index:05x}");
        let started_at = Instant::now();
        let id = connection.create(&terminal_id, &format!("delay-{index}"), true);
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
    assert!(p95 < HOST_DELAY / 4, "the reply waited for the start: p95 {p95:?}");
}

/// A start that fails reports `terminal-start-failed` with the create's
/// mutation id, creates nothing, and gives input sent meanwhile back.
#[test]
fn terminal_async_start_failure_rolls_back_by_mutation_id() {
    let mut connection = Connection::new(true);
    let gate = StartGate::install(&connection.mux);
    let key = connection.workspace_key();
    let id = connection.send(json!({
        "cmd": "create-terminal",
        "key": key,
        "cols": 80,
        "rows": 24,
        "terminal_id": TERMINAL_B,
        "origin": "async-start-test",
        "mutation_id": "async-fails",
        "expected_generation": "not-this-generation",
        "async_start": true,
    }));
    gate.wait_entered();
    let reply = connection.next();
    assert_eq!(reply["id"], id, "{reply}");
    assert_eq!(reply["data"]["starting"], true, "{reply}");

    let send = connection.send(json!({"cmd": "send", "terminal_id": TERMINAL_B, "text": "ls\r"}));
    let queued = connection.next();
    assert_eq!(queued["id"], send, "{queued}");
    assert_eq!(queued["data"]["queued"], true, "input waits for the start: {queued}");

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
    assert_eq!(failed["key"], key);
    assert!(failed["error"].as_str().unwrap().contains("generation conflict"), "{failed}");
    let unclaimed = unclaimed.unwrap();
    assert_eq!(unclaimed["terminal_id"], TERMINAL_B);
    assert_eq!(unclaimed["reason"], "failed");
    assert!(
        connection.mux.resolve_terminal(TERMINAL_B).unwrap().is_none(),
        "the failed start left no terminal"
    );
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
    let tabs = connection.mux.with_state(|state| {
        let pane = state.active_pane().unwrap();
        state.panes[&pane].tabs.clone()
    });
    let placed: Vec<u64> =
        started.iter().map(|s| s["result"]["surface"].as_u64().unwrap()).collect();
    assert_eq!(&tabs[tabs.len() - 2..], placed.as_slice(), "tabs land in request order");
}
