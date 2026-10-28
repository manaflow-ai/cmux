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
//!   loom picks: after any header word the protocol stores (its
//!   `KillPoint`), before or after a `read(2)`, or between data bytes. The
//!   daemon then sees the segment as the dead holder left it (a join: the
//!   link ended), adopts it the way a new holder does, and checks that every
//!   byte it trusts is the byte first written at that offset, that a read
//!   the kernel completed but whose end was never published is named at the
//!   adopted end (the loss is never silent), that a `reading` behind its end
//!   names no loss, and that the new holder continues the stream at that
//!   end.
//! - Ordering, against a reader thread running at the same time: a
//!   published `end` carries every byte below it (Release/Acquire); the
//!   forfeit fence puts the new `oldest` before the bytes a write
//!   overwrites; the `reading` marker is in place before a read's bytes and
//!   cleared only after its end.
//!
//! Each model counts the states its assertions are about ([`Reached`]) and
//! fails when loom never reached one, so no check passes for want of a case.
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
use ring_protocol::{Cursor, KillPoint, Snapshot, Words, interrupted_read, published_end};

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

/// Run `model` under loom in every interleaving with at most three
/// preemptions: a kill or a reader's look lands anywhere in the writer
/// with one switch there and one back.
fn explore(model: impl Fn() + Sync + Send + 'static) {
    let mut builder = loom::model::Builder::new();
    builder.preemption_bound = Some(3);
    builder.check(model);
}

/// A writer no one kills.
struct Alive;

impl KillPoint for Alive {
    fn reached(&self) {}
}

/// The SIGKILL a killer thread sends: the writer stops at its next kill
/// point after it.
struct Killer(AtomicBool);

/// The unwind payload of a killed writer: no panic hook runs for it.
struct Killed;

impl Killer {
    fn new() -> Self {
        Self(AtomicBool::new(false))
    }

    fn kill(&self) {
        self.0.store(true, Ordering::SeqCst);
    }

    /// Run `writer` until it returns or the kill stops it.
    fn run(&self, writer: impl FnOnce()) {
        if let Err(payload) = catch_unwind(AssertUnwindSafe(writer))
            && !payload.is::<Killed>()
        {
            resume_unwind(payload);
        }
    }
}

impl KillPoint for Killer {
    fn reached(&self) {
        if self.0.load(Ordering::SeqCst) {
            resume_unwind(Box::new(Killed));
        }
    }
}

/// How many model executions reached each of a model's named states;
/// outside loom, so it counts across executions. The model asserts at the
/// end that it reached every one.
struct Reached {
    states: &'static [&'static str],
    counts: Vec<std::sync::atomic::AtomicUsize>,
}

impl Reached {
    fn new(states: &'static [&'static str]) -> std::sync::Arc<Self> {
        let counts = states.iter().map(|_| std::sync::atomic::AtomicUsize::new(0)).collect();
        std::sync::Arc::new(Self { states, counts })
    }

    fn note(&self, state: &'static str) {
        let index = self.states.iter().position(|named| *named == state);
        let index = index.unwrap_or_else(|| panic!("{state} is not a state of this model"));
        self.counts[index].fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    }

    fn assert_all(&self) {
        for (state, count) in self.states.iter().zip(&self.counts) {
            let count = count.load(std::sync::atomic::Ordering::Relaxed);
            assert!(count > 0, "the model never reached: {state}");
        }
    }
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

    /// The header words, for a writer no one kills.
    fn words(&self) -> Words<'_> {
        self.words_of(&Alive)
    }

    /// The header words, for a writer that stops at `writer`'s kill points.
    fn words_of<'a>(&'a self, writer: &'a dyn KillPoint) -> Words<'a> {
        Words { end: &self.end, oldest: &self.oldest, reading: &self.reading, kill_point: writer }
    }

    /// The initial cursor of a new segment, as `Ring::adopt` reads it.
    fn cursor(&self) -> Cursor {
        Snapshot::load(&self.words()).adopt(CAPACITY, BASE, true).unwrap()
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

    /// `push` from the PTY stream: `data` is the bytes at `from ..`; the
    /// writer may stop before any data byte.
    fn push(&self, writer: &dyn KillPoint, cursor: &mut Cursor, from: u64, len: usize) {
        let data: Vec<u8> = (from..from + len as u64).map(pty_byte).collect();
        cursor.push(&self.words_of(writer), &data, |range, bytes| {
            for (position, &byte) in range.zip(bytes) {
                writer.reached();
                self.store(position, byte);
            }
        });
    }
}

