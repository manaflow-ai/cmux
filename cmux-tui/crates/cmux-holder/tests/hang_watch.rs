//! The holder's loop is hang-watched: it registers with the process's
//! hang watch while it serves, its `poll` wait is never blamed, and a turn whose work outlasts the
//! turn deadline is one hang record naming the loop.
//!
//! The process watch is per process, so this file holds one test.

#![cfg(unix)]

use std::io;
use std::os::unix::net::UnixListener;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_hang_watch::{Config, Hang, HangSink, ThreadKind, TraceClock};
use cmux_holder::client::HolderClient;
use cmux_holder::holder::{Holder, POLL_THREAD, TraceControl};
use cmux_holder::link::{HolderLink, TraceForward};
use cmux_holder::wire::TraceStart;

mod support;

const TOKEN: [u8; 32] = [0x74; 32];
const TURN: Duration = Duration::from_millis(100);
/// How long the fake tracer's start takes: the slow turn's work.
const SLOW_START: Duration = Duration::from_millis(400);

/// Every hang the watcher reports.
struct Recorded(Mutex<Sender<Hang>>);

impl HangSink for Recorded {
    fn record(&self, hang: &Hang) -> io::Result<()> {
        let _ = self.0.lock().unwrap().send(hang.clone());
        Ok(())
    }
}

/// A tracer whose start blocks the turn that handles it.
struct SlowTrace;

impl TraceControl for SlowTrace {
    fn available(&self) -> bool {
        true
    }
    fn start(&mut self, _request: TraceStart) -> Result<(), String> {
        std::thread::sleep(SLOW_START);
        Ok(())
    }
    fn stop(&mut self) -> Result<(), String> {
        Ok(())
    }
}

fn wait_for(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn registered() -> u64 {
    cmux_hang_watch::stats().expect("the process watch runs").registered
}

fn drain(hangs: &Receiver<Hang>) -> Vec<Hang> {
    hangs.try_iter().collect()
}

#[test]
fn hang_watch_the_holder_loop_registers_and_blames_a_slow_turn_never_its_wait() {
    let (sender, hangs) = channel();
    // A short period and a wide drift tolerance: a loaded test machine's late watcher pass must
    // not skip the slow turn.
    let config =
        Config { min_deadline: Duration::from_millis(20), drift_tolerance: Duration::from_secs(5) };
    cmux_hang_watch::init_process(
        config,
        Arc::new(TraceClock),
        Box::new(Recorded(Mutex::new(sender))),
    )
    .expect("the process watch starts");
    assert_eq!(registered(), 0);

    let dir = support::unique_dir("cmhw");
    let socket = dir.join("h.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let serving = std::thread::spawn(move || {
        let mut holder = Holder::new(listener, TOKEN).unwrap();
        holder.set_trace_control(Box::new(SlowTrace));
        holder.set_turn_deadline(TURN);
        holder.set_idle_exit(Duration::from_millis(300));
        holder.run().unwrap();
    });
    wait_for("the loop's registration", || registered() == 1);

    let (link, _) = HolderLink::connect(&socket, &TOKEN, Box::new(|_| {})).unwrap();
    // Idle in `poll` for several turn deadlines: the wait is outside every scope.
    std::thread::sleep(TURN * 5);
    assert_eq!(drain(&hangs), [], "an idle holder was blamed for its wait");

    // One turn handles the TRACE_START and runs the slow start: one hang of the loop.
    assert_eq!(link.trace_start(0x4400, 0).unwrap(), TraceForward::Sent);
    let hang = hangs.recv_timeout(Duration::from_secs(10)).expect("the slow turn is reported");
    assert_eq!(hang.thread, POLL_THREAD);
    assert_eq!(hang.kind, ThreadKind::Io);
    assert_eq!(hang.deadline_ms, TURN.as_millis() as u64);
    assert_eq!(hang.pid, std::process::id());
    // Reported once, and the turns after it are quick again.
    std::thread::sleep(SLOW_START + TURN * 3);
    assert_eq!(drain(&hangs), [], "the slow turn was reported twice");

    // Another daemon takes the holder and leaves: no link and no terminal, so the holder exits
    // at its idle exit.
    let (taker, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    wait_for("the superseded link", || !link.is_open());
    taker.end();
    drop(link);
    serving.join().unwrap();
    // The loop ended: its slot is free.
    assert_eq!(registered(), 0);
    let _ = std::fs::remove_dir_all(&dir);
}
