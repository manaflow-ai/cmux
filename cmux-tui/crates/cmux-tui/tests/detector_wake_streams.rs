//! The screen detector's two wake streams against a real headless owner
//! whose session holds more than a new session does.
//!
//! The detector (`bindings/examples/rust-agent-screen-detection`,
//! `scanner.rs`, `scan_connection`) follows the journal with its list of
//! kinds, opens the session event stream, reads the terminals, and then
//! reads the items of the two streams. The SDK decodes each item with a
//! strict type. An item that the type refuses ends the stream with an error:
//! the detector ends its pass and connects again. The first item of the
//! session event stream is the snapshot of the whole session, so ONE row
//! that the type refuses, anywhere in the session, ends each pass after its
//! first read of the terminals.
//!
//! Each test makes one kind of row in a session, makes the detector's calls
//! in the detector's order, and asserts that the first item decodes. A
//! failure prints the SDK's error text. The detector's list of journal kinds
//! is the detector's own file (`src/wake_kinds.rs`), compiled as a module.

#![cfg(unix)]

use crate::fault_support;

use crate::detector_wake_kinds;

use std::path::Path;
use std::time::{Duration, Instant};

use cmux::{
    Client, Config, EventStreamOptions, JournalSensitivity, JournalStart, Selector, Session,
    SessionEvent, SessionId, SessionJournalOptions, SessionJournalStream, StreamPoll,
    TerminalExitOutcome, TerminalLifecycle, TerminalSnapshot,
};
use detector_wake_kinds::journal_wake_kinds;
use fault_support::{FaultDir, NO_MAINTENANCE, Owner};
use serde_json::{Value, json};

const READY_BOUND: Duration = Duration::from_secs(60);
/// A liveness bound of the setup: how long a test waits for a row that its
/// own request makes.
const SETUP_BOUND: Duration = Duration::from_secs(60);

/// The terminals of the session with many terminals, and how many of their
/// tabs the test closes while their processes stay.
const STORED_TERMINALS: usize = 96;
const CLOSED_TABS: usize = 16;
const TABS_OF_A_WORKSPACE: usize = 12;

/// A process that stays and costs nothing.
fn idle_argv() -> Value {
    json!(["/bin/cat"])
}

/// What the detector has after its first calls on a session.
#[derive(Debug)]
struct FirstRead {
    /// The terminals of `terminal.list`.
    listed: usize,
    /// The listed terminals that `terminal.get` does not find.
    not_found: usize,
    /// The lifecycle of each listed terminal.
    lifecycles: Vec<TerminalLifecycle>,
    /// The rows of the snapshot, by kind.
    snapshot: String,
}

