//! One run of the same work at a time: a caller whose work is already running joins that run and
//! gets its answer, instead of starting its own. `_acpmux/session/auth {refresh}` comes from a
//! page (each chat switch, each turn's start and end), so without this every request could start
//! its own route probe and its own sign-in check process.
//!
//! The run is a spawned task, so it ends (and leaves the table) even when every caller went away.
//! No timer: a caller that comes after the run ended starts a new one.

use futures::FutureExt;
use futures::future::{BoxFuture, Shared};
use std::future::Future;
use std::sync::Mutex;
use std::sync::atomic::{AtomicU64, Ordering};

/// The runs in flight, each by its key (the work's whole input, compared with `==`).
pub(crate) struct Flights<K, V: Clone> {
    running: Mutex<Vec<Flight<K, V>>>,
    next: AtomicU64,
}

struct Flight<K, V: Clone> {
    key: K,
    id: u64,
    answer: Shared<BoxFuture<'static, V>>,
}

impl<K, V> Flights<K, V>
where
    K: PartialEq + Send + 'static,
    V: Clone + Send + Sync + 'static,
{
    pub(crate) const fn new() -> Self {
        Self { running: Mutex::new(Vec::new()), next: AtomicU64::new(0) }
    }

    /// The answer of the run for `key`: the one in flight, else a new run of `work`. A run that
    /// panicked or was cancelled answers `failed` with why.
    pub(crate) async fn join<W>(
        &'static self,
        key: K,
        work: impl FnOnce() -> W,
        failed: fn(String) -> V,
    ) -> V
    where
        W: Future<Output = V> + Send + 'static,
    {
        let answer = {
            let mut running = self.running.lock().unwrap_or_else(|p| p.into_inner());
            match running.iter().find(|f| f.key == key) {
                Some(flight) => flight.answer.clone(),
                None => {
                    let id = self.next.fetch_add(1, Ordering::Relaxed);
                    let run = work();
                    // The task leaves the table when it ends, panics or is cancelled, whether or
                    // not a caller still waits.
                    let task = tokio::spawn(async move {
                        let _landing = Landing { flights: self, id };
                        run.await
                    });
                    let answer =
                        async move { task.await.unwrap_or_else(|e| failed(e.to_string())) }
                            .boxed()
                            .shared();
                    running.push(Flight { key, id, answer: answer.clone() });
                    answer
                }
            }
        };
        answer.await
    }

    #[cfg(test)]
    fn in_flight(&self) -> usize {
        self.running.lock().unwrap_or_else(|p| p.into_inner()).len()
    }
}

/// Takes run `id` out of the table when its task ends: later callers start a new one.
struct Landing<K: 'static, V: Clone + 'static> {
    flights: &'static Flights<K, V>,
    id: u64,
}

impl<K, V: Clone> Drop for Landing<K, V> {
    fn drop(&mut self) {
        let mut running = self.flights.running.lock().unwrap_or_else(|p| p.into_inner());
        running.retain(|f| f.id != self.id);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::sync::atomic::AtomicUsize;
    use std::time::Duration;

    static FLIGHTS: Flights<&'static str, usize> = Flights::new();

    #[tokio::test]
    async fn callers_of_the_same_key_share_one_run_and_a_later_caller_starts_a_new_one() {
        let runs = Arc::new(AtomicUsize::new(0));
        let (go, wait) = tokio::sync::watch::channel(false);
        let call = |key: &'static str| {
            let runs = runs.clone();
            let mut wait = wait.clone();
            FLIGHTS.join(
                key,
                move || async move {
                    let n = runs.fetch_add(1, Ordering::SeqCst) + 1;
                    let _ = wait.wait_for(|go| *go).await;
                    n
                },
                |_| 0,
            )
        };
        let a = tokio::spawn(call("same"));
        let b = tokio::spawn(call("same"));
        let c = tokio::spawn(call("same"));
        let other = tokio::spawn(call("other"));
        // Every caller is in before the run may end.
        while runs.load(Ordering::SeqCst) < 2 {
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
        go.send(true).unwrap();
        let same = [a.await.unwrap(), b.await.unwrap(), c.await.unwrap()];
        assert_eq!(same[0], same[1]);
        assert_eq!(same[1], same[2]);
        assert_ne!(other.await.unwrap(), same[0], "another key runs on its own");
        assert_eq!(runs.load(Ordering::SeqCst), 2, "one run per key");
        assert_eq!(FLIGHTS.in_flight(), 0, "an ended run leaves the table");
        assert_eq!(call("same").await, 3, "a caller after the run ends starts a new one");
    }

    #[tokio::test]
    async fn a_run_whose_callers_went_away_still_ends_and_leaves() {
        static GONE: Flights<u8, u8> = Flights::new();
        let (done, finished) = tokio::sync::oneshot::channel();
        let caller = tokio::spawn(GONE.join(
            1,
            move || async move {
                tokio::time::sleep(Duration::from_millis(20)).await;
                let _ = done.send(());
                7
            },
            |_| 0,
        ));
        tokio::time::sleep(Duration::from_millis(5)).await;
        caller.abort();
        finished.await.unwrap();
        for _ in 0..100 {
            if GONE.in_flight() == 0 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert_eq!(GONE.in_flight(), 0, "the run left the table with no caller");
        assert_eq!(GONE.join(1, || async { 8 }, |_| 0).await, 8);
    }
}
