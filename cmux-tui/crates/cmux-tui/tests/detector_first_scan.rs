//! The screen detector's first reads of a pass against a real headless owner.
//!
//! The detector (`bindings/examples/rust-agent-screen-detection`,
//! `scanner.rs`, `scan_connection`) reads the list of the terminals of the
//! session with one request, and then reads terminals of that list one by
//! one, with one request each, before it waits for a wake. Which terminals
//! it reads is the detector's own function (`src/first_scan.rs`, a file with
//! no dependency), compiled here as a module: the choice in these tests is
//! the detector's own choice, not a copy.
//!
//! A terminal whose process ended keeps its row in the list until a
//! `terminal.close`, so a session that lived for long holds many such rows.
//! A read of such a row gives nothing that its list row does not hold. The
//! first test counts the reads on a session with a terminal that ended; the
//! second is the table of the choice; the third holds the item that the owner
//! sends when a terminal that ended gets a new process.
//!
//! The tests do not run the detector's binary: the first test makes the list
//! request, and then the reads that the detector's function names.

#![cfg(unix)]

mod fault_support;

#[path = "../../../bindings/examples/rust-agent-screen-detection/src/first_scan.rs"]
mod detector_first_scan;

use std::path::Path;
use std::time::{Duration, Instant};

use cmux::{
    Client, Config, EventStreamOptions, ResourceChange, ResourceEntitySnapshot, ResourceReference,
    Selector, Session, SessionEvent, SessionEventStream, SessionId, StreamPoll, TerminalId,
    TerminalLifecycle, TerminalSnapshot,
};
use detector_first_scan::{ListedTerminal, first_scan_ids};
use fault_support::{FaultDir, NO_MAINTENANCE, Owner};
use serde_json::json;

const READY_BOUND: Duration = Duration::from_secs(60);
/// A liveness bound of the setup: how long a test waits for a row that its
/// own request makes.
const SETUP_BOUND: Duration = Duration::from_secs(60);

/// The first reads of a pass of a detector that holds no state.
#[derive(Debug)]
struct FirstReads {
    /// The rows of `terminal.list`.
    listed: Vec<TerminalSnapshot>,
    /// What `terminal.get` gave for each id that the detector's function
    /// named: the requests of the detector after its list request.
    read: Vec<TerminalSnapshot>,
    /// Each listed row that the function did not name, with what a
    /// `terminal.get` of the test gave for its id. The detector does not
    /// make this request.
    not_read: Vec<(TerminalSnapshot, TerminalSnapshot)>,
}

fn sdk_session(socket: &Path, session_name: &str) -> Result<(Client, Session), String> {
    let selector = match SessionId::parse(session_name.to_owned()) {
        Ok(id) => Selector::id(id),
        Err(_) => Selector::name(session_name.to_owned()),
    };
    let client = Client::connect(Config::from_socket_path(socket))
        .map_err(|error| format!("connect: {error}"))?;
    let session = client.session(selector);
    Ok((client, session))
}

/// The list request of a pass, then one `terminal.get` for each id that the
/// detector's function names. The detector has just started: it holds state
/// for no terminal. The error names the call that failed and holds the SDK's
/// text.
fn first_reads(socket: &Path, session_name: &str) -> Result<FirstReads, String> {
    let (_client, session) = sdk_session(socket, session_name)?;
    let listed = session.terminal_snapshots().map_err(|error| format!("terminal list: {error}"))?;
    let rows = listed.iter().map(|row| ListedTerminal {
        id: row.id.as_str(),
        exited: row.lifecycle == TerminalLifecycle::Exited,
        known: false,
    });
    let named = first_scan_ids(rows);
    let mut read = Vec::with_capacity(named.len());
    for id in &named {
        let terminal =
            TerminalId::parse(*id).map_err(|error| format!("the id {id} of the list: {error}"))?;
        let got = session
            .terminal(terminal)
            .refresh()
            .map_err(|error| format!("terminal get of {id}: {error}"))?;
        read.push(got);
    }
    let mut not_read = Vec::new();
    for row in listed.iter().filter(|row| !named.contains(&row.id.as_str())) {
        let got = session
            .terminal(row.id.clone())
            .refresh()
            .map_err(|error| format!("terminal get of {} by the test: {error}", row.id))?;
        not_read.push((row.clone(), got));
    }
    Ok(FirstReads { listed, read, not_read })
}

