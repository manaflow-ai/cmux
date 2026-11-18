//! A Keychain call that never answers (a locked, prompting or stuck Keychain) still answers within the deadline,
//! with the refusal naming its item, and never holds another call behind it for longer than that.

use std::ffi::c_void;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_cloud_config::keychain::Item;
use cmux_layout_reducer_ffi::keychain::{Gate, bounded, cmux_keychain_bounded};
use cmux_layout_reducer_ffi::{ERR_INVALID, OK};
use serde_json::Value;

const DEADLINE: Duration = Duration::from_millis(300);
/// Slack for a busy test host: well under the stalled call's own hold.
const SLACK: Duration = Duration::from_millis(1500);
/// How long a stalled call holds when nothing releases it: past the deadline and the slack, so a call that waited
/// for it (no deadline) answers late and the assertions see it.
const HOLD: Duration = Duration::from_secs(6);

fn install_key() -> Item {
    Item {
        service: "com.cmuxterm.app.next.install-key.api.cmux.dev".into(),
        account: "install-key-0123456789abcdef".into(),
    }
}

/// A Keychain call that answers only when the test lets it (or after [`HOLD`]).
fn stalled() -> (Sender<()>, impl FnOnce() -> &'static str + Send + 'static) {
    let (release, held) = mpsc::channel::<()>();
    (release, move || {
        let _ = held.recv_timeout(HOLD);
        "late"
    })
}

#[test]
fn a_stalled_call_answers_nothing_within_the_deadline() {
    let gate = Gate::default();
    let (release, work) = stalled();
    let started = Instant::now();
    let answer = gate.run(&install_key(), DEADLINE, work);
    let waited = started.elapsed();
    let _ = release.send(());
    assert_eq!(answer, None, "a call that never answers must not be waited for");
    assert!(waited >= DEADLINE, "answered before the deadline: {waited:?}");
    assert!(waited < DEADLINE + SLACK, "waited {waited:?}, past the deadline {DEADLINE:?}");
}

#[test]
fn a_call_that_answers_in_time_gives_its_answer() {
    let gate = Gate::default();
    assert_eq!(gate.run(&install_key(), DEADLINE, || 7), Some(7));
    // The item is free again: the next call runs too.
    assert_eq!(gate.run(&install_key(), DEADLINE, || 8), Some(8));
}

#[test]
fn an_item_stuck_past_its_deadline_refuses_the_next_call_at_once_and_runs_nothing() {
    let gate = Gate::default();
    let (release, work) = stalled();
    assert_eq!(gate.run(&install_key(), DEADLINE, work), None);
    let ran = Arc::new(Mutex::new(false));
    let marked = Arc::clone(&ran);
    let started = Instant::now();
    let answer = gate.run(&install_key(), DEADLINE, move || *marked.lock().unwrap() = true);
    let waited = started.elapsed();
    assert_eq!(answer, None);
    assert!(waited < DEADLINE, "a call on a stuck item waited {waited:?}");
    assert!(!*ran.lock().unwrap(), "a second call stacked behind the stuck one");
    // Another item is not held by it.
    let other = Item { account: "install-key-fedcba9876543210".into(), ..install_key() };
    assert_eq!(gate.run(&other, DEADLINE, || 1), Some(1));
    // Once the stuck call answers, the item takes calls again.
    let _ = release.send(());
    let deadline = Instant::now() + HOLD;
    loop {
        if gate.run(&install_key(), DEADLINE, || 2) == Some(2) {
            break;
        }
        assert!(Instant::now() < deadline, "the item stayed stuck after its call answered");
        // The stuck call's thread frees the item right after it returns.
        std::thread::yield_now();
    }
}

#[test]
fn a_call_behind_one_still_running_waits_for_it_within_its_own_deadline() {
    let gate = Gate::default();
    let (release, held) = mpsc::channel::<()>();
    let (took, taken) = mpsc::channel::<()>();
    let first = {
        let gate = gate.clone();
        std::thread::spawn(move || {
            gate.run(&install_key(), Duration::from_secs(5), move || {
                let _ = took.send(());
                let _ = held.recv_timeout(HOLD);
                "first"
            })
        })
    };
    // The first call holds the item: the second finds it in flight.
    taken.recv_timeout(HOLD).expect("the first call never ran");
    let second = {
        let gate = gate.clone();
        std::thread::spawn(move || gate.run(&install_key(), Duration::from_secs(5), || "second"))
    };
    let _ = release.send(());
    assert_eq!(first.join().unwrap(), Some("first"));
    assert_eq!(second.join().unwrap(), Some("second"));
}

/// What `done` saw: `answered` and the refusal, if any.
type Answers = Receiver<(u8, Option<Value>)>;

