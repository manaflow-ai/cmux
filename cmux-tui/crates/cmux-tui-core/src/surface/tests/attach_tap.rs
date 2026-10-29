//! Attach tap queue tests.

use super::*;
use bytes::Bytes;

#[test]
fn attach_tap_overflow_cancels_the_shared_lifecycle_once() {
    let lifecycle = AttachLifecycle::default();
    let (tap, _receiver) = AttachTap::pair(lifecycle.clone(), 1, usize::MAX);

    assert!(tap.try_send(AttachFrame::ColorsChanged(Arc::new(TerminalColors::default()))));
    assert!(!tap.try_send(AttachFrame::ColorsChanged(Arc::new(TerminalColors::default()))));
    assert!(lifecycle.is_canceled());
    assert!(lifecycle.overflowed());
    assert!(lifecycle.claim_overflow_report());
    assert!(!lifecycle.claim_overflow_report());
}

#[test]
fn attach_tap_overflow_is_bounded_by_retained_bytes() {
    let lifecycle = AttachLifecycle::default();
    let frame_bytes = AttachFrame::Output(vec![1].into()).retained_bytes();
    let (tap, _receiver) = AttachTap::pair(lifecycle.clone(), 4, frame_bytes);

    assert!(tap.try_send(AttachFrame::Output(vec![1].into())));
    assert!(!tap.try_send(AttachFrame::Output(vec![2].into())));
    assert!(lifecycle.overflowed());
}

/// A tap whose receiver is gone cancels the attachment, and cancel fires the
/// attachment's interrupts. The receiver's interrupt waker locks the same
/// queue, so canceling while holding the queue lock deadlocked the sender
/// (the window between the receiver marking itself gone and its own cancel).
#[test]
fn attach_tap_cancels_without_holding_its_queue_lock() {
    let lifecycle = AttachLifecycle::default();
    let (tap, receiver) = AttachTap::pair(lifecycle.clone(), 4, usize::MAX);
    let interrupt = crate::stream_interrupt::StreamInterrupt::new();
    receiver.wake_on(&interrupt);
    lifecycle.register_interrupt(&interrupt);
    // The receiver has marked itself gone but has not canceled yet.
    tap.state.queue.lock().unwrap().receiver_alive = false;
    let (done_tx, done_rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let sent = tap.try_send(AttachFrame::Output(vec![1].into()));
        let _ = done_tx.send(sent);
    });
    let Ok(sent) = done_rx.recv_timeout(Duration::from_secs(2)) else {
        // Dropping the receiver locks the queue the stuck thread holds.
        std::mem::forget(receiver);
        panic!("try_send deadlocked on its own queue lock while canceling");
    };
    assert!(!sent);
    assert!(lifecycle.is_canceled());
    drop(receiver);
}

fn output_chunk(index: usize, len: usize) -> Vec<u8> {
    (0..len).map(|offset| ((index * 31 + offset) % 251) as u8).collect()
}

fn output_frames(receiver: &AttachFrameReceiver) -> Vec<AttachFrame> {
    std::iter::from_fn(|| receiver.try_recv().ok()).collect()
}