/// One listed terminal: its row of `terminal.list`, and what `terminal.get`
/// gave for its id (`None`: the get did not find it).
#[derive(Debug)]
struct TerminalRead {
    row: TerminalSnapshot,
    got: Option<TerminalSnapshot>,
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

/// The detector's journal stream: from the tail, `follow`, its own kinds.
fn follow_journal(session: &Session) -> Result<SessionJournalStream, String> {
    session
        .journal(SessionJournalOptions {
            start: Some(JournalStart::Tail),
            follow: Some(true),
            kinds: journal_wake_kinds(),
            max_sensitivity: Some(JournalSensitivity::Sensitive),
            ..Default::default()
        })
        .map_err(|error| format!("journal stream open: {error}"))
}

/// The detector's first calls in the detector's order: the two streams, the
/// list of the terminals, one read of each listed terminal, then the first
/// item of the session event stream. The error names the call that failed
/// and holds the SDK's text.
fn detector_first_read(socket: &Path, session_name: &str) -> Result<FirstRead, String> {
    detector_reads(socket, session_name).map(|(read, _)| read)
}

/// [`detector_first_read`], and each listed terminal with what its read gave.
fn detector_reads(
    socket: &Path,
    session_name: &str,
) -> Result<(FirstRead, Vec<TerminalRead>), String> {
    let (_client, session) = sdk_session(socket, session_name)?;
    let _journal = follow_journal(&session)?;
    let mut records = session
        .events(EventStreamOptions::default())
        .map_err(|error| format!("session event stream open: {error}"))?;
    let listed = session.terminal_snapshots().map_err(|error| format!("terminal list: {error}"))?;
    let mut terminals = Vec::with_capacity(listed.len());
    for row in listed {
        let got = match session.terminal(row.id.clone()).refresh() {
            Ok(got) => Some(got),
            Err(cmux::Error::Protocol { ref code, .. })
                if code == "selector.not_found" || code == "resource.not_found" =>
            {
                None
            }
            Err(error) => return Err(format!("terminal get of {}: {error}", row.id)),
        };
        terminals.push(TerminalRead { row, got });
    }
    let first = records
        .recv()
        .map_err(|error| format!("first item of the session event stream: {error}"))?;
    let Some(item) = first else {
        return Err("the session event stream ended before its first item".into());
    };
    let event = match item.value {
        SessionEvent::Snapshot(event) => event,
        other => {
            return Err(format!(
                "the first item of the session event stream is not a snapshot: {other:?}"
            ));
        }
    };
    let rows = event.snapshot;
    let read = FirstRead {
        listed: terminals.len(),
        not_found: terminals.iter().filter(|terminal| terminal.got.is_none()).count(),
        lifecycles: terminals.iter().map(|terminal| terminal.row.lifecycle).collect(),
        snapshot: format!(
            "workspaces {} screens {} panes {} tabs {} terminals {} browsers {} clients {} \
             notifications {} agents {} frontend_projections {} sidebar_views {}",
            rows.workspaces.len(),
            rows.screens.len(),
            rows.panes.len(),
            rows.tabs.len(),
            rows.terminals.len(),
            rows.browsers.len(),
            rows.clients.len(),
            rows.notifications.len(),
            rows.agents.len(),
            rows.frontend_projections.len(),
            rows.sidebar_views.len(),
        ),
    };
    Ok((read, terminals))
}

/// The detector's pass does not end on a session that `setup` made.
fn decodes_after(label: &str, setup: impl FnOnce(&Owner<'_>)) -> FirstRead {
    let dir = FaultDir::new(label);
    let owner = Owner::start(&dir, label, &[NO_MAINTENANCE], READY_BOUND);
    setup(&owner);
    let read = detector_first_read(&dir.socket(), label);
    owner.stop();
    match read {
        Ok(read) => {
            eprintln!("{label}: {read:?}");
            read
        }
        Err(error) => panic!("the detector's pass on the session `{label}` ends: {error}"),
    }
}

/// The workspace named `name` in the owner's tree.
fn workspace(owner: &Owner<'_>, name: &str) -> Value {
    let tree = owner.data(json!({"cmd": "list-workspaces"}));
    tree["workspaces"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|workspace| workspace["name"] == name)
        .unwrap_or_else(|| panic!("setup: no workspace {name}: {tree}"))
        .clone()
}

/// A new workspace named `name` with one terminal; its first pane and the
/// surface of its first tab.
fn new_workspace(owner: &Owner<'_>, name: &str) -> (Value, Value) {
    owner.data(json!({"cmd": "new-workspace", "name": name, "cols": 160, "rows": 40}));
    let made = workspace(owner, name);
    let pane = made["screens"][0]["panes"][0].clone();
    assert!(!pane["id"].is_null(), "setup: the workspace {name} has no pane: {made}");
    (pane["id"].clone(), pane["tabs"][0]["surface"].clone())
}

/// A workspace named `name` with two columns; the pane of the left column.
fn left_of_two_columns(owner: &Owner<'_>, name: &str) -> Value {
    let (left, _) = new_workspace(owner, name);
    owner.data(json!({"cmd": "new-pane-right", "pane": left, "width": 0.5}));
    let made = workspace(owner, name);
    let columns = made["screens"][0]["columns"].as_array().map_or(0, Vec::len);
    assert_eq!(columns, 2, "setup: the workspace {name} does not have 2 columns: {made}");
    left
}

/// Docks the left column of a new workspace with two columns. `flags` are
/// the members of `set-column-dock` beside the edge and the mode.
fn dock_left_column(owner: &Owner<'_>, flags: Value) {
    let left = left_of_two_columns(owner, "dock");
    let mut request = json!({
        "cmd": "set-column-dock", "pane": left, "dock": true, "edge": "left", "mode": "docked",
    });
    for (name, value) in flags.as_object().into_iter().flatten() {
        request[name] = value.clone();
    }
    let data = owner.data(request);
    assert!(data["dock"].is_object(), "setup: the column is not docked: {data}");
}

/// Control: a session with one workspace and one terminal.
#[test]
fn detector_wake_streams_decode_a_session_with_one_terminal() {
    let read = decodes_after("dws-one", |owner| {
        new_workspace(owner, "plain");
    });
    assert!(read.listed >= 1, "setup: no terminal is listed: {read:?}");
}

#[test]
fn detector_wake_streams_decode_a_session_with_an_agent_chat_tab() {
    decodes_after("dws-chat", |owner| {
        let (pane, _) = new_workspace(owner, "chat");
        owner.data(json!({
            "cmd": "new-conversation-tab", "pane": pane,
            "agent_session": {
                "host": "install:detector-wake-streams",
                "session": "ses-detector-wake-streams",
                "harness": "codex",
            },
        }));
    });
}

#[test]
fn detector_wake_streams_decode_a_session_with_a_page_tab() {
    decodes_after("dws-page", |owner| {
        let (pane, _) = new_workspace(owner, "page");
        owner.data(json!({"cmd": "new-conversation-tab", "pane": pane, "page": "settings"}));
    });
}

#[test]
fn detector_wake_streams_decode_a_session_with_a_browser_tab() {
    decodes_after("dws-browser", |owner| {
        let (pane, _) = new_workspace(owner, "browser");
        owner.data(json!({
            "cmd": "new-frontend-browser-tab", "pane": pane,
            "url": "https://example.com/detector-wake-streams", "engine": "webkit",
        }));
    });
}

/// Control for the docked columns: a dock with an edge and a mode only.
#[test]
fn detector_wake_streams_decode_a_session_with_a_docked_column() {
    decodes_after("dws-dock", |owner| dock_left_column(owner, json!({})));
}

#[test]
fn detector_wake_streams_decode_a_session_with_an_agent_chat_column() {
    decodes_after("dws-role", |owner| dock_left_column(owner, json!({"role": "agent_chat"})));
}

#[test]
fn detector_wake_streams_decode_a_session_with_a_permanent_column() {
    decodes_after("dws-perm", |owner| {
        dock_left_column(owner, json!({"role": "agent_chat", "permanent": true}));
    });
}

#[test]
fn detector_wake_streams_decode_a_session_with_a_pinned_column() {
    decodes_after("dws-pin", |owner| {
        dock_left_column(owner, json!({"role": "agent_chat", "pinned": true}));
    });
}

#[test]
fn detector_wake_streams_decode_a_session_with_a_notification() {
    decodes_after("dws-note", |owner| {
        let (_, surface) = new_workspace(owner, "note");
        owner.data(json!({
            "cmd": "notify", "title": "detector wake streams", "body": "one notification",
            "surface": surface,
        }));
    });
}

#[test]
fn detector_wake_streams_decode_a_session_with_an_agent_report() {
    decodes_after("dws-agent", |owner| {
        let (_, surface) = new_workspace(owner, "agent");
        owner.data(json!({
            "cmd": "report-agent", "surface": surface, "source": "hook", "state": "working",
        }));
    });
}

#[test]
fn detector_wake_streams_decode_a_session_with_a_frontend_projection() {
    decodes_after("dws-proj", |owner| {
        new_workspace(owner, "projection");
        owner.data(json!({
            "cmd": "put-frontend-projection", "frontend": "cmux-next", "scope": "personal",
            "subject_key": "windows", "schema_version": 1,
            "projection": {"pad": "detector wake streams"},
            "origin": "test", "mutation_id": "dws-projection",
        }));
    });
}

/// Waits until `terminal.list` holds a terminal that ended and has no tab,
/// and each other listed terminal runs (one of them at least). A wait on
/// that state with the liveness bound `SETUP_BOUND` (60 s): after the bound
/// the test fails as `setup:`.
fn wait_for_an_ended_terminal_with_no_tab(socket: &Path, session_name: &str) {
    let (_client, session) =
        sdk_session(socket, session_name).unwrap_or_else(|error| panic!("setup: {error}"));
    let deadline = Instant::now() + SETUP_BOUND;
    loop {
        let listed = session.terminal_snapshots().unwrap_or_else(|error| {
            panic!("the terminal list on the session `{session_name}` fails: {error}")
        });
        let (ended, others): (Vec<_>, Vec<_>) =
            listed.iter().partition(|terminal| terminal.lifecycle == TerminalLifecycle::Exited);
        let no_tab = ended.iter().any(|terminal| terminal.tab_ids.is_empty());
        let others_run =
            others.iter().all(|terminal| terminal.lifecycle == TerminalLifecycle::Running);
        if no_tab && !others.is_empty() && others_run {
            return;
        }
        let seen = listed
            .iter()
            .map(|terminal| (terminal.lifecycle, terminal.tab_ids.len()))
            .collect::<Vec<_>>();
        assert!(
            Instant::now() < deadline,
            "setup: within {SETUP_BOUND:?} the list has no ended terminal with no tab beside \
             terminals that run; the lifecycle and the tab count of each listed terminal: \
             {seen:?}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

/// A terminal whose process ended and whose tab went, beside a terminal that
/// runs. The process ends by itself (`exit 3`) under the default on-exit
/// policy: the owner takes the tab away and keeps the row of the terminal,
/// and `terminal.list` gives that row until a `terminal.close`. The
/// detector's calls find each listed terminal, the read of the ended one
/// gives its list row, and the first item of the session event stream decodes
/// after the reads.
///
/// This proves that the detector's calls go on with such a row in the list.
/// It does not run the detector's binary: `detector_reads` makes the calls.
#[test]
fn detector_wake_streams_decode_a_session_with_a_terminal_that_ended() {
    let label = "dws-ended";
    let dir = FaultDir::new(label);
    let owner = Owner::start(&dir, label, &[NO_MAINTENANCE], READY_BOUND);
    new_workspace(&owner, "stays");
    owner.data(json!({
        "cmd": "run", "argv": ["/bin/sh", "-c", "exit 3"], "new_workspace": true, "name": "ended",
    }));
    wait_for_an_ended_terminal_with_no_tab(&dir.socket(), label);
    let reads = detector_reads(&dir.socket(), label);
    owner.stop();
    let (read, terminals) = reads.unwrap_or_else(|error| {
        panic!("the detector's pass on the session `{label}` ends: {error}")
    });
    eprintln!("{label}: {read:?}");
    assert!(
        read.lifecycles.contains(&TerminalLifecycle::Exited),
        "setup: the detector's list had no terminal that ended: {read:?}"
    );
    let (ended, others): (Vec<_>, Vec<_>) =
        terminals.iter().partition(|terminal| terminal.row.lifecycle == TerminalLifecycle::Exited);
    assert_eq!(
        ended.len(),
        1,
        "setup: the list does not have 1 terminal that ended: {terminals:?}"
    );
    let ended = ended[0];
    assert!(ended.row.tab_ids.is_empty(), "setup: the ended terminal has a tab: {ended:?}");
    assert!(
        !others.is_empty()
            && others.iter().all(|terminal| terminal.row.lifecycle == TerminalLifecycle::Running),
        "setup: the other listed terminals do not all run, or there is none: {terminals:?}"
    );
    assert_eq!(
        read.not_found, 0,
        "`terminal.get` does not find {} of the {} terminals that `terminal.list` gives: \
         {terminals:?}",
        read.not_found, read.listed
    );
    assert_eq!(
        ended.got.as_ref(),
        Some(&ended.row),
        "`terminal.get` of the ended terminal does not give its row of `terminal.list`"
    );
    assert!(!ended.row.running, "the ended terminal runs: {ended:?}");
    assert_eq!(
        ended.row.exit.as_ref().map(|exit| &exit.outcome),
        Some(&TerminalExitOutcome::Exit { code: 3 }),
        "the ended terminal does not hold the exit code of its process: {ended:?}"
    );
    for terminal in others {
        assert_eq!(
            terminal.got.as_ref().map(|got| got.lifecycle),
            Some(TerminalLifecycle::Running),
            "`terminal.get` of a terminal that runs does not give a terminal that runs: \
             {terminal:?}"
        );
    }
}

/// Many terminals, and a part of them with no tab: the test closes their
/// tabs and keeps their processes. The owner lists each terminal still, with
/// a tab or with none.
#[test]
fn detector_wake_streams_decode_a_session_with_many_terminals_and_closed_tabs() {
    let label = "dws-many";
    let dir = FaultDir::new(label);
    let owner = Owner::start(&dir, label, &[NO_MAINTENANCE], READY_BOUND);
    let workspaces = STORED_TERMINALS / TABS_OF_A_WORKSPACE;
    for index in 0..workspaces {
        let name = format!("many-{index}");
        owner.data(json!({"cmd": "run", "argv": idle_argv(), "new_workspace": true, "name": name}));
        let pane = workspace(&owner, &name)["screens"][0]["panes"][0]["id"].clone();
        assert!(!pane.is_null(), "setup: the workspace {name} has no pane");
        for _ in 1..TABS_OF_A_WORKSPACE {
            owner.data(json!({"cmd": "run", "argv": idle_argv(), "pane": pane}));
        }
    }
    // The tabs to close: the last tabs of the first workspaces, never the
    // first tab of a workspace.
    let of_a_workspace = 4;
    let mut surfaces = Vec::new();
    for index in 0..CLOSED_TABS / of_a_workspace {
        let made = workspace(&owner, &format!("many-{index}"));
        let tabs = made["screens"][0]["panes"][0]["tabs"].as_array().cloned().unwrap_or_default();
        assert_eq!(tabs.len(), TABS_OF_A_WORKSPACE, "setup: the tabs of many-{index}: {made}");
        surfaces.extend(tabs.iter().rev().take(of_a_workspace).map(|tab| tab["surface"].clone()));
    }
    assert_eq!(surfaces.len(), CLOSED_TABS, "setup: the tabs to close");
    owner.data(json!({"cmd": "close-tabs", "surfaces": surfaces, "end_terminals": false}));
    let read = detector_first_read(&dir.socket(), label);
    owner.stop();
    let read = read.unwrap_or_else(|error| {
        panic!("the detector's pass on the session `{label}` ends: {error}")
    });
    eprintln!("{label}: {read:?}");
    assert!(
        read.listed >= STORED_TERMINALS,
        "setup: {} terminals are listed (`terminal.get` does not find {} of them); wanted \
         {STORED_TERMINALS}: {}",
        read.listed,
        read.not_found,
        read.snapshot
    );
}

/// The journal stream: the first record that the owner writes for a new
/// terminal decodes.
#[test]
fn detector_wake_streams_decode_a_journal_record_of_a_new_terminal() {
    let label = "dws-journal";
    let dir = FaultDir::new(label);
    let owner = Owner::start(&dir, label, &[NO_MAINTENANCE], READY_BOUND);
    new_workspace(&owner, "first");
    let (_client, session) =
        sdk_session(&dir.socket(), label).unwrap_or_else(|error| panic!("setup: {error}"));
    let mut journal = follow_journal(&session).unwrap_or_else(|error| panic!("{error}"));
    owner.data(json!({"cmd": "run", "argv": idle_argv(), "new_workspace": true, "name": "new"}));
    let item = journal.next_timeout(SETUP_BOUND);
    drop(journal);
    owner.stop();
    match item {
        Ok(StreamPoll::Item(item)) => eprintln!("{label}: a record of kind {}", item.value.kind),
        Ok(StreamPoll::TimedOut) => panic!(
            "setup: the owner wrote no journal record of the detector's kinds for a new \
             terminal within {SETUP_BOUND:?}"
        ),
        Ok(StreamPoll::End) => panic!("the journal stream ended before its first record"),
        Err(error) => {
            panic!("the detector's pass on the session `{label}` ends: journal record: {error}")
        }
    }
}
