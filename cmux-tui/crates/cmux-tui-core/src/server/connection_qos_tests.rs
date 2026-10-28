//! Connection client classes (p02-threads task 224): how a connection is
//! classed, when, and that its reader and request threads follow the class
//! under `daemonRequestQos` and only then.

use std::io::{BufRead, BufReader, Write};
use std::net::Shutdown;
use std::os::unix::net::UnixStream;
use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_threads::ThreadQos;
use cmux_threads::work::Lane;
use serde_json::{Value, json};

use super::{ConnectionClass, ConnectionClassCell, ConnectionThread, ReaderClass, RestingClass};
use crate::event_cause::{EventCause, EventCauseScope};
use crate::panic_free::RecoverPoison;
use crate::request_origin::{HelloRole, RequestOrigin};
use crate::request_qos::{RequestQos, RequestQosGate};
use crate::server::line_connection::line_classes;
use crate::server::terminal_io_wire::ClearHistoryParams;
use crate::server::{
    BoundedOutbound, ClientTransport, Command, ConnectionSurfaceScheduler, MessageWriter,
    QueuedSink, Request, handle_connection,
};

const WAIT: Duration = Duration::from_secs(10);

fn gate(enabled: bool) -> RequestQos {
    let gate = RequestQosGate::default();
    gate.set_for_test(enabled);
    gate.snapshot()
}

fn classified(class: ConnectionClass) -> Arc<ConnectionClassCell> {
    let cell = Arc::new(ConnectionClassCell::default());
    cell.set(class);
    cell
}

/// The classes the lines of `client` entered since the last call.
fn classes(mux: &crate::Mux, client: u64) -> Vec<ThreadQos> {
    line_classes::take(mux, client).into_iter().map(|(qos, _)| qos).collect()
}

#[test]
fn the_class_follows_the_derived_origin_and_remote_lanes() {
    use ClientTransport::{Remote, Unix, WebSocket};
    let cases = [
        (Unix, false, RequestOrigin::User, false, ConnectionClass::Person),
        (WebSocket, false, RequestOrigin::User, false, ConnectionClass::Person),
        (Unix, false, RequestOrigin::Agent, false, ConnectionClass::Automation),
        (Unix, false, RequestOrigin::App, false, ConnectionClass::Automation),
        (WebSocket, false, RequestOrigin::Page, false, ConnectionClass::Automation),
        // The app's own connections without a hello (terminal_attach,
        // journal_read, ...) are the person's; its page relays are not.
        (Unix, false, RequestOrigin::Agent, true, ConnectionClass::Person),
        (Unix, false, RequestOrigin::Page, true, ConnectionClass::Automation),
        // A remote device's lane and a link peer are automation even when
        // the connection's origin is the person's.
        (Unix, true, RequestOrigin::User, false, ConnectionClass::Automation),
        (Unix, true, RequestOrigin::Agent, true, ConnectionClass::Automation),
        (Remote, false, RequestOrigin::User, false, ConnectionClass::Automation),
    ];
    for (transport, remote_device, origin, app_process, expected) in cases {
        assert_eq!(
            ConnectionClass::of(transport, remote_device, origin, app_process),
            expected,
            "{} remote_device={remote_device} origin={origin:?} app_process={app_process}",
            transport.as_str()
        );
    }
}

/// p02-threads.md task 224: the person's reader rests at the echo class
/// and its dispatcher at user-initiated; automation rests at utility; a
/// connection not classed yet at user-initiated.
#[test]
fn the_person_reads_at_the_echo_class_and_automation_rests_at_utility() {
    use ConnectionThread::{Reader, Request};
    assert_eq!(ConnectionClass::Person.qos(Reader), ThreadQos::UserInteractive);
    assert_eq!(ConnectionClass::Person.qos(Reader), crate::echo_thread::ECHO_PATH_QOS);
    assert_eq!(ConnectionClass::Person.qos(Request), ThreadQos::UserInitiated);
    for role in [Reader, Request] {
        assert_eq!(ConnectionClass::Automation.qos(role), ThreadQos::Utility);
        assert_eq!(ConnectionClass::Unclassified.qos(role), ThreadQos::UserInitiated);
    }
}

