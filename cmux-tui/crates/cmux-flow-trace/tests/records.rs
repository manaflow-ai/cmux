//! Hops end to end, in their own process (this test binary), with CMUX_TRACE_FLOWS set: `init`
//! starts a key recording in that directory, each hop is one v1 ring record there (name, phase,
//! terminal key, flow id, thread, clock), and a hop allocates nothing on its thread.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

use cmux_flow_trace::{Handoff, Terminal};
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
    cmux_flow_trace::hop("daemon.send.written", 42, "00ff");
    cmux_flow_trace::hop_id("host.pty.write", 0, &[0xab; 16]);
    // One echo through every Rust handoff: a flow out where a thread queues it, a flow in where the
    // next takes it. An item no press waits for (flow 0) writes nothing.
    for handoff in Handoff::ALL {
        cmux_flow_trace::queued(handoff, 42, Terminal::Id(&[0xab; 16]));
        cmux_flow_trace::taken(handoff, 42, Terminal::Unknown);
        cmux_flow_trace::queued(handoff, 0, Terminal::Hex("00ff"));
        cmux_flow_trace::taken(handoff, 0, Terminal::Hex("00ff"));
    }
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

    let mut hops: Vec<_> = decoded
        .records
        .iter()
        .map(|record| (decoded.name(record.name).unwrap_or("?"), record))
        .filter(|(name, _)| HOPS.contains(name))
        .collect();
    hops.sort_by_key(|(_, record)| record.t_ns);
    let shape: Vec<_> =
        hops.iter().map(|(name, record)| (*name, record.phase, record.arg1)).collect();
    // Each hop with the id is a flow step, FlowIn then FlowOut (none ends the press's flow); the
    // hop without it is one instant.
    let (step_in, step_out, instant) =
        (Phase::FlowIn as u8, Phase::FlowOut as u8, Phase::Instant as u8);
    assert_eq!(
        shape,
        [
            ("daemon.send.write", step_in, 41),
            ("daemon.send.write", step_out, 41),
            ("daemon.send.write", step_in, 42),
            ("daemon.send.write", step_out, 42),
            ("daemon.send.written", step_in, 42),
            ("daemon.send.written", step_out, 42),
            ("host.pty.write", instant, 0),
        ]
    );
    let (_, sent) = hops[2];
    assert_eq!(sent.arg0, 0x00ff_0000_0000_0000);
    let (_, written) = hops[6];
    assert_eq!(written.arg0, 0xabab_abab_abab_abab);
    assert!(written.t_ns >= sent.t_ns && sent.t_ns > 0);
    let thread = decoded.thread_of(sent).expect("the hop names its thread");
    assert_ne!(thread.tid, 0);

    let mut handoffs: Vec<_> = decoded
        .records
        .iter()
        .filter_map(|record| {
            let name = decoded.name(record.name)?;
            Handoff::ALL.iter().any(|handoff| handoff.text() == name).then_some((name, record))
        })
        .collect();
    handoffs.sort_by_key(|(_, record)| record.t_ns);
    let shape: Vec<_> = handoffs
        .iter()
        .map(|(name, record)| (*name, record.phase, record.arg0, record.arg1))
        .collect();
    let expected: Vec<_> = Handoff::ALL
        .iter()
        .flat_map(|handoff| {
            [
                (handoff.text(), step_out, 0xabab_abab_abab_abab, 42),
                (handoff.text(), step_in, 0, 42),
            ]
        })
        .collect();
    assert_eq!(shape, expected, "each handoff is a flow out where queued, a flow in where taken");

    // After a stop, the key category is still on for the black box, but a hop writes nothing.
    cmux_trace::stop().expect("the recording stops");
    assert!(!cmux_flow_trace::enabled(), "hops are on with no recording");
    cmux_flow_trace::hop("daemon.send.write", 43, "00ff");
    cmux_flow_trace::hop_id("holder.pty.read", 0, &[0xab; 16]);
    let blackbox = decode(&cmux_trace::snapshot_active().unwrap()).expect("the black box decodes");
    let leaked: Vec<_> = blackbox
        .records
        .iter()
        .filter_map(|record| blackbox.name(record.name))
        .filter(|name| HOPS.contains(name))
        .collect();
    assert!(leaked.is_empty(), "hops went to the black box: {leaked:?}");

    cmux_flow_trace::set_enabled(false);
    assert!(!cmux_flow_trace::enabled());
    let _ = std::fs::remove_dir_all(&dir);
}

const HOPS: [&str; 4] =
    ["daemon.send.write", "daemon.send.written", "host.pty.write", "holder.pty.read"];
