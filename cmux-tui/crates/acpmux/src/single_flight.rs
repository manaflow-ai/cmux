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
#[path = "single_flight_tests.rs"]
mod tests;