#[test]
fn the_cell_round_trips_every_class() {
    let cell = ConnectionClassCell::default();
    assert_eq!(cell.get(), ConnectionClass::Unclassified);
    for class in [ConnectionClass::Person, ConnectionClass::Automation] {
        cell.set(class);
        assert_eq!(cell.get(), class);
    }
}

/// With the feature on, a request thread of an automation connection asks
/// for Utility and runs at it as its work class (so a ranked lock raises
/// it), when the process can take Utility back.
#[test]
fn a_resting_thread_follows_its_connection_class() {
    let cell = Arc::new(ConnectionClassCell::default());
    let thread_cell = cell.clone();
    let (applied, desired, work) =
        cmux_threads::spawn("mux-test-resting-on", ThreadQos::UserInitiated, move || {
            let mut resting = RestingClass::new(thread_cell, ConnectionThread::Request, gate(true));
            resting.follow();
            let unclassified = resting.applied();
            let slot = cmux_threads::current_slot().expect("a registered thread");
            assert_eq!(slot.desired(), ThreadQos::UserInitiated, "unclassified: user-initiated");
            cell.set(ConnectionClass::Automation);
            resting.follow();
            ((unclassified, resting.applied()), slot.desired(), cmux_tui_platform::qos::work_qos())
        })
        .expect("start the thread")
        .join()
        .expect("the thread returns");
    assert_eq!(applied, (Some(ConnectionClass::Unclassified), Some(ConnectionClass::Automation)));
    assert_eq!(desired, ThreadQos::Utility);
    let expected = cmux_threads::reversible(ThreadQos::Utility).then_some(ThreadQos::Utility);
    assert_eq!(work, expected, "the resting class is the thread's work class");
}

/// With the feature off the class is recorded and no thread changes.
#[test]
fn with_the_feature_off_a_thread_keeps_its_class() {
    let (applied, desired, work) =
        cmux_threads::spawn("mux-test-resting-off", ThreadQos::UserInitiated, move || {
            let cell = classified(ConnectionClass::Automation);
            let mut resting = RestingClass::new(cell, ConnectionThread::Request, gate(false));
            resting.follow();
            let slot = cmux_threads::current_slot().expect("a registered thread");
            (resting.applied(), slot.desired(), cmux_tui_platform::qos::work_qos())
        })
        .expect("start the thread")
        .join()
        .expect("the thread returns");
    assert_eq!(applied, None);
    assert_eq!(desired, ThreadQos::UserInitiated);
    assert_eq!(work, None);
}

/// A request's own class nests inside the resting class and gives it back.
#[test]
fn a_request_class_nests_inside_the_resting_class() {
    let work = cmux_threads::spawn("mux-test-resting-nest", ThreadQos::UserInitiated, || {
        let mut resting = RestingClass::new(
            classified(ConnectionClass::Automation),
            ConnectionThread::Request,
            gate(true),
        );
        resting.follow();
        let rested = cmux_tui_platform::qos::work_qos();
        {
            let _request = gate(true).enter(EventCause::Frontend);
        }
        (rested, cmux_tui_platform::qos::work_qos())
    })
    .expect("start the thread")
    .join()
    .expect("the thread returns");
    assert_eq!(work.0, work.1, "the resting class comes back after the request");
}

fn writer() -> (Arc<BoundedOutbound>, MessageWriter) {
    let outbound = Arc::new(BoundedOutbound::default());
    let writer = MessageWriter::new(QueuedSink { outbound: outbound.clone(), control: None });
    (outbound, writer)
}