/// One `read(2)` of the holder: the kernel takes `got` bytes of the PTY
/// stream from `taken` and copies them into `room` in one step (a SIGKILL
/// lands before the syscall or after it returns, never inside).
fn pty_read(
    segment: &Segment,
    taken: &AtomicU64,
    writer: &dyn KillPoint,
    room: Range<usize>,
    got: isize,
) -> isize {
    writer.reached();
    if got <= 0 {
        return got;
    }
    let n = room.len().min(got as usize);
    let from = taken.load(Ordering::Relaxed);
    for (index, position) in room.take(n).enumerate() {
        segment.store(position, pty_byte(from + index as u64));
    }
    taken.store(from + n as u64, Ordering::Relaxed);
    writer.reached();
    n as isize
}

/// The daemon's checks on the segment of a holder that died anywhere in
/// its reads, and the new holder's continuation. `taken` is how far the
/// kernel read the PTY stream. The ring numbers the stream one to one up to
/// the dead holder's last published end.
fn check_handoff(segment: &Segment, taken: u64, reached: &Reached) {
    let words = segment.words();
    let end = published_end(&words);
    let reading = segment.reading.load(Ordering::Relaxed);
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
        reached.note("a read taken but not published");
        assert_eq!(
            interrupted,
            Some(end),
            "{} bytes the kernel took were lost silently",
            taken - end
        );
    }
    // A holder killed after it published a read's end, before it cleared
    // `reading`, lost nothing.
    if reading != 0 && reading <= end {
        reached.note("a reading behind its end");
        assert_eq!(interrupted, None, "reading {reading} behind end {end} names a false loss");
    }
    if let Some(at) = interrupted {
        reached.note("a named loss");
        assert_eq!(at, end, "a loss is named only at the adopted end");
    }
    assert!(taken >= end, "the ring published bytes the kernel never read");

    // The new holder reads on from where the kernel left the PTY; its first
    // byte has the dead ring's end as offset, and its read clears the mark.
    let pty = AtomicU64::new(taken);
    let n = cursor.read_with(&words, CAPACITY, |room| pty_read(segment, &pty, &Alive, room, 1));
    assert_eq!(n, 1);
    assert_eq!(interrupted_read(&words), None, "the new holder's read clears the mark");
    let (from, head, _) = cursor.window(end, 1);
    assert_eq!((from, segment.byte(head.start)), (end, pty_byte(taken)));
}

/// A holder whose ring starts with `filled` bytes runs `reads` (each
/// `(max, got)`: the room it offers at most, what `read(2)` returns) while
/// a killer may SIGKILL it at any kill point; the daemon then takes the
/// segment over ([`check_handoff`]).
fn kill_anywhere(filled: usize, reads: &'static [(usize, isize)]) {
    let reached = Reached::new(&[
        "a read taken but not published",
        "a reading behind its end",
        "a named loss",
    ]);
    explore({
        let reached = reached.clone();
        move || {
            let segment = Arc::new(Segment::new(BASE));
            let mut cursor = segment.cursor();
            segment.push(&Alive, &mut cursor, BASE, filled);
            let taken = Arc::new(AtomicU64::new(BASE + filled as u64));
            let killer = Arc::new(Killer::new());

            let holder = {
                let (segment, taken, killer) = (segment.clone(), taken.clone(), killer.clone());
                thread::spawn(move || {
                    killer.run(|| {
                        let words = segment.words_of(&*killer);
                        for &(max, got) in reads {
                            cursor.read_with(&words, max, |room| {
                                pty_read(&segment, &taken, &*killer, room, got)
                            });
                        }
                    });
                })
            };
            let kill = {
                let killer = killer.clone();
                thread::spawn(move || killer.kill())
            };
            kill.join().unwrap();
            // The link ended: everything the dead holder stored is in the segment.
            holder.join().unwrap();
            check_handoff(&segment, taken.load(Ordering::Relaxed), &reached);
        }
    });
    reached.assert_all();
}

/// Short reads, a read with nothing to read, and wraps over kept bytes.
#[test]
fn a_holder_killed_anywhere_in_its_reads_leaves_whole_bytes_and_names_its_loss() {
    kill_anywhere(3, &[(8, 3), (8, WOULD_BLOCK), (2, 2)]);
}

/// Reads that each reuse the room of the oldest kept bytes, from a full
/// ring; the first is one byte, so its `reading` equals its published end.
#[test]
fn a_holder_killed_while_reads_overwrite_a_full_ring_keeps_no_overwritten_byte() {
    kill_anywhere(4, &[(1, 1), (8, 2), (8, 4)]);
}

