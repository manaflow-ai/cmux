//! R-DAEMON-STATE stage S1 (handoff/rewrites/R-DAEMON-STATE/DESIGN.md, section 2.6): the person's key takes no lock
//! that another terminal, another connection, a reader or a writer of the session takes.
//!
//! #31940 took the session lock (`Mux::state`) off the key. The key line still takes the client registry lock about
//! nine times: the daemon handoff checks, the remote-client and remote-device checks, the request's actor, the kept
//! terminal of the key and the reply's incognito filter. Every connect, disconnect, attach, detach and capability
//! change of every client holds that lock, and an agent storm connects and disconnects about 120 times a second.
//! Under the L6 storm the fixed build still showed a daemon key part of p99 20-24 ms and max 74-223 ms (STATUS 7761).
//!
//! The test drives a key line through the real connection path (the line handler, the connection's dispatcher, the
//! `send` handler) while another thread holds one lock for 300 ms. A key that waits for the lock reaches its PTY after
//! about 300 ms; a key that does not wait reaches it in well under a millisecond. Two keys go in a row: a lock taken
//! after the PTY write delays the second key, which waits on the connection's dispatcher behind the first.

// The test terminal's in-process PTY runtime is Unix-only (as for input_lane.rs).
#![cfg(unix)]

use super::*;
use base64::Engine;
use std::sync::mpsc;
use std::time::Instant;

/// How long the other thread holds the lock.
const HOLD: Duration = Duration::from_millis(300);
/// A key that took longer than this waited for the held lock: well above scheduling noise on a loaded fleet host,
/// well below `HOLD` (the budget of input_lane.rs).
const BUDGET: Duration = Duration::from_millis(150);

/// Records when each write reached the test terminal's PTY input.
struct TimedInput(mpsc::Sender<(Instant, Vec<u8>)>);

