//! A terminal's connection that starts a stream, a wait or a follow leaves
//! the terminals' short lane for a long place (`server/message_writer/long_connection.rs`).

use super::*;
use crate::diagnostics::ConnectionStats;
use crate::diagnostics::LongConnectionsFull;

const LANE: u64 = MAX_TERMINAL_CONNECTIONS as u64;
const LONG: u64 = message_writer::long_connection::MAX_LONG_TERMINAL_CONNECTIONS;

/// A writer bound to `permit`, as `line_connection` binds a connection's.
fn writer_of(permit: &ConnectionPermit) -> (MessageWriter, Arc<BoundedOutbound>) {
    let (writer, outbound) = captured_writer();
    writer.long.attach(permit);
    (writer, outbound)
}

fn start_stream(writer: &MessageWriter) -> std::io::Result<OutboundStream> {
    writer.start_stream(&json!({"event": "overflow"}))
}

/// `(short connections, long connections)`.
fn held(connections: &ConnectionStats) -> (u64, u64) {
    (connections.active(), connections.long_active())
}

/// Fills the long lane: each connection from its own terminal, each with a
/// stream.
fn fill_long_lane(connections: &Arc<ConnectionStats>) -> Vec<ConnectionPermit> {
    (1000u32..)
        .zip(0..LONG)
        .map(|(terminal, _)| {
            let permit = claim_terminal_connection_from(connections, terminal)
                .expect("a short slot, free again after each stream");
            start_stream(&writer_of(&permit).0).expect("a long place below the bound");
            permit
        })
        .collect()
}

/// 48 terminals that each read the session's events held the 48 places of the
/// terminal lane, and every hook and typed command of every other terminal
/// was refused until one of them closed. A connection with a stream now holds
/// a long place, and the short lane and the app's slots are free.
#[test]
fn terminal_connections_with_a_stream_leave_the_short_lane() {
    let connections = Arc::new(ConnectionStats::default());
    let holders: Vec<ConnectionPermit> = (0u32..)
        .zip(0..LANE)
        .map(|(terminal, _)| {
            claim_terminal_connection_from(&connections, terminal).expect("a short slot")
        })
        .collect();
    assert!(
        claim_terminal_connection_from(&connections, 9000).is_none(),
        "the lane is full while each holder is a short connection"
    );
    let writers: Vec<MessageWriter> = holders.iter().map(|holder| writer_of(holder).0).collect();
    for writer in &writers {
        start_stream(writer).expect("a long place");
    }
    assert_eq!(held(&connections), (0, LANE));
    assert!(holders.iter().all(|holder| holder.lease().is_long()));

    // A second stream on a long connection takes no second place.
    start_stream(&writers[0]).expect("the connection is long already");
    assert_eq!(held(&connections), (0, LANE));

    let short: Vec<ConnectionPermit> = (9000u32..)
        .zip(0..LANE)
        .map(|(terminal, _)| {
            claim_terminal_connection_from(&connections, terminal)
                .expect("the whole short lane is free for hooks and commands")
        })
        .collect();
    let app: Vec<ConnectionPermit> = (MAX_TERMINAL_CONNECTIONS..MAX_SERVER_CONNECTIONS)
        .map(|_| claim_connection(&connections).expect("the app's slots are free"))
        .collect();
    assert!(claim_connection(&connections).is_none(), "the limit of short connections holds");
    assert_eq!(held(&connections), (MAX_SERVER_CONNECTIONS as u64, LANE));

    drop(holders);
    assert_eq!(held(&connections), (MAX_SERVER_CONNECTIONS as u64, 0));
    drop((short, app));
    assert_eq!(held(&connections), (0, 0));
}

/// Above the bound no stream starts. The error names the limit and what a
/// person can do, and the connection is still a short one that holds its
/// slots; when a long connection ends, its place serves the next stream.
#[test]
fn at_the_bound_no_stream_starts_and_the_connection_stays_short() {
    let connections = Arc::new(ConnectionStats::default());
    let mut long = fill_long_lane(&connections);
    assert_eq!(held(&connections), (0, LONG));

    let permit = claim_terminal_connection_from(&connections, 1).expect("the short lane is free");
    let (writer, _outbound) = writer_of(&permit);
    let Err(error) = start_stream(&writer) else { panic!("a stream started above the bound") };
    let full = error
        .get_ref()
        .and_then(|inner| inner.downcast_ref::<LongConnectionsFull>())
        .expect("the error of the bound");
    assert_eq!(full.limit, LONG);
    let text = error.to_string();
    assert!(text.contains("limit 256"), "{text}");
    assert!(text.contains("end a `cmux` wait"), "{text}");
    let typed = message_writer::long_connection::stream_start_error("session.events", &error);
    assert_eq!(typed.code, "operation.failed");
    assert!(!typed.retryable, "a client does not try again by itself");
    assert_eq!(typed.details["operation"], "session.events");
    assert_eq!(
        typed.details["extra"],
        json!({"reason_code":"long_connection_capacity","scope":"server","limit":256})
    );
    assert!(!permit.lease().is_long());
    assert_eq!(held(&connections), (1, LONG));

    long.pop();
    start_stream(&writer).expect("the place of a long connection that ended");
    assert!(permit.lease().is_long());
    assert_eq!(held(&connections), (0, LONG));
    drop((long, permit));
    assert_eq!(held(&connections), (0, 0));
}