/// `set-client-info` classes the connection from its derived origin, never
/// from its `kind`; `remote: true` makes it a remote lane, and so automation.
#[test]
fn set_client_info_classes_by_origin_and_remote_lane() {
    let mux = crate::Mux::new_for_test("connection-qos-registry", crate::SurfaceOptions::default());
    let (_, agent_writer) = writer();
    let agent = mux.control_clients.register(ClientTransport::Unix, agent_writer);
    let agent_class = mux.control_clients.connection_class(agent);
    assert_eq!(agent_class.get(), ConnectionClass::Unclassified);
    mux.control_clients.set_info(agent, None, Some("frontend".into()), None).unwrap();
    assert_eq!(agent_class.get(), ConnectionClass::Automation, "a kind label never raises");

    let (_, app_writer) = writer();
    let app = mux.control_clients.register(ClientTransport::Unix, app_writer);
    {
        let mut state = mux.control_clients.state.lock().recover_poison();
        let record = state.clients.get_mut(&app).unwrap();
        record.origin.role = HelloRole::Main;
        record.origin.verified_app = true;
    }
    let app_class = mux.control_clients.connection_class(app);
    mux.control_clients.set_info(app, Some("cmux".into()), None, None).unwrap();
    assert_eq!(app_class.get(), ConnectionClass::Person);
    mux.control_clients.mark_remote_device(app);
    assert_eq!(app_class.get(), ConnectionClass::Automation);
    mux.shutdown();
}

/// The kernel peer key of this test process, as the daemon reads it at
/// accept for a socket this process connected.
fn own_peer_key() -> String {
    use crate::platform::transport::Stream;
    let (ours, _theirs) = UnixStream::pair().unwrap();
    ours.peer_process_key().expect("a peer key for a local socket")
}

fn connect_peer(mux: &Arc<crate::Mux>, key: Option<&str>) -> u64 {
    let (_, writer) = writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer);
    if let Some(key) = key {
        crate::server::origin_gate::set_peer_key_for_test(mux, client, key);
    }
    client
}

/// A connection without a hello whose peer is a verified app's process is
/// the person's: classed so after the app proved itself, and reclassed when
/// the app proves itself later (the install-key prover here). A page relay
/// of that process and a connection of another process stay automation.
#[test]
fn the_app_processs_other_connections_are_the_persons() {
    use crate::server::origin_gate::{set_hello, set_install_proved};
    let mux =
        crate::Mux::new_for_test("connection-qos-app-process", crate::SurfaceOptions::default());
    let app_key = "token:4242.7";
    // Classed before the app proved itself: automation until it does.
    let early = connect_peer(&mux, Some(app_key));
    mux.control_clients.set_info(early, None, Some("frontend".into()), None).unwrap();
    let early_class = mux.control_clients.connection_class(early);
    assert_eq!(early_class.get(), ConnectionClass::Automation);
    let other = connect_peer(&mux, Some("token:9999.1"));
    mux.control_clients.classify_connection(other);
    let relay = connect_peer(&mux, None);
    assert!(set_hello(&mux, relay, HelloRole::PageRelay, Some(app_key.into()), false, None, false));
    mux.control_clients.classify_connection(relay);

    let app = connect_peer(&mux, None);
    assert!(set_hello(&mux, app, HelloRole::Main, Some(app_key.into()), false, None, false));
    assert_eq!(early_class.get(), ConnectionClass::Automation, "not proved yet");
    assert!(set_install_proved(&mux, app, "install_1"));
    assert_eq!(early_class.get(), ConnectionClass::Person, "reclassed by the proof");

    // Classed after the proof: the person's from the start.
    let late = connect_peer(&mux, Some(app_key));
    mux.control_clients.classify_connection(late);
    assert_eq!(mux.control_clients.connection_class(late).get(), ConnectionClass::Person);
    let relay_class = mux.control_clients.connection_class(relay).get();
    assert_eq!(relay_class, ConnectionClass::Automation, "a page relay of the app's process");
    let other_class = mux.control_clients.connection_class(other).get();
    assert_eq!(other_class, ConnectionClass::Automation, "another process");
    mux.shutdown();
}

/// The code-signature prover reclasses the app's other connections too.
#[test]
fn a_signed_app_hello_reclasses_its_processs_connections() {
    let mux =
        crate::Mux::new_for_test("connection-qos-app-signed", crate::SurfaceOptions::default());
    let app_key = "token:4243.7";
    let early = connect_peer(&mux, Some(app_key));
    mux.control_clients.classify_connection(early);
    let early_class = mux.control_clients.connection_class(early);
    assert_eq!(early_class.get(), ConnectionClass::Automation);
    let app = connect_peer(&mux, None);
    assert!(crate::server::origin_gate::set_hello(
        &mux,
        app,
        HelloRole::Main,
        Some(app_key.into()),
        true,
        None,
        false
    ));
    assert_eq!(early_class.get(), ConnectionClass::Person);
    mux.shutdown();
}