/// fan-out shares one buffer per PTY read. Three viewers of
/// 10k chunks cost at most one allocation per chunk (the old fan-out made
/// four: the read's copy and one copy per viewer), every viewer gets the same
/// bytes in the same buffer, and each viewer's backlog counts the chunk as
/// before.
#[test]
fn attach_tap_fan_out_allocates_each_chunk_once_for_every_viewer() {
    const VIEWERS: usize = 3;
    const CHUNKS: usize = 10_000;
    const CHUNK_BYTES: usize = 1_000;
    let mux = Mux::new_for_test("attach-fan-out-allocations", SurfaceOptions::default());
    let surface =
        Surface::spawn_for_test(1, SurfaceOptions::default(), Arc::downgrade(&mux)).unwrap();
    let viewers = (0..VIEWERS).map(|_| surface.attach_stream().unwrap()).collect::<Vec<_>>();
    let pty = surface.as_pty().unwrap();
    // The first send warms the queues and the lock-rank thread-locals.
    assert!(pty.broadcast_attach_output(&output_chunk(0, CHUNK_BYTES)));
    for viewer in &viewers {
        assert_eq!(output_frames(&viewer.stream).len(), 1);
    }

    let mut total = allocation_counter::Allocations::default();
    for index in 1..=CHUNKS {
        let chunk = output_chunk(index, CHUNK_BYTES);
        let (sent, allocations) =
            allocation_counter::count_allocations(|| pty.broadcast_attach_output(&chunk));
        assert!(sent, "chunk {index} reached no viewer");
        total.count += allocations.count;
        total.large += allocations.large;
        for viewer in &viewers {
            assert_eq!(
                viewer.stream.backlog_bytes(),
                size_of::<AttachFrame>() + CHUNK_BYTES,
                "a queued chunk counts its frame and its bytes, as a viewer's own copy did"
            );
        }
        let frames = viewers
            .iter()
            .map(|viewer| {
                let mut frames = output_frames(&viewer.stream);
                assert_eq!(frames.len(), 1, "one chunk queues one frame per viewer");
                frames.remove(0)
            })
            .collect::<Vec<_>>();
        let buffer = frames[0].output().unwrap().as_ptr();
        for frame in &frames {
            let AttachFrame::Output(output) = frame else { panic!("unexpected {frame:?}") };
            assert_eq!(&output[..], &chunk[..], "chunk {index}: bytes differ");
            assert_eq!(output.as_ptr(), buffer, "chunk {index}: a viewer got its own copy");
        }
    }
    assert!(
        total.count <= CHUNKS,
        "{total:?} allocations for {CHUNKS} chunks to {VIEWERS} viewers"
    );
    // Viewers that keep up release each block before the arena wraps, so the
    // arena reuses it in place instead of allocating.
    assert_eq!(total, allocation_counter::Allocations::default(), "a reused block allocated");
}

/// Chunks a viewer still holds keep their block, so the arena starts a new
/// one: a fresh block costs its buffer and its shared count, once per block
/// and not once per chunk or per viewer.
#[test]
fn attach_output_arena_allocates_once_per_block_while_viewers_hold_chunks() {
    const VIEWERS: usize = 3;
    const CHUNKS: usize = 10_000;
    const CHUNK_BYTES: usize = 1_000;
    let mut arena = OutputArena::default();
    let mut held = Vec::with_capacity(CHUNKS * VIEWERS);
    let ((), allocations) = allocation_counter::count_allocations(|| {
        for index in 0..CHUNKS {
            let chunk = arena.chunk(&output_chunk(index, CHUNK_BYTES));
            held.extend(std::iter::repeat_n(chunk, VIEWERS));
        }
    });
    let blocks = CHUNKS.div_ceil(OUTPUT_ARENA_BLOCK_BYTES / CHUNK_BYTES);
    // `output_chunk` builds each test read in a Vec of its own.
    assert_eq!(allocations.count - CHUNKS, 2 * blocks, "{allocations:?}");
    assert_eq!(allocations.large - CHUNKS, blocks, "{allocations:?}");
    for (index, chunks) in held.chunks(VIEWERS).enumerate() {
        for chunk in chunks {
            assert_eq!(&chunk[..], &output_chunk(index, CHUNK_BYTES)[..]);
            assert_eq!(chunk.as_ptr(), chunks[0].as_ptr());
        }
    }
}

