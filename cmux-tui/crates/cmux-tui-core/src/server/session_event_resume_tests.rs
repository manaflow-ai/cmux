//! A `session.events` resume and the live terminal facts
//! (`mux/terminal_live.rs`).
//!
//! A live fact moves no revision, so a cursor of `generation` and `revision`
//! does not say which live facts its client has. A connection that asks
//! (`session-live-cursor-v1` in `set-client-info`) gets a third cursor field,
//! `live`, and a resume from that cursor sends only the terminals whose live
//! facts changed after it. A client that polls with a new connection each
//! time (`cmux agents events --after`) otherwise gets the record of every
//! terminal with a live fact on each poll.
//!
//! A connection that does not ask keeps the cursor of two fields and gets
//! every such terminal on a resume.

use super::*;
use crate::Surface;
use crate::server::ClientTransport;
use crate::server::tests::captured_writer;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// The capability a connection sends to get the cursor's live position.
const LIVE_CURSOR: &str = "session-live-cursor-v1";
/// Test-only settle: a stream that sends no item for this long has sent
/// what it had.
const QUIET: Duration = Duration::from_millis(300);

/// An on-disk session of `workspaces` workspaces, of which `terminals` have
/// a terminal (a test terminal: no child process).
fn session(
    name: &str,
    workspaces: usize,
    terminals: usize,
) -> (PathBuf, Arc<Mux>, Vec<Arc<Surface>>) {
    let root = std::env::temp_dir()
        .join(format!("cmux-{name}-{}", crate::workspace_registry::new_uuid_v4()));
    let registry = crate::workspace_registry::WorkspaceRegistry::open(&root, name).unwrap();
    let mux = Mux::from_workspace_registry(
        name.to_owned(),
        crate::SurfaceOptions::default(),
        registry,
        crate::mux::ProviderWorkspaceState::default(),
        true,
    )
    .unwrap();
    mux.stop_journal_maintenance();
    let mut surfaces = Vec::with_capacity(terminals);
    for _ in 0..terminals {
        surfaces.push(mux.new_workspace(None, Some((80, 24))).unwrap());
    }
    for index in terminals..workspaces {
        mux.create_empty_workspace(Some(format!("idle {index}")), None, None).unwrap();
    }
    for surface in &surfaces {
        surface.publish_pending_directory();
        surface.publish_pending_progress();
    }
    assert!(
        mux.wait_for_terminal_publisher_for_test(Duration::from_secs(120)),
        "the terminal publisher did not drain"
    );
    (root, mux, surfaces)
}

fn terminal_id(surface: &Surface) -> String {
    surface.terminal_public_id().expect("a public terminal").as_str().to_owned()
}

fn terminal_ids(surfaces: &[Arc<Surface>]) -> Vec<String> {
    let mut ids: Vec<_> = surfaces.iter().map(|surface| terminal_id(surface)).collect();
    ids.sort();
    ids
}

/// Each of `surfaces`, in order, prints one line with a new OSC 9;4 value at
/// the clock's next step and publishes it: one live fact for each.
fn print(surfaces: &[Arc<Surface>], clock: &mut u64) {
    *clock += 5_000;
    for surface in surfaces {
        let frame = format!("\x1b]9;4;1;{}\x07line\r\n", (*clock / 5_000) % 100);
        surface.apply_stream_output_for_test(frame.as_bytes()).unwrap();
        surface.note_output_at_for_test(*clock);
        surface.publish_pending_state();
    }
}

/// One open `session.events` stream of its own connection.
struct Stream {
    outbound: Arc<crate::server::BoundedOutbound>,
    stream: OutboundStream,
    worker: std::thread::JoinHandle<()>,
    /// The response to the open request.
    opened: Value,
    requested: Instant,
}

