//! The macOS stack sampler (p09-observability task 072): a thread parked in a known function
//! resolves to that function's image and offset, and a thread blocked inside the allocator, holding
//! its lock, does not deadlock the sampler, which allocates nothing while the thread is suspended.
#![cfg(target_os = "macos")]

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::hint::black_box;
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::thread;
use std::time::{Duration, Instant};

use cmux_hang_watch::sample_macos::{self, RawStack, SampleError};
use cmux_hang_watch::{Config, Hang, HangSink, HangWatch, ThreadKind, TraceClock};

/// The test allocator: it counts each thread's allocations, and the thread whose port is in
/// `HOLD_FOR` keeps a lock inside `alloc` at its next allocation (the malloc lock of a thread hung in
/// malloc), so any other allocation in the process waits on it.
struct Gate;

static HOLD_FOR: AtomicU32 = AtomicU32::new(0);
static HOLDING: AtomicBool = AtomicBool::new(false);
static RELEASE: AtomicBool = AtomicBool::new(false);
static ALLOC_LOCK: AtomicBool = AtomicBool::new(false);

thread_local! {
    static ALLOCATIONS: Cell<u64> = const { Cell::new(0) };
}

fn allocations() -> u64 {
    ALLOCATIONS.with(Cell::get)
}

/// Waits for the allocator lock (a spin with sched_yield: no allocation, no std lock).
fn lock_allocator() {
    while ALLOC_LOCK.compare_exchange(false, true, Ordering::Acquire, Ordering::Relaxed).is_err() {
        // SAFETY: sched_yield has no preconditions.
        unsafe { libc::sched_yield() };
    }
}

/// The function the malloc test's thread is stuck in, holding the allocator lock.
#[inline(never)]
fn stuck_in_malloc() {
    HOLDING.store(true, Ordering::Release);
    while !RELEASE.load(Ordering::Acquire) {
        // SAFETY: usleep has no preconditions.
        unsafe { libc::usleep(1_000) };
    }
    black_box(());
}

// SAFETY: every call forwards to the system allocator with the caller's arguments.
unsafe impl GlobalAlloc for Gate {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let _ = ALLOCATIONS.try_with(|count| count.set(count.get() + 1));
        lock_allocator();
        let held_for = HOLD_FOR.load(Ordering::Acquire);
        if held_for != 0 && held_for == sample_macos::current_thread_port() {
            HOLD_FOR.store(0, Ordering::Release);
            stuck_in_malloc();
        }
        // SAFETY: forwarded unchanged.
        let pointer = unsafe { System.alloc(layout) };
        ALLOC_LOCK.store(false, Ordering::Release);
        pointer
    }

    unsafe fn dealloc(&self, pointer: *mut u8, layout: Layout) {
        // SAFETY: forwarded unchanged.
        unsafe { System.dealloc(pointer, layout) }
    }
}

#[global_allocator]
static GLOBAL: Gate = Gate;

/// One test at a time touches the allocator gate.
static SERIAL: Mutex<()> = Mutex::new(());

/// The function the parked test's thread waits in.
#[inline(never)]
fn parked_in_known_function(stop: &AtomicBool) {
    while !stop.load(Ordering::Acquire) {
        thread::park_timeout(Duration::from_millis(50));
    }
    black_box(stop);
}

/// A frame that returns into `function`: the function's code starts at its address, and a body as
/// small as these keeps its call sites within its first 4 KiB.
fn frame_in(frames: &[u64], function: u64) -> Option<u64> {
    frames.iter().copied().find(|address| *address > function && *address - function < 4096)
}

fn spawn_parked() -> (thread::JoinHandle<()>, Arc<AtomicBool>, u32) {
    let stop = Arc::new(AtomicBool::new(false));
    let (port_tx, port_rx) = mpsc::channel();
    let thread_stop = Arc::clone(&stop);
    let handle = thread::spawn(move || {
        port_tx.send(sample_macos::current_thread_port()).unwrap();
        parked_in_known_function(&thread_stop);
    });
    let port = port_rx.recv().unwrap();
    thread::sleep(Duration::from_millis(100));
    (handle, stop, port)
}

#[test]
fn sample_resolves_a_parked_thread_to_its_function() {
    let _serial = SERIAL.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let (handle, stop, port) = spawn_parked();

    let stack = sample_macos::sample(port).expect("sampled");
    stop.store(true, Ordering::Release);
    handle.thread().unpark();
    handle.join().unwrap();

    let function = parked_in_known_function as *const () as u64;
    let addresses: Vec<u64> = stack.frames.iter().map(|frame| frame.address).collect();
    let address = frame_in(&addresses, function)
        .unwrap_or_else(|| panic!("no frame in the parked function {function:#x}: {stack:#?}"));
    let frame = stack.frames.iter().find(|frame| frame.address == address).unwrap();
    let offset = stack.offset(frame).expect("the frame maps to an image");
    let image = &stack.images[frame.image.unwrap() as usize];
    assert_eq!(image.load_address + offset, address);
    assert_ne!(image.uuid, [0; 16], "the image has its LC_UUID");
    assert!(!image.name.contains('/'), "only the file name: {}", image.name);
    let own = sample_macos::image_for(function).expect("the test binary is in the table");
    assert_eq!(own.uuid, image.uuid, "the frame is in the test binary");
    assert!(stack.frames.len() >= 3, "{stack:#?}");
}

