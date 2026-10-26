//! LaneWriter pops never allocate (p05-ipc-052 acceptance): the queue is
//! filled first, then every pop, chunk and lane switch runs under a counting
//! allocator.
//!
//! An integration test because the counting allocator needs `unsafe`, which
//! the library forbids.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;

use bytes::Bytes;
use cmux_ipc::{Aux, CallAux, CallFlags, Frame, FrameKind, LaneWriter, PriorityHint, StreamLane};

thread_local! {
    static ALLOCATIONS: Cell<u64> = const { Cell::new(0) };
}

struct Counting;

// SAFETY: forwards to the system allocator; the counter is a const-initialized
// thread-local Cell, which never allocates.
unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        let _ = ALLOCATIONS.try_with(|count| count.set(count.get() + 1));
        // SAFETY: same contract as the caller's.
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        // SAFETY: same contract as the caller's.
        unsafe { System.dealloc(ptr, layout) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

fn allocations() -> u64 {
    ALLOCATIONS.with(Cell::get)
}

#[test]
fn lane_writer_pops_do_not_allocate() {
    let mut writer = LaneWriter::default();
    writer.open_stream(1, StreamLane::Bulk).unwrap();
    writer.open_stream(2, StreamLane::Bulk).unwrap();
    writer.open_stream(3, StreamLane::Input).unwrap();
    writer.open_stream(4, StreamLane::Background).unwrap();
    for stream in [1, 2, 4] {
        let bulk = Bytes::from(vec![stream as u8; 8 * 1024 * 1024]);
        let frame = Frame::new(FrameKind::Output, stream, Aux::Offset(0), bulk).unwrap();
        writer.push_stream(frame).unwrap();
    }
    let reply = Aux::Call(CallAux {
        request_id: 1,
        method_id: 0x0101,
        priority: PriorityHint::Control,
        flags: CallFlags::empty(),
    });
    let big_reply = Frame::new(FrameKind::Reply, 0, reply, Bytes::from(vec![7; 1 << 20]));
    writer.push_control(big_reply.unwrap()).unwrap();
    for flow in 0..1000 {
        let input = Frame::new(FrameKind::Input, 3, Aux::FlowId(flow), Bytes::from(vec![1; 8]));
        writer.push_stream(input.unwrap()).unwrap();
    }
    writer.close_stream(2);

    let before = allocations();
    let mut frames = 0_u64;
    let mut bytes = 0_usize;
    while let Some(frame) = writer.pop() {
        frames += 1;
        bytes += frame.payload().len();
        drop(frame);
    }
    let allocated = allocations() - before;

    assert_eq!(bytes, 3 * 8 * 1024 * 1024 + (1 << 20) + 8000);
    assert!(frames > 800, "the payloads were chunked ({frames} frames)");
    assert_eq!(allocated, 0, "{allocated} allocations over {frames} pops");
}
