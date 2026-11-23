//! Share one in-flight asynchronous operation with callers using the same key.

use futures::future::{BoxFuture, FutureExt, Shared};
use std::collections::HashMap;
use std::future::Future;
use std::hash::Hash;
use std::sync::{Arc, Mutex};

type SharedResult<V, E> = Shared<BoxFuture<'static, Result<V, E>>>;

struct Flight<V, E> {
    result: SharedResult<V, E>,
}

/// A keyed operation table that keeps results only for the duration of a flight.
///
/// The first caller evaluates the operation. Callers arriving before it completes await the same
/// shared future and receive cloned values or the same cloned error. Once the future completes,
/// its entry is removed before the caller returns, so a later call starts a fresh operation.
pub(crate) struct SingleFlight<K, V, E> {
    flights: Mutex<HashMap<K, Arc<Flight<V, E>>>>,
}

impl<K, V, E> Default for SingleFlight<K, V, E> {
    fn default() -> Self {
        Self { flights: Mutex::new(HashMap::new()) }
    }
}

impl<K, V, E> SingleFlight<K, V, E>
where
    K: Eq + Hash + Clone,
    V: Clone + Send + 'static,
    E: Clone + Send + 'static,
{
    /// Run `operation` once for each overlapping group of calls with `key`.
    pub(crate) async fn run<F, Fut>(&self, key: K, operation: F) -> Result<V, E>
    where
        F: FnOnce() -> Fut + Send + 'static,
        Fut: Future<Output = Result<V, E>> + Send + 'static,
    {
        let flight = {
            let mut flights = self.flights.lock().unwrap_or_else(|error| error.into_inner());
            if let Some(flight) = flights.get(&key) {
                flight.clone()
            } else {
                let result = operation().boxed().shared();
                let flight = Arc::new(Flight { result });
                flights.insert(key.clone(), flight.clone());
                flight
            }
        };

        let result = flight.result.clone().await;
        let mut flights = self.flights.lock().unwrap_or_else(|error| error.into_inner());
        if flights.get(&key).is_some_and(|current| Arc::ptr_eq(current, &flight)) {
            flights.remove(&key);
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::SingleFlight;
    use serde_json::json;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};

    #[tokio::test(start_paused = true)]
    async fn concurrent_callers_share_one_result_and_later_call_starts_again() {
        const CALLERS: usize = 8;
        let flights = Arc::new(SingleFlight::<&'static str, _, &'static str>::default());
        let operations = Arc::new(AtomicUsize::new(0));
        let release = Arc::new(std::sync::atomic::AtomicBool::new(false));

        let mut callers = Vec::with_capacity(CALLERS);
        for _ in 0..CALLERS {
            let flights = flights.clone();
            let operations = operations.clone();
            let release = release.clone();
            callers.push(tokio::spawn(async move {
                flights
                    .run("same-read", move || async move {
                        operations.fetch_add(1, Ordering::SeqCst);
                        while !release.load(Ordering::SeqCst) {
                            tokio::task::yield_now().await;
                        }
                        Ok(json!({"answer": 7}))
                    })
                    .await
            }));
        }

        // The first operation is held open, so all callers must join its flight before it ends.
        while flights.flights.lock().unwrap().len() != 1 {
            tokio::task::yield_now().await;
        }
        release.store(true, Ordering::SeqCst);

        for caller in callers {
            assert_eq!(caller.await.unwrap().unwrap(), json!({"answer": 7}));
        }
        assert_eq!(operations.load(Ordering::SeqCst), 1);

        let operation_count = operations.clone();
        let result = flights
            .run("same-read", move || async move {
                operation_count.fetch_add(1, Ordering::SeqCst);
                Ok(json!({"answer": 8}))
            })
            .await
            .unwrap();
        assert_eq!(result, json!({"answer": 8}));
        assert_eq!(operations.load(Ordering::SeqCst), 2);
    }

    #[tokio::test(start_paused = true)]
    async fn concurrent_callers_share_errors() {
        const CALLERS: usize = 5;
        let flights = Arc::new(SingleFlight::<&'static str, usize, &'static str>::default());
        let operations = Arc::new(AtomicUsize::new(0));
        let release = Arc::new(std::sync::atomic::AtomicBool::new(false));
        let mut callers = Vec::with_capacity(CALLERS);
        for _ in 0..CALLERS {
            let flights = flights.clone();
            let operations = operations.clone();
            let release = release.clone();
            callers.push(tokio::spawn(async move {
                flights
                    .run("same-error", move || async move {
                        operations.fetch_add(1, Ordering::SeqCst);
                        while !release.load(Ordering::SeqCst) {
                            tokio::task::yield_now().await;
                        }
                        Err("read failed")
                    })
                    .await
            }));
        }
        while flights.flights.lock().unwrap().len() != 1 {
            tokio::task::yield_now().await;
        }
        release.store(true, Ordering::SeqCst);
        for caller in callers {
            assert_eq!(caller.await.unwrap(), Err("read failed"));
        }
        assert_eq!(operations.load(Ordering::SeqCst), 1);
    }
}
