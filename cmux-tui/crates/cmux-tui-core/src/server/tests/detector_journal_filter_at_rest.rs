//! The screen detector's journal stream keeps a session at rest.
//!
//! The bundled screen detector follows the journal with its own kind list
//! (`bindings/examples/rust-agent-screen-detection/src/wake_kinds.rs`) and
//! appends a `plugin.<id>.agent.state.changed` row when an agent's state
//! changes. A terminal that only prints is a live fact and no journal row
//! (`mux/tests/at_rest_writers.rs`), but while a journal stream follows the
//! kinds of live facts each one is a row again
//! (`terminal_progress_follower.rs`). The detector's list must match none of
//! those kinds, or each printing terminal costs one commit per 5 s.
//!
//! These tests run the scenario of `at_rest_writers.rs` (30 printing
//! terminals, 5 simulated minutes; 1, 60 and 826 workspaces) with the 2
//! streams that the detector opens on one connection (`scanner.rs`,
//! `scan_connection`): its journal stream through `session.journal.subscribe`
//! (the detector's own list, compiled in from its file) and its
//! `session.events` stream, which a thread reads to its end as the detector's
//! connection does. The detector's rows are appended before the span through
//! `session.journal.append`. The span must add no journal row, no revision,
//! no WAL commit and no WAL byte, and the events stream must get the live
//! facts of the span as items that move no revision.
//!
//! Not in the count: no detector process runs here, so when a real detector
//! appends (its screen reads and its state rule) is not measured.

#![cfg(unix)]

use super::*;
use crate::mux::tests::at_rest_writers::{AfterSpan, printing_terminals_at_rest_with};

#[path = "../../../../../bindings/examples/rust-agent-screen-detection/src/wake_kinds.rs"]
mod detector_wake_kinds;

use detector_wake_kinds::journal_wake_kinds;

const PLUGIN: &str = "detector_at_rest_test";
const DETECTOR_STREAM: &str = "stream_00000000000000000000000000000d01";
const CONTROL_STREAM: &str = "stream_00000000000000000000000000000d02";
const EVENTS_STREAM: &str = "stream_00000000000000000000000000000d03";
const EVENTS_CANCEL: &str = "detector-events-cancel";
/// The most that the test waits for a message of the daemon. A failure bound
/// only: no result depends on it.
const MESSAGE_BOUND: Duration = Duration::from_secs(30);

/// A local client of the session.
struct Client {
    id: u64,
    writer: MessageWriter,
    outbound: Arc<BoundedOutbound>,
    scheduler: Arc<ConnectionSurfaceScheduler>,
}

impl Client {
    fn connect(mux: &Arc<Mux>) -> Self {
        let (writer, outbound) = captured_writer();
        let id = mux.control_clients.register(ClientTransport::Unix, writer.clone());
        let scheduler =
            Arc::new(ConnectionSurfaceScheduler::new(mux.surface_operation_admission.clone()));
        Self { id, writer, outbound, scheduler }
    }

    /// Sends `request` and returns the reply to `id`; stream items that come
    /// before it are skipped.
    fn request(&self, mux: &Arc<Mux>, id: &str, request: &str) -> Value {
        assert!(
            handle_connection_message(mux, self.id, request, &self.writer, &self.scheduler),
            "the connection closed on the request {id}"
        );
        loop {
            let message = pop_json(&self.outbound);
            if message["id"] == id {
                return message;
            }
        }
    }
}

/// The detector's producer manifest (`scanner.rs`, `producer_manifest`) for
/// the test's plugin id.
fn producer_manifest() -> Value {
    let event = |name: &str| {
        json!({
            "kind": format!("plugin.{PLUGIN}.agent.{name}"),
            "schema_version": 1,
            "class": "state",
            "replay": "required",
            "sensitivity": "sensitive",
            "payload_schema": {
                "type": "object",
                "required": ["format", "plugin", "adapter", "event", "normalized"],
                "properties": {
                    "format": {"const": "cmux.agent-plugin.v1"},
                    "plugin": {
                        "type": "object",
                        "required": ["id", "version"],
                        "properties": {
                            "id": {"type": "string"},
                            "version": {"type": "integer", "minimum": 1}
                        },
                        "additionalProperties": false
                    },
                    "adapter": {
                        "type": "object",
                        "required": ["id", "version"],
                        "properties": {
                            "id": {"type": "string"},
                            "version": {"type": "integer", "minimum": 1}
                        },
                        "additionalProperties": false
                    },
                    "event": {"enum": ["state.changed", "session.ended"]},
                    "normalized": {
                        "type": "object",
                        "required": ["state", "source_session", "observed_at_ms"],
                        "properties": {
                            "state": {"enum": ["working", "blocked", "idle", "done", "unknown"]},
                            "source_session": {"type": "string"},
                            "plugin_generation": {"type": "string", "pattern": "^[0-9]+$"},
                            "observed_at_ms": {"type": "string", "pattern": "^[0-9]+$"}
                        },
                        "additionalProperties": false
                    },
                    "native": {"type": "object"}
                },
                "additionalProperties": false
            },
        })
    };
    json!({
        "producer_id": PLUGIN,
        "namespace": format!("plugin.{PLUGIN}"),
        "manifest_version": 1,
        "max_sensitivity": "sensitive",
        "permissions": [format!("journal.append.plugin.{PLUGIN}")],
        "events": [event("state.changed"), event("session.ended")],
    })
}