impl Write for TimedInput {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let _ = self.0.send((Instant::now(), bytes.to_vec()));
        Ok(bytes.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

/// One attached typing connection, as the app's terminal view makes it: its own client, its own dispatcher, a view
/// that joined the terminal's sizing.
struct TypingConnection {
    mux: Arc<Mux>,
    client: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
    surface: SurfaceId,
    input: mpsc::Receiver<(Instant, Vec<u8>)>,
}

impl TypingConnection {
    /// A typing connection with stage S1 on (the lane under test).
    fn open() -> Self {
        Self::open_with(true)
    }

    /// A typing connection with stage S1 `lane` on or off (off: the old path, a test's control).
    fn open_with(lane: bool) -> Self {
        let mux = test_mux();
        mux.set_input_lane_for_test(lane);
        let terminal = mux.new_workspace(Some("typing".into()), Some((80, 24))).unwrap();
        let (sent, input) = mpsc::channel();
        terminal.replace_input_writer_for_test(Box::new(TimedInput(sent)));
        let (writer, outbound) = captured_writer();
        let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        attach_test_view(&mux, client, terminal.id, &writer);
        // The view reports its size, as the app's view does: its grid is then decided and applied, so a key's sizing
        // note is skipped through the settled-grid check, not only while no view counts.
        mux.resize_surface_for_client(terminal.id, client, 100, 30).unwrap();
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        Self { mux, client, writer, outbound, scheduler, surface: terminal.id, input }
    }

    /// Hands one `send` line to the connection, as its reader thread does.
    fn submit(&self, id: &str, byte: u8) {
        let line = json!({
            "id": id,
            "cmd": "send",
            "surface": self.surface,
            "bytes": base64::engine::general_purpose::STANDARD.encode([byte]),
        })
        .to_string();
        assert!(
            handle_connection_frame(
                &self.mux,
                self.client,
                ClientTransport::Unix,
                &line,
                &self.writer,
                &self.scheduler,
            ),
            "the connection closed on a key line"
        );
    }

    /// When `byte` reached the PTY, or `None` after 5 s.
    fn arrival(&self, byte: u8) -> Option<Instant> {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let remaining = deadline.saturating_duration_since(Instant::now());
            let (at, bytes) = self.input.recv_timeout(remaining).ok()?;
            if bytes.contains(&byte) {
                return Some(at);
            }
        }
    }

    /// Waits for the replies to `ids` (each must be ok), so the connection's dispatcher is idle again.
    fn settle(&self, ids: &[&str]) {
        let deadline = Instant::now() + Duration::from_secs(5);
        let mut left: Vec<&str> = ids.to_vec();
        while !left.is_empty() && Instant::now() < deadline {
            match self.outbound.try_pop() {
                Some(line) => {
                    let value: Value = serde_json::from_str(&line).unwrap_or_default();
                    if let Some(id) = value["id"].as_str()
                        && value.get("ok").is_some()
                    {
                        assert_eq!(value["ok"], true, "key {id} failed: {value}");
                        left.retain(|pending| *pending != id);
                    }
                }
                None => std::thread::sleep(Duration::from_millis(1)),
            }
        }
        assert!(left.is_empty(), "no reply within 5 s to {left:?}");
    }

    fn close(self) {
        self.scheduler.finish_and_wait();
        disconnect_client(&self.mux, self.client, false);
        self.mux.shutdown();
    }
}

/// Holds one lock on another thread and runs `hold` while it holds it.
type Holder = fn(&Arc<Mux>, &dyn Fn());

fn hold_client_registry(mux: &Arc<Mux>, hold: &dyn Fn()) {
    let _held = mux.control_clients.state.lock().unwrap_or_else(|e| e.into_inner());
    hold();
}

fn hold_session(mux: &Arc<Mux>, hold: &dyn Fn()) {
    mux.with_state(|_| hold());
}

fn hold_surface_admission(mux: &Arc<Mux>, hold: &dyn Fn()) {
    mux.surface_operation_admission.hold_for_test(hold);
}

fn hold_workspace_registry(mux: &Arc<Mux>, hold: &dyn Fn()) {
    let _held = mux.workspace_registry.lock().unwrap_or_else(|e| e.into_inner());
    hold();
}

fn hold_link_peers(mux: &Arc<Mux>, hold: &dyn Fn()) {
    let _held = mux.remote_relay().peers.lock().unwrap_or_else(|e| e.into_inner());
    hold();
}

fn hold_proxy_authors(mux: &Arc<Mux>, hold: &dyn Fn()) {
    mux.control_clients.agent_sessions.hold_proxy_authors_for_test(hold);
}

fn hold_creating_inputs(mux: &Arc<Mux>, hold: &dyn Fn()) {
    mux.hold_creating_inputs_for_test(hold);
}

fn hold_client_sizing(mux: &Arc<Mux>, hold: &dyn Fn()) {
    mux.hold_client_sizing_for_test(hold);
}

fn hold_activity(mux: &Arc<Mux>, hold: &dyn Fn()) {
    mux.activity.hold_for_test(hold);
}

/// A terminal another creation names, still being created (`terminal-input-while-creating-v1`).
const CREATING_TERMINAL: &str = "000000000000000000000000c4ea7e01";
/// A terminal nobody creates: a reader asks about it under the creating-input lock.
const OTHER_TERMINAL: &str = "000000000000000000000000c4ea7e02";

/// While another terminal is being created, one thread holds the session lock and another asks about a terminal
/// under the creating-input lock. The old path looked up the live terminal under that lock, so the reader waited
/// for the session lock while it held the creating-input lock, and a key behind it waited too.
fn hold_session_behind_a_creating_input_reader(mux: &Arc<Mux>, hold: &dyn Fn()) {
    let generation =
        mux.begin_creating_input(CREATING_TERMINAL).expect("no live terminal has the id");
    let mut reader = None;
    mux.with_state(|_| {
        let asking = mux.clone();
        let asked = std::thread::spawn(move || asking.knows_terminal_input_target(OTHER_TERMINAL));
        // Until the reader holds the creating-input lock (the old path waits under it) or has its answer.
        let deadline = Instant::now() + Duration::from_secs(1);
        while !asked.is_finished()
            && !mux.creating_inputs_held_for_test()
            && Instant::now() < deadline
        {
            std::thread::yield_now();
        }
        reader = Some(asked);
        hold();
    });
    if let Some(reader) = reader {
        let _ = reader.join();
    }
    mux.finish_creating_input(CREATING_TERMINAL, generation, Some("test"));
}

/// How long two keys took to reach their PTY while another thread held one lock (the later key's arrival from the
/// first key's submit; `Duration::MAX` when a key never arrived), on a connection that `connection` is.
fn key_wait_while_held(connection: &TypingConnection, index: usize, holder: Holder) -> Duration {
    let first = b'a' + u8::try_from(index * 2).unwrap_or(0);
    let second = first + 1;
    let (held, holding) = mpsc::channel();
    let (release, released) = mpsc::channel::<()>();
    let mux = connection.mux.clone();
    let other = std::thread::spawn(move || {
        holder(&mux, &|| {
            let _ = held.send(());
            let _ = released.recv_timeout(HOLD);
        });
    });
    holding.recv().expect("the other thread took its lock");
    let started = Instant::now();
    let (first_id, second_id) = (format!("{index}-first"), format!("{index}-second"));
    connection.submit(&first_id, first);
    connection.submit(&second_id, second);
    let first_at = connection.arrival(first);
    let second_at = connection.arrival(second);
    let _ = release.send(());
    other.join().expect("the lock holder ended");
    connection.settle(&[first_id.as_str(), second_id.as_str()]);
    match (first_at, second_at) {
        (Some(first_at), Some(second_at)) => first_at.max(second_at) - started,
        _ => Duration::MAX,
    }
}

/// A connection whose first key took the long way already: every key after it must not wait.
fn warmed(connection: TypingConnection) -> TypingConnection {
    connection.submit("warm", b'w');
    assert!(connection.arrival(b'w').is_some(), "the first key never reached its terminal");
    connection.settle(&["warm"]);
    connection
}

/// Sends two keys while another thread holds each lock in turn, and fails when a key waited for one of them.
fn assert_keys_wait_for_none(locks: &[(&str, Holder)]) {
    let connection = warmed(TypingConnection::open());
    let mut waits = Vec::new();
    for (index, (name, holder)) in locks.iter().copied().enumerate() {
        let waited = key_wait_while_held(&connection, index, holder);
        eprintln!("SHARED-LOCKS key wait while {name} is held {HOLD:?}: {waited:?}");
        waits.push((name, waited));
    }
    connection.close();

    let blocked: Vec<String> = waits
        .iter()
        .filter(|(_, waited)| *waited >= BUDGET)
        .map(|(name, waited)| format!("{name}: {waited:?}"))
        .collect();
    assert!(
        blocked.is_empty(),
        "the person's keys waited for {} lock(s) another thread held (budget {BUDGET:?}, held {HOLD:?}): {}",
        blocked.len(),
        blocked.join("; ")
    );
}

/// The control of a lock test: on the old path (stage S1 off) the key does wait for the held lock, so the hold is
/// real and the lane's result is not a test that holds nothing.
fn assert_old_path_waits_for(name: &str, holder: Holder) {
    let connection = warmed(TypingConnection::open_with(false));
    let waited = key_wait_while_held(&connection, 0, holder);
    connection.close();
    eprintln!("SHARED-LOCKS control (lane off) key wait while {name} is held {HOLD:?}: {waited:?}");
    assert!(
        waited != Duration::MAX,
        "control: with stage S1 off a key never reached its terminal while {name} was held"
    );
    assert!(
        waited >= BUDGET,
        "control: with stage S1 off the key took {waited:?} while {name} was held {HOLD:?}; the hold does not reach \
         the old path, so the lane's test proves nothing"
    );
}

/// Stage S1 step 1: the key line reads the facts of the session's connections from the client registry's published
/// projection, never through its lock.
#[test]
fn a_key_waits_for_no_client_registry_lock() {
    assert_old_path_waits_for("client registry (ClientRegistry.state)", hold_client_registry);
    assert_keys_wait_for_none(&[(
        "client registry (ClientRegistry.state)",
        hold_client_registry as Holder,
    )]);
}

/// Stage S1 step 3: every request of every connection reserves its bytes from one daemon-wide budget; the reservation
/// is an atomic compare-and-swap, so a key never waits for another connection's request to reserve or release.
#[test]
fn a_key_waits_for_no_surface_admission_lock() {
    let name = "surface admission (ServerSurfaceOperationAdmission)";
    assert_old_path_waits_for(name, hold_surface_admission);
    assert_keys_wait_for_none(&[(name, hold_surface_admission as Holder)]);
}

/// Stage S1 step 2: the key line asks whether its connection has a link peer record (the remote-client check and the
/// request's actor) and whether it is a host proxy's link for a teammate. It reads both from published values, never
/// through the link peers lock (every remote bind, disconnect and revocation sweep holds it) or the proxy authors lock
/// (every proxy bind and every client's disconnect holds it).
#[test]
fn a_key_waits_for_neither_the_link_peers_nor_the_proxy_authors_lock() {
    let peers = "link peers (RemoteRelayState.peers)";
    let authors = "host proxy authors (AgentSessions.proxy_authors)";
    assert_old_path_waits_for(peers, hold_link_peers);
    assert_old_path_waits_for(authors, hold_proxy_authors);
    assert_keys_wait_for_none(&[
        (peers, hold_link_peers as Holder),
        (authors, hold_proxy_authors as Holder),
    ]);
}

/// Stage S1 step 4: a key asks whether creating input of its terminal must go first. With no terminal being created
/// it reads an atomic count and takes no lock; with one, the creating-input lock is a leaf: no holder waits under it
/// for the session lock (its live-terminal lookups read the published routes).
#[test]
fn a_key_waits_for_no_creating_input_lock() {
    let creating = "creating input (CreatingInputs.terminals)";
    let behind = "session (Mux.state) behind a creating-input reader";
    assert_old_path_waits_for(creating, hold_creating_inputs);
    assert_old_path_waits_for(behind, hold_session_behind_a_creating_input_reader);
    assert_keys_wait_for_none(&[
        (creating, hold_creating_inputs as Holder),
        (behind, hold_session_behind_a_creating_input_reader as Holder),
    ]);
}

/// Stage S1 step 5: after a key, the terminal's sizing notes activity (the newest view sets the grid under the
/// default policy) and the VM activity stream notes a person's input. When the key's view is already the newest and
/// the grid is settled, the note changes nothing, so the key reads that from the terminal with no lock; the input
/// time is an atomic. Every attach, detach, resize and size report of every terminal holds the sizing lock, and a
/// PTY resize runs under it.
#[test]
fn a_key_waits_for_neither_the_sizing_nor_the_activity_lock() {
    let sizing = "client sizing (Mux.client_sizing)";
    let activity = "VM activity stream (ActivityStream)";
    assert_old_path_waits_for(sizing, hold_client_sizing);
    assert_old_path_waits_for(activity, hold_activity);
    assert_keys_wait_for_none(&[
        (sizing, hold_client_sizing as Holder),
        (activity, hold_activity as Holder),
    ]);
}

/// A respawn under the same placement and runtime id builds a new terminal runtime: its keys must get the sizing
/// fast path back (the sizing entry outlives the respawn, and must follow it to the new runtime), so after one key
/// that takes the slow path, keys again wait for no sizing lock.
#[test]
fn after_a_respawn_keys_wait_for_no_sizing_lock_again() {
    let connection = warmed(TypingConnection::open());
    let removed = connection
        .mux
        .remove_surface_runtime_for_test(connection.surface)
        .expect("the placement had a runtime");
    let respawned =
        crate::Surface::spawn_for_test(connection.surface, SurfaceOptions::default(), Weak::new())
            .unwrap();
    let (sent, input) = mpsc::channel();
    respawned.replace_input_writer_for_test(Box::new(TimedInput(sent)));
    connection.mux.insert_surface_runtime_for_test(respawned);
    let connection = TypingConnection { input, ..connection };
    // One key on the slow path: it finds the sizing entry and, with the fix, points it at the new runtime.
    connection.submit("after-respawn", b'r');
    assert!(connection.arrival(b'r').is_some(), "the key after the respawn never arrived");
    connection.settle(&["after-respawn"]);
    // The old runtime's slot is cleared, so nothing publishes into a runtime that no view types into.
    assert!(
        !removed.skips_sizing_note(connection.client),
        "the replaced runtime still publishes the sizing fast path"
    );
    let waited = key_wait_while_held(&connection, 0, hold_client_sizing);
    eprintln!(
        "SHARED-LOCKS after a respawn, key wait while client sizing is held {HOLD:?}: {waited:?}"
    );
    drop(removed);
    connection.close();
    assert!(
        waited < BUDGET,
        "after a respawn the keys waited {waited:?} for the sizing lock held {HOLD:?}"
    );
}

/// #34261 review 2: a settled terminal's sizing entry looks its surface up only when it makes the entry, so a size
/// state read takes the session lock once with the switch off (the caller's own lookup), never again under the
/// sizing lock, and none with the switch on. Looked up on every access, it took the session lock under the sizing
/// lock in every attach, size report, claim and size-state read, so with the switch off (the default) a key's sizing
/// note waited for automation's session-lock holds behind them.
#[test]
fn a_settled_size_state_read_takes_the_session_lock_once_with_the_switch_off() {
    let mut counts = Vec::new();
    for (lane, expected) in [(false, 1), (true, 0)] {
        let connection = TypingConnection::open_with(lane);
        // The view's attach and its 100x30 report made the entry; this read settles nothing new.
        assert!(connection.mux.terminal_size_state(connection.surface).is_some());
        let before = crate::mux::state_locks_taken_on_this_thread();
        assert!(connection.mux.terminal_size_state(connection.surface).is_some());
        let taken = crate::mux::state_locks_taken_on_this_thread() - before;
        connection.close();
        counts.push((lane, taken, expected));
    }
    eprintln!(
        "SHARED-LOCKS session locks per settled size-state read (lane, taken, expected): {counts:?}"
    );
    for (lane, taken, expected) in counts {
        assert_eq!(
            taken, expected,
            "lane {lane}: one settled size-state read took the session lock {taken} times, not {expected}"
        );
    }
}

/// R-DAEMON-STATE S1.6b: on the lane the person's key (a connection attached to the terminal it types into) answers
/// when the input port took it; any other client's write (a script's `cmux send`, MCP) answers when the port wrote it,
/// with its error, as the old path answered.
#[test]
fn the_persons_keys_answer_when_taken_and_other_writes_when_written() {
    let connection = TypingConnection::open();
    let (_, reply) = cmd_terminal_io::input_surface(
        &connection.mux,
        connection.client,
        &connection.writer,
        connection.surface,
    )
    .unwrap();
    assert_eq!(reply, crate::surface::InputReply::Accepted, "the person's key waits for its write");
    let (script_writer, _script_outbound) = captured_writer();
    let script =
        connection.mux.control_clients.register(ClientTransport::Unix, script_writer.clone());
    let (_, reply) =
        cmd_terminal_io::input_surface(&connection.mux, script, &script_writer, connection.surface)
            .unwrap();
    assert_eq!(
        reply,
        crate::surface::InputReply::Written,
        "a script's write answers before it is written"
    );
    connection.close();
}

/// The next `activity-changed` event on `outbound` within `wait`.
fn next_activity_event(outbound: &BoundedOutbound, wait: Duration) -> Option<Value> {
    let deadline = Instant::now() + wait;
    while Instant::now() < deadline {
        match outbound.try_pop() {
            Some(line) => {
                let value: Value = serde_json::from_str(&line).unwrap_or_default();
                if value["event"] == "activity-changed" {
                    return Some(value);
                }
            }
            None => std::thread::sleep(Duration::from_millis(5)),
        }
    }
    None
}

/// #34261 review: a `subscribe-activity` subscriber hears the person's keys on both arms (the lock-free arm notes a
/// key's time in an atomic and wakes the worker only while a subscriber exists): a key typed before the subscription
/// is in its snapshot, a key after it comes as an event at once (the leading edge), and a key inside the one-second
/// spacing comes in the trailing event, with a time never older than the one before.
#[test]
fn an_activity_subscriber_hears_the_persons_keys_on_both_arms() {
    for lane in [false, true] {
        let connection = TypingConnection::open_with(lane);
        connection.submit("before", b'b');
        connection.settle(&["before"]);
        let (subscriber_writer, subscriber_outbound) = captured_writer();
        let subscriber = connection
            .mux
            .control_clients
            .register(ClientTransport::Unix, subscriber_writer.clone());
        let snapshot = handle_command(
            &connection.mux,
            subscriber,
            Command::SubscribeActivity,
            &subscriber_writer,
        )
        .unwrap();
        let before = snapshot["activity"]["last_user_input_at_ms"].as_u64().unwrap_or_else(|| {
            panic!("lane {lane}: the snapshot has no time for the key before it: {snapshot}")
        });
        // Events the subscription itself caused (an attach count) are not the key's.
        while subscriber_outbound.try_pop().is_some() {}

        connection.submit("first", b'1');
        connection.settle(&["first"]);
        let first = next_activity_event(&subscriber_outbound, Duration::from_secs(3))
            .unwrap_or_else(|| panic!("lane {lane}: no activity event after the first key"));
        let first_ms = first["activity"]["last_user_input_at_ms"].as_u64().unwrap_or(0);
        assert!(
            first_ms >= before,
            "lane {lane}: the first key's time went back: {first_ms} < {before}"
        );

        std::thread::sleep(Duration::from_millis(20));
        connection.submit("second", b'2');
        connection.settle(&["second"]);
        let second = next_activity_event(&subscriber_outbound, Duration::from_secs(3))
            .unwrap_or_else(|| {
                panic!("lane {lane}: no trailing activity event after the second key")
            });
        let second_ms = second["activity"]["last_user_input_at_ms"].as_u64().unwrap_or(0);
        assert!(
            second_ms > first_ms,
            "lane {lane}: the trailing event does not carry the second key's time: {second_ms} <= {first_ms}"
        );
        connection.close();
    }
}

/// One step of a sizing scenario for [`grid_trace`].
#[derive(Clone, Copy, Debug)]
enum SizingStep {
    /// The typing view (100x30) types a key.
    TypingKey,
    /// The other view (60x20) types a key.
    OtherKey,
    /// The other view's connection closes (a phone that leaves starts the departed-grid hold).
    OtherLeaves,
    /// The other client, a relay, forwards activity of its phone sub-view `mobile:p1` (54x26).
    RelayPhoneActivity,
}

/// The grid after each step, for a terminal with the typing view and one other view of `other` identity
/// (`set-client-info` fields) under the size policy `policy`, on the lane or the old path.
fn grid_trace(lane: bool, policy: &Value, other: &Value, steps: &[SizingStep]) -> Vec<(u16, u16)> {
    let connection = TypingConnection::open_with(lane);
    let mux = connection.mux.clone();
    let surface = connection.surface;
    let (other_writer, _other_outbound) = captured_writer();
    let other_client = mux.control_clients.register(ClientTransport::Unix, other_writer.clone());
    let mut info = other.clone();
    info["cmd"] = json!("set-client-info");
    handle_command(&mux, other_client, json_command(info), &other_writer).unwrap();
    attach_test_view(&mux, other_client, surface, &other_writer);
    mux.resize_surface_for_client(surface, other_client, 60, 20).unwrap();
    handle_command(
        &mux,
        connection.client,
        json_command(json!({"cmd": "set-size-policy", "surface": surface, "policy": policy})),
        &connection.writer,
    )
    .unwrap();
    let key = |client: u64, writer: &MessageWriter| {
        let send = json!({"cmd": "send", "surface": surface, "bytes": "eA=="});
        handle_command(&mux, client, json_command(send), writer).unwrap();
    };
    let grid = || mux.surface(surface).expect("the terminal").size();
    let mut trace = Vec::new();
    for step in steps {
        match step {
            SizingStep::TypingKey => key(connection.client, &connection.writer),
            SizingStep::OtherKey => key(other_client, &other_writer),
            SizingStep::OtherLeaves => {
                disconnect_client(&mux, other_client, false);
            }
            SizingStep::RelayPhoneActivity => {
                handle_command(
                    &mux,
                    other_client,
                    json_command(json!({
                        "cmd": "resize-attached-view", "surface": surface, "view": "mobile:p1",
                        "identity": {"user_id": "u1", "device_kind": "iphone"}, "cols": 54, "rows": 26,
                    })),
                    &other_writer,
                )
                .unwrap();
                handle_command(
                    &mux,
                    other_client,
                    json_command(json!({"cmd": "note-size-activity", "surface": surface, "view": "mobile:p1"})),
                    &other_writer,
                )
                .unwrap();
            }
        }
        trace.push(grid());
    }
    connection.close();
    trace
}

/// #34261 review: the key's sizing-note skip (stage S1.5) never changes a grid the old path would have set, for every
/// policy, with a desktop or a phone as the other view, while a departed phone holds the grid, and with a relay's
/// phone sub-view: the lane's grid after every step equals the old path's.
#[test]
fn the_sizing_note_skip_sets_the_grids_the_old_path_sets() {
    let mac = json!({"kind": "frontend", "device_kind": "mac"});
    let phone = json!({"kind": "ios", "device_kind": "iphone"});
    let relay = json!({
        "kind": "frontend", "device_kind": "mac", "user_id": "u1",
        "capabilities": [SHARED_SIZING_CAPABILITY, HOST_GRID_VIEW_CAPABILITY],
    });
    use SizingStep::{OtherKey, OtherLeaves, RelayPhoneActivity, TypingKey};
    let policies = [
        json!({"mode": "latest"}),
        json!({"mode": "smallest"}),
        json!({"mode": "largest"}),
        json!({"mode": "fixed", "fixed": {"cols": 90, "rows": 20}}),
    ];
    let mut cases: Vec<(String, Value, Value, Vec<SizingStep>)> = Vec::new();
    for policy in &policies {
        for (name, other) in [("mac", &mac), ("phone", &phone)] {
            cases.push((
                format!("{policy} with a {name}"),
                policy.clone(),
                other.clone(),
                vec![TypingKey, OtherKey, TypingKey, OtherKey, OtherLeaves, TypingKey, TypingKey],
            ));
        }
    }
    cases.push((
        "latest with a relay's phone sub-view".into(),
        json!({"mode": "latest"}),
        relay,
        vec![TypingKey, RelayPhoneActivity, TypingKey, RelayPhoneActivity, TypingKey],
    ));
    for (name, policy, other, steps) in cases {
        let old_path = grid_trace(false, &policy, &other, &steps);
        let lane = grid_trace(true, &policy, &other, &steps);
        assert_eq!(
            lane, old_path,
            "{name}: the lane's grids differ from the old path's after {steps:?}"
        );
    }
}

/// The skipped note must never keep the grid from a view: under the default policy (the newest view sets the grid),
/// another view's focus click takes the grid, and the next key from the first view takes it back, on both arms.
#[test]
fn after_another_views_click_a_key_takes_the_grid_back() {
    for lane in [false, true] {
        let first = TypingConnection::open_with(lane);
        let mux = first.mux.clone();
        let surface = first.surface;
        mux.pin_latest_size_policy_for_test(surface);
        let (second_writer, _second_outbound) = captured_writer();
        let second = mux.control_clients.register(ClientTransport::Unix, second_writer.clone());
        attach_test_view(&mux, second, surface, &second_writer);
        mux.resize_surface_for_client(surface, first.client, 100, 30).unwrap();
        mux.resize_surface_for_client(surface, second, 60, 20).unwrap();

        first.submit("first-key", b'a');
        assert!(first.arrival(b'a').is_some(), "lane {lane}: the first key never arrived");
        first.settle(&["first-key"]);
        let grid =
            |mux: &Mux| mux.terminal_size_state(surface).map(|state| (state.cols, state.rows));
        assert_eq!(grid(&mux), Some((100, 30)), "lane {lane}: the typing view sets the grid");

        assert_eq!(mux.note_terminal_activity(surface, second, None), Some(true), "lane {lane}");
        assert_eq!(grid(&mux), Some((60, 20)), "lane {lane}: the clicked view takes the grid");

        first.submit("second-key", b'b');
        assert!(first.arrival(b'b').is_some(), "lane {lane}: the second key never arrived");
        first.settle(&["second-key"]);
        assert_eq!(grid(&mux), Some((100, 30)), "lane {lane}: the key took the grid back");
        assert!(mux.activity.user_input_ms_for_test().is_some(), "lane {lane}: the input time");

        disconnect_client(&mux, second, false);
        first.close();
    }
}

/// #31940 and TYPING FIX 2 took these two off the key; this keeps them off on the stage's new path.
#[test]
fn a_key_waits_for_neither_the_session_nor_the_workspace_registry_lock() {
    assert_keys_wait_for_none(&[
        ("session (Mux.state)", hold_session as Holder),
        ("workspace registry (Mux.workspace_registry)", hold_workspace_registry as Holder),
    ]);
}

/// The published facts follow the routing: after a respawn under the same placement id, the next key reaches the new
/// shell, never the replaced one (the route rule of #31940, on the stage's path).
#[test]
fn after_a_respawn_the_next_key_reaches_the_new_terminal_on_the_input_lane() {
    let connection = TypingConnection::open();
    connection.submit("before", b'a');
    assert!(connection.arrival(b'a').is_some(), "the first key never reached its terminal");
    connection.settle(&["before"]);

    let removed = connection
        .mux
        .remove_surface_runtime_for_test(connection.surface)
        .expect("the placement had a runtime");
    let respawned =
        crate::Surface::spawn_for_test(connection.surface, SurfaceOptions::default(), Weak::new())
            .unwrap();
    let (sent, input) = mpsc::channel();
    respawned.replace_input_writer_for_test(Box::new(TimedInput(sent)));
    connection.mux.insert_surface_runtime_for_test(respawned);

    connection.submit("after", b'b');
    let reached = input
        .recv_timeout(Duration::from_secs(5))
        .ok()
        .is_some_and(|(_, bytes)| bytes.contains(&b'b'));
    connection.settle(&["after"]);
    assert!(reached, "the key after the respawn did not reach the new shell");
    assert!(
        connection.input.try_recv().is_err(),
        "the key after the respawn went to the replaced terminal"
    );
    drop(removed);
    connection.close();
}
