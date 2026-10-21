//! One-shot authority wakeups. The clock is checked before every timer poll;
//! cached reactor readiness can never authorize work after elapsed expiry.
use std::future::{Future, poll_fn};
use std::task::Poll;
use std::time::Instant;

use cmux_link::elapsed::Deadline;

/// Timer setup failures stop the actor and preserve its retry backoff.
pub(super) async fn wait(active: Instant, elapsed: Option<Deadline>) -> std::io::Result<()> {
    let retained = elapsed.clone();
    expired(active, elapsed).await;
    match retained {
        Some(budget) if budget.remaining().is_none() => Ok(()),
        None if active <= Instant::now() => Ok(()),
        _ => Err(std::io::Error::other("receiver deadline unavailable")),
    }
}

pub(super) async fn expired(active: Instant, elapsed: Option<Deadline>) {
    let Some(budget) = elapsed else {
        tokio::time::sleep_until(tokio::time::Instant::from_std(active)).await;
        return;
    };
    #[cfg(target_os = "linux")]
    if let Some(at) = budget.boottime() {
        kernel_expired(budget, at).await;
        return;
    }
    // Injected clocks have no kernel clock id. Their model still rechecks the
    // same budget on each poll. Native Linux system observations use timerfd.
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

#[cfg(target_os = "linux")]
async fn kernel_expired(budget: Deadline, at: std::time::Duration) {
    use cmux_host::linux::fds::{Clock, TimerFd};
    use tokio::io::unix::AsyncFd;
    let timer = match TimerFd::new(Clock::Boottime) {
        Ok(timer) => timer,
        Err(_) => return,
    };
    if timer.arm_at(at).is_err() {
        return;
    }
    let descriptor = match AsyncFd::new(timer) {
        Ok(descriptor) => descriptor,
        Err(_) => return,
    };
    poll_fn(|cx| {
        loop {
            if budget.remaining().is_none() {
                return Poll::Ready(());
            }
            match descriptor.poll_read_ready(cx) {
                Poll::Pending => return Poll::Pending,
                Poll::Ready(Err(_)) => return Poll::Ready(()),
                Poll::Ready(Ok(mut ready)) => {
                    match ready.try_io(|fd| fd.get_ref().read_expirations()) {
                        Ok(_) => return Poll::Ready(()),
                        Err(_) => continue,
                    }
                }
            }
        }
    })
    .await;
}

#[cfg(all(test, target_os = "linux"))]
#[path = "receiver_deadline_tests.rs"]
mod tests;