fn state_changed_kind() -> String {
    format!("plugin.{PLUGIN}.agent.state.changed")
}

/// The detector's report that the agent on `terminal` works (`scanner.rs`,
/// `prepare_emission`).
fn working_report(terminal: &str, observed_at_ms: u64) -> Value {
    json!({
        "producer_id": PLUGIN,
        "manifest_version": 1,
        "kind": state_changed_kind(),
        "schema_version": 1,
        "occurred_at_ms": observed_at_ms.to_string(),
        "subjects": [{"kind": "terminal", "id": terminal}],
        "sensitivity": "sensitive",
        "payload": {
            "format": "cmux.agent-plugin.v1",
            "plugin": {"id": PLUGIN, "version": 1},
            "adapter": {"id": "claude", "version": 1},
            "event": "state.changed",
            "normalized": {
                "state": "working",
                "source_session": format!("terminal:{terminal}"),
                "observed_at_ms": observed_at_ms.to_string(),
            },
            "native": {
                "engine": "herdr-manifest-v3",
                "matched_rule": "at-rest-test",
                "visible": {"idle": false, "blocker": false, "working": true},
            },
        },
    })
}

/// A live journal stream from the tail, as the detector opens it
/// (`scanner.rs`, `scan_connection`).
fn follow_request(stream: &str, kinds: &[String]) -> String {
    resource_request(
        stream,
        "session.journal.subscribe",
        json!({
            "machine": "current",
            "session": "current",
            "stream_id": stream,
            "start": "tail",
            "follow": true,
            "filter": journal_subscription_filter(
                JournalSensitivity::Sensitive,
                json!({"kinds": kinds}),
            ),
        }),
        None,
    )
}

/// The detector's `session.events` stream (`scanner.rs`, `scan_connection`:
/// `session.events(EventStreamOptions::default())`, so no cursor).
fn events_request() -> String {
    resource_request(
        EVENTS_STREAM,
        "session.events",
        json!({"machine": "current", "session": "current", "stream_id": EVENTS_STREAM}),
        None,
    )
}

/// Reads each message that the daemon sends to `outbound`, as the thread of
/// the detector's connection does, until the queue closes.
fn read_connection(
    outbound: Arc<BoundedOutbound>,
) -> (std::sync::mpsc::Receiver<Value>, JoinHandle<()>) {
    let (messages, receiver) = std::sync::mpsc::channel();
    let reader = std::thread::spawn(move || {
        while let Some(item) = outbound.recv() {
            match item {
                OutboundItem::Text(text) => {
                    let message: Value = serde_json::from_str(&text).expect("outbound JSON");
                    if messages.send(message).is_err() {
                        return;
                    }
                }
                OutboundItem::Flush(flushed) => {
                    let _ = flushed.send(());
                }
            }
        }
    });
    (receiver, reader)
}

/// What the detector's connection got after its 2 streams opened.
#[derive(Debug, Default)]
struct Received {
    /// Snapshot items of the events stream.
    snapshots: usize,
    /// Delta items of the events stream.
    deltas: usize,
    /// Of `deltas`: the items that move no revision (live facts).
    live_deltas: usize,
    /// Items of the events stream of another kind.
    other_event_items: Vec<String>,
    /// Items of the journal stream.
    journal_items: usize,
    /// Each stream end: the stream and its reason.
    ends: Vec<(String, String)>,
    /// The reply to the cancel of the events stream.
    cancel_reply: Option<Value>,
}

