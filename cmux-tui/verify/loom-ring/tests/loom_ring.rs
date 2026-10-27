//! Loom model of the holder ring's offset protocol
//! (`cmux-tui/crates/cmux-holder/src/ring_protocol.rs`, included below
//! through `#[path]` and built with loom's atomics under `--cfg loom`).
//!
//! The segment here is loom atomics in place of the shared mapping: three
//! header words and one `AtomicU8` per data byte (the holder stores data with
//! plain writes; relaxed atomics let loom see every value a reader can get).
//! The PTY's byte at stream offset `o` is [`pty_byte`]`(o)`, never 0, so an
//! unwritten data byte cannot pass for a written one.
//!
//! - Offsets and handoff: a killer thread SIGKILLs the writer at a point
//!   loom picks, inside or between its PTY reads. The daemon then sees the
//!   segment as the dead holder left it (a join: the link ended), adopts it
//!   the way a new holder does, and checks that every byte it trusts is the
//!   byte first written at that offset, that a read the kernel completed
//!   but whose end was never published is named at the adopted end (the
//!   loss is never silent), and that the new holder continues the stream
//!   at that end.
//! - Ordering, against a reader running at the same time: a published `end`
//!   carries every byte below it (Release/Acquire); the forfeit fence puts
//!   the new `oldest` before the bytes a write overwrites; the `reading`
//!   marker is in place before a read's bytes and cleared only after its
//!   end.
//!
//! Run: `RUSTFLAGS='--cfg loom' cargo test --release --manifest-path
//! cmux-tui/verify/loom-ring/Cargo.toml`.
#![cfg(loom)]

#[path = "../../../crates/cmux-holder/src/ring_protocol.rs"]
mod ring_protocol;

use std::ops::Range;
use std::panic::{AssertUnwindSafe, catch_unwind, resume_unwind};

use loom::sync::Arc;
use loom::sync::atomic::{AtomicBool, AtomicU8, AtomicU64, Ordering, fence};
use loom::thread;
use ring_protocol::{Cursor, Snapshot, Words, interrupted_read, published_end};

/// Small enough for loom, small enough that the scripts wrap.
const CAPACITY: usize = 4;
/// A ring that does not start at offset 0 (an adopted one never does).
const BASE: u64 = 10;
/// `read(2)` with nothing to read (`EAGAIN`).
const WOULD_BLOCK: isize = -1;

/// The PTY's byte at stream offset `offset`: never 0.
fn pty_byte(offset: u64) -> u8 {
    (offset % 250) as u8 + 1
}

/// A ring segment: the header words and the data area.
struct Segment {
    end: AtomicU64,
    oldest: AtomicU64,
    reading: AtomicU64,
    data: Vec<AtomicU8>,
}

impl Segment {
    /// What `create_segment` makes: an empty ring whose next byte is `base`.
    fn new(base: u64) -> Self {
        let segment = Self {
            end: AtomicU64::new(0),
            oldest: AtomicU64::new(0),
            reading: AtomicU64::new(0),
            data: (0..CAPACITY).map(|_| AtomicU8::new(0)).collect(),
        };
        Cursor::new(CAPACITY, base, base).republish(&segment.words());
        segment
    }

    fn words(&self) -> Words<'_> {
        Words { end: &self.end, oldest: &self.oldest, reading: &self.reading }
    }

    /// What `Ring::adopt` does with a segment: its window, republished.
    fn adopt(&self) -> Cursor {
        let mut cursor = Snapshot::load(&self.words())
            .adopt(CAPACITY, BASE, true)
            .expect("a segment the model made is a ring");
        assert_eq!(cursor.capacity(), CAPACITY);
        cursor.republish(&self.words());
        cursor
    }

    fn store(&self, position: usize, byte: u8) {
        self.data[position].store(byte, Ordering::Relaxed);
    }

    fn byte(&self, position: usize) -> u8 {
        self.data[position].load(Ordering::Relaxed)
    }

    /// The bytes of `cursor`'s kept window, with the offset each has.
    fn kept(&self, cursor: &Cursor) -> Vec<(u64, u8)> {
        let (from, head, tail) = cursor.window(0, CAPACITY);
        head.chain(tail)
            .enumerate()
            .map(|(index, position)| (from + index as u64, self.byte(position)))
            .collect()
    }

    /// `push` from the PTY stream: `data` is the bytes at `from ..`.
    fn push(&self, cursor: &mut Cursor, from: u64, len: usize) {
        let data: Vec<u8> = (from..from + len as u64).map(pty_byte).collect();
        cursor.push(&self.words(), &data, |range, bytes| {
            for (position, &byte) in range.zip(bytes) {
                self.store(position, byte);
            }
        });
    }
}

