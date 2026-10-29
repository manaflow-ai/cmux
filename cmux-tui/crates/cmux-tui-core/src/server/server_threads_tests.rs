//! `server-threads` and `server-blocking`: the registry,
//! lane and site-table snapshots behind them, the owner-only refusal, the
//! capability, and the read cost.

use std::panic::Location;
use std::sync::mpsc;
use std::thread::JoinHandle;
use std::time::{Duration, Instant};

use cmux_threads::blocking::{self, BlockingMode, BlockingSnapshot};
use cmux_threads::{ThreadQos, spawn};
use serde_json::Value;

use super::super::*;
use super::{ThreadDiagnosticsRefused, blocking_snapshot};

fn writer() -> MessageWriter {
    MessageWriter::new(QueuedSink { outbound: Arc::new(BoundedOutbound::default()), control: None })
}

fn local_mux(label: &str) -> (Arc<Mux>, u64) {
    let mux =
        Mux::new_for_test(format!("server-threads-{label}"), crate::SurfaceOptions::default());
    let client = mux.control_clients.register(ClientTransport::Unix, writer());
    (mux, client)
}

fn threads(mux: &Arc<Mux>, client: u64) -> Value {
    handle_command(mux, client, Command::ServerThreads, &writer()).unwrap()
}

fn row<'a>(reply: &'a Value, name: &str) -> Option<&'a Value> {
    reply["threads"].as_array().unwrap().iter().find(|row| row["name"] == name)
}

/// A thread that stays registered until the returned sender drops.
fn parked(name: &str, qos: ThreadQos) -> (mpsc::Sender<()>, JoinHandle<()>) {
    let (started_tx, started_rx) = mpsc::channel();
    let (finish_tx, finish_rx) = mpsc::channel::<()>();
    let handle = spawn(name, qos, move || {
        started_tx.send(()).unwrap();
        let _ = finish_rx.recv();
    })
    .unwrap();
    started_rx.recv().unwrap();
    (finish_tx, handle)
}

