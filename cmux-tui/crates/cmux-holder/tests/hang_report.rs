//! The holder loop's hang watch ([`capability::HANG_REPORT`], p02-threads
//! task 232): a pass of the loop's work busy past 100 ms is one HANG frame
//! to a daemon link granted the bit, which the link's reader hands to its
//! [`FrameWatch::hang`]; a link not granted the bit gets none; the idle
//! loop's watcher does not wake. (In process: the stall is a test tracer
//! that takes 150 ms to start, inside the loop's pass.)
//!
//! One test in this binary: the holder's self-pipe is process-wide, so a
//! second in-process holder would take the watcher's wake.

#![cfg(unix)]

use std::os::fd::AsRawFd;
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use cmux_holder::client::HolderClient;
use cmux_holder::holder::{HangWatch, Holder, TraceControl};
use cmux_holder::link::{FrameWatch, HolderLink, SPAWN_TIMEOUT, TraceForward};
use cmux_holder::wire::{self, HangReport, Kind, Out, TraceStart, capability};

mod support;

const TOKEN: [u8; 32] = [0x23; 32];

/// The loop stalls 150 ms in each TRACE_START it takes.
struct StallingTrace;

impl TraceControl for StallingTrace {
    fn available(&self) -> bool {
        true
    }
    fn start(&mut self, _request: TraceStart) -> Result<(), String> {
        std::thread::sleep(Duration::from_millis(150));
        Ok(())
    }
    fn stop(&mut self) -> Result<(), String> {
        Ok(())
    }
}

static REPORTS: Mutex<Vec<HangReport>> = Mutex::new(Vec::new());

const WATCH: FrameWatch = FrameWatch {
    enter: |_| 0,
    exit: |_| {},
    hang: |report| REPORTS.lock().unwrap().push(report.clone()),
};

fn wait_for(what: &str, mut done: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !done() {
        assert!(Instant::now() < deadline, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

fn read_frame(stream: &UnixStream, reader: &mut wire::Reader) -> wire::Frame {
    stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
    loop {
        if let Some(frame) = reader.next_frame().unwrap() {
            return frame;
        }
        assert!(reader.fill(stream.as_raw_fd()).unwrap(), "the holder closed the link");
    }
}

/// The watcher's wakes once they stop changing.
fn settled_wakeups(watch: &cmux_threads::HangWatcher) -> u64 {
    let mut last = watch.snapshot().wakeups;
    loop {
        std::thread::sleep(Duration::from_millis(300));
        let now = watch.snapshot().wakeups;
        if now == last {
            return now;
        }
        last = now;
    }
}

#[test]
fn a_stalled_holder_pass_is_one_hang_report_to_a_granted_link_only() {
    let dir = support::unique_dir("cmhh");
    let socket = dir.join("h.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let watch = HangWatch::start().unwrap();
    let watcher = watch.watcher();
    let serving = std::thread::spawn(move || {
        let mut holder = Holder::new(listener, TOKEN).unwrap();
        holder.set_trace_control(Box::new(StallingTrace));
        holder.set_hang_watch(watch);
        holder.set_idle_exit(Duration::from_secs(2));
        holder.run().unwrap();
    });

    // A daemon that asks for TRACE_CONTROL and WRITE_FLOW only: its stalled
    // pass is recorded, and no HANG comes before the PONG behind it.
    let older = UnixStream::connect(&socket).unwrap();
    let mut reader = wire::Reader::default();
    let hello = Out::default().u16(wire::VERSION).bytes(&TOKEN).u32(3).0;
    wire::send_all(older.as_raw_fd(), &wire::encode(Kind::Hello, 0, &hello), &[]).unwrap();
    assert_eq!(read_frame(&older, &mut reader).kind, Kind::Welcome as u16);
    let start = TraceStart { categories: 1, budget_bytes: 0 };
    let trace_start = wire::encode(Kind::TraceStart, 0, &start.encode());
    wire::send_all(older.as_raw_fd(), &trace_start, &[]).unwrap();
    wait_for("the first stall's record", || watcher.snapshot().total == 1);
    wire::send_all(older.as_raw_fd(), &wire::encode(Kind::Ping, 0, b"after"), &[]).unwrap();
    let answer = read_frame(&older, &mut reader);
    assert_eq!(answer.kind, Kind::Pong as u16, "an ungranted link got {answer:?}");
    drop(older);

    // This build's link is granted HANG_REPORT: the stall comes back once.
    let (link, _) =
        HolderLink::connect_watched(&socket, &TOKEN, Box::new(|_| {}), SPAWN_TIMEOUT, WATCH)
            .unwrap();
    assert_ne!(link.capabilities() & capability::HANG_REPORT, 0);
    assert_eq!(link.trace_start(1, 0).unwrap(), TraceForward::Sent);
    wait_for("the hang report", || !REPORTS.lock().unwrap().is_empty());
    let report = REPORTS.lock().unwrap()[0].clone();
    assert_eq!((report.site.as_str(), report.deadline_ms), ("holder-loop", 100), "{report:?}");
    assert!(report.busy_ms >= 100, "{report:?}");

    // Idle: no pass, no record, no watcher wake.
    let idle = settled_wakeups(&watcher);
    std::thread::sleep(Duration::from_secs(1));
    assert_eq!(watcher.snapshot().wakeups, idle, "the idle loop's watcher woke");
    assert_eq!(REPORTS.lock().unwrap().len(), 1, "one report per stalled pass");
    assert_eq!(watcher.snapshot().total, 2);

    // The link's reader keeps its socket open: a taker supersedes it and
    // leaves, so the holder has no link and exits at its idle exit.
    let (taker, _) = HolderClient::connect(&socket, &TOKEN).unwrap();
    wait_for("the superseded link", || !link.is_open());
    taker.end();
    drop(link);
    serving.join().unwrap();
    let _ = std::fs::remove_dir_all(&dir);
}