/// An automation connection's clear-history request runs as a `Mux::work`
/// item on the system lane at its cause's class (p02-threads 230), not on a
/// thread of its own that rests at the connection's class: the reader enters
/// the automation cause for the connection's lines, and that cause runs its
/// requests at Utility (crate::request_qos). The control task that posted
/// the item ran on a shared pool worker inside a scope of the connection's
/// class, which leaves the worker's row at its declared class.
#[test]
fn an_automation_connections_clear_history_runs_at_its_cause_on_the_work_pool() {
    let mux = crate::Mux::new_for_test("connection-qos-dispatch", crate::SurfaceOptions::default());
    mux.set_request_qos_for_test(true);
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (outbound, writer) = writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    mux.control_clients.classify_connection(client);
    let class = mux.control_clients.connection_class(client);
    assert_eq!(class.get(), ConnectionClass::Automation);
    assert_eq!(EventCause::Automation.request_qos(), Some(ThreadQos::Utility));
    let scheduler = Arc::new(
        ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()).classed(class),
    );
    let mut clear = Some(Request {
        id: Some(json!(1)),
        cmd: Command::ClearHistory(ClearHistoryParams { surface: surface.id, fallback_key: None }),
    });
    // The item waits for the terminal lock held here, so it is running while
    // the lane is read.
    let held = surface.with_terminal(|_| {
        let _cause = EventCauseScope::enter(EventCause::Automation);
        assert_eq!(scheduler.dispatch(mux.clone(), client, &mut clear, 0, writer), Some(true));
        let deadline = Instant::now() + WAIT;
        while mux.work.stats()[Lane::System as usize].running == 0 {
            assert!(Instant::now() < deadline, "the clear-history item never started");
            std::thread::yield_now();
        }
        assert!(
            cmux_threads::snapshot().iter().all(|row| row.name != "mux-surface-control"),
            "a clear-history request started its own thread"
        );
    });
    assert!(held.is_some(), "a PTY surface");
    scheduler.finish_and_wait();
    let reply: Value = serde_json::from_str(&outbound.try_pop().expect("a reply")).unwrap();
    assert_eq!(reply["id"], 1, "{reply}");
    mux.close_surface(surface.id).unwrap();
    mux.shutdown();
}

fn exchange(stream: &mut UnixStream, reader: &mut BufReader<UnixStream>, line: Value) -> Value {
    stream.write_all(format!("{line}\n").as_bytes()).unwrap();
    // Event lines (an attach's output) may come before the reply.
    loop {
        let mut reply = String::new();
        reader.read_line(&mut reply).unwrap();
        let reply: Value = serde_json::from_str(&reply).unwrap();
        if reply.get("id") == line.get("id") {
            return reply;
        }
    }
}

/// A connection without a hello is classed when its hello window closes:
/// its first line closes it, and the connection, which can no longer become
/// the verified app, is automation. The connection has no reader thread:
/// each line runs at the connection's class on the pool
/// worker that handles it, so the hello gate sees the first line unclassed
/// and its dispatch, and every later line, runs at utility. (`identify`,
/// which keeps the window open, reads the registry's revision from SQLite:
/// a recorded blocking site on a request worker, left out here.)
#[test]
fn a_connection_is_classed_when_its_hello_window_closes() {
    let mux = crate::Mux::new_for_test("connection-qos-reader", crate::SurfaceOptions::default());
    mux.set_request_qos_for_test(true);
    let (server, mut client) = UnixStream::pair().unwrap();
    client.set_read_timeout(Some(WAIT)).unwrap();
    let handler = {
        let mux = mux.clone();
        std::thread::spawn(move || handle_connection(mux, Box::new(server)))
    };
    let mut reader = BufReader::new(client.try_clone().unwrap());
    let reply = exchange(&mut client, &mut reader, json!({"id": 1, "cmd": "ping"}));
    assert_eq!(reply["ok"], true, "{reply}");
    let id = *mux.control_clients.client_ids().first().expect("the connection's client");
    assert_eq!(mux.control_clients.connection_class(id).get(), ConnectionClass::Automation);
    assert_eq!(
        classes(&mux, id),
        [ThreadQos::UserInitiated, ThreadQos::Utility],
        "the hello gate sees the line unclassed; its dispatch runs at the class"
    );

    let reply = exchange(&mut client, &mut reader, json!({"id": 2, "cmd": "ping"}));
    assert_eq!(reply["ok"], true, "{reply}");
    assert_eq!(
        classes(&mux, id),
        [ThreadQos::Utility, ThreadQos::Utility],
        "a later line runs at utility"
    );
    // `server-threads` names the connection and the class its lines run
    // at: the QoS audit judges the person's connection by it (RUN-4).
    let snapshot = serde_json::to_value(crate::server::server_stats::server_threads(&mux)).unwrap();
    let row = snapshot["connections"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["client"] == id)
        .cloned()
        .expect("the connection's row");
    assert_eq!(
        (&row["transport"], &row["class"], &row["lines_qos"]),
        (&json!("unix"), &json!("automation"), &json!("utility")),
        "{row}"
    );

    client.shutdown(Shutdown::Both).unwrap();
    handler.join().unwrap();
    mux.shutdown();
}

