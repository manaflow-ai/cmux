//! [`assert_every_wait_recovers`]: the property every [`BoundedMachine`] owes.

use std::time::{Duration, Instant};

use crate::{BoundedMachine, Driver, Wait};

/// The most recovery edges one walk follows before it calls the machine a loop.
pub const MAX_HOPS: usize = 1024;

/// One bounded state's walk to rest.
#[derive(Debug, Clone)]
pub struct Recovery {
    /// The labels from the bounded state to the one it came to rest in.
    pub path: Vec<String>,
    /// Virtual time from the first state's entry to rest.
    pub took: Duration,
}

/// For each of `states`: an [`Wait::OnPerson`] state must name its action; a [`Wait::Bounded`]
/// state, driven on a manual clock with no event but its own recovery edges, must leave itself at
/// its first bound and reach a [`Wait::Settled`] or [`Wait::OnPerson`] state within `budget` of
/// virtual time (a retry may repeat, with backoff, but not forever). `make` builds a machine in
/// the given state. Panics with the walk on a failure; returns the walks for a test to print.
pub fn assert_every_wait_recovers<M: BoundedMachine>(
    make: impl Fn(&M::State) -> M,
    states: &[M::State],
    budget: Duration,
) -> Vec<Recovery> {
    let mut walks = Vec::new();
    for start in states {
        match M::wait(start) {
            Wait::Settled => continue,
            Wait::OnPerson { action } => {
                assert!(
                    !action.trim().is_empty(),
                    "{}: {:?} waits on a person but names no action",
                    M::NAME,
                    start
                );
                continue;
            }
            Wait::Bounded { .. } => {}
        }
        let t0 = Instant::now();
        let mut driver = Driver::<M, Instant>::new_at(make(start), t0);
        assert_eq!(driver.state(), start, "{}: the factory built another state", M::NAME);
        let mut path = vec![M::label(start)];
        let mut now = t0;
        let mut hops: usize = 0;
        while let Some(due) = driver.deadline() {
            hops = hops.saturating_add(1);
            now = due;
            assert!(
                now.saturating_duration_since(t0) <= budget,
                "{}: from {:?}, still waiting ({}) past the {budget:?} budget: {}",
                M::NAME,
                start,
                M::label(driver.state()),
                path.join(" -> ")
            );
            assert!(
                hops <= MAX_HOPS,
                "{}: from {start:?}, {MAX_HOPS} recovery edges and still waiting: {}",
                M::NAME,
                path.join(" -> ")
            );
            let before = driver.state().clone();
            driver.expire_due_at(now);
            assert!(
                *driver.state() != before,
                "{}: the recovery edge of {:?} returned to the same state: it waits forever",
                M::NAME,
                before
            );
            path.push(M::label(driver.state()));
        }
        walks.push(Recovery { path, took: now.saturating_duration_since(t0) });
    }
    walks
}
