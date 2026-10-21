//! One-shot authority wakeups. The clock is checked before every timer poll;
//! cached reactor readiness can never authorize work after elapsed expiry.
use std::future::{Future, poll_fn};
use std::task::Poll;
use std::time::Instant;

use cmux_link::elapsed::Deadline;

/// Timer setup failures stop the actor and preserve its retry backoff.
pub async fn wait(active: Instant, elapsed: Option<Deadline>) -> std::io::Result<()> {
    let retained = elapsed.clone();
    expired(active, elapsed).await;
    match retained {
        Some(budget) if budget.remaining().is_none() => Ok(()),
        None if active <= Instant::now() => Ok(()),
        _ => Err(std::io::Error::other("receiver deadline unavailable")),
    }
}

pub async fn expired(active: Instant, elapsed: Option<Deadline>) {
    let Some(budget) = elapsed else {
        tokio::time::sleep_until(tokio::time::Instant::from_std(active)).await;
        return;
    };
    #[cfg(target_os = "linux")]
    if let Some(at) = budget.boottime() {
        kernel_expired(budget, at).await;
        return;
    }
    #[cfg(target_vendor = "apple")]
    if budget.kernel_clock() == Some(cmux_link::elapsed::KernelClock::MachContinuous) {
        darwin::expired(budget).await;
        return;
    }
    // Injected clocks have no kernel clock id. Their model still rechecks the
    // same budget on each poll. System observations use their kernel timer.
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
    use self::fd::{Clock, TimerFd};
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
    descriptor_expired(budget, descriptor, |timer| timer.read_expirations().map(drop)).await;
}

#[cfg(any(target_os = "linux", target_vendor = "apple"))]
async fn descriptor_expired<T: std::os::fd::AsRawFd>(
    budget: Deadline,
    descriptor: tokio::io::unix::AsyncFd<T>,
    consume: impl Fn(&T) -> std::io::Result<()>,
) {
    poll_fn(|cx| {
        loop {
            if budget.remaining().is_none() {
                return Poll::Ready(());
            }
            match descriptor.poll_read_ready(cx) {
                Poll::Pending => return Poll::Pending,
                Poll::Ready(Err(_)) => return Poll::Ready(()),
                Poll::Ready(Ok(mut ready)) => match ready.try_io(|fd| consume(fd.get_ref())) {
                    Ok(_) => return Poll::Ready(()),
                    Err(_) => continue,
                },
            }
        }
    })
    .await;
}

/// Why one re-arm attempt failed.
#[derive(Debug, PartialEq, Eq)]
pub enum ArmError {
    /// `ECANCELED`: the clock was set again between the read and the
    /// re-arm. Drain the timer and retry.
    Cancelled,
    /// Any other errno. Not retried.
    Other(i32),
}

#[cfg(target_os = "linux")]
pub mod fd;

#[cfg(target_vendor = "apple")]
mod darwin;