/// Waits until `terminal.list` holds one terminal that ended and has no tab,
/// and each other listed terminal runs (one of them at least).
///
/// The wait is on items of `events`, a session event stream that the test
/// opened before the request that makes the ended terminal: the function
/// reads the list, and reads it again only after the stream gives an item.
/// A change before the stream opened is in the first list, and a change
/// after it gives an item, so there is no sleep and no change is lost.
/// `SETUP_BOUND` (60 s) is a liveness bound of the whole wait: after it the
/// test fails as `setup:`.
fn wait_for_an_ended_terminal_with_no_tab(session: &Session, events: &mut SessionEventStream) {
    let deadline = Instant::now() + SETUP_BOUND;
    loop {
        let listed = session
            .terminal_snapshots()
            .unwrap_or_else(|error| panic!("setup: the terminal list fails: {error}"));
        let (ended, others): (Vec<_>, Vec<_>) =
            listed.iter().partition(|terminal| terminal.lifecycle == TerminalLifecycle::Exited);
        let no_tab = ended.len() == 1 && ended[0].tab_ids.is_empty();
        let others_run =
            others.iter().all(|terminal| terminal.lifecycle == TerminalLifecycle::Running);
        if no_tab && !others.is_empty() && others_run {
            return;
        }
        match events.next_timeout(deadline.saturating_duration_since(Instant::now())) {
            Ok(StreamPoll::Item(_)) => {}
            Ok(StreamPoll::TimedOut) => {
                let seen = listed
                    .iter()
                    .map(|terminal| (terminal.lifecycle, terminal.tab_ids.len()))
                    .collect::<Vec<_>>();
                panic!(
                    "setup: within {SETUP_BOUND:?} the list does not have one ended terminal \
                     with no tab beside terminals that run; the lifecycle and the tab count of \
                     each listed terminal: {seen:?}"
                );
            }
            Ok(StreamPoll::End) => {
                panic!("setup: the session event stream ended before the list had the ended row")
            }
            Err(error) => panic!("setup: session event stream item: {error}"),
        }
    }
}

fn sorted_ids<'a>(terminals: impl IntoIterator<Item = &'a TerminalSnapshot>) -> Vec<String> {
    let mut ids = terminals.into_iter().map(|terminal| terminal.id.to_string()).collect::<Vec<_>>();
    ids.sort();
    ids
}

/// A session with a terminal that runs and a terminal whose process ended
/// (`exit 3`) and whose tab went: the owner keeps the row of the ended
/// terminal, and `terminal.list` gives it. A detector that holds no state
/// reads each terminal that did not end, and does not read the ended one:
/// one request less for each ended row of the list. A read of the ended row
/// by the test gives the list row again, so the detector loses nothing.
#[test]
fn detector_first_scan_does_not_read_a_listed_terminal_that_ended() {
    let label = "dfs-ended";
    let dir = FaultDir::new(label);
    let owner = Owner::start(&dir, label, &[NO_MAINTENANCE], READY_BOUND);
    owner.data(json!({"cmd": "new-workspace", "name": "stays", "cols": 160, "rows": 40}));
    let (_client, session) =
        sdk_session(&dir.socket(), label).unwrap_or_else(|error| panic!("setup: {error}"));
    let mut events = session
        .events(EventStreamOptions::default())
        .unwrap_or_else(|error| panic!("setup: session event stream open: {error}"));
    owner.data(json!({
        "cmd": "run", "argv": ["/bin/sh", "-c", "exit 3"], "new_workspace": true, "name": "ended",
    }));
    wait_for_an_ended_terminal_with_no_tab(&session, &mut events);
    drop(events);
    let reads = first_reads(&dir.socket(), label);
    owner.stop();
    let reads = match reads {
        Ok(reads) => reads,
        Err(error) => panic!("the first reads on the session `{label}` fail: {error}"),
    };
    let (ended, others): (Vec<_>, Vec<_>) =
        reads.listed.iter().partition(|terminal| terminal.lifecycle == TerminalLifecycle::Exited);
    assert_eq!(ended.len(), 1, "setup: the list does not have 1 terminal that ended: {reads:?}");
    assert!(
        !others.is_empty()
            && others.iter().all(|terminal| terminal.lifecycle == TerminalLifecycle::Running),
        "setup: the other listed terminals do not all run, or there is none: {reads:?}"
    );
    eprintln!(
        "{label}: {} listed terminals ({} ended), {} read after the list",
        reads.listed.len(),
        ended.len(),
        reads.read.len()
    );
    assert_eq!(
        sorted_ids(&reads.read),
        sorted_ids(others.iter().copied()),
        "after its list request the detector makes {} `terminal.get` requests on a session \
         with {} listed terminals, {} of them ended; wanted {}: one for each terminal that \
         did not end",
        reads.read.len(),
        reads.listed.len(),
        ended.len(),
        others.len()
    );
    for got in &reads.read {
        assert_eq!(
            got.lifecycle,
            TerminalLifecycle::Running,
            "`terminal.get` of a terminal that runs does not give a terminal that runs: {got:?}"
        );
    }
    assert_eq!(
        reads.not_read.len(),
        1,
        "the detector's function does not leave out 1 listed terminal: {reads:?}"
    );
    let (row, got) = &reads.not_read[0];
    assert_eq!(row.lifecycle, TerminalLifecycle::Exited, "the row left out did not end: {row:?}");
    assert_eq!(
        got, row,
        "`terminal.get` of the ended terminal does not give its row of `terminal.list`"
    );
}