/// A served connection holds no thread (no `mux-conn`,
/// `mux-line-out` or `mux-events-out` row); its class is still recorded on
/// its client (its lines and requests run at it on the pool's workers).
#[test]
fn a_served_connection_holds_no_thread_of_its_own() {
    let mux = crate::Mux::new_for_test("connection-qos-row", crate::SurfaceOptions::default());
    let (server, mut client) = UnixStream::pair().unwrap();
    client.set_read_timeout(Some(WAIT)).unwrap();
    let handler = {
        let mux = mux.clone();
        std::thread::spawn(move || handle_connection(mux, Box::new(server)))
    };
    let mut reader = BufReader::new(client.try_clone().unwrap());
    let reply = exchange(&mut client, &mut reader, json!({"id": 1, "cmd": "ping"}));
    assert_eq!(reply["ok"], true, "{reply}");
    let id = *mux.control_clients.client_ids().first().expect("the connection's client");
    assert_eq!(mux.control_clients.connection_class(id).get(), ConnectionClass::Automation);

    let snapshot = serde_json::to_value(crate::server::server_stats::server_threads(&mux)).unwrap();
    let rows = snapshot["threads"].as_array().unwrap();
    // Thread rows are the process's; other tests' muxes have a client 1 too,
    // so the check is by name: no reader or writer thread exists.
    for row in rows {
        let name = row["name"].as_str().unwrap_or_default();
        assert!(!matches!(name, "mux-conn" | "mux-line-out" | "mux-events-out"), "{row}");
    }

    client.shutdown(Shutdown::Both).unwrap();
    handler.join().unwrap();
    mux.shutdown();
}

/// The reader classes its connection once, at the first line after the
/// hello window closed.
#[test]
fn a_reader_classes_its_connection_once() {
    let mux = crate::Mux::new_for_test("connection-qos-once", crate::SurfaceOptions::default());
    let (_, writer) = writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer);
    let class = mux.control_clients.connection_class(client);
    let mut reader = ReaderClass::new(class.clone(), gate(false));
    reader.before_line(&mux, client, false);
    assert_eq!(class.get(), ConnectionClass::Unclassified);
    reader.before_line(&mux, client, true);
    assert_eq!(class.get(), ConnectionClass::Automation);
    // A later reclassification is set-client-info's; the reader does not
    // read the registry again.
    class.set(ConnectionClass::Person);
    reader.before_line(&mux, client, true);
    assert_eq!(class.get(), ConnectionClass::Person);
    mux.shutdown();
}

