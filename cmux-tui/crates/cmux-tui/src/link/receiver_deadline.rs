//! One-shot authority wakeups. The clock is checked before every timer poll;
//! cached reactor readiness can never authorize work after elapsed expiry.
use std::future::{Future, poll_fn};
use std::task::Poll;
use std::time::Instant;

use cmux_link::elapsed::Deadline;

pub(super) async fn expired(active: Instant, elapsed: Option<Deadline>) {
    let Some(budget) = elapsed else {
        tokio::time::sleep_until(tokio::time::Instant::from_std(active)).await;
        return;
    };
    // Retain the active-clock wait while checking elapsed expiry on each poll.
    // The kernel wake regression covers the missing independent wake source.
    let timer = tokio::time::sleep_until(tokio::time::Instant::from_std(active));
    tokio::pin!(timer);
    poll_fn(|cx| {
        if budget.remaining().is_none() {
            return Poll::Ready(());
        }
        Future::poll(timer.as_mut(), cx)
    })
    .await;
}

#[cfg(all(test, target_os = "linux"))]
#[path = "receiver_deadline_tests.rs"]
mod tests;