impl Received {
    fn note(&mut self, message: Value) {
        let text = |value: &Value| value.as_str().unwrap_or_default().to_owned();
        let kind = text(&message["type"]);
        match kind.as_str() {
            "stream_item" if message["stream_id"] == EVENTS_STREAM => {
                let item = &message["item"];
                match item["kind"].as_str() {
                    Some("snapshot") => self.snapshots += 1,
                    Some("delta") => {
                        self.deltas += 1;
                        if item["revision"].is_string()
                            && item["previous_revision"] == item["revision"]
                        {
                            self.live_deltas += 1;
                        }
                    }
                    _ => self.other_event_items.push(item["kind"].to_string()),
                }
            }
            "stream_item" if message["stream_id"] == DETECTOR_STREAM => {
                self.journal_items += 1;
            }
            "stream_end" => {
                self.ends.push((text(&message["stream_id"]), text(&message["reason"])));
            }
            "response" if message["id"] == EVENTS_CANCEL => {
                self.cancel_reply = Some(message);
            }
            _ => {}
        }
    }

    /// Takes the next message; false when none comes in the bound.
    fn take(&mut self, messages: &std::sync::mpsc::Receiver<Value>) -> bool {
        match messages.recv_timeout(MESSAGE_BOUND) {
            Ok(message) => {
                self.note(message);
                true
            }
            Err(_) => false,
        }
    }
}

/// The kinds of the journal rows after `sequence`.
fn kinds_after(mux: &Mux, mut sequence: u64) -> Vec<String> {
    let mut kinds = Vec::new();
    loop {
        let page = mux.session_journal_after(sequence, 500).unwrap();
        let Some(last) = page.records.last() else { return kinds };
        sequence = last.sequence;
        kinds.extend(page.records.iter().map(|record| record.kind.clone()));
    }
}

/// The terminal prints and reports a progress value: live facts only.
fn live_fact(surface: &crate::Surface, progress: u8, at_ms: u64) {
    surface
        .apply_stream_output_for_test(format!("\x1b]9;4;1;{progress}\x07line\r\n").as_bytes())
        .unwrap();
    surface.note_output_at_for_test(at_ms);
    surface.publish_pending_state();
}