/// The choice with no owner: the detector reads each listed terminal but one
/// that ended and for which it holds no state. A terminal that ended and for
/// which it holds state gets its read: the detector must close what it said
/// about that terminal.
#[test]
fn detector_first_scan_reads_each_listed_terminal_but_an_ended_one_with_no_state() {
    let row = |id, exited, known| ListedTerminal { id, exited, known };
    let listed = [
        row("runs-new", false, false),
        row("runs-known", false, true),
        row("ended-known", true, true),
        row("ended-new", true, false),
        row("starts", false, false),
    ];
    assert_eq!(
        first_scan_ids(listed),
        ["runs-new", "runs-known", "ended-known", "starts"],
        "the detector's first reads of the rows {listed:?}"
    );
    assert!(first_scan_ids(Vec::<ListedTerminal<'_>>::new()).is_empty());
}

/// The wake that gives an ended terminal its read again, on the owner's side.
/// A terminal whose process ended and whose tab stays (`on_exit: keep`) is in
/// the list as `exited`. A `restart-tab` gives it a new process under the
/// same id, and a session event stream that was open before the list then
/// gets a delta with an upsert of that terminal which is not `exited`. The
/// detector reads a terminal that such a delta names (`scanner.rs`,
/// `terminal_wakes`). Each wait is on a stream item, with the liveness bound
/// `SETUP_BOUND`. The test does not use the detector's choice: it holds what
/// the owner sends.
#[test]
fn detector_first_scan_gets_an_upsert_when_an_ended_terminal_restarts() {
    let label = "dfs-restart";
    let dir = FaultDir::new(label);
    let owner = Owner::start(&dir, label, &[NO_MAINTENANCE], READY_BOUND);
    let workspace = fault_support::create_workspace(&dir.socket(), "kept");
    let (_client, session) =
        sdk_session(&dir.socket(), label).unwrap_or_else(|error| panic!("setup: {error}"));
    let mut events = session
        .events(EventStreamOptions::default())
        .unwrap_or_else(|error| panic!("setup: session event stream open: {error}"));
    let run = fault_support::v2(
        &dir.socket(),
        "workspace.run",
        json!({"workspace": workspace, "argv": ["/bin/sh", "-c", "exit 3"], "on_exit": "keep"}),
        "dfs-restart-run",
    );
    let terminal = run["value"]["terminal_id"].as_str().expect("the run names its terminal");
    let mut restarted = None;
    let woke = loop {
        let item = match events.next_timeout(SETUP_BOUND) {
            Ok(StreamPoll::Item(item)) => item,
            Ok(StreamPoll::TimedOut) => panic!(
                "within {SETUP_BOUND:?} the stream has no upsert of the terminal {terminal}; \
                 the answer to `restart-tab`, if the test sent it: {restarted:?}"
            ),
            Ok(StreamPoll::End) => panic!("the session event stream ended before the upsert"),
            Err(error) => panic!("session event stream item: {error}"),
        };
        let SessionEvent::Delta(delta) = item.value else { continue };
        let upsert = delta.changes.iter().find_map(|change| match change {
            ResourceChange::Upsert {
                id: ResourceReference::Terminal(id),
                value: ResourceEntitySnapshot::Terminal(row),
                ..
            } if id.as_str() == terminal => Some(row.clone()),
            _ => None,
        });
        let Some(row) = upsert else { continue };
        let ended = row.lifecycle == TerminalLifecycle::Exited;
        if restarted.is_none() && ended {
            // The list of a pass: the stream is open, and the row is there as ended.
            let listed = session.terminal_snapshots().expect("terminal list");
            let lifecycles = listed
                .iter()
                .filter(|row| row.id.as_str() == terminal)
                .map(|row| row.lifecycle)
                .collect::<Vec<_>>();
            assert_eq!(lifecycles, [TerminalLifecycle::Exited], "setup: the rows of {terminal}");
            let tab = &run["value"]["tab_id"];
            restarted = Some(owner.data(json!({"cmd": "restart-tab", "surface": tab})));
        } else if restarted.is_some() && !ended {
            break row;
        }
    };
    drop(events);
    owner.stop();
    eprintln!("{label}: after `restart-tab` the stream gives the terminal as {:?}", woke.lifecycle);
    let restarted = restarted.expect("the loop ends after the restart only");
    assert_eq!(restarted["terminal"], terminal, "`restart-tab` names another terminal");
}