/// The share rule of the short lane holds in the long one: one terminal that
/// opens streams in a loop stops at half, and another terminal's first long
/// connection still finds room.
#[test]
fn one_terminal_cannot_take_the_long_lane_from_the_others() {
    let connections = Arc::new(ConnectionStats::default());
    let mut first = Vec::new();
    while first.len() as u64 <= LONG {
        let permit = claim_terminal_connection_from(&connections, 101)
            .expect("its short slot is free again after each stream");
        if start_stream(&writer_of(&permit).0).is_err() {
            break;
        }
        first.push(permit);
    }
    assert_eq!(first.len() as u64, LONG / 2, "terminal 101 stops at half of the long lane");
    assert_eq!(held(&connections), (0, LONG / 2));
    let second = claim_terminal_connection_from(&connections, 102).expect("a short slot");
    start_stream(&writer_of(&second).0).expect("another terminal's first long connection");
    assert_eq!(held(&connections), (0, LONG / 2 + 1));
}

/// A connection from outside the terminals (the app, a relay, a remote link)
/// is in neither lane: a stream on it changes no count, also when the long
/// lane is full.
#[test]
fn an_outside_connection_with_a_stream_keeps_its_slot_and_its_counts() {
    let connections = Arc::new(ConnectionStats::default());
    let _long = fill_long_lane(&connections);
    let app = claim_connection(&connections).expect("the app's slot");
    let (writer, _outbound) = writer_of(&app);
    let counts = || {
        let snapshot = connections.snapshot(MAX_SERVER_CONNECTIONS as u64);
        (
            snapshot.active,
            snapshot.peak,
            snapshot.accepted,
            snapshot.refused,
            snapshot.hung_up,
            snapshot.reclaimed,
            connections.long_active(),
        )
    };
    let before = counts();
    assert_eq!((before.0, before.6), (1, LONG));
    start_stream(&writer).expect("an outside connection is not in the long lane");
    assert_eq!(counts(), before);
    assert!(!app.lease().is_long());
    drop(app);
    assert_eq!(held(&connections), (0, LONG));

    // A writer with no slot at all (an in-process client) starts its stream.
    start_stream(&test_writer()).expect("no gate without a slot");
    assert_eq!(held(&connections), (0, LONG));
}

/// A long connection whose client hung up has no short slot to give back: the
/// accept loop does not take it back, and it keeps its long place until its
/// thread ends. A short connection whose client hung up is taken back as
/// before, and a stream on it changes nothing.
#[cfg(unix)]
#[test]
fn a_hung_up_connection_and_a_long_one_do_not_trade_places() {
    use std::os::unix::net::UnixStream;
    let connections = Arc::new(ConnectionStats::default());
    let mut clients = Vec::new();
    let parked: Vec<ConnectionPermit> = (0..MAX_TERMINAL_CONNECTIONS)
        .map(|_| {
            let (daemon_side, client) = UnixStream::pair().unwrap();
            clients.push(client);
            claim_watched_terminal_connection(&connections, &daemon_side, None)
                .expect("terminal slot below its share")
        })
        .collect();
    start_stream(&writer_of(&parked[0]).0).expect("a long place");
    assert_eq!(held(&connections), (LANE - 1, 1));

    // The client of the long connection and the client of one short
    // connection hang up.
    clients.remove(0);
    clients.remove(0);
    let (first_daemon_side, _first_client) = UnixStream::pair().unwrap();
    let (second_daemon_side, _second_client) = UnixStream::pair().unwrap();
    let (third_daemon_side, _third_client) = UnixStream::pair().unwrap();
    let first = claim_watched_terminal_connection(&connections, &first_daemon_side, None)
        .expect("the short slot the long connection gave back");
    let second = claim_watched_terminal_connection(&connections, &second_daemon_side, None)
        .expect("the slot of the short connection whose client hung up");
    assert!(
        claim_watched_terminal_connection(&connections, &third_daemon_side, None).is_none(),
        "the long connection has no slot to take back"
    );
    let snapshot = connections.snapshot(MAX_SERVER_CONNECTIONS as u64);
    assert_eq!((snapshot.hung_up, snapshot.reclaimed, snapshot.refused), (1, 1, 1));
    assert_eq!(held(&connections), (LANE, 1));
    assert!(parked[0].lease().is_long() && !parked[0].lease().is_hung_up());
    assert!(parked[1].lease().is_hung_up() && !parked[1].lease().is_long());

    start_stream(&writer_of(&parked[1]).0).expect("no gate for a connection with no slot");
    assert!(parked[1].lease().is_hung_up());
    assert_eq!(held(&connections), (LANE, 1));

    drop((parked, first, second));
    let snapshot = connections.snapshot(MAX_SERVER_CONNECTIONS as u64);
    assert_eq!((snapshot.active, snapshot.hung_up, connections.long_active()), (0, 0, 0));
}