/// The unwind payload of a killed writer: no panic hook runs for it.
struct Killed;

/// The writer stops here if the killer has struck.
fn die_if(killed: &AtomicBool) {
    if killed.load(Ordering::SeqCst) {
        resume_unwind(Box::new(Killed));
    }
}

/// One `read(2)` of the holder: the kernel takes `got` bytes of the PTY
/// stream from `taken` and copies them into `room` in one step (a SIGKILL
/// lands before the syscall or after it returns, never inside).
fn pty_read(
    segment: &Segment,
    taken: &AtomicU64,
    killed: &AtomicBool,
    room: Range<usize>,
    got: isize,
) -> isize {
    die_if(killed);
    if got <= 0 {
        return got;
    }
    let n = room.len().min(got as usize);
    let from = taken.load(Ordering::Relaxed);
    for (index, position) in room.take(n).enumerate() {
        segment.store(position, pty_byte(from + index as u64));
    }
    taken.store(from + n as u64, Ordering::Relaxed);
    die_if(killed);
    n as isize
}

/// The daemon's checks on the segment of a holder that died anywhere in
/// its reads, and the new holder's continuation. `taken` is how far the
/// kernel read the PTY stream. The ring numbers the stream one to one up to
/// the dead holder's last published end.
fn check_handoff(segment: &Segment, taken: u64) {
    let words = segment.words();
    let end = published_end(&words);
    let interrupted = interrupted_read(&words);
    let mut cursor = segment.adopt();
    assert_eq!(cursor.end(), end, "the adopted ring continues at the published end");
    assert!(cursor.oldest() >= BASE && cursor.end() - cursor.oldest() <= CAPACITY as u64);
    for (offset, byte) in segment.kept(&cursor) {
        assert_eq!(
            byte,
            pty_byte(offset),
            "offset {offset} is trusted with a byte not first written there"
        );
    }
    // A read the kernel finished whose end was never published lost its
    // bytes: the segment names the loss at the end the new holder continues.
    if taken > end {
        assert_eq!(
            interrupted,
            Some(end),
            "{} bytes the kernel took were lost silently",
            taken - end
        );
    }
    if let Some(at) = interrupted {
        assert_eq!(at, end, "a loss is named only at the adopted end");
    }
    assert!(taken >= end, "the ring published bytes the kernel never read");

    // The new holder reads on from where the kernel left the PTY; its first
    // byte has the dead ring's end as offset, and its read clears the mark.
    let killed = AtomicBool::new(false);
    let pty = AtomicU64::new(taken);
    let n = cursor.read_with(&words, CAPACITY, |room| pty_read(segment, &pty, &killed, room, 1));
    assert_eq!(n, 1);
    assert_eq!(interrupted_read(&words), None, "the new holder's read clears the mark");
    let (from, head, _) = cursor.window(end, 1);
    assert_eq!((from, segment.byte(head.start)), (end, pty_byte(taken)));
}

