use super::*;
use std::cell::RefCell;
use std::rc::Rc;

/// One write the child can read, with when it went out after the start.
type TimedWrite = (Vec<u8>, Duration);

/// A clock that moves only when slept, and records every write with the time it was made.
struct FakeClock {
    now: Instant,
}

impl PaceClock for FakeClock {
    fn now(&self) -> Instant {
        self.now
    }

    fn sleep(&mut self, duration: Duration) {
        self.now += duration;
    }
}

/// The child's input queue: the bytes written that it has not read yet.
struct Child {
    queued: usize,
}

fn paste(len: usize) -> Vec<u8> {
    let mut bytes = b"\x1b[200~".to_vec();
    bytes.extend((0..len).map(|index| b"abcdefghij "[index % 11]));
    bytes.extend_from_slice(PASTE_END);
    bytes
}

#[test]
fn return_in_the_same_write_as_a_multi_kb_paste_is_its_own_write_after_the_paste_was_read() {
    // The phone's composer: an 8 KB bracketed paste and its Return, coalesced into one write.
    let paste = paste(8 * 1024);
    let mut payload = paste.clone();
    payload.push(b'\r');
    let start = Instant::now();
    let mut clock = FakeClock { now: start };
    let child = Rc::new(RefCell::new(Child { queued: 0 }));
    let writes: Rc<RefCell<Vec<TimedWrite>>> = Rc::default();
    let mut pacer = PastePacer::default();
    // The child reads 1 KB every 5 ms poll: whatever was written stays queued until then.
    let reader = Rc::clone(&child);
    let mut unread = move || {
        let mut child = reader.borrow_mut();
        let pending = child.queued;
        child.queued = child.queued.saturating_sub(1024);
        Some(pending)
    };
    let (sink, queue) = (Rc::clone(&writes), Rc::clone(&child));
    let now = Rc::new(RefCell::new(start));
    let stamp = Rc::clone(&now);
    let mut write = move |piece: &[u8]| -> Result<(), ()> {
        // The macOS queue holds 1022 bytes: the write returns with that much of the paste unread.
        queue.borrow_mut().queued = piece.len().min(1022);
        sink.borrow_mut().push((piece.to_vec(), stamp.borrow().saturating_duration_since(start)));
        Ok(())
    };
    // The fake clock's time, as the write closure sees it.
    struct Shared<'a> {
        clock: &'a mut FakeClock,
        now: Rc<RefCell<Instant>>,
    }
    impl PaceClock for Shared<'_> {
        fn now(&self) -> Instant {
            self.clock.now()
        }
        fn sleep(&mut self, duration: Duration) {
            self.clock.sleep(duration);
            *self.now.borrow_mut() = self.clock.now();
        }
    }
    let mut shared = Shared { clock: &mut clock, now };
    pacer.write(&payload, &mut unread, &mut shared, &mut write).unwrap();
    let writes = writes.borrow();
    assert_eq!(writes.len(), 2, "the paste and its Return are two writes");
    assert_eq!(writes[0].0, paste, "the first write is the whole paste, through its end marker");
    assert_eq!(writes[1].0, b"\r", "Return is a write of its own");
    // The child needed one poll to read the 1022 queued bytes; Return waited for that and the settle.
    assert!(writes[1].1 >= SETTLE, "Return waited {:?}", writes[1].1);
    assert!(writes[1].1 < DRAIN_LIMIT, "Return waited {:?}", writes[1].1);
}

#[test]
fn return_after_a_paste_frame_waits_until_the_child_read_it_then_the_settle() {
    let start = Instant::now();
    let mut clock = FakeClock { now: start };
    let mut pacer = PastePacer::default();
    pacer.paste_written(&clock);
    // 3 KB still unread, read at 1 KB per poll.
    let mut queued = 3 * 1024usize;
    let mut unread = || {
        let pending = queued;
        queued = queued.saturating_sub(1024);
        Some(pending)
    };
    let waited = pacer.settle(&mut unread, &mut clock);
    assert_eq!(waited, POLL * 3 + SETTLE);
    // The next key after that waits for nothing.
    assert_eq!(pacer.settle(&mut || Some(0), &mut clock), Duration::ZERO);
}

#[test]
fn a_key_long_after_a_paste_waits_for_nothing() {
    let start = Instant::now();
    let mut clock = FakeClock { now: start };
    let mut pacer = PastePacer::default();
    pacer.paste_written(&clock);
    clock.sleep(Duration::from_secs(1));
    assert_eq!(pacer.settle(&mut || Some(0), &mut clock), Duration::ZERO);
}

#[test]
fn without_a_queue_count_input_waits_the_settle_after_the_paste() {
    let mut clock = FakeClock { now: Instant::now() };
    let mut pacer = PastePacer::default();
    pacer.paste_written(&clock);
    clock.sleep(Duration::from_millis(50));
    assert_eq!(pacer.settle(&mut || None, &mut clock), SETTLE - Duration::from_millis(50));
}

#[test]
fn a_child_that_stopped_reading_gets_its_input_after_the_drain_limit() {
    let start = Instant::now();
    let mut clock = FakeClock { now: start };
    let mut pacer = PastePacer::default();
    pacer.paste_written(&clock);
    let waited = pacer.settle(&mut || Some(1022), &mut clock);
    assert_eq!(waited, DRAIN_LIMIT + SETTLE);
}

#[test]
fn input_with_no_paste_is_written_whole_at_once() {
    let mut clock = FakeClock { now: Instant::now() };
    let start = clock.now();
    let mut pacer = PastePacer::default();
    let mut writes = Vec::new();
    pacer
        .write(b"ls -la\r", &mut || Some(0), &mut clock, &mut |piece: &[u8]| -> Result<(), ()> {
            writes.push(piece.to_vec());
            Ok(())
        })
        .unwrap();
    assert_eq!(writes, vec![b"ls -la\r".to_vec()]);
    assert_eq!(clock.now(), start);
}

#[test]
fn pieces_cut_after_every_paste_end() {
    let cut: Vec<&[u8]> = pieces(b"\x1b[200~a\x1b[201~\x1b[200~b\x1b[201~\r").collect();
    assert_eq!(cut, vec![&b"\x1b[200~a\x1b[201~"[..], b"\x1b[200~b\x1b[201~", b"\r"]);
    assert_eq!(pieces(b"\x1b[200~a\x1b[201~").count(), 1);
    assert_eq!(pieces(b"").count(), 0);
}
