//! When a chat's inbound loop stops (`next_inbound`, #41081 F1 F2): a close stops it only once
//! the chat's producers are done, and a close that came before the loop first ran counts.

use super::*;
use std::time::Duration;

fn exited() -> Inbound {
    Inbound::Exited { pid: Some(7), code: None, host_seq: None }
}

/// The chat's own sender, its receiver, and a closed flag already set.
fn closed_chat()
-> (mpsc::Sender<Inbound>, mpsc::Receiver<Inbound>, tokio::sync::watch::Sender<bool>) {
    let (tx, rx) = mpsc::channel(8);
    (tx, rx, tokio::sync::watch::channel(true).0)
}

/// F1: an agent a close killed queues its `Exited` after the chat reads Closed. The loop waits
/// for it while the agent's reader still holds a sender, hands it over, and stops only once that
/// sender is gone.
#[tokio::test(start_paused = true)]
async fn a_closed_chat_still_takes_the_exit_its_agent_sends_late() {
    let (own, mut rx, flag) = closed_chat();
    let mut closed = flag.subscribe();
    let stop = tokio_util::sync::CancellationToken::new();
    let reader = own.clone();
    let late = tokio::spawn(async move {
        tokio::time::sleep(Duration::from_secs(2)).await;
        reader.send(exited()).await.unwrap();
        tokio::time::sleep(Duration::from_secs(1)).await;
        drop(reader);
    });
    let item = next_inbound(&mut rx, &stop, &mut closed, &own).await;
    assert!(matches!(item, Some(Inbound::Exited { pid: Some(7), .. })), "the late exit is handled");
    let started = tokio::time::Instant::now();
    assert!(next_inbound(&mut rx, &stop, &mut closed, &own).await.is_none());
    assert!(started.elapsed() >= Duration::from_secs(1), "it stopped only once the reader let go");
    late.await.unwrap();
}

/// F2: the loop's first look at a chat that closed before it ran ends it (nothing queued, no
/// producer), instead of waiting for another change of the flag.
#[tokio::test(start_paused = true)]
async fn a_loop_that_first_runs_after_the_close_ends() {
    let (own, mut rx, flag) = closed_chat();
    let mut closed = flag.subscribe();
    let stop = tokio_util::sync::CancellationToken::new();
    let ended = tokio::time::timeout(
        Duration::from_secs(1),
        next_inbound(&mut rx, &stop, &mut closed, &own),
    )
    .await;
    assert!(matches!(ended, Ok(None)), "it ended at once");
}

/// What was queued before the close is handled before the loop stops.
#[tokio::test(start_paused = true)]
async fn a_closed_chat_drains_its_queue_first() {
    let (own, mut rx, flag) = closed_chat();
    own.send(exited()).await.unwrap();
    own.send(exited()).await.unwrap();
    let mut closed = flag.subscribe();
    let stop = tokio_util::sync::CancellationToken::new();
    assert!(next_inbound(&mut rx, &stop, &mut closed, &own).await.is_some());
    assert!(next_inbound(&mut rx, &stop, &mut closed, &own).await.is_some());
    assert!(next_inbound(&mut rx, &stop, &mut closed, &own).await.is_none());
}

/// An open chat with no agent keeps its loop; the close then ends it.
#[tokio::test(start_paused = true)]
async fn an_open_chat_keeps_its_loop_until_it_closes() {
    let (own, mut rx) = mpsc::channel(8);
    let flag = tokio::sync::watch::channel(false).0;
    let mut closed = flag.subscribe();
    let stop = tokio_util::sync::CancellationToken::new();
    let waiting = tokio::time::timeout(
        Duration::from_secs(3600),
        next_inbound(&mut rx, &stop, &mut closed, &own),
    )
    .await;
    assert!(waiting.is_err(), "an open chat's loop waits");
    flag.send_replace(true);
    assert!(next_inbound(&mut rx, &stop, &mut closed, &own).await.is_none());
}