/// A holder whose ring starts with `filled` bytes runs `reads` (each
/// `(max, got)`: the room it offers at most, what `read(2)` returns) while
/// a killer may SIGKILL it at any point; the daemon then takes the segment
/// over ([`check_handoff`]).
fn kill_anywhere(filled: usize, reads: &'static [(usize, isize)]) {
    let mut builder = loom::model::Builder::new();
    builder.preemption_bound = Some(3);
    builder.check(move || {
        let segment = Arc::new(Segment::new(BASE));
        let mut cursor = Snapshot::load(&segment.words()).adopt(CAPACITY, BASE, true).unwrap();
        segment.push(&mut cursor, BASE, filled);
        let taken = Arc::new(AtomicU64::new(BASE + filled as u64));
        let killed = Arc::new(AtomicBool::new(false));

        let holder = {
            let (segment, taken, killed) = (segment.clone(), taken.clone(), killed.clone());
            thread::spawn(move || {
                let run = catch_unwind(AssertUnwindSafe(|| {
                    for &(max, got) in reads {
                        cursor.read_with(&segment.words(), max, |room| {
                            pty_read(&segment, &taken, &killed, room, got)
                        });
                    }
                }));
                if let Err(payload) = run
                    && !payload.is::<Killed>()
                {
                    resume_unwind(payload);
                }
            })
        };
        let killer = {
            let killed = killed.clone();
            thread::spawn(move || killed.store(true, Ordering::SeqCst))
        };
        killer.join().unwrap();
        // The link ended: everything the dead holder stored is in the segment.
        holder.join().unwrap();
        check_handoff(&segment, taken.load(Ordering::Relaxed));
    });
}

/// Short reads, a read with nothing to read, and wraps over kept bytes.
#[test]
fn a_holder_killed_anywhere_in_its_reads_leaves_whole_bytes_and_names_its_loss() {
    kill_anywhere(3, &[(8, 3), (8, WOULD_BLOCK), (2, 2)]);
}

/// Reads that each reuse the room of the oldest kept bytes, from a full ring.
#[test]
fn a_holder_killed_while_reads_overwrite_a_full_ring_keeps_no_overwritten_byte() {
    kill_anywhere(4, &[(1, 1), (8, 2), (8, 4)]);
}

/// A push larger than the ring publishes no skipped offset as a byte, wherever
/// its writer stops (the `store` closure is where a kill can land).
#[test]
fn an_oversized_push_killed_anywhere_keeps_only_its_tail() {
    loom::model(|| {
        let segment = Arc::new(Segment::new(BASE));
        let killed = Arc::new(AtomicBool::new(false));
        let holder = {
            let (segment, killed) = (segment.clone(), killed.clone());
            thread::spawn(move || {
                let mut cursor =
                    Snapshot::load(&segment.words()).adopt(CAPACITY, BASE, true).unwrap();
                let data: Vec<u8> = (BASE..BASE + 6).map(pty_byte).collect();
                let run = catch_unwind(AssertUnwindSafe(|| {
                    cursor.push(&segment.words(), &data, |range, bytes| {
                        for (position, &byte) in range.zip(bytes) {
                            die_if(&killed);
                            segment.store(position, byte);
                        }
                    });
                }));
                if let Err(payload) = run
                    && !payload.is::<Killed>()
                {
                    resume_unwind(payload);
                }
            })
        };
        killed.store(true, Ordering::SeqCst);
        holder.join().unwrap();
        let cursor = segment.adopt();
        assert!(cursor.oldest() >= BASE && cursor.end() <= BASE + 6);
        for (offset, byte) in segment.kept(&cursor) {
            assert_eq!(byte, pty_byte(offset), "offset {offset} is trusted with a wrong byte");
        }
    });
}

