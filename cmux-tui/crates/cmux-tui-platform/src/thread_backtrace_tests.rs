//! Backtraces of a busy thread: the interrupted pc lies in the function it
//! runs, a capture takes well under a millisecond, and the thread keeps
//! running afterwards.

use std::hint::black_box;
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use super::*;

/// The function the busy thread is in when it is captured: a loop with no
/// call, so the interrupted pc is inside it.
#[inline(never)]
fn backtrace_test_spin(stop: &AtomicBool, spins: &AtomicU64) {
    while !stop.load(Ordering::Relaxed) {
        spins.fetch_add(1, Ordering::Relaxed);
        std::hint::spin_loop();
    }
}

/// The address range a pc in [`backtrace_test_spin`] falls in: its entry
/// and a bound far past a loop this small.
fn spin_range() -> std::ops::Range<usize> {
    let entry = backtrace_test_spin as *const () as usize;
    entry..entry + 4096
}

struct Spinner {
    handle: ThreadHandle,
    stop: Arc<AtomicBool>,
    spins: Arc<AtomicU64>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Spinner {
    fn start() -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let spins = Arc::new(AtomicU64::new(0));
        let (sender, receiver) = mpsc::channel();
        let thread = std::thread::spawn({
            let stop = stop.clone();
            let spins = spins.clone();
            move || {
                sender.send(ThreadHandle::current()).unwrap();
                backtrace_test_spin(black_box(&stop), black_box(&spins));
            }
        });
        let handle = receiver.recv().unwrap().expect("a thread handle");
        // Wait until the thread is inside the loop.
        let deadline = Instant::now() + Duration::from_secs(5);
        while spins.load(Ordering::Relaxed) == 0 {
            assert!(Instant::now() < deadline, "the spinner never started");
            std::thread::yield_now();
        }
        Self { handle, stop, spins, thread: Some(thread) }
    }
}

impl Drop for Spinner {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Relaxed);
        if let Some(thread) = self.thread.take() {
            thread.join().unwrap();
        }
    }
}

#[test]
fn request_watchdog_stack_captures_the_function_a_busy_thread_runs() {
    let spinner = Spinner::start();
    let backtrace = capture(spinner.handle).expect("a capture");
    let frames = backtrace.frames();
    assert!(!frames.is_empty(), "{backtrace:?}");
    assert!(spin_range().contains(&frames[0]), "pc {:#x} outside {:#x?}", frames[0], spin_range());

    let symbolicated = backtrace.symbolicate();
    assert_eq!(symbolicated.len(), frames.len());
    let entry = symbolicate_address(spin_range().start);
    assert!(entry.image.is_some(), "the test binary is a loaded image: {entry:?}");
    let top = &symbolicated[0];
    assert_eq!(top.image, entry.image, "{top:?}");
    assert!(top.offset >= entry.offset && top.offset < entry.offset + 4096, "{top:?} vs {entry:?}");

    // The thread runs on after the capture.
    let before = spinner.spins.load(Ordering::Relaxed);
    let deadline = Instant::now() + Duration::from_secs(5);
    while spinner.spins.load(Ordering::Relaxed) == before {
        assert!(Instant::now() < deadline, "the captured thread did not run again");
        std::thread::yield_now();
    }
}

#[test]
fn request_watchdog_stack_capture_takes_under_a_millisecond() {
    let spinner = Spinner::start();
    let mut times: Vec<Duration> = (0..21)
        .map(|_| {
            let start = Instant::now();
            capture(spinner.handle).expect("a capture");
            start.elapsed()
        })
        .collect();
    times.sort();
    let median = times[times.len() / 2];
    assert!(median < Duration::from_millis(1), "median capture {median:?} ({times:?})");
}

#[test]
fn request_watchdog_stack_refuses_the_current_thread() {
    let current = ThreadHandle::current().expect("captures run on this OS");
    assert_eq!(capture(current).unwrap_err(), BacktraceError::CurrentThread);
}

#[test]
fn request_watchdog_stack_fails_cleanly_for_an_exited_thread() {
    let handle = std::thread::spawn(ThreadHandle::current).join().unwrap().expect("a handle");
    // A thread that exited: its port or tid is gone (or, rarely, reused by a
    // live thread of this process, which is then captured and resumed).
    if let Err(error) = capture(handle) {
        assert!(
            matches!(
                error,
                BacktraceError::Suspend(_) | BacktraceError::Signal(_) | BacktraceError::Timeout
            ),
            "{error}"
        );
    }
}

#[test]
fn request_watchdog_stack_handle_round_trips_through_a_word() {
    assert_eq!(ThreadHandle::from_raw(0), None);
    let handle = ThreadHandle::current().expect("a thread handle");
    assert_eq!(ThreadHandle::from_raw(handle.raw()), Some(handle));
    assert_eq!(ThreadHandle::current(), Some(handle), "cached per thread");
}

#[test]
fn request_watchdog_stack_walk_stops_at_unreadable_or_descending_records() {
    // Records at 0x1000 -> 0x1100 -> 0x1080 (descends: stop).
    let read = |fp: usize| match fp {
        0x1000 => Some([0x1100, 0xaaa]),
        0x1100 => Some([0x1080, 0xbbb]),
        0x1080 => Some([0x1200, 0xccc]),
        _ => None,
    };
    let backtrace = walk(0x42, 0x1000, 0x0f00, read);
    assert_eq!(backtrace.frames(), &[0x42, 0xaaa, 0xbbb]);

    // An unreadable first record keeps only the pc.
    assert_eq!(walk(0x42, 0x9000, 0x0f00, |_| None).frames(), &[0x42]);
    // A frame pointer below the stack pointer is not followed.
    assert_eq!(walk(0x42, 0x0e00, 0x0f00, read).frames(), &[0x42]);
    // A cycle is bounded by the frame cap... and by the climb rule first.
    let cycle = |fp: usize| Some([fp, 0xddd]);
    assert_eq!(walk(0x42, 0x1000, 0x0f00, cycle).frames(), &[0x42, 0xddd]);
    // A long chain stops at MAX_FRAMES.
    let chain = |fp: usize| Some([fp + 16, 0xeee]);
    assert_eq!(walk(0x42, 0x1000, 0x0f00, chain).frames().len(), MAX_FRAMES);
}