/// The app's terminal attachment (TerminalAttachment.swift) sends no hello:
/// `identify`, `set-client-info {kind: frontend}`, then `attach-surface`, and
/// it carries the person's keys. From the process of a verified app
/// connection its lines run at the echo class, never at utility, and on the
/// pool's input workers, ahead of automation's lines (the
/// connection has no reader thread of its own). `identify` is left out here
/// (a recorded SQLite site on a request worker); `set-client-info` closes
/// the window in its place.
#[test]
fn the_apps_terminal_attachment_lines_run_at_the_echo_class() {
    let mux = crate::Mux::new_for_test("connection-qos-attach", crate::SurfaceOptions::default());
    mux.set_request_qos_for_test(true);
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    // The app's control connection, verified, from this process.
    let app = connect_peer(&mux, None);
    assert!(crate::server::origin_gate::set_hello(
        &mux,
        app,
        HelloRole::Main,
        Some(own_peer_key()),
        true,
        None,
        false
    ));

    let (server, mut client) = UnixStream::pair().unwrap();
    client.set_read_timeout(Some(WAIT)).unwrap();
    let handler = {
        let mux = mux.clone();
        std::thread::spawn(move || handle_connection(mux, Box::new(server)))
    };
    let mut reader = BufReader::new(client.try_clone().unwrap());
    let info = json!({
        "id": 1, "cmd": "set-client-info", "name": "cmux-next-terminal", "kind": "frontend",
    });
    let reply = exchange(&mut client, &mut reader, info);
    assert_eq!(reply["ok"], true, "{reply}");
    let attachment = mux
        .control_clients
        .client_ids()
        .into_iter()
        .find(|id| *id != app)
        .expect("the attachment's client");
    let entered = classes(&mux, attachment);
    assert_eq!(entered.first(), Some(&ThreadQos::UserInitiated), "not classed yet: {entered:?}");
    assert_eq!(mux.control_clients.connection_class(attachment).get(), ConnectionClass::Person);

    let attach = json!({"id": 2, "cmd": "attach-surface", "surface": surface.id});
    let reply = exchange(&mut client, &mut reader, attach);
    assert_eq!(reply["ok"], true, "{reply}");
    let entered = line_classes::take(&mux, attachment);
    let echo = crate::echo_thread::ECHO_PATH_QOS;
    assert_eq!(echo, ThreadQos::UserInteractive);
    assert!(
        entered.len() == 2 && entered.iter().all(|(qos, _)| *qos == echo),
        "the echo class: {entered:?}"
    );
    assert!(
        entered.iter().all(|(_, thread)| thread == crate::server::mux_io::MUX_IO_INPUT_THREAD),
        "the person's lines are routed on the person's IO loop: {entered:?}"
    );

    client.shutdown(Shutdown::Both).unwrap();
    handler.join().unwrap();
    mux.close_surface(surface.id).unwrap();
    mux.shutdown();
}

