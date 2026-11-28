//! Share an asynchronous read until it completes or its last waiter leaves.

use futures::future::{BoxFuture, FutureExt, Shared};
use std::collections::HashMap;
use std::future::Future;
use std::hash::Hash;
use std::sync::Mutex;

type Read<T> = Shared<BoxFuture<'static, T>>;

struct Flight<T> {
    read: Read<T>,
    waiters: usize,
}

pub(crate) struct SingleFlight<K, T> {
    flights: Mutex<HashMap<K, Flight<T>>>,
}

impl<K, T> Default for SingleFlight<K, T> {
    fn default() -> Self {
        Self { flights: Mutex::new(HashMap::new()) }
    }
}

struct Waiter<'a, K: Eq + Hash, T> {
    table: &'a SingleFlight<K, T>,
    key: K,
    read: Read<T>,
    finished: bool,
}

impl<K: Eq + Hash, T> Drop for Waiter<'_, K, T> {
    fn drop(&mut self) {
        let mut flights = self.table.flights.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(current) = flights.get_mut(&self.key)
            && current.read.ptr_eq(&self.read)
        {
            current.waiters -= 1;
            if self.finished || current.waiters == 0 {
                flights.remove(&self.key);
            }
        }
    }
}

impl<K: Eq + Hash + Clone, T: Clone + Send + 'static> SingleFlight<K, T> {
    pub(crate) async fn run<F>(&self, key: K, operation: impl FnOnce() -> F) -> T
    where
        F: Future<Output = T> + Send + 'static,
    {
        let read = {
            let mut flights = self.flights.lock().unwrap_or_else(|e| e.into_inner());
            // A waiter on another thread can still be unwinding after the read became ready.
            if flights.get(&key).is_some_and(|flight| flight.read.peek().is_some()) {
                flights.remove(&key);
            }
            let flight = flights
                .entry(key.clone())
                .or_insert_with(|| Flight { read: operation().boxed().shared(), waiters: 0 });
            flight.waiters += 1;
            flight.read.clone()
        };
        let mut waiter = Waiter { table: self, key, read, finished: false };
        let result = waiter.read.clone().await;
        waiter.finished = true;
        result
    }
}

#[cfg(test)]
mod tests {
    use super::SingleFlight;
    use futures::{future, poll};
    use tokio::sync::oneshot;

    #[tokio::test]
    async fn single_flight_shares_results_and_errors_only_while_pending() {
        const CALLERS: usize = 8;
        let table = SingleFlight::default();
        for answer in [Ok(7), Err("read failed")] {
            let (send, receive) = oneshot::channel();
            let mut first = Box::pin(table.run("key", || async move { receive.await.unwrap() }));
            assert!(poll!(&mut first).is_pending());
            let mut others = Vec::new();
            for _ in 1..CALLERS {
                let mut other = Box::pin(table.run("key", || async { panic!("duplicate read") }));
                assert!(poll!(&mut other).is_pending());
                others.push(other);
            }
            // Cancelling the caller that started the read leaves it available to its joiners.
            drop(first);
            assert_eq!(table.run("other", || async { Ok(9) }).await, Ok(9));
            send.send(answer).unwrap();
            for caller in others {
                assert_eq!(caller.await, answer);
            }
        }
        assert_eq!(table.run("key", || async { Ok(8) }).await, Ok(8));
    }

    #[tokio::test]
    async fn single_flight_completed_read_is_fresh_before_waiter_cleanup() {
        let table = SingleFlight::default();
        let (send, receive) = oneshot::channel();
        let mut waiter = Box::pin(table.run("key", || async move { receive.await.unwrap() }));
        assert!(poll!(&mut waiter).is_pending());
        let read = table.flights.lock().unwrap()["key"].read.clone();
        send.send(1).unwrap();
        assert_eq!(read.await, 1);
        assert_eq!(table.run("key", || async { 2 }).await, 2);
        assert_eq!(waiter.await, 1);
    }

    #[tokio::test]
    async fn single_flight_last_waiter_cancels_read_and_releases_key() {
        let table = SingleFlight::default();
        let mut pending = Box::pin(table.run("key", future::pending::<()>));
        assert!(poll!(&mut pending).is_pending());
        drop(pending);
        assert!(table.flights.lock().unwrap().is_empty());
        table.run("key", || async {}).await;
    }
}
