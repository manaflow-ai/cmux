//! The driver on a manual clock and on tokio's paused clock, and the recovery property.

use std::time::{Duration, Instant};

use cmux_bounded::testing::assert_every_wait_recovers;
use cmux_bounded::{BoundedMachine, Driver, Wait, WaitKind, overrun_count};

const S: fn(u64) -> Duration = Duration::from_secs;
const ATTEMPTS: u32 = 3;

/// A link that connects, retries with backoff, and after `ATTEMPTS` asks the person.
#[derive(Debug, Clone, PartialEq)]
enum Link {
    Idle,
    Connecting { attempt: u32 },
    Backoff { attempt: u32 },
    Connected,
    Failed,
}

#[derive(Debug)]
enum Ev {
    Connect,
    Up,
    Noise,
    TimedOut,
    Retry,
}

struct LinkMachine(Link);

impl BoundedMachine for LinkMachine {
    type State = Link;
    type Event = Ev;
    const NAME: &'static str = "test.link";

    fn wait(state: &Link) -> Wait<Ev> {
        match state {
            Link::Idle | Link::Connected => Wait::Settled,
            Link::Connecting { .. } => Wait::bounded(S(5), Ev::TimedOut, "the handshake"),
            Link::Backoff { attempt } => {
                Wait::bounded(S(1 << attempt), Ev::Retry, "backoff before the next try")
            }
            Link::Failed => Wait::OnPerson { action: "Reconnect" },
        }
    }

    fn step(&mut self, event: Ev) {
        self.0 = match (&self.0, event) {
            (Link::Idle | Link::Failed, Ev::Connect) => Link::Connecting { attempt: 1 },
            (Link::Connecting { .. }, Ev::Up) => Link::Connected,
            (Link::Connecting { attempt }, Ev::TimedOut) if *attempt >= ATTEMPTS => Link::Failed,
            (Link::Connecting { attempt }, Ev::TimedOut) => Link::Backoff { attempt: *attempt },
            (Link::Backoff { attempt }, Ev::Retry) => Link::Connecting { attempt: attempt + 1 },
            (state, _) => state.clone(),
        };
    }

    fn state(&self) -> &Link {
        &self.0
    }
}

fn all_states() -> Vec<Link> {
    let mut states = vec![Link::Idle, Link::Connected, Link::Failed];
    for attempt in 1..=ATTEMPTS {
        states.push(Link::Connecting { attempt });
        states.push(Link::Backoff { attempt });
    }
    states
}

#[test]
fn a_bound_fires_its_recovery_edge_and_counts_the_overrun() {
    let t0 = Instant::now();
    let before = overrun_count("test.link");
    let mut d = Driver::<_, Instant>::new_at(LinkMachine(Link::Idle), t0);
    assert_eq!(d.deadline(), None);
    assert!(d.feed_at(Ev::Connect, t0));
    assert_eq!(d.deadline(), Some(t0 + S(5)));
    assert_eq!(d.expire_due_at(t0 + S(4)), None);
    let overran = d.expire_due_at(t0 + S(6)).expect("past the bound");
    assert_eq!(
        (overran.state.as_str(), overran.bound, overran.waited, overran.to.as_str()),
        ("Connecting", S(5), S(6), "Backoff")
    );
    assert_eq!(d.state(), &Link::Backoff { attempt: 1 });
    assert_eq!(d.deadline(), Some(t0 + S(6) + S(2)));
    assert_eq!(d.overruns().len(), 1);
    assert!(overrun_count("test.link") > before);
}

/// An event the state ignores keeps the running clock: noise never extends a wait.
#[test]
fn an_ignored_event_does_not_extend_the_wait() {
    let t0 = Instant::now();
    let mut d = Driver::<_, Instant>::new_at(LinkMachine(Link::Connecting { attempt: 1 }), t0);
    assert!(!d.feed_at(Ev::Noise, t0 + S(4)));
    assert_eq!(d.deadline(), Some(t0 + S(5)));
    assert!(d.feed_at(Ev::Up, t0 + S(4)));
    assert_eq!(d.deadline(), None);
    assert_eq!(d.expire_due_at(t0 + S(60)), None);
}

