//! The input queues' backstop ([`INPUT_QUEUE_BACKSTOP`](super::super::creating_input)) on an
//! injected clock: a queue whose creation never ends is given back once, after 120 s on that
//! clock, and a creation that ends before it takes its queue. No test waits for real time.

use super::*;
use crate::mux::creating_input::{InputQueueClock, TerminalInputTarget, UnclaimedNotice};

const TERMINAL: &str = "000000000000000000000000b4c457a1";
/// How long a "not given back yet" check waits: a backstop thread woken by a clock move gives
/// back within a few ms, so a check that does not wait passes even with a wrong deadline.
const NOT_YET: Duration = Duration::from_millis(300);

/// A clock the test moves by hand.
struct ManualClock {
    start: Instant,
    moved: Mutex<Duration>,
}

impl ManualClock {
    fn new() -> Arc<Self> {
        Arc::new(Self { start: Instant::now(), moved: Mutex::new(Duration::ZERO) })
    }

    /// Moves the clock to `at` after its start and wakes every backstop to read it.
    fn move_to(&self, mux: &Mux, at: Duration) {
        *self.moved.lock().unwrap() = at;
        mux.wake_input_queue_backstops_for_test();
    }
}

impl InputQueueClock for ManualClock {
    fn now(&self) -> Instant {
        self.start + *self.moved.lock().unwrap()
    }
}

/// One give-back: its bytes and reason.
type GivenBack = (Vec<u8>, String);

/// A creation of [`TERMINAL`] that has not committed, with bytes queued for it by connection 7.
struct QueuedCreation {
    mux: Arc<Mux>,
    clock: Arc<ManualClock>,
    generation: u64,
    /// Each give-back of the queue.
    back: Receiver<GivenBack>,
}

fn queued_creation(bytes: &[u8]) -> QueuedCreation {
    let mux = test_mux();
    let clock = ManualClock::new();
    mux.set_input_queue_clock_for_test(clock.clone());
    let generation = mux.begin_creating_input(TERMINAL, 7).expect("no live terminal has the id");
    let (given, back) = std::sync::mpsc::channel();
    let given = Mutex::new(given);
    let notice: UnclaimedNotice = Arc::new(move |_: &str, bytes: &[u8], reason: &str| {
        let _ = given.lock().unwrap().send((bytes.to_vec(), reason.to_owned()));
    });
    let target = mux.write_terminal_input(TERMINAL, 7, bytes, false, notice).unwrap();
    assert_eq!(target, TerminalInputTarget::Queued);
    QueuedCreation { mux, clock, generation, back }
}

#[test]
fn a_creation_that_never_ends_gives_its_input_back_at_the_backstop() {
    let QueuedCreation { mux, clock, back, .. } = queued_creation(b"echo typed\r");
    // Past the old 10 s give-back, and just short of the backstop: the queue stays.
    clock.move_to(&mux, Duration::from_secs(119));
    assert!(back.recv_timeout(NOT_YET).is_err(), "given back before the backstop");
    assert!(mux.knows_terminal_input_target(TERMINAL), "the queue was dropped before the backstop");
    // Past the backstop: given back once, whole, as "expired", and counted.
    clock.move_to(&mux, Duration::from_secs(121));
    let (bytes, reason) = back.recv_timeout(Duration::from_secs(10)).expect("never given back");
    assert_eq!((bytes.as_slice(), reason.as_str()), (&b"echo typed\r"[..], "expired"));
    assert_eq!(mux.input_queue_backstop_give_backs_for_test(), 1);
    assert!(back.recv_timeout(NOT_YET).is_err(), "given back twice");
}

#[test]
fn a_creation_that_ends_after_the_old_expiry_keeps_its_queue_until_its_end() {
    let QueuedCreation { mux, clock, generation, back } = queued_creation(b"ls\r");
    clock.move_to(&mux, Duration::from_secs(60));
    assert!(back.recv_timeout(NOT_YET).is_err(), "given back before the creation ended");
    // The creation fails now: its end gives the queue back with its own reason, not the backstop.
    mux.finish_creating_input(TERMINAL, generation, Some("failed"));
    let (bytes, reason) = back.recv_timeout(Duration::from_secs(10)).expect("never given back");
    assert_eq!((bytes.as_slice(), reason.as_str()), (&b"ls\r"[..], "failed"));
    // The backstop of that queue ends with it.
    clock.move_to(&mux, Duration::from_secs(600));
    assert!(back.recv_timeout(NOT_YET).is_err(), "given back twice");
    assert_eq!(mux.input_queue_backstop_give_backs_for_test(), 0);
}