/// A reader that loads a published `end` sees every byte below it, and a
/// window decoded at any moment never names more than the capacity.
#[test]
fn a_published_end_carries_every_byte_below_it() {
    loom::model(|| {
        let segment = Arc::new(Segment::new(BASE));
        let holder = {
            let segment = segment.clone();
            thread::spawn(move || {
                let mut cursor =
                    Snapshot::load(&segment.words()).adopt(CAPACITY, BASE, true).unwrap();
                let killed = AtomicBool::new(false);
                let taken = AtomicU64::new(BASE);
                // Offsets 10 and 11 at positions 2 and 3, then 12 at 0: no
                // kept byte is overwritten.
                for got in [2, 1] {
                    cursor.read_with(&segment.words(), CAPACITY, |room| {
                        pty_read(&segment, &taken, &killed, room, got)
                    });
                }
            })
        };
        let words = segment.words();
        let end = published_end(&words);
        assert!((BASE..=BASE + 3).contains(&end));
        for offset in BASE..end {
            assert_eq!(segment.byte((offset % CAPACITY as u64) as usize), pty_byte(offset));
        }
        let window = Snapshot::load(&words).adopt(CAPACITY, BASE, true).unwrap();
        assert!(
            window.oldest() <= window.end() && window.end() - window.oldest() <= CAPACITY as u64
        );
        if let Some(at) = interrupted_read(&words) {
            assert!(at == BASE || at == BASE + 2, "a loss named at {at}, where no read started");
        }
        holder.join().unwrap();
    });
}

/// The forfeit fence: a reader that sees a byte a write stored over a kept
/// byte, then fences, sees the `oldest` that dropped the old byte. `write`
/// stores offset 14 at position 2, over offset 10, into a full ring.
fn overwrite_publishes_oldest_first(write: fn(&Segment, &mut Cursor)) {
    loom::model(move || {
        let segment = Arc::new(Segment::new(BASE));
        let mut cursor = Snapshot::load(&segment.words()).adopt(CAPACITY, BASE, true).unwrap();
        // A full ring: offsets 10..14 at positions 2, 3, 0, 1.
        segment.push(&mut cursor, BASE, CAPACITY);
        let holder = {
            let segment = segment.clone();
            thread::spawn(move || write(&segment, &mut cursor))
        };
        let byte = segment.byte(2);
        fence(Ordering::Acquire);
        let oldest = segment.oldest.load(Ordering::Acquire);
        if byte == pty_byte(BASE + CAPACITY as u64) {
            assert!(oldest > BASE, "offset {BASE} is still kept after its byte was overwritten");
        } else {
            assert_eq!(byte, pty_byte(BASE));
        }
        holder.join().unwrap();
    });
}

/// A PTY read: its `reading` fence comes after the forfeit too.
#[test]
fn a_read_publishes_the_new_oldest_before_it_overwrites() {
    overwrite_publishes_oldest_first(|segment, cursor| {
        let killed = AtomicBool::new(false);
        let taken = AtomicU64::new(BASE + CAPACITY as u64);
        cursor.read_with(&segment.words(), 1, |room| pty_read(segment, &taken, &killed, room, 1));
    });
}

/// A push: the forfeit fence alone orders its overwrite.
#[test]
fn a_push_publishes_the_new_oldest_before_it_overwrites() {
    overwrite_publishes_oldest_first(|segment, cursor| {
        segment.push(cursor, BASE + CAPACITY as u64, 1);
    });
}

/// The `reading` marker: a reader that sees a byte a read stored, then
/// fences, sees the marker, or the read's published end (the marker is
/// cleared only after it). A read's bytes are never taken unmarked.
#[test]
fn a_reads_bytes_are_marked_until_its_end_is_published() {
    loom::model(|| {
        let segment = Arc::new(Segment::new(BASE));
        let holder = {
            let segment = segment.clone();
            thread::spawn(move || {
                let mut cursor =
                    Snapshot::load(&segment.words()).adopt(CAPACITY, BASE, true).unwrap();
                let killed = AtomicBool::new(false);
                let taken = AtomicU64::new(BASE);
                cursor.read_with(&segment.words(), CAPACITY, |room| {
                    pty_read(&segment, &taken, &killed, room, 2)
                });
            })
        };
        // Offset 10 is at position 2.
        let byte = segment.byte(2);
        fence(Ordering::Acquire);
        let reading = segment.reading.load(Ordering::Acquire);
        let end = segment.end.load(Ordering::Acquire);
        if byte == pty_byte(BASE) {
            assert!(
                reading == BASE + 1 || end == BASE + 2,
                "a read's bytes are in the ring with no mark and no end (reading {reading}, end {end})"
            );
        }
        holder.join().unwrap();
    });
}