#[test]
fn a_report_hides_a_bounded_wait_for_the_quiet_bound_and_shows_a_persons_action_at_once() {
    let t0 = Instant::now();
    let d = Driver::<_, Instant>::new_at(LinkMachine(Link::Connecting { attempt: 1 }), t0);
    let early = d.report_at(t0 + S(3));
    assert_eq!((early.kind, early.bound_ms, early.show), (WaitKind::Bounded, Some(5000), false));
    assert!(d.report_at(t0 + S(10)).show);
    let failed = Driver::<_, Instant>::new_at(LinkMachine(Link::Failed), t0).report_at(t0);
    assert_eq!((failed.action.as_deref(), failed.show), (Some("Reconnect"), true));
    let json = serde_json::to_value(&failed).unwrap();
    assert_eq!(json["kind"], "on_person");
    assert_eq!(json["state"], "Failed");
}

#[test]
fn every_wait_of_the_link_recovers() {
    let walks = assert_every_wait_recovers(|s: &Link| LinkMachine(s.clone()), &all_states(), S(60));
    let longest = walks.iter().map(|w| w.path.len()).max().unwrap();
    assert_eq!(longest, 6, "{walks:?}");
}

/// A recovery edge back to the very state it left is a wait that never ends.
#[test]
#[should_panic(expected = "returned to the same state")]
fn a_recovery_edge_to_the_same_state_fails_the_property() {
    struct Stuck(Link);
    impl BoundedMachine for Stuck {
        type State = Link;
        type Event = Ev;
        const NAME: &'static str = "test.stuck";
        fn wait(state: &Link) -> Wait<Ev> {
            LinkMachine::wait(state)
        }
        fn step(&mut self, _event: Ev) {}
        fn state(&self) -> &Link {
            &self.0
        }
    }
    assert_every_wait_recovers(
        |s: &Link| Stuck(s.clone()),
        &[Link::Connecting { attempt: 1 }],
        S(60),
    );
}

/// Retrying forever with a growing attempt count changes the state but never ends.
#[test]
#[should_panic(expected = "budget")]
fn a_retry_with_no_last_attempt_fails_the_budget() {
    struct Forever(Link);
    impl BoundedMachine for Forever {
        type State = Link;
        type Event = Ev;
        const NAME: &'static str = "test.forever";
        fn wait(state: &Link) -> Wait<Ev> {
            match state {
                Link::Idle | Link::Connected | Link::Failed | Link::Backoff { .. } => Wait::Settled,
                Link::Connecting { .. } => Wait::bounded(S(5), Ev::TimedOut, "the handshake"),
            }
        }
        fn step(&mut self, _event: Ev) {
            if let Link::Connecting { attempt } = self.0 {
                self.0 = Link::Connecting { attempt: attempt + 1 };
            }
        }
        fn state(&self) -> &Link {
            &self.0
        }
    }
    assert_every_wait_recovers(
        |s: &Link| Forever(s.clone()),
        &[Link::Connecting { attempt: 1 }],
        S(600),
    );
}

#[test]
fn the_quiet_bound_matches_the_notice_timing_schema() {
    let schema =
        concat!(env!("CARGO_MANIFEST_DIR"), "/../../../schemas/notice-timing/notice-timing.json");
    let Ok(text) = std::fs::read_to_string(schema) else {
        eprintln!("no schema at {schema} (a cmux-tui-only checkout); skipped");
        return;
    };
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    let ms = value["connectionQuietMs"].as_u64().unwrap();
    assert_eq!(Duration::from_millis(ms), cmux_bounded::CONNECTION_QUIET);
}

#[cfg(feature = "tokio")]
#[tokio::test(start_paused = true)]
async fn the_async_driver_fires_each_bound_on_a_paused_clock() {
    use tokio::sync::mpsc;
    let (tx, mut rx) = mpsc::channel(4);
    let mut d = Driver::<_, tokio::time::Instant>::new(LinkMachine(Link::Idle));
    tx.send(Ev::Connect).await.unwrap();
    let run = async {
        d.run(&mut rx).await;
        d
    };
    let close = async move {
        // 3 tries of 5 s and backoffs of 2 s and 4 s: Failed at 21 s.
        tokio::time::sleep(S(30)).await;
        drop(tx);
    };
    let (d, ()) = tokio::join!(run, close);
    assert_eq!(d.state(), &Link::Failed);
    assert_eq!(d.overruns().len(), 5);
}