/// A push larger than the ring publishes no skipped offset as a byte, wherever
/// its writer stops (after any word store or before any data byte).
#[test]
fn an_oversized_push_killed_anywhere_keeps_only_its_tail() {
    let reached = Reached::new(&["the skipped offsets dropped"]);
    explore({
        let reached = reached.clone();
        move || {
            let segment = Arc::new(Segment::new(BASE));
            let killer = Arc::new(Killer::new());
            let holder = {
                let (segment, killer) = (segment.clone(), killer.clone());
                thread::spawn(move || {
                    let mut cursor = segment.cursor();
                    killer.run(|| segment.push(&*killer, &mut cursor, BASE, 6));
                })
            };
            killer.kill();
            holder.join().unwrap();
            let cursor = segment.adopt();
            assert!(cursor.oldest() >= BASE && cursor.end() <= BASE + 6);
            if cursor.oldest() > BASE {
                reached.note("the skipped offsets dropped");
            }
            for (offset, byte) in segment.kept(&cursor) {
                assert_eq!(byte, pty_byte(offset), "offset {offset} is trusted with a wrong byte");
            }
        }
    });
    reached.assert_all();
}

/// A reader thread that loads a published `end` sees every byte below it,
/// and a window decoded at any moment never names more than the capacity.
/// `write` stores offsets 10, 11 at positions 2, 3, then 12 at 0 (no kept
/// byte is overwritten), publishing an end after each piece.
fn a_published_end_carries_every_byte_below_it(write: fn(&Segment)) {
    let reached = Reached::new(&["a published end past the base"]);
    explore({
        let reached = reached.clone();
        move || {
            let segment = Arc::new(Segment::new(BASE));
            let holder = {
                let segment = segment.clone();
                thread::spawn(move || write(&segment))
            };
            let reader = {
                let (segment, reached) = (segment.clone(), reached.clone());
                thread::spawn(move || {
                    let words = segment.words();
                    let end = published_end(&words);
                    assert!((BASE..=BASE + 3).contains(&end));
                    if end > BASE {
                        reached.note("a published end past the base");
                    }
                    for offset in BASE..end {
                        assert_eq!(
                            segment.byte((offset % CAPACITY as u64) as usize),
                            pty_byte(offset),
                            "end {end} is published without the byte at {offset}"
                        );
                    }
                    let window = Snapshot::load(&words).adopt(CAPACITY, BASE, true).unwrap();
                    assert!(
                        window.oldest() <= window.end()
                            && window.end() - window.oldest() <= CAPACITY as u64
                    );
                    if let Some(at) = interrupted_read(&words) {
                        assert!(
                            at == BASE || at == BASE + 2,
                            "a loss named at {at}, where no read started"
                        );
                    }
                })
            };
            holder.join().unwrap();
            reader.join().unwrap();
        }
    });
    reached.assert_all();
}

/// Two PTY reads: their `end` stores carry the bytes the kernel stored.
#[test]
fn a_reads_published_end_carries_every_byte_below_it() {
    a_published_end_carries_every_byte_below_it(|segment| {
        let mut cursor = segment.cursor();
        let taken = AtomicU64::new(BASE);
        for got in [2, 1] {
            cursor.read_with(&segment.words(), CAPACITY, |room| {
                pty_read(segment, &taken, &Alive, room, got)
            });
        }
    });
}

/// One push that wraps: its `end` store per piece carries that piece.
#[test]
fn a_pushs_published_end_carries_every_byte_below_it() {
    a_published_end_carries_every_byte_below_it(|segment| {
        let mut cursor = segment.cursor();
        segment.push(&Alive, &mut cursor, BASE, 3);
    });
}

/// The forfeit fence: a reader that sees a byte a write stored over a kept
/// byte, then fences, sees the `oldest` that dropped the old byte. `write`
/// stores offset 14 at position 2, over offset 10, into a full ring.
fn overwrite_publishes_oldest_first(write: fn(&Segment, &mut Cursor)) {
    let reached = Reached::new(&["an overwritten byte"]);
    let observed = reached.clone();
    explore(move || {
        let segment = Arc::new(Segment::new(BASE));
        let mut cursor = segment.cursor();
        // A full ring: offsets 10..14 at positions 2, 3, 0, 1.
        segment.push(&Alive, &mut cursor, BASE, CAPACITY);
        let holder = {
            let segment = segment.clone();
            thread::spawn(move || write(&segment, &mut cursor))
        };
        let byte = segment.byte(2);
        fence(Ordering::Acquire);
        let oldest = segment.oldest.load(Ordering::Acquire);
        if byte == pty_byte(BASE + CAPACITY as u64) {
            observed.note("an overwritten byte");
            assert!(oldest > BASE, "offset {BASE} is still kept after its byte was overwritten");
        } else {
            assert_eq!(byte, pty_byte(BASE));
        }
        holder.join().unwrap();
    });
    reached.assert_all();
}