/// Opens `session.events` on a new connection, from `cursor` when given.
/// `asks`: the connection sends `session-live-cursor-v1` first.
fn open(mux: &Arc<Mux>, asks: bool, number: u64, cursor: Option<&Value>) -> Stream {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    if asks {
        mux.control_clients
            .set_info(client, None, None, Some(vec![LIVE_CURSOR.to_owned()]))
            .unwrap();
    }
    let mut params = json!({
        "machine":"current",
        "session":"current",
        "stream_id":format!("stream_{number:012x}43338333{number:012x}"),
    });
    if let Some(cursor) = cursor {
        params["cursor"] = cursor.clone();
    }
    let message = json!({
        "protocol":"cmux.protocol/2",
        "type":"request",
        "id":"resume",
        "operation":"session.events",
        "params":params,
    });
    let request = crate::resource_router::parse_resource_request(&message.to_string()).unwrap();
    let requested = Instant::now();
    let (opened, start) = prepare_session_event_stream(mux, client, &writer, &request).unwrap();
    let stream = start.outbound.clone();
    let worker = {
        let mux = mux.clone();
        std::thread::spawn(move || run_session_event_stream(&mux, client, &writer, start))
    };
    Stream { outbound, stream, worker, opened, requested }
}

/// What a stream sent until it went quiet.
struct Sent {
    /// The stream messages (`stream_item` with its cursor and item).
    messages: Vec<Value>,
    /// The bytes of those messages as the connection writes them.
    bytes: usize,
    /// From the open request to the last message.
    last: Duration,
}

impl Sent {
    /// The id of each terminal upsert, in the order sent.
    fn terminal_records(&self) -> Vec<String> {
        let mut ids = Vec::new();
        for message in &self.messages {
            let changes =
                message["item"]["changes"].as_array().map(Vec::as_slice).unwrap_or_default();
            for change in changes {
                if change["resource"] == "terminal" && change["kind"] == "upsert" {
                    ids.push(change["id"].as_str().unwrap().to_owned());
                }
            }
        }
        ids
    }

    fn sorted_terminal_records(&self) -> Vec<String> {
        let mut ids = self.terminal_records();
        ids.sort();
        ids
    }
}

impl Stream {
    /// The messages until the stream sends none for [`QUIET`].
    fn drain(&self) -> Sent {
        let mut sent = Sent { messages: Vec::new(), bytes: 0, last: Duration::ZERO };
        let mut quiet_since = Instant::now();
        while quiet_since.elapsed() < QUIET {
            let Some(message) = self.outbound.try_pop() else {
                std::thread::sleep(Duration::from_micros(200));
                continue;
            };
            quiet_since = Instant::now();
            sent.last = self.requested.elapsed();
            sent.bytes += message.len() + 1;
            let message: Value = serde_json::from_str(&message).expect("outbound JSON");
            assert_eq!(message["type"], "stream_item", "{message}");
            sent.messages.push(message);
        }
        sent
    }

    fn close(self) {
        self.stream.close();
        self.worker.join().unwrap();
    }
}

/// The cursor a client holds after `sent`: the last message's.
fn last_cursor(sent: &Sent) -> Value {
    sent.messages.last().expect("the stream sent a message")["cursor"].clone()
}

#[cfg(unix)]
#[test]
fn a_resume_sends_only_the_live_records_after_its_cursor() {
    let (root, mux, terminals) = session("resume-bound", 12, 12);
    let mut clock = crate::workspace_registry::unix_epoch_ms().unwrap() + 60_000;
    // Each terminal has a live fact before a client connects.
    print(&terminals, &mut clock);

    let first = open(&mux, true, 1, None);
    let snapshot = first.drain();
    assert_eq!(snapshot.messages.len(), 1, "the open sends one snapshot");
    assert_eq!(snapshot.messages[0]["item"]["kind"], "snapshot");

    // Each terminal prints again: one live record for each.
    print(&terminals, &mut clock);
    let live = first.drain();
    assert_eq!(live.sorted_terminal_records(), terminal_ids(&terminals));
    let held = last_cursor(&live);
    let cursor_of = |surface: &Arc<Surface>| {
        let id = terminal_id(surface);
        live.messages
            .iter()
            .find(|message| message["item"]["changes"][0]["id"] == id.as_str())
            .unwrap_or_else(|| panic!("no live record of {id}"))["cursor"]
            .clone()
    };
    let middle = cursor_of(&terminals[7]);
    first.close();

    // At rest the client has every live fact: a resume sends no record.
    let at_rest = open(&mux, true, 2, Some(&held));
    let sent = at_rest.drain();
    assert_eq!(
        sent.terminal_records(),
        Vec::<String>::new(),
        "a resume at rest sent the records of live facts its cursor has"
    );
    at_rest.close();

    // Three terminals print after the cursor: a resume sends these three.
    print(&terminals[..3], &mut clock);
    let after = open(&mux, true, 3, Some(&held));
    assert_eq!(
        after.drain().sorted_terminal_records(),
        terminal_ids(&terminals[..3]),
        "records sent by a resume = the records after its cursor"
    );
    after.close();

    // A client that left in the middle of the burst (it has the record of
    // terminal 7) gets the terminals after it and the three that printed.
    let from_middle = open(&mux, true, 4, Some(&middle));
    let mut expected = terminal_ids(&terminals[8..]);
    expected.extend(terminal_ids(&terminals[..3]));
    expected.sort();
    assert_eq!(from_middle.drain().sorted_terminal_records(), expected);
    from_middle.close();

    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}