/// Echo latency under an agent burst (p01-process-203 finding: the person's
/// keys share the daemon's connection path with automation). The app's
/// terminal attachment (the person's, classed so from this verified
/// process) sends a key with `send` and times it to its `output` echo,
/// 400 times, while 8 automation connections (remote lanes) each keep 32
/// `ping`s in flight. Prints p50, p95, p99 and max. Run by hand:
/// `cargo test -p cmux-tui-core --lib -- echo_latency_under_an_agent_burst
/// --ignored --nocapture`.
#[test]
#[ignore = "measurement; run by hand"]
fn echo_latency_under_an_agent_burst() {
    use std::sync::atomic::{AtomicBool, Ordering};

    const KEYS: usize = 400;
    // `CMUX_ECHO_BENCH_AGENTS=0` measures the idle path.
    let agents_count: usize =
        std::env::var("CMUX_ECHO_BENCH_AGENTS").ok().and_then(|n| n.parse().ok()).unwrap_or(8);
    const IN_FLIGHT: usize = 32;
    let options = crate::SurfaceOptions {
        command: Some(vec!["/bin/cat".to_string()]),
        ..crate::SurfaceOptions::default()
    };
    // A real PTY (the test surface runtime runs no process).
    let mux = crate::Mux::new(format!("connection-qos-echo-burst-{}", std::process::id()), options);
    mux.set_request_qos_for_test(true);
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let serve = |server: UnixStream| {
        let mux = mux.clone();
        std::thread::spawn(move || handle_connection(mux, Box::new(server)))
    };

    // Automation first: each a remote lane, so automation from this process.
    let stop = Arc::new(AtomicBool::new(false));
    let answered = Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let mut agents = Vec::new();
    for _ in 0..agents_count {
        let (server, mut client) = UnixStream::pair().unwrap();
        client.set_read_timeout(Some(WAIT)).unwrap();
        let handler = serve(server);
        let mut reader = BufReader::new(client.try_clone().unwrap());
        let before = mux.control_clients.client_ids();
        assert_eq!(exchange(&mut client, &mut reader, json!({"id": 0, "cmd": "ping"}))["ok"], true);
        let id = *mux
            .control_clients
            .client_ids()
            .iter()
            .find(|id| !before.contains(id))
            .expect("the agent's client");
        mux.control_clients.mark_remote_device(id);
        let stop = stop.clone();
        let answered = answered.clone();
        let burst = std::thread::spawn(move || {
            let mut line = String::new();
            let ping = format!("{}\n", json!({"id": 1, "cmd": "ping"}));
            while !stop.load(Ordering::Relaxed) {
                client.write_all(ping.repeat(IN_FLIGHT).as_bytes()).unwrap();
                for _ in 0..IN_FLIGHT {
                    line.clear();
                    reader.read_line(&mut line).unwrap();
                }
                answered.fetch_add(IN_FLIGHT, Ordering::Relaxed);
            }
            client.shutdown(Shutdown::Both).unwrap();
        });
        agents.push((handler, burst));
    }

    // The app's control connection, verified, from this process.
    let app = connect_peer(&mux, None);
    assert!(crate::server::origin_gate::set_hello(
        &mux,
        app,
        HelloRole::Main,
        Some(own_peer_key()),
        true,
        None,
        false
    ));
    let (server, mut client) = UnixStream::pair().unwrap();
    client.set_read_timeout(Some(WAIT)).unwrap();
    let handler = serve(server);
    let mut reader = BufReader::new(client.try_clone().unwrap());
    let info = json!({"id": 1, "cmd": "set-client-info", "name": "cmux-next-terminal", "kind": "frontend"});
    assert_eq!(exchange(&mut client, &mut reader, info)["ok"], true);
    let attach = json!({"id": 2, "cmd": "attach-surface", "surface": surface.id});
    assert_eq!(exchange(&mut client, &mut reader, attach)["ok"], true);
    let mut line = String::new();
    let mut next = |reader: &mut BufReader<UnixStream>| -> Value {
        line.clear();
        reader.read_line(&mut line).unwrap();
        serde_json::from_str(&line).unwrap()
    };
    // The attach's `vt-state` came with its reply (`exchange` skips events).

    let mut samples = Vec::with_capacity(KEYS);
    let (burst_started, answered_before) = (Instant::now(), answered.load(Ordering::Relaxed));
    for key in 0..KEYS {
        let id = 100 + key;
        let send = json!({"id": id, "cmd": "send", "surface": surface.id, "text": "x"});
        let started = Instant::now();
        client.write_all(format!("{send}\n").as_bytes()).unwrap();
        loop {
            let message = next(&mut reader);
            if message["event"] == "output" {
                break;
            }
        }
        samples.push(started.elapsed());
        // The reply may come after the echo; it is skipped above or here.
        std::thread::sleep(Duration::from_millis(2));
    }
    let pings_per_second = (answered.load(Ordering::Relaxed) - answered_before) as f64
        / burst_started.elapsed().as_secs_f64();
    stop.store(true, Ordering::Relaxed);
    let person_loop = cmux_threads::snapshot()
        .iter()
        .any(|row| row.name == crate::server::mux_io::MUX_IO_INPUT_THREAD);
    samples.sort();
    let at = |q: f64| samples[((samples.len() as f64 * q) as usize).min(samples.len() - 1)];
    eprintln!(
        "echo under agent burst: p50 {:?} p95 {:?} p99 {:?} max {:?} ({KEYS} keys, {agents_count} agents x {IN_FLIGHT} pings, {pings_per_second:.0} pings/s, person loop {person_loop})",
        at(0.50),
        at(0.95),
        at(0.99),
        samples[samples.len() - 1],
    );
    client.shutdown(Shutdown::Both).unwrap();
    handler.join().unwrap();
    for (handler, burst) in agents {
        burst.join().unwrap();
        handler.join().unwrap();
    }
    mux.close_surface(surface.id).unwrap();
    mux.shutdown();
}