#[test]
fn sample_of_a_thread_blocked_in_malloc_does_not_deadlock() {
    let _serial = SERIAL.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let (port_tx, port_rx) = mpsc::channel();
    let (go_tx, go_rx) = mpsc::channel::<()>();
    // Everything the sampling side needs is allocated before the target takes the lock.
    let mut raw = Box::new(RawStack::new());
    let target = thread::spawn(move || {
        port_tx.send(sample_macos::current_thread_port()).unwrap();
        go_rx.recv().unwrap();
        black_box(Box::new(7u64));
    });
    let port = port_rx.recv().unwrap();
    HOLD_FOR.store(port, Ordering::Release);
    go_tx.send(()).unwrap();
    let started = Instant::now();
    while !HOLDING.load(Ordering::Acquire) {
        assert!(started.elapsed() < Duration::from_secs(5), "the target never entered malloc");
        thread::sleep(Duration::from_millis(1));
    }

    // The allocator lock is held now: an allocation anywhere here would wait for RELEASE.
    let before = allocations();
    let result = sample_macos::sample_raw(port, &mut raw);
    let during = allocations() - before;
    RELEASE.store(true, Ordering::Release);
    target.join().unwrap();

    assert_eq!(result, Ok(()));
    assert_eq!(during, 0, "the suspended part of a sample allocates nothing");
    let function = stuck_in_malloc as *const () as u64;
    let alloc_fn = <Gate as GlobalAlloc>::alloc as *const () as u64;
    let addresses = raw.addresses();
    assert!(
        frame_in(addresses, function).is_some() || frame_in(addresses, alloc_fn).is_some(),
        "the stack is inside the allocator: {addresses:#x?}"
    );
    let stack = sample_macos::resolve(&raw);
    assert_eq!(stack.frames.len(), addresses.len());
    HOLDING.store(false, Ordering::Release);
    RELEASE.store(false, Ordering::Release);
}

#[test]
fn sample_refuses_its_own_thread_and_a_missing_port() {
    let mut raw = RawStack::new();
    assert_eq!(
        sample_macos::sample_raw(sample_macos::current_thread_port(), &mut raw),
        Err(SampleError::SelfThread)
    );
    assert_eq!(sample_macos::sample_raw(0, &mut raw), Err(SampleError::NoThread));
    assert!(raw.addresses().is_empty());
}

#[test]
fn sample_checked_does_not_suspend_a_thread_that_unregistered() {
    let _serial = SERIAL.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let (handle, stop, port) = spawn_parked();
    let result = sample_macos::sample_checked(port, || false);
    stop.store(true, Ordering::Release);
    handle.thread().unpark();
    handle.join().unwrap();
    assert_eq!(result.err(), Some(SampleError::Unregistered));
}

#[test]
fn sample_checked_rechecks_after_the_suspend_and_walks_nothing_when_it_changed() {
    // The thread unregisters between the first check and the suspend (a Guard that dropped on its
    // way to pthread_exit): the second check, while it is suspended, refuses the walk.
    let _serial = SERIAL.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let (handle, stop, port) = spawn_parked();
    let calls = Cell::new(0u32);
    let mut raw = RawStack::new();
    let result = sample_macos::sample_raw_checked(port, &mut raw, || {
        calls.set(calls.get() + 1);
        calls.get() == 1
    });
    // The join returns only if the refused sample resumed the thread.
    stop.store(true, Ordering::Release);
    handle.thread().unpark();
    handle.join().unwrap();
    assert_eq!(result, Err(SampleError::Unregistered));
    assert_eq!(calls.get(), 2, "checked before and after the suspend");
    assert!(raw.addresses().is_empty(), "no frames: {:#x?}", raw.addresses());
}

#[derive(Clone, Default)]
struct Collect(Arc<Mutex<Vec<Hang>>>);

impl HangSink for Collect {
    fn record(&self, hang: &Hang) -> std::io::Result<()> {
        self.0.lock().unwrap().push(hang.clone());
        Ok(())
    }
}

#[test]
fn sample_rides_on_the_hang_record() {
    let _serial = SERIAL.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    let sink = Collect::default();
    let config = Config { min_deadline: Duration::from_millis(50), ..Config::default() };
    let watch = HangWatch::spawn(config, Arc::new(TraceClock), Box::new(sink.clone())).unwrap();
    let stop = AtomicBool::new(false);
    thread::scope(|threads| {
        threads.spawn(|| {
            let guard = watch.register_thread(ThreadKind::Io, "sampled-io");
            let _scope = guard.watch(Duration::from_millis(100));
            parked_in_known_function(&stop);
        });
        let started = Instant::now();
        while sink.0.lock().unwrap().is_empty() && started.elapsed() < Duration::from_secs(5) {
            thread::sleep(Duration::from_millis(20));
        }
        stop.store(true, Ordering::Release);
    });

    let hangs = sink.0.lock().unwrap().clone();
    assert_eq!(hangs.len(), 1, "{hangs:?}");
    let stack = hangs[0].stack.as_ref().expect("the record has a stack");
    let function = parked_in_known_function as *const () as u64;
    let addresses: Vec<u64> = stack.frames.iter().map(|frame| frame.address).collect();
    assert!(frame_in(&addresses, function).is_some(), "{stack:#?}");
    let line = hangs[0].to_json_line();
    assert!(line.contains("\"stack\":{\"truncated\":false,\"frames\":[{\"addr\":"), "{line}");
    assert!(line.ends_with("]}}\n"), "{line}");
    assert_eq!(watch.stats().sample_errors, 0);
}