#[test]
fn server_threads_lists_a_registered_thread_until_it_exits() {
    const NAME: &str = "server-threads-test-utility";
    let (mux, client) = local_mux("row");
    let (finish, handle) = parked(NAME, ThreadQos::Utility);

    let reply = threads(&mux, client);
    assert_eq!(reply["schema"], 1);
    assert_eq!(reply["process"]["pid"], std::process::id());
    let thread = row(&reply, NAME).unwrap_or_else(|| panic!("{NAME} is listed: {reply}"));
    assert_eq!(thread["declared"], "utility");
    assert_eq!(thread["desired"], "utility");
    assert!(thread["tid"].is_u64(), "{thread}");
    #[cfg(any(target_os = "linux", target_os = "android"))]
    {
        assert!(reply["process"]["role"].is_null(), "Linux has no task role: {reply}");
        assert!(reply["process"]["darwin_bg"].is_null(), "Linux has no PRIO_DARWIN_BG: {reply}");
        let nice = thread["nice"].as_i64().unwrap_or_else(|| panic!("Linux reads nice: {thread}"));
        assert_eq!(thread["priority"].as_i64(), Some(20 + nice), "{thread}");
        assert_eq!(thread["matches"], nice == i64::from(ThreadQos::Utility.linux_nice()));
        assert!(thread["requested_qos"].is_null());
    }
    #[cfg(target_vendor = "apple")]
    {
        assert!(reply["process"]["role"].is_string(), "macOS reads a task role: {reply}");
        let darwin_bg = &reply["process"]["darwin_bg"];
        assert!(darwin_bg["internal"].is_boolean(), "macOS reads PRIO_DARWIN_BG: {reply}");
        assert!(darwin_bg["external"].is_boolean(), "macOS reads PRIO_DARWIN_BG: {reply}");
        assert_eq!(thread["requested_qos"], "utility", "{thread}");
        assert_eq!(thread["matches"], true);
        assert!(thread["priority"].is_i64(), "{thread}");
    }
    let lanes: Vec<&str> = reply["lanes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|lane| lane["lane"].as_str().unwrap())
        .collect();
    assert_eq!(lanes, ["files", "system", "cpu", "user"]);

    drop(finish);
    handle.join().unwrap();
    assert!(row(&threads(&mux, client), NAME).is_none(), "a joined thread has no row");
}

#[test]
fn server_threads_and_blocking_refuse_a_remote_client() {
    let (mux, _) = local_mux("remote");
    let remote = mux.control_clients.register(ClientTransport::WebSocket, writer());
    for command in [Command::ServerThreads, Command::ServerBlocking] {
        let error = handle_command(&mux, remote, command, &writer())
            .expect_err("a remote client must not read thread diagnostics");
        assert_eq!(
            error.downcast_ref::<ThreadDiagnosticsRefused>(),
            Some(&ThreadDiagnosticsRefused::NotLocal)
        );
    }
}

#[test]
fn server_threads_is_in_the_capabilities() {
    let (mux, client) = local_mux("capability");
    let identity =
        handle_command(&mux, client, Command::Identify(Default::default()), &writer()).unwrap();
    assert!(
        identity["capabilities"]
            .as_array()
            .unwrap()
            .iter()
            .any(|capability| capability == SERVER_THREADS_CAPABILITY),
        "{identity}"
    );
    assert!(build_capabilities().contains(&SERVER_THREADS_CAPABILITY));
}

#[test]
fn server_blocking_of_an_empty_table_has_no_sites() {
    let reply = serde_json::to_value(blocking_snapshot(
        7,
        BlockingMode::Record,
        BlockingSnapshot::default(),
    ))
    .unwrap();
    assert_eq!(
        reply,
        serde_json::json!({
            "schema": 1,
            "uptime_ms": 7,
            "mode": "record",
            "site_capacity": blocking::SITE_CAPACITY,
            "overflow": 0,
            "sites": [],
        })
    );
}

/// Acceptance: the two reads add no blocking site. They run as the daemon runs
/// them, on a thread that disallows blocking, in panic mode, so a blocking
/// call in them panics there (Debug). The site table, read before and after
/// and through the live command, gains no site in the files they run through.
#[test]
fn server_threads_and_blocking_add_no_blocking_site() {
    const READ_PATH: [&str; 5] = [
        "server/server_stats.rs",
        "server/cmd_server.rs",
        "cmux-threads/src/registry.rs",
        "cmux-threads/src/qos.rs",
        "cmux-threads/src/process_role.rs",
    ];
    let in_read_path = |file: &str| READ_PATH.iter().any(|name| file.ends_with(name));
    let (mux, client) = local_mux("no-site");
    let before = blocking::snapshot();

    let reply = std::thread::scope(|scope| {
        scope
            .spawn(|| {
                blocking::with_mode(BlockingMode::Panic, || {
                    blocking::with_blocking_disallowed(|| {
                        threads(&mux, client);
                        handle_command(&mux, client, Command::ServerBlocking, &writer()).unwrap()
                    })
                })
            })
            .join()
            .expect("server-threads and server-blocking make no blocking call")
    });

    let added: Vec<_> = blocking::snapshot()
        .sites
        .into_iter()
        .filter(|site| in_read_path(site.file))
        .filter(|site| before.site(site.file, site.line).is_none_or(|old| old.count < site.count))
        .collect();
    assert_eq!(added, [], "the reads recorded blocking sites");
    let listed: Vec<&Value> = reply["sites"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|row| {
            row["file"].as_str().is_some_and(|file| file.ends_with("server/server_stats.rs"))
        })
        .collect();
    assert!(listed.is_empty(), "server-blocking lists a site in its own read: {reply}");
}

#[test]
fn server_blocking_lists_a_sleep_on_a_disallowed_thread() {
    let (mux, client) = local_mux("site");
    let site = spawn("server-blocking-test-site", ThreadQos::Utility, || {
        blocking::with_mode(BlockingMode::Record, || {
            blocking::with_blocking_disallowed(|| {
                let site = Location::caller();
                cmux_threads::checked::sync::sleep(Duration::ZERO);
                site
            })
        })
    })
    .unwrap()
    .join()
    .unwrap();

    let reply = handle_command(&mux, client, Command::ServerBlocking, &writer()).unwrap();
    let recorded = reply["sites"]
        .as_array()
        .unwrap()
        .iter()
        .find(|row| row["file"] == site.file() && row["line"] == site.line() + 1)
        .unwrap_or_else(|| panic!("the sleep is a listed site: {reply}"));
    assert!(recorded["count"].as_u64().unwrap() >= 1, "{recorded}");
    assert!(recorded["kinds"].as_array().unwrap().iter().any(|kind| kind == "sleep"), "{recorded}");
    assert_eq!(reply["site_capacity"], blocking::SITE_CAPACITY);
}

/// Acceptance: a read with 64 more registered threads stays under 1 ms.
/// The best of 20 reads, so a preempted run does not fail the test.
#[test]
fn server_threads_and_blocking_read_in_under_a_millisecond() {
    let (mux, client) = local_mux("cost");
    let parked: Vec<_> = (0..64)
        .map(|index| parked(&format!("server-threads-test-cost-{index}"), ThreadQos::Utility))
        .collect();
    let commands: [fn() -> Command; 2] = [|| Command::ServerThreads, || Command::ServerBlocking];
    for command in commands {
        let best = (0..20)
            .map(|_| {
                let started = Instant::now();
                handle_command(&mux, client, command(), &writer()).unwrap();
                started.elapsed()
            })
            .min()
            .unwrap();
        assert!(best < Duration::from_millis(1), "best read took {best:?}");
    }
    for (finish, handle) in parked {
        drop(finish);
        handle.join().unwrap();
    }
}