/// A block every chunk of has been dropped is reused in place; a read longer
/// than a block gets a block of its own; an empty read allocates nothing.
#[test]
fn attach_output_arena_reuses_a_released_block_in_place() {
    let mut arena = OutputArena::default();
    let read = vec![7; OUTPUT_ARENA_BLOCK_BYTES / 2];
    let first = arena.chunk(&read).as_ptr();
    drop(arena.chunk(&read));
    let (reused, allocations) = allocation_counter::count_allocations(|| arena.chunk(&read));
    assert_eq!(allocations, allocation_counter::Allocations::default());
    assert_eq!(reused.as_ptr(), first, "the released block was not reused");
    assert_eq!(&reused[..], &read[..]);

    let long = vec![9; OUTPUT_ARENA_BLOCK_BYTES * 3];
    let (chunk, allocations) = allocation_counter::count_allocations(|| arena.chunk(&long));
    assert_eq!(&chunk[..], &long[..]);
    assert_eq!(allocations.large, 1, "a long read is copied once");
    drop(reused);

    let (empty, allocations) = allocation_counter::count_allocations(|| arena.chunk(&[]));
    assert!(empty.is_empty());
    assert_eq!(allocations, allocation_counter::Allocations::default());
}

/// An output-with-colors frame built from a buffer with spare capacity holds
/// only its bytes, so the viewer's backlog counts what the frame keeps alive.
#[test]
fn attach_tap_output_with_colors_backlog_counts_all_it_retains() {
    let mut output = Vec::with_capacity(4_096);
    output.extend_from_slice(b"colored output");
    let len = output.len();
    let (tap, receiver) = AttachTap::pair(AttachLifecycle::default(), 4, usize::MAX);
    assert!(tap.try_send(AttachFrame::output_with_colors(output, Box::default(), 0)));
    assert_eq!(
        receiver.backlog_bytes(),
        size_of::<AttachFrame>() + len + size_of::<TerminalColors>()
    );
    let Ok(AttachFrame::OutputWithColors { output, .. }) = receiver.try_recv() else {
        panic!("no output-with-colors frame")
    };
    assert_eq!(&output[..], b"colored output");
    let retained = output.try_into_mut().expect("the viewer holds the only handle").capacity();
    assert_eq!(retained, len, "the frame keeps spare capacity its backlog does not count");
}

/// A slow viewer's merged output keeps the key
/// press it echoes, and the echoes of two key presses never merge into one
/// event (each `output` carries at most one `flow`).
#[test]
fn attach_tap_rope_keeps_one_echo_flow_per_output_event() {
    let budget = usize::MAX;
    let mut rope = OutputRope::new(Bytes::from_static(b"a"), 0);
    assert!(matches!(
        rope.merge(AttachFrame::with_flow(Bytes::from_static(b"b"), 42), budget),
        AttachFrameMerge::Merged
    ));
    assert!(matches!(
        rope.merge(AttachFrame::Output(Bytes::from_static(b"c")), budget),
        AttachFrameMerge::Merged
    ));
    let AttachFrameMerge::Unmerged(next) =
        rope.merge(AttachFrame::with_flow(Bytes::from_static(b"d"), 43), budget)
    else {
        panic!("two flows merged into one output event");
    };
    assert_eq!((next.flow(), next.output()), (43, Some(&b"d"[..])));
    assert_eq!(
        rope.into_frame(),
        AttachFrame::FlowOutput { output: Bytes::from_static(b"abc"), flow: 42 }
    );
    assert_eq!(
        AttachFrame::with_flow(Bytes::from_static(b"e"), 0),
        AttachFrame::Output(Bytes::from_static(b"e"))
    );
    let colors = AttachFrame::OutputWithColors {
        output: Bytes::from_static(b"f"),
        colors: Box::default(),
        flow: 0,
    };
    let mut rope = OutputRope::new(Bytes::from_static(b"g"), 0);
    assert!(matches!(rope.merge(colors, budget), AttachFrameMerge::Unmerged(_)));
}

