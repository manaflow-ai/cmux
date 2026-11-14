//! The first machine list's wait, driven the way its callers drive it, with a list that answers late.

use super::*;

/// One read of a list that loads `loads_at` into the wait (`None`: never); each read takes `read`.
struct LateList {
    clock: Duration,
    loads_at: Option<Duration>,
    read: Duration,
    reads: usize,
}

impl LateList {
    fn loaded(&self) -> bool {
        self.loads_at.is_some_and(|at| self.clock >= at)
    }

    /// The loop both starts run: ask, pause, read again as told. Its last answer and when it came.
    fn run(&mut self, deadline: Option<Duration>) -> (ListWait, Duration) {
        loop {
            let left = deadline.map(|end| end.saturating_sub(self.clock));
            match list_wait(self.clock, left, self.loaded(), true) {
                ListWait::Pause { pause_ms, read_after } => {
                    assert!(pause_ms > 0, "a pause that is no pause would spin");
                    self.clock += Duration::from_millis(pause_ms);
                    if read_after {
                        self.reads += 1;
                        self.clock += self.read;
                    }
                }
                done => return (done, self.clock),
            }
        }
    }
}

fn late(loads_at: Option<u64>, read_ms: u64) -> LateList {
    LateList {
        clock: Duration::ZERO,
        loads_at: loads_at.map(Duration::from_secs),
        read: Duration::from_millis(read_ms),
        reads: 0,
    }
}

/// An app just launched loads its list a few seconds after sign-in: the start reads it again
/// [`LIST_LOAD_POLL`] apart and goes on once it is loaded, instead of refusing it at once.
#[test]
fn a_list_that_answers_late_is_read_again_until_it_loads() {
    let mut list = late(Some(7), 100);
    let (answer, at) = list.run(None);
    assert_eq!(answer, ListWait::Proceed);
    assert!(at >= Duration::from_secs(7) && at < Duration::from_secs(7) + LIST_LOAD_POLL, "{at:?}");
    assert_eq!(list.reads, 4, "{at:?}");

    // `--timeout` past the load does not cut it short.
    let mut list = late(Some(7), 100);
    assert_eq!(list.run(Some(Duration::from_secs(30))).0, ListWait::Proceed);
}

/// A list still unread after [`LIST_LOAD_WAIT`] is refused then, never later; a shorter deadline
/// bounds the wait, and no read starts at its end.
#[test]
fn a_list_that_never_loads_is_unread_once_the_wait_or_the_deadline_is_over() {
    let mut list = late(None, 0);
    let (answer, at) = list.run(None);
    assert_eq!((answer, at), (ListWait::Unread, LIST_LOAD_WAIT));
    assert_eq!(list.reads, 29, "a read every pace, none at the wait's end");

    // Reads that take long (5 s each): the wait still ends within one read past it.
    let mut list = late(None, 5_000);
    let (answer, at) = list.run(None);
    assert_eq!(answer, ListWait::Unread);
    assert!(at <= LIST_LOAD_WAIT + Duration::from_secs(5), "{at:?}");

    let mut list = late(None, 0);
    let (answer, at) = list.run(Some(Duration::from_secs(5)));
    assert_eq!((answer, at), (ListWait::Unread, Duration::from_secs(5)));
    assert_eq!(list.reads, 2);

    // A deadline already passed: refused at once.
    assert_eq!(list_wait(Duration::ZERO, Some(Duration::ZERO), false, true), ListWait::Unread);
}

/// A loaded list goes on at once, and a signed-out app is never waited for: its own refusal comes at once.
#[test]
fn a_loaded_list_or_a_signed_out_app_is_never_waited_for() {
    assert_eq!(list_wait(Duration::ZERO, None, true, true), ListWait::Proceed);
    assert_eq!(list_wait(Duration::ZERO, None, false, false), ListWait::Proceed);
    assert_eq!(list_wait(LIST_LOAD_WAIT, None, true, true), ListWait::Proceed);
}

/// The app reads the answer as JSON (op `cloud_start_list_wait`).
#[test]
fn the_wait_answers_in_the_apps_words() {
    let pause = serde_json::to_value(list_wait(Duration::ZERO, None, false, true)).unwrap();
    assert_eq!(pause, serde_json::json!({"next": "pause", "pauseMs": 2000, "readAfter": true}));
    let last = serde_json::to_value(list_wait(Duration::from_millis(59_500), None, false, true));
    assert_eq!(
        last.unwrap(),
        serde_json::json!({"next": "pause", "pauseMs": 500, "readAfter": false})
    );
    assert_eq!(
        serde_json::to_value(ListWait::Unread).unwrap(),
        serde_json::json!({"next": "unread"})
    );
    assert_eq!(
        serde_json::to_value(ListWait::Proceed).unwrap(),
        serde_json::json!({"next": "proceed"})
    );
}
