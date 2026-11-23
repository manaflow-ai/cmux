//! Part of `Hub`; see `hub/mod.rs`. Concurrent reads of one list reply share one build.
//!
//! A list reply builds each of its live rows from the session's state when it is read
//! (`page_first.rs`, `views.rs`): about 0.35 ms a row, 0.25 s for a page of 700 chats. Each read
//! built them again on its own, so N readers at once cost N builds, and the daemon's two malloc
//! arenas run those builds nearly one at a time: 8 readers took 1.4 s each, 16 took 2.8 s. On
//! 2026-11-19 a host with about 700 chats timed its broker's paged read out at 8 s for minutes
//! after a restart; a caller that retries on its deadline only adds readers.
//!
//! Here a read takes a ticket when it arrives. It is answered by a build of the same reply that
//! started after its ticket: the build under way when it arrived is too old for it, so it waits
//! for that one to end and shares the next. A reply is never older than its request, and N reads
//! at once cost at most two builds, whatever N is.

use std::collections::HashMap;
use std::future::Future;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};

/// The reads in flight, by the reply they ask for.
#[derive(Default)]
pub(crate) struct ListFlights {
    tickets: AtomicU64,
    flights: Mutex<HashMap<String, Arc<Flight>>>,
}

/// One reply's builds: one at a time, the last kept for the reads waiting on it.
#[derive(Default)]
struct Flight {
    /// The last build's ticket and its reply.
    last: tokio::sync::Mutex<Option<(u64, Arc<String>)>>,
}

impl ListFlights {
    /// The reply `key` names, from a build that started after this call: `build`'s, or one
    /// another read of `key` started since. `key` must name every input of the reply.
    pub(crate) async fn read<E, F>(&self, key: String, build: F) -> Result<Arc<String>, E>
    where
        F: Future<Output = Result<Arc<String>, E>>,
    {
        let arrived = self.tickets.fetch_add(1, Ordering::SeqCst);
        let flight = self.lock().entry(key.clone()).or_default().clone();
        let reply = {
            let mut last = flight.last.lock().await;
            match last.as_ref() {
                Some((started, text)) if *started > arrived => Ok(text.clone()),
                _ => {
                    let started = self.tickets.fetch_add(1, Ordering::SeqCst);
                    let built = build.await;
                    *last = built.as_ref().ok().map(|text| (started, text.clone()));
                    built
                }
            }
        };
        // The last read of `key` lets its reply go: nothing is kept between reads.
        let mut flights = self.lock();
        if Arc::strong_count(&flight) == 2 {
            flights.remove(&key);
        }
        reply
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, HashMap<String, Arc<Flight>>> {
        self.flights.lock().unwrap_or_else(|e| e.into_inner())
    }

    #[cfg(test)]
    pub(crate) fn in_flight(&self) -> usize {
        self.lock().len()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_read_after_a_build_builds_again_and_nothing_is_kept() {
        let flights = ListFlights::default();
        let builds = AtomicU64::new(0);
        for _ in 0..3 {
            let got = flights
                .read::<(), _>("k".into(), async {
                    builds.fetch_add(1, Ordering::SeqCst);
                    Ok(Arc::new("x".to_owned()))
                })
                .await;
            assert_eq!(got.unwrap().as_str(), "x");
        }
        // One read at a time: each is newer than the last build, so each builds.
        assert_eq!(builds.load(Ordering::SeqCst), 3);
        assert_eq!(flights.in_flight(), 0);
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 4)]
    async fn reads_that_wait_on_a_build_share_the_next() {
        let flights = Arc::new(ListFlights::default());
        let builds = Arc::new(AtomicU64::new(0));
        let (go, gate) = tokio::sync::watch::channel(false);
        let read = |flights: Arc<ListFlights>,
                    builds: Arc<AtomicU64>,
                    mut gate: tokio::sync::watch::Receiver<bool>| async move {
            flights
                .read::<(), _>("k".into(), async move {
                    let n = builds.fetch_add(1, Ordering::SeqCst);
                    // The first build holds until every other read arrived.
                    if n == 0 {
                        gate.wait_for(|open| *open).await.unwrap();
                    }
                    Ok(Arc::new(format!("build {n}")))
                })
                .await
                .unwrap()
        };
        let first = tokio::spawn(read(flights.clone(), builds.clone(), gate.clone()));
        while builds.load(Ordering::SeqCst) == 0 {
            tokio::task::yield_now().await;
        }
        let rest: Vec<_> = (0..8)
            .map(|_| tokio::spawn(read(flights.clone(), builds.clone(), gate.clone())))
            .collect();
        // Every later read holds its ticket before the first build ends.
        while flights.tickets.load(Ordering::SeqCst) < 10 {
            tokio::task::yield_now().await;
        }
        go.send(true).unwrap();
        assert_eq!(first.await.unwrap().as_str(), "build 0");
        for r in rest {
            // Arrived while build 0 ran: answered by the build after it, never by build 0.
            assert_eq!(r.await.unwrap().as_str(), "build 1");
        }
        assert_eq!(builds.load(Ordering::SeqCst), 2);
        assert_eq!(flights.in_flight(), 0);
    }
}