/// A replayed batch carries the live facts of its commit. They can be older
/// than a live item the client has (the stream sent that item before the
/// batch), and the live position of the cursor is after both: the resume
/// checks each terminal a replayed batch upserts again and sends its
/// current record when it differs.
#[cfg(unix)]
#[test]
fn a_resume_checks_again_each_terminal_a_replayed_batch_upserts() {
    let (root, mux, terminals) = session("resume-replay", 2, 2);
    let mut clock = crate::workspace_registry::unix_epoch_ms().unwrap() + 60_000;
    print(&terminals, &mut clock);
    let terminal = terminal_id(&terminals[0]);

    let first = open(&mux, true, 1, None);
    let before = last_cursor(&first.drain());
    // A durable edge: one commit, whose record has the progress of now.
    terminals[0].report_program_status_for_test(ghostty_vt::ProgramStatusState::Working, clock);
    terminals[0].publish_pending_state();
    let committed = first.drain();
    assert_eq!(committed.terminal_records(), [terminal.as_str()], "the edge is one batch");
    // Then a newer live fact.
    print(&terminals[..1], &mut clock);
    let live = first.drain();
    assert_eq!(live.terminal_records(), [terminal.as_str()], "one live record");
    let held = last_cursor(&live);
    let progress =
        |message: &Value| message["item"]["changes"][0]["value"]["extra"]["progress"].clone();
    let newest = progress(live.messages.last().unwrap());
    assert_ne!(progress(committed.messages.last().unwrap()), newest);
    first.close();

    // A client that has the live fact and not the batch.
    let mut cursor = before;
    cursor["live"] = held["live"].clone();
    let resumed = open(&mux, true, 2, Some(&cursor));
    let sent = resumed.drain();
    assert_eq!(
        sent.terminal_records(),
        [terminal.clone(), terminal],
        "the replayed batch, then the terminal's current record"
    );
    assert_eq!(
        progress(sent.messages.last().unwrap()),
        newest,
        "the client ends at the older fact"
    );
    assert_eq!(sent.messages.last().unwrap()["cursor"], held);
    resumed.close();

    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}

/// A live position this daemon process did not give (a daemon restart, or
/// a text a client made) names no change here: the resume sends every
/// terminal with a live fact, as for a cursor with no position.
#[cfg(unix)]
#[test]
fn a_live_position_of_another_daemon_process_sends_every_live_record() {
    let (root, mux, terminals) = session("resume-epoch", 3, 3);
    let mut clock = crate::workspace_registry::unix_epoch_ms().unwrap() + 60_000;
    print(&terminals, &mut clock);
    let first = open(&mux, true, 1, None);
    let held = last_cursor(&first.drain());
    first.close();
    let live = held["live"].as_str().expect("a live position");
    let (_, sequence) = live.rsplit_once('.').expect("epoch.sequence");

    for (number, position) in
        [format!("0123456789abcdef.{sequence}"), "no-position".to_owned(), format!("{live}9999")]
            .into_iter()
            .enumerate()
    {
        let mut cursor = held.clone();
        cursor["live"] = json!(position);
        let resumed = open(&mux, true, 2 + u64::try_from(number).unwrap(), Some(&cursor));
        assert_eq!(
            resumed.drain().sorted_terminal_records(),
            terminal_ids(&terminals),
            "the position {position}"
        );
        resumed.close();
    }

    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}