/// At the bound a detached wait and an event stream get the typed error, the
/// connection still serves its next request, and the same stream starts when
/// a long connection ends.
#[test]
fn at_the_bound_a_wait_and_an_event_stream_get_an_error_and_the_connection_goes_on() {
    let mux = test_mux();
    let connections = mux.connection_stats().clone();
    let permit = claim_terminal_connection_from(&connections, 1).expect("a short slot");
    let (writer, outbound) = writer_of(&permit);
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    let scheduler =
        Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
    let send = |id: &str, operation: &str, params: Value, idempotency_key: Option<&str>| {
        let request = resource_request(id, operation, params, idempotency_key);
        assert!(handle_connection_message(&mux, client, &request, &writer, &scheduler));
        let response = pop_json(&outbound);
        assert_eq!(response["id"], id, "{response}");
        response
    };
    let created = send(
        "create",
        "workspace.create",
        json!({"machine":"current","session":"current","initial_content":"terminal"}),
        Some("create-for-the-long-bound"),
    );
    let terminal_id = created["result"]["value"]["terminal_id"].clone();
    assert!(terminal_id.is_string(), "{created}");
    let wait = json!({
        "machine":"current",
        "session":"current",
        "terminal":terminal_id,
        "pattern":"cmux-pattern-that-never-matches",
        "timeout_ms":"60000",
    });
    let events = json!({
        "machine":"current",
        "session":"current",
        "stream_id":"stream_00000000000000000000000000000001",
    });

    let mut long = fill_long_lane(&connections);
    for (id, operation, params) in [
        ("wait-at-the-bound", "terminal.wait", wait.clone()),
        (
            "exit-at-the-bound",
            "terminal.wait_exit",
            json!({
                "machine":"current",
                "session":"current",
                "terminal":terminal_id,
            }),
        ),
        ("events-at-the-bound", "session.events", events.clone()),
    ] {
        let refused = send(id, operation, params, None);
        let error = &refused["error"];
        assert_eq!(refused["ok"], false, "{refused}");
        assert_eq!(error["code"], "operation.failed", "{refused}");
        assert_eq!(error["retryable"], false, "{refused}");
        assert_eq!(error["details"]["operation"], operation, "{refused}");
        assert_eq!(error["details"]["extra"]["reason_code"], "long_connection_capacity");
        assert_eq!(error["details"]["extra"]["limit"], LONG);
        assert!(error["message"].as_str().is_some_and(|text| text.contains("limit 256")));
    }
    // The legacy `wait-for` with a timeout is a wait of the same kind.
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let legacy_wait = json!({
        "id":"legacy-wait-at-the-bound",
        "cmd":"wait-for",
        "surface":surface.id,
        "pattern":"cmux-pattern-that-never-matches",
        "timeout_ms":60_000,
    })
    .to_string();
    assert!(handle_connection_message(&mux, client, &legacy_wait, &writer, &scheduler));
    let refused = pop_json(&outbound);
    assert_eq!(refused["id"], "legacy-wait-at-the-bound", "{refused}");
    assert_eq!(refused["ok"], false, "{refused}");
    assert!(
        refused["error"].as_str().is_some_and(|text| text.contains("limit 256")),
        "the refusal does not name the limit: {refused}"
    );
    assert_eq!(
        mux.control_clients.resource_wait_admission.active(),
        0,
        "a wait refused at the bound took a wait worker"
    );
    assert!(!permit.lease().is_long());
    assert_eq!(held(&connections), (1, LONG));

    let read =
        send("read", "session.snapshot", json!({"machine":"current","session":"current"}), None);
    assert_eq!(read["ok"], true, "the connection serves its next request: {read}");

    long.pop();
    let opened = send("events-below-the-bound", "session.events", events, None);
    assert_eq!(opened["ok"], true, "{opened}");
    assert!(permit.lease().is_long());
    assert_eq!(held(&connections), (0, LONG));
    // A wait on the long connection takes no second place.
    let waiting = resource_request("wait-on-a-long-connection", "terminal.wait", wait, None);
    assert!(handle_connection_message(&mux, client, &waiting, &writer, &scheduler));
    assert_eq!(held(&connections), (0, LONG));
    assert!(disconnect_client(&mux, client, false));
}