/// A slow viewer merges large chunks by handle (no copy on the reader) and
/// small chunks into one copied piece; taking the run joins it once.
#[test]
fn attach_tap_rope_shares_large_chunks_and_copies_small_ones() {
    let large = OUTPUT_ROPE_COPY_MAX_BYTES + 1;
    let head = Bytes::from(output_chunk(0, large));
    let mut rope = OutputRope::new(head.clone(), 0);
    let mut expected = head.to_vec();
    for index in 1..=3 {
        let chunk = Bytes::from(output_chunk(index, large));
        expected.extend_from_slice(&chunk);
        let ((), allocations) = allocation_counter::count_allocations(|| {
            assert!(matches!(
                rope.merge(AttachFrame::Output(chunk), usize::MAX),
                AttachFrameMerge::Merged
            ));
        });
        assert_eq!(allocations.large, 0, "merging a shared chunk copied it");
    }
    assert_eq!(rope.pieces(), 4);
    for index in 0..100 {
        let chunk = output_chunk(index, 7);
        expected.extend_from_slice(&chunk);
        assert!(matches!(
            rope.merge(AttachFrame::Output(chunk.into()), usize::MAX),
            AttachFrameMerge::Merged
        ));
    }
    assert_eq!(rope.pieces(), 5, "adjacent small chunks share one copied piece");
    assert_eq!(rope.len(), expected.len());
    assert_eq!(rope.into_frame(), AttachFrame::Output(expected.into()));
    // A run with nothing merged is handed over without a join.
    let alone = OutputRope::new(head.clone(), 0).into_frame();
    assert_eq!(alone.output().unwrap().as_ptr(), head.as_ptr());
}

/// A merge never takes the run past its budget, and a refused merge leaves
/// the run as it was.
#[test]
fn attach_tap_rope_merge_respects_the_exact_retained_budget() {
    let mut rope = OutputRope::new(Bytes::from(vec![1; 1_024]), 0);
    assert_eq!(rope.retained_bytes(), size_of::<AttachFrame>() + 1_024);
    let full = rope.retained_bytes();
    for len in [1, OUTPUT_ROPE_COPY_MAX_BYTES + 1] {
        let refused = rope.merge(AttachFrame::Output(vec![2; len].into()), full);
        assert!(matches!(refused, AttachFrameMerge::Overflow));
        assert_eq!(rope.retained_bytes(), full, "overflow must not append rejected bytes");
        assert_eq!(rope.len(), 1_024);
    }

    // Small merges fill the budget and stop there.
    let budget = full + 64 + OUTPUT_ROPE_COPY_MAX_BYTES;
    let mut merged = 0;
    while matches!(
        rope.merge(AttachFrame::Output(vec![2].into()), budget),
        AttachFrameMerge::Merged
    ) {
        merged += 1;
        assert!(rope.retained_bytes() <= budget);
    }
    assert!(merged >= OUTPUT_ROPE_COPY_MAX_BYTES);
    assert_eq!(rope.len(), 1_024 + merged);
}

/// Merging keeps a slow viewer within its cap and loses no byte: it reads
/// the stream a fast viewer reads.
#[test]
fn attach_tap_slow_viewer_reads_the_bytes_a_fast_viewer_reads() {
    let (slow, slow_receiver) = AttachTap::pair(AttachLifecycle::default(), 4, 1 << 20);
    let (fast, fast_receiver) = AttachTap::pair(AttachLifecycle::default(), 4, 1 << 20);
    let mut fast_bytes = Vec::new();
    for index in 0..200 {
        let len = if index % 3 == 0 { OUTPUT_ROPE_COPY_MAX_BYTES * 2 } else { 13 };
        let frame = AttachFrame::with_flow(output_chunk(index, len).into(), 0);
        assert!(slow.try_send(frame.clone()));
        assert!(fast.try_send(frame));
        assert!(slow_receiver.backlog_bytes() <= 1 << 20);
        for frame in output_frames(&fast_receiver) {
            fast_bytes.extend_from_slice(frame.output().unwrap());
        }
    }
    let slow_frames = output_frames(&slow_receiver);
    assert_eq!(slow_frames.len(), 1, "adjacent output merged into one frame");
    assert_eq!(slow_frames[0].output().unwrap(), &fast_bytes[..]);
    assert_eq!(slow_receiver.backlog_bytes(), 0);
}
