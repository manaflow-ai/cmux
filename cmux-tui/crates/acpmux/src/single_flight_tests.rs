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