/// A PTY read: its `reading` fence comes after the forfeit too.
#[test]
fn a_read_publishes_the_new_oldest_before_it_overwrites() {
    overwrite_publishes_oldest_first(|segment, cursor| {
        let taken = AtomicU64::new(BASE + CAPACITY as u64);
        cursor.read_with(&segment.words(), 1, |room| pty_read(segment, &taken, &Alive, room, 1));
    });
}

/// A push: the forfeit fence alone orders its overwrite.
#[test]
fn a_push_publishes_the_new_oldest_before_it_overwrites() {
    overwrite_publishes_oldest_first(|segment, cursor| {
        segment.push(&Alive, cursor, BASE + CAPACITY as u64, 1);
    });
}

/// The `reading` marker: a reader that sees a byte a read stored, then
/// fences, sees the marker, or the read's published end (the marker is
/// cleared only after it). A read's bytes are never taken unmarked.
#[test]
fn a_reads_bytes_are_marked_until_its_end_is_published() {
    let reached = Reached::new(&["a read's byte"]);
    let observed = reached.clone();
    explore(move || {
        let segment = Arc::new(Segment::new(BASE));
        let holder = {
            let segment = segment.clone();
            thread::spawn(move || {
                let mut cursor = segment.cursor();
                let taken = AtomicU64::new(BASE);
                cursor.read_with(&segment.words(), CAPACITY, |room| {
                    pty_read(&segment, &taken, &Alive, room, 2)
                });
            })
        };
        // Offset 10 is at position 2.
        let byte = segment.byte(2);
        fence(Ordering::Acquire);
        let reading = segment.reading.load(Ordering::Acquire);
        let end = segment.end.load(Ordering::Acquire);
        if byte == pty_byte(BASE) {
            observed.note("a read's byte");
            assert!(
                reading == BASE + 1 || end == BASE + 2,
                "a read's bytes are in the ring with no mark and no end (reading {reading}, end {end})"
            );
        }
        holder.join().unwrap();
    });
    reached.assert_all();
}

/// A release (`Ring::release_before`): `drop_before`
/// publishes the new `oldest`, then the holder gives the dropped bytes'
/// pages to the kernel, which may read them as zeros. A holder killed
/// anywhere in it leaves a segment whose adopter trusts no given-away byte.
/// Full ring: offsets 10..14; the release drops 10 and 11 (positions 2, 3).
fn release(segment: &Segment, writer: &dyn KillPoint, cursor: &mut Cursor) {
    if cursor.drop_before(&segment.words_of(writer), BASE + 2) {
        for offset in BASE..BASE + 2 {
            writer.reached();
            segment.store((offset % CAPACITY as u64) as usize, 0);
        }
    }
}

#[test]
fn a_holder_killed_anywhere_in_a_release_trusts_no_given_away_byte() {
    let reached = Reached::new(&["a byte given away"]);
    explore({
        let reached = reached.clone();
        move || {
            let segment = Arc::new(Segment::new(BASE));
            let mut cursor = segment.cursor();
            segment.push(&Alive, &mut cursor, BASE, CAPACITY);
            let killer = Arc::new(Killer::new());
            let holder = {
                let (segment, killer) = (segment.clone(), killer.clone());
                thread::spawn(move || killer.run(|| release(&segment, &*killer, &mut cursor)))
            };
            killer.kill();
            holder.join().unwrap();
            if segment.byte(2) == 0 {
                reached.note("a byte given away");
            }
            let cursor = segment.adopt();
            assert_eq!(cursor.end(), BASE + CAPACITY as u64);
            for (offset, byte) in segment.kept(&cursor) {
                assert_eq!(byte, pty_byte(offset), "offset {offset} is trusted with a wrong byte");
            }
        }
    });
    reached.assert_all();
}

/// The release fence: a reader that sees a given-away byte, then fences,
/// sees the `oldest` that dropped it.
#[test]
fn a_release_publishes_the_new_oldest_before_a_page_goes() {
    let reached = Reached::new(&["a byte given away"]);
    let observed = reached.clone();
    explore(move || {
        let segment = Arc::new(Segment::new(BASE));
        let mut cursor = segment.cursor();
        segment.push(&Alive, &mut cursor, BASE, CAPACITY);
        let holder = {
            let segment = segment.clone();
            thread::spawn(move || release(&segment, &Alive, &mut cursor))
        };
        // Offset 10 is at position 2.
        let byte = segment.byte(2);
        fence(Ordering::Acquire);
        let oldest = segment.oldest.load(Ordering::Acquire);
        if byte == 0 {
            observed.note("a byte given away");
            assert!(oldest >= BASE + 2, "offset {BASE} is still kept after its page went");
        } else {
            assert_eq!(byte, pty_byte(BASE));
        }
        holder.join().unwrap();
    });
    reached.assert_all();
}
