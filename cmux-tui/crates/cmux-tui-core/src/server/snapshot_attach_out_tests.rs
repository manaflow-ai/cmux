//! A snapshot viewer's bulk work never takes a worker the person's echo
//! runs on, and automation's viewers run below the person's.
//!
//! Each test holds every utility worker of the daemon's pool busy: bulk
//! work and automation's views then cannot run, and what still arrives ran
//! on the input workers.

use std::sync::Arc;
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::server::connection_scheduler::connection_qos::ConnectionClass;
use crate::server::sequenced_pool::SequencePriority;
use crate::server::tests::captured_writer;
use crate::server::{
    BoundedOutbound, ClientTransport, Command, MessageWriter, disconnect_client, handle_command,
};
use crate::{Mux, Surface, SurfaceOptions};

const WAIT: Duration = Duration::from_secs(10);

/// The next stream event other than notifications, within `timeout`.
fn next_event(outbound: &BoundedOutbound, timeout: Duration) -> Option<Value> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some(message) = outbound.try_pop() {
            let value: Value = serde_json::from_str(&message).expect("outbound JSON");
            if value["event"] != "notification" {
                return Some(value);
            }
            continue;
        }
        if Instant::now() >= deadline {
            return None;
        }
        std::thread::sleep(Duration::from_millis(2));
    }
}

/// The next event named `name`, skipping others.
fn next_named(outbound: &BoundedOutbound, name: &str, timeout: Duration) -> Option<Value> {
    let deadline = Instant::now() + timeout;
    loop {
        let left = deadline.checked_duration_since(Instant::now())?;
        let event = next_event(outbound, left)?;
        if event["event"] == name {
            return Some(event);
        }
    }
}

/// A mux whose terminals run `cat`, with `lines` lines of scrollback on
/// its first terminal.
fn mux_with_scrollback(session: &str, lines: usize) -> (Arc<Mux>, Arc<Surface>) {
    let mux = Mux::new_for_test(
        session,
        SurfaceOptions { command: Some(vec!["cat".to_string()]), ..SurfaceOptions::default() },
    );
    let surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let mut chunk = String::new();
    for line in 0..lines {
        chunk.push_str(&format!("\x1b[32m{line:06}\x1b[0m compiling crate-{}\r\n", line % 977));
        if chunk.len() > 1 << 16 {
            surface.inject_output_for_test(chunk.as_bytes());
            chunk.clear();
        }
    }
    surface.inject_output_for_test(chunk.as_bytes());
    (mux, surface)
}

/// A snapshot viewer of `surface` on a connection of `class`.
fn attach_viewer(
    mux: &Arc<Mux>,
    surface: &Surface,
    class: ConnectionClass,
) -> (MessageWriter, Arc<BoundedOutbound>, u64) {
    let (writer, outbound) = captured_writer();
    let client = mux.control_clients.register(ClientTransport::Unix, writer.clone());
    mux.control_clients.connection_class(client).set(class);
    let command: Command = serde_json::from_value(json!({
        "cmd": "attach-surface", "surface": surface.id,
        "snapshot": "ghostsnp", "snapshot_version": ghostty_vt::snapshot_version(),
    }))
    .expect("raw command");
    handle_command(mux, client, command, &writer).unwrap();
    (writer, outbound, client)
}

/// The attach READY and its history through `done`.
fn drain_ready_and_history(outbound: &BoundedOutbound) {
    let ready = next_event(outbound, WAIT).expect("ready");
    assert_eq!(ready["phase"], "ready", "{ready}");
    loop {
        let event = next_event(outbound, WAIT).expect("history");
        if event["event"] == "snapshot" && event["phase"] == "history" && event["done"] == true {
            return;
        }
    }
}

/// Holds every utility worker of `mux`'s pool until dropped.
struct UtilityHeld {
    release: Vec<mpsc::Sender<()>>,
}

impl UtilityHeld {
    fn hold(mux: &Mux) -> Self {
        let pool = &mux.sequenced_pool;
        let workers = pool.config().workers(SequencePriority::Utility);
        let (entered, entering) = mpsc::channel();
        let mut release = Vec::new();
        for _ in 0..workers {
            let (go, wait) = mpsc::channel::<()>();
            let entered = entered.clone();
            pool.sequence(SequencePriority::Utility)
                .post(move || {
                    let _ = entered.send(());
                    let _ = wait.recv();
                })
                .expect("posted");
            release.push(go);
        }
        for _ in 0..workers {
            entering.recv_timeout(WAIT).expect("every utility worker is held");
        }
        Self { release }
    }
}

