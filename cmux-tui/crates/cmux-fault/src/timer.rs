//! The shapers' arrival timer. tokio's timer wheel ticks in whole milliseconds and rounds a
//! deadline up to the next tick, so a profile's 1 ms one-way delay delivers in 1 to 2 ms. With
//! `CMUX_FAULT_EXACT_TIMERS=1` a deadline is met to tens of microseconds instead: tokio's sleep
//! to 2 ms before it, then a timer thread's precise wait (a futex timeout) for the rest. Off by
//! default, so every existing measurement keeps its numbers.

use std::cmp::Reverse;
use std::collections::{BinaryHeap, HashMap};
use std::sync::OnceLock;
use std::sync::mpsc;
use std::time::Duration;

use tokio::sync::oneshot;
use tokio::time::Instant;

/// The switch: `1` (or `true`) makes the shapers' delays exact.
pub const ENV: &str = "CMUX_FAULT_EXACT_TIMERS";

/// Whether this process asked for exact delays.
pub fn exact() -> bool {
    static ON: OnceLock<bool> = OnceLock::new();
    *ON.get_or_init(|| matches!(std::env::var(ENV).as_deref().map(str::trim), Ok("1" | "true")))
}

type Wake = (std::time::Instant, oneshot::Sender<()>);

fn thread() -> Option<&'static mpsc::Sender<Wake>> {
    static SENDER: OnceLock<Option<mpsc::Sender<Wake>>> = OnceLock::new();
    SENDER.get_or_init(spawn).as_ref()
}

fn spawn() -> Option<mpsc::Sender<Wake>> {
    let (sender, receiver) = mpsc::channel::<Wake>();
    std::thread::Builder::new()
        .name("cmux-fault timer".into())
        .spawn(move || {
            let mut due: BinaryHeap<Reverse<(std::time::Instant, u64)>> = BinaryHeap::new();
            let mut waiting: HashMap<u64, oneshot::Sender<()>> = HashMap::new();
            let mut next = 0_u64;
            loop {
                let now = std::time::Instant::now();
                while let Some(Reverse((at, id))) = due.peek().copied() {
                    if at > now {
                        break;
                    }
                    due.pop();
                    if let Some(wake) = waiting.remove(&id) {
                        // A dropped sleep (its select lost) is not waiting any more.
                        let _ = wake.send(());
                    }
                }
                let received = match due.peek() {
                    Some(Reverse((at, _))) => {
                        receiver.recv_timeout(at.saturating_duration_since(now))
                    }
                    None => receiver.recv().map_err(|_| mpsc::RecvTimeoutError::Disconnected),
                };
                match received {
                    Ok((at, wake)) => {
                        next += 1;
                        due.push(Reverse((at, next)));
                        waiting.insert(next, wake);
                    }
                    Err(mpsc::RecvTimeoutError::Timeout) => {}
                    Err(mpsc::RecvTimeoutError::Disconnected) => return,
                }
            }
        })
        .ok()?;
    Some(sender)
}

/// Waits until `at`: tokio's `sleep_until`, or to the microsecond when [`exact`].
pub async fn sleep_until(at: Instant) {
    if !exact() {
        return tokio::time::sleep_until(at).await;
    }
    if let Some(early) = at.checked_sub(Duration::from_millis(2))
        && early > Instant::now()
    {
        tokio::time::sleep_until(early).await;
    }
    if at <= Instant::now() {
        return;
    }
    let (wake, woken) = oneshot::channel();
    match thread() {
        Some(sender) if sender.send((at.into_std(), wake)).is_ok() => {
            let _ = woken.await;
        }
        _ => tokio::time::sleep_until(at).await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn a_deadline_is_not_met_early() {
        let at = Instant::now() + Duration::from_micros(1500);
        sleep_until(at).await;
        assert!(Instant::now() >= at);
    }
}