/// The detector's client on the session, before the span at rest: its
/// manifest, its journal stream with its own kind list, its events stream,
/// and one report for each printing terminal. After the span: the journal
/// stream is still a live follower with that list, a control shows that this
/// session does make a live fact a row for a stream that follows
/// `terminal.*`, and the events stream got the live facts and ends only when
/// the client cancels it.
fn attach_detector(mux: &Arc<Mux>, terminals: &[Arc<crate::Surface>]) -> AfterSpan {
    let kinds = journal_wake_kinds();
    let head = mux.session_journal_head().unwrap();

    let requests = Client::connect(mux);
    let put = resource_request(
        "detector-manifest",
        "session.journal.producer.put",
        json!({"machine": "current", "session": "current", "manifest": producer_manifest()}),
        Some("detector-at-rest-manifest"),
    );
    let installed = requests.request(mux, "detector-manifest", &put);
    assert_eq!(installed["ok"], true, "the detector's manifest was refused: {installed}");

    let follower = Client::connect(mux);
    let opened = follower.request(mux, DETECTOR_STREAM, &follow_request(DETECTOR_STREAM, &kinds));
    assert_eq!(
        opened["ok"],
        true,
        "the daemon refused the detector's journal filter of {} kinds: {opened}",
        kinds.len()
    );
    let events = follower.request(mux, EVENTS_STREAM, &events_request());
    assert_eq!(events["ok"], true, "the daemon refused the detector's events stream: {events}");
    // From here a thread takes each message of the detector's connection, so
    // no stream of it waits on a reader.
    let (messages, reader) = read_connection(Arc::clone(&follower.outbound));

    let observed_at_ms = crate::workspace_registry::unix_epoch_ms().unwrap();
    for (index, surface) in terminals.iter().enumerate() {
        let terminal = surface.terminal_public_id().expect("a public terminal").as_str();
        let id = format!("detector-report-{index}");
        let key = format!("detector-at-rest-report-{index}");
        let append = resource_request(
            &id,
            "session.journal.append",
            json!({
                "machine": "current",
                "session": "current",
                "event": working_report(terminal, observed_at_ms),
            }),
            Some(&key),
        );
        let appended = requests.request(mux, &id, &append);
        assert_eq!(appended["ok"], true, "the detector's report was refused: {appended}");
    }
    // The roster's owner folds and saves after the request answered; the
    // span starts with nothing left to write.
    assert!(mux.settle_agent_roster_for_test(), "the agent roster's owner did not settle");
    assert!(
        mux.wait_for_terminal_publisher_for_test(Duration::from_secs(30)),
        "the terminal publisher did not drain"
    );
    let attached = kinds_after(mux, head);
    let report_kind = state_changed_kind();
    let reports = attached.iter().filter(|kind| **kind == report_kind).count();
    println!(
        "detector_journal_filter_at_rest: before the span the detector's client added {} journal \
         rows, {reports} of them its reports",
        attached.len()
    );
    assert_eq!(
        reports,
        terminals.len(),
        "each first report of the detector is one journal row; the rows were {attached:?}"
    );

    let printing = Arc::clone(&terminals[1]);
    Box::new(move |mux: &Arc<Mux>| {
        let mut failures = Vec::new();
        let mut wanted = kinds;
        wanted.sort_unstable();
        let stats = mux.journal_followers_stats();
        match stats.followers.iter().find(|row| row.stream_id == DETECTOR_STREAM) {
            None => failures.push(format!(
                "the detector's stream has no follower row after the span: {stats:?}"
            )),
            Some(row) => {
                let mut sent = row.kinds.clone();
                sent.sort_unstable();
                if row.left_ms.is_some()
                    || sent != wanted
                    || row.keeps_hook_rows
                    || row.keeps_report_rows
                {
                    failures.push(format!(
                        "the detector's follower row after the span must be live, have the \
                         detector's {} kinds and keep no hook row and no report row: {row:?}",
                        wanted.len()
                    ));
                }
            }
        }

        // The events stream got the live facts of the span, so the count of
        // the span is not 0 because that stream was idle. Read here: after
        // this the control makes live facts of its own.
        let mut received = Received::default();
        while received.live_deltas == 0 && received.take(&messages) {}
        if received.live_deltas == 0 {
            failures.push(format!(
                "the detector's events stream must get the live facts of the span as delta \
                 items that move no revision: {received:?}"
            ));
        }

        // Control: with the detector's 2 streams alone a live fact is no row;
        // with a stream that follows `terminal.*` the same fact is a row. So
        // the count of the span is not 0 because the session sees no stream.
        let at_ms = crate::workspace_registry::unix_epoch_ms().unwrap() + 3_600_000;
        let head = mux.session_journal_head().unwrap();
        live_fact(&printing, 77, at_ms);
        let alone = kinds_after(mux, head);
        if !alone.is_empty() {
            failures.push(format!(
                "a live fact was a journal row with the detector's 2 streams alone: {alone:?}"
            ));
        }
        let control = Client::connect(mux);
        let request = follow_request(CONTROL_STREAM, &["terminal.*".to_owned()]);
        let opened = control.request(mux, CONTROL_STREAM, &request);
        let head = mux.session_journal_head().unwrap();
        live_fact(&printing, 78, at_ms + 5_000);
        let followed = kinds_after(mux, head);
        if opened["ok"] != true || followed.is_empty() {
            failures.push(format!(
                "control: with a stream that follows `terminal.*` a live fact must be a journal \
                 row; the stream's reply was {opened}, the rows were {followed:?}"
            ));
        }

        // The 2 streams of the detector's connection are open until the
        // client cancels the events stream.
        let cancel = resource_request(
            EVENTS_CANCEL,
            "stream.cancel",
            json!({"machine": "current", "session": "current", "stream": EVENTS_STREAM}),
            None,
        );
        if !handle_connection_message(
            mux,
            follower.id,
            &cancel,
            &follower.writer,
            &follower.scheduler,
        ) {
            failures.push("the detector's connection closed on the cancel".to_owned());
        }
        while received.cancel_reply.is_none() && received.take(&messages) {}
        println!(
            "detector_journal_filter_at_rest: the detector's events stream got {} snapshot \
             items and {} delta items ({} of them move no revision); its journal stream got {} \
             items",
            received.snapshots, received.deltas, received.live_deltas, received.journal_items
        );
        let canceled = vec![(EVENTS_STREAM.to_owned(), "canceled".to_owned())];
        if received.snapshots == 0
            || !received.other_event_items.is_empty()
            || received.ends != canceled
            || received.cancel_reply.as_ref().is_none_or(|reply| reply["ok"] != true)
        {
            failures.push(format!(
                "the detector's events stream must get its snapshot and then delta items only, \
                 and no stream of the connection must end before the client's cancel: \
                 {received:?}"
            ));
        }

        for client in [&requests, &follower, &control] {
            disconnect_client(mux, client.id, false);
        }
        follower.outbound.close();
        if reader.join().is_err() {
            failures.push("the reader of the detector's connection panicked".to_owned());
        }
        failures
    })
}

#[test]
fn printing_terminals_with_the_detector_stream_write_nothing_on_1_workspace() {
    printing_terminals_at_rest_with(1, attach_detector);
}

#[test]
fn printing_terminals_with_the_detector_stream_write_nothing_on_60_workspaces() {
    printing_terminals_at_rest_with(60, attach_detector);
}

#[test]
fn printing_terminals_with_the_detector_stream_write_nothing_on_826_workspaces() {
    printing_terminals_at_rest_with(826, attach_detector);
}