/// The app's side of the C entry: what `done` and `release` saw.
struct Probe {
    held: Mutex<Option<Receiver<()>>>,
    worked: Mutex<bool>,
    done: Sender<(u8, Option<Value>)>,
    released: Sender<()>,
}

unsafe extern "C" fn probe_work(context: *mut c_void) {
    // SAFETY: the test's Probe, alive until release.
    let probe = unsafe { &*(context as *const Probe) };
    let held = probe.held.lock().unwrap().take();
    if let Some(held) = held {
        let _ = held.recv_timeout(HOLD);
    }
    *probe.worked.lock().unwrap() = true;
}

unsafe extern "C" fn probe_done(
    context: *mut c_void,
    answered: u8,
    refusal: *const u8,
    refusal_len: usize,
) {
    // SAFETY: as above; `refusal` is `refusal_len` readable bytes during the call.
    let probe = unsafe { &*(context as *const Probe) };
    let refusal = (refusal_len > 0).then(|| {
        serde_json::from_slice(unsafe { std::slice::from_raw_parts(refusal, refusal_len) }).unwrap()
    });
    let _ = probe.done.send((answered, refusal));
}

unsafe extern "C" fn probe_release(context: *mut c_void) {
    // SAFETY: the Box made in `probe`, freed once.
    let probe = unsafe { Box::from_raw(context as *mut Probe) };
    let _ = probe.released.send(());
}

fn probe(held: Option<Receiver<()>>) -> (*mut c_void, Answers, Receiver<()>) {
    let (done, answers) = mpsc::channel();
    let (released, releases) = mpsc::channel();
    let probe =
        Box::new(Probe { held: Mutex::new(held), worked: Mutex::new(false), done, released });
    (Box::into_raw(probe).cast(), answers, releases)
}

fn request(item: &Item) -> Vec<u8> {
    serde_json::to_vec(item).unwrap()
}

#[test]
fn the_c_entry_answers_a_stalled_call_with_the_refusal_naming_its_item() {
    let gate = Gate::default();
    let (release, held) = mpsc::channel();
    let (context, answers, releases) = probe(Some(held));
    let started = Instant::now();
    // SAFETY: the probe's callbacks and context.
    let code = unsafe {
        bounded(
            &gate,
            DEADLINE,
            &request(&install_key()),
            context,
            probe_work,
            probe_done,
            probe_release,
        )
    };
    assert_eq!(code, OK);
    assert!(started.elapsed() < DEADLINE, "the C entry waited on the call");
    let (answered, refusal) =
        answers.recv_timeout(DEADLINE + SLACK).expect("no answer within the deadline");
    assert!(started.elapsed() >= DEADLINE);
    assert_eq!(answered, 0);
    let refusal = refusal.expect("a stalled call answers its refusal");
    assert_eq!(refusal["code"], "owner.unreachable");
    let message = refusal["message"].as_str().unwrap();
    assert!(
        message.contains("\"com.cmuxterm.app.next.install-key.api.cmux.dev\" (account install-key-0123456789abcdef)"),
        "the refusal does not name the item: {message}"
    );
    assert_eq!(refusal["details"]["keychain"]["account"], "install-key-0123456789abcdef");
    // The stalled call still holds the context: it is released only once the call returns.
    assert!(releases.try_recv().is_err(), "released while the call still ran");
    let _ = release.send(());
    releases.recv_timeout(HOLD).expect("never released after the call returned");
}

#[test]
fn the_c_entry_answers_a_call_that_returns_in_time() {
    let gate = Gate::default();
    let (context, answers, releases) = probe(None);
    // SAFETY: the probe's callbacks and context.
    let code = unsafe {
        bounded(
            &gate,
            DEADLINE,
            &request(&install_key()),
            context,
            probe_work,
            probe_done,
            probe_release,
        )
    };
    assert_eq!(code, OK);
    assert_eq!(answers.recv_timeout(DEADLINE + SLACK).unwrap(), (1, None));
    releases.recv_timeout(SLACK).expect("never released");
}

#[test]
fn the_c_entry_refuses_a_bad_request_and_calls_nothing() {
    let (context, answers, releases) = probe(None);
    let body = b"{\"service\":1}";
    // SAFETY: the probe's callbacks and context; a refused call leaves the context to the caller.
    let code = unsafe {
        cmux_keychain_bounded(
            body.as_ptr(),
            body.len(),
            context,
            Some(probe_work),
            Some(probe_done),
            Some(probe_release),
        )
    };
    assert_eq!(code, ERR_INVALID);
    assert!(answers.try_recv().is_err() && releases.try_recv().is_err());
    // SAFETY: still ours.
    unsafe { probe_release(context) };
}