impl Drop for UtilityHeld {
    fn drop(&mut self) {
        for go in self.release.drain(..) {
            let _ = go.send(());
        }
    }
}

/// Several viewers of a deep scrollback resync at a resize while the
/// focused terminal echoes. Their READY encodes and history chunks wait for
/// a utility worker; the focused view's frame does not wait behind them.
/// When each viewer's bulk work ran on its drain, the READYs went out on
/// the input workers (no worker free for them here would mean no READY at
/// all before the release) and the echo queued behind them.
#[test]
fn a_resync_of_many_viewers_does_not_hold_the_focused_echo() {
    const VIEWERS: usize = 6;
    let (mux, deep) = mux_with_scrollback("snapshot-bulk-off-echo", 4_000);
    let focused = mux.new_workspace(None, Some((80, 24))).unwrap();
    let mut viewers = Vec::new();
    for _ in 0..VIEWERS {
        let viewer = attach_viewer(&mux, &deep, ConnectionClass::Person);
        drain_ready_and_history(&viewer.1);
        viewers.push(viewer);
    }
    let (_writer, focus, focus_client) = attach_viewer(&mux, &focused, ConnectionClass::Person);
    drain_ready_and_history(&focus);

    let held = UtilityHeld::hold(&mux);
    deep.resize(60, 20).unwrap();
    focused.inject_output_for_test(b"typed while others resync\r\n");
    let echo = next_named(&focus, "output", WAIT).expect("the echo while the viewers resync");
    assert!(echo["data"].is_string(), "{echo}");
    for (_writer, outbound, _client) in &viewers {
        let early = next_named(outbound, "snapshot", Duration::from_millis(300));
        let early = early.map(|event| (event["phase"].clone(), event["cols"].clone()));
        assert!(early.is_none(), "a resync READY ran on the echo path: {early:?}");
    }

    drop(held);
    for (_writer, outbound, _client) in &viewers {
        let ready = next_named(outbound, "snapshot", WAIT).expect("the READY after the release");
        assert_eq!(ready["phase"], "ready", "{ready}");
        assert_eq!(ready["cols"], 60, "{ready}");
        let history = next_named(outbound, "snapshot", WAIT).expect("its history");
        assert_eq!(history["phase"], "history", "{history}");
        assert_eq!(history["generation"], ready["generation"], "{history}");
    }
    for (_writer, _outbound, client) in viewers {
        disconnect_client(&mux, client, false);
    }
    disconnect_client(&mux, focus_client, false);
    mux.shutdown();
}

/// An automation viewer's frames run on the utility workers, below the
/// person's: with those held, the person's terminal still echoes and the
/// agent's output waits.
#[test]
fn an_automation_viewer_runs_below_the_person() {
    let (mux, person_surface) = mux_with_scrollback("snapshot-view-priority", 10);
    let agent_surface = mux.new_workspace(None, Some((80, 24))).unwrap();
    let (_writer, person, person_client) =
        attach_viewer(&mux, &person_surface, ConnectionClass::Person);
    drain_ready_and_history(&person);
    let (_writer, agent, agent_client) =
        attach_viewer(&mux, &agent_surface, ConnectionClass::Automation);
    drain_ready_and_history(&agent);

    let held = UtilityHeld::hold(&mux);
    agent_surface.inject_output_for_test(b"agent output\r\n");
    person_surface.inject_output_for_test(b"person echo\r\n");
    next_named(&person, "output", WAIT).expect("the person's echo");
    let early = next_named(&agent, "output", Duration::from_millis(300));
    let early = early.map(|event| event["offset"].clone());
    assert!(early.is_none(), "an automation view ran on the input workers: {early:?}");

    drop(held);
    next_named(&agent, "output", WAIT).expect("the agent's output after the release");
    disconnect_client(&mux, person_client, false);
    disconnect_client(&mux, agent_client, false);
    mux.shutdown();
}

/// The view priority of each connection class.
#[test]
fn each_connection_class_has_its_view_priority() {
    assert_eq!(ConnectionClass::Person.view_priority(), SequencePriority::Input);
    assert_eq!(ConnectionClass::Unclassified.view_priority(), SequencePriority::Control);
    assert_eq!(ConnectionClass::Automation.view_priority(), SequencePriority::Utility);
}
