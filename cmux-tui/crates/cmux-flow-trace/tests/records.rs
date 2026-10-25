//! Hops end to end, in their own process (this test binary), with CMUX_TRACE_FLOWS set: `init`
//! starts a key recording in that directory, each hop is one v1 ring record there (name, phase,
//! terminal key, flow id, thread, clock), and a hop allocates nothing on its thread.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

use cmux_trace::{Phase, Role, decode};

/// Counts the allocations of the calling thread only.
struct ThreadCounting;

thread_local! {
    static ALLOCATIONS: Cell<usize> = const { Cell::new(0) };
}

// SAFETY: forwards every call to the system allocator; the counter is a const-initialised thread-local Cell.
unsafe impl GlobalAlloc for ThreadCounting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.with(|count| count.set(count.get() + 1));
        unsafe { System.alloc(layout) }
    }
    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        ALLOCATIONS.with(|count| count.set(count.get() + 1));
        unsafe { System.alloc_zeroed(layout) }
    }
    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static ALLOCATOR: ThreadCounting = ThreadCounting;

#[test]
fn hops_are_ring_records_in_the_recording_and_allocate_nothing() {
    let dir = std::env::temp_dir().join(format!("cmux-flow-trace-test-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    // SAFETY: set before any thread of this test binary reads the environment (`init` reads it once).
    unsafe { std::env::set_var("CMUX_TRACE_FLOWS", &dir) };
    assert!(cmux_flow_trace::init());
    assert!(cmux_flow_trace::init(), "a second init turned hops off");
    assert!(cmux_flow_trace::enabled());

    // The first hop of a thread registers it in the ring and interns its name; measure the next.
    cmux_flow_trace::hop("daemon.send.write", 41, "00ff");
    let before = ALLOCATIONS.with(Cell::get);
    cmux_flow_trace::hop("daemon.send.write", 42, "00ff");
    cmux_flow_trace::hop_id("host.pty.write", 0, &[0xab; 16]);
    let after = ALLOCATIONS.with(Cell::get);
    assert_eq!(after - before, 0, "a hop allocated on the caller's thread");
    assert!(cmux_flow_trace::flush());

    let status = cmux_trace::status().expect("init started the black box");
    assert!(status.recording, "init started no recording");
    let path = status.recording_path.expect("the recording has a file");
    assert_eq!(path.parent(), Some(dir.as_path()), "the recording is not in CMUX_TRACE_FLOWS");
    let decoded = decode(&std::fs::read(&path).unwrap()).expect("the recording decodes");
    assert_eq!(decoded.header.role, Role::Daemon as u16);
    assert_eq!(decoded.header.pid, std::process::id());

    let hops: Vec<_> = decoded
        .records
        .iter()
        .map(|record| (decoded.name(record.name).unwrap_or("?"), record))
        .filter(|(name, _)| matches!(*name, "daemon.send.write" | "host.pty.write"))
        .collect();
    assert_eq!(hops.len(), 3, "{:?}", hops.iter().map(|(name, _)| name).collect::<Vec<_>>());
    let (name, sent) = hops[1];
    assert_eq!(name, "daemon.send.write");
    assert_eq!(sent.phase, Phase::FlowIn as u8);
    assert_eq!(sent.arg1, 42);
    assert_eq!(sent.arg0, 0x00ff_0000_0000_0000);
    let (name, written) = hops[2];
    assert_eq!(name, "host.pty.write");
    assert_eq!(written.phase, Phase::Instant as u8);
    assert_eq!(written.arg1, 0);
    assert_eq!(written.arg0, 0xabab_abab_abab_abab);
    assert!(written.t_ns >= sent.t_ns && sent.t_ns > 0);
    let thread = decoded.thread_of(sent).expect("the hop names its thread");
    assert_ne!(thread.tid, 0);

    cmux_flow_trace::set_enabled(false);
    assert!(!cmux_flow_trace::enabled());
    let _ = std::fs::remove_dir_all(&dir);
}