/// The other half of the compatibility pair: a client of a build before the
/// live position (it does not ask) against this daemon.
#[cfg(unix)]
#[test]
fn a_connection_that_does_not_ask_keeps_the_two_field_cursor_and_gets_every_live_record() {
    let (root, mux, terminals) = session("resume-plain", 6, 6);
    let mut clock = crate::workspace_registry::unix_epoch_ms().unwrap() + 60_000;
    print(&terminals, &mut clock);

    let plain = |cursor: &Value, what: &str| {
        let mut fields: Vec<_> = cursor.as_object().unwrap().keys().cloned().collect();
        fields.sort();
        assert_eq!(fields, ["generation", "revision"], "{what}: {cursor}");
    };
    let first = open(&mux, false, 1, None);
    plain(&first.opened["cursor"], "the cursor of the open response");
    let snapshot = first.drain();
    plain(&snapshot.messages[0]["cursor"], "the cursor of the snapshot message");
    plain(&snapshot.messages[0]["item"]["cursor"], "the cursor in the snapshot item");
    plain(&snapshot.messages[0]["item"]["snapshot"]["cursor"], "the cursor of the snapshot");

    print(&terminals, &mut clock);
    let live = first.drain();
    assert_eq!(live.sorted_terminal_records(), terminal_ids(&terminals));
    for message in &live.messages {
        plain(&message["cursor"], "the cursor of a live message");
        plain(&message["item"]["cursor"], "the cursor in a live item");
    }
    let held = last_cursor(&live);
    first.close();

    // Its cursor does not say which live facts it has: it gets them all.
    let resumed = open(&mux, false, 2, Some(&held));
    plain(&resumed.opened["cursor"], "the cursor of the resume response");
    assert_eq!(resumed.drain().sorted_terminal_records(), terminal_ids(&terminals));
    resumed.close();

    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
}

/// Measurement: ONE resume at rest on a session of 826 workspaces
/// (Lawrence's size) where 798 terminals have a live fact, for a connection
/// that does not ask (`plain`) and one that does (`live_cursor`).
///
/// Run it by name:
/// `cargo test -p cmux-tui-core --lib session_events_resume_cost -- --ignored --nocapture --test-threads 1`.
#[cfg(unix)]
#[test]
#[ignore = "measurement"]
fn session_events_resume_cost_on_826_workspaces() {
    const WORKSPACES: usize = 826;
    const LIVE: usize = 798;
    let (root, mux, terminals) = session("resume-cost", WORKSPACES, LIVE);
    let mut clock = crate::workspace_registry::unix_epoch_ms().unwrap() + 60_000;
    print(&terminals, &mut clock);

    let mut records = Vec::new();
    for (number, (arm, asks)) in [("plain", false), ("live_cursor", true)].into_iter().enumerate() {
        let number = u64::try_from(number).unwrap() * 10;
        let first = open(&mux, asks, number + 1, None);
        let snapshot = first.drain();
        assert_eq!(snapshot.messages.len(), 1, "the open sends one snapshot");
        print(&terminals, &mut clock);
        let live = first.drain();
        assert_eq!(live.terminal_records().len(), LIVE, "one live record for each terminal");
        let held = last_cursor(&live);
        first.close();

        for run in 0..5 {
            let resumed = open(&mux, asks, number + 2 + run, Some(&held));
            let open_time = resumed.requested.elapsed();
            let sent = resumed.drain();
            println!(
                "session_events_resume_cost: workspaces={WORKSPACES} live_marks={LIVE} arm={arm} run={run} \
                 records={} bytes={} open_ms={:.3} last_record_ms={:.3}",
                sent.terminal_records().len(),
                sent.bytes,
                open_time.as_secs_f64() * 1000.0,
                sent.last.as_secs_f64() * 1000.0,
            );
            if run == 0 {
                records.push(sent.terminal_records().len());
            }
            resumed.close();
        }
    }
    mux.shutdown();
    let _ = std::fs::remove_dir_all(&root);
    assert_eq!(records[0], LIVE, "a connection that does not ask gets every live record");
    assert_eq!(records[1], 0, "a resume at rest sent the records of live facts its cursor has");
}
