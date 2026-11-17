//! The cold connect's race of a peer's paths (`peer_carriers.rs`): which dial starts when, and
//! which one wins. Pure over futures, so its timing is tested on a paused clock.

use crate::peer_paths::Via;
use futures_util::StreamExt;
use futures_util::stream::FuturesUnordered;
use std::future::Future;
use std::time::Duration;

/// Dial `candidates` in order: the first at once, each next one `stagger` (`STAGGER`) after
/// the one before, or at once when every one started so far failed. The first to open wins;
/// the rest are dropped, which cancels them. Returns the winner and the failures seen before
/// it, or every failure, in the order they came.
#[cfg(test)]
#[allow(clippy::type_complexity)]
pub(in crate::peer) async fn race<T, F>(
    candidates: Vec<(Via, F)>,
    stagger: Duration,
) -> Result<(Via, T, Vec<(Via, String)>), Vec<(Via, String)>>
where
    F: Future<Output = Result<T, String>>,
{
    race_together(candidates, 1, stagger).await
}

/// [`race`] with the first `together` candidates dialed at once (relay first: the hub relay
/// and the remembered path, `Paths::dial_together`), the rest staggered after them.
#[allow(clippy::type_complexity)]
pub(in crate::peer) async fn race_together<T, F>(
    candidates: Vec<(Via, F)>,
    together: usize,
    stagger: Duration,
) -> Result<(Via, T, Vec<(Via, String)>), Vec<(Via, String)>>
where
    F: Future<Output = Result<T, String>>,
{
    let mut together = together.max(1);
    async fn tagged<T, F: Future<Output = Result<T, String>>>(
        via: Via,
        dial: F,
    ) -> (Via, Result<T, String>) {
        (via, dial.await)
    }
    let mut waiting = candidates.into_iter();
    let mut running = FuturesUnordered::new();
    let mut failed = Vec::new();
    let mut next_at: Option<tokio::time::Instant> = None;
    loop {
        let now = tokio::time::Instant::now();
        if running.is_empty() || next_at.is_some_and(|at| at <= now) {
            match waiting.next() {
                Some((via, dial)) => {
                    running.push(tagged(via, dial));
                    together = together.saturating_sub(1);
                    next_at = Some(if together > 0 { now } else { now + stagger });
                }
                None if running.is_empty() => return Err(failed),
                None => next_at = None,
            }
            continue;
        }
        tokio::select! {
            Some((via, result)) = running.next() => match result {
                Ok(value) => return Ok((via, value, failed)),
                Err(error) => {
                    failed.push((via, error));
                    // Nothing is left running: the next one starts now.
                    if running.is_empty() {
                        next_at = Some(tokio::time::Instant::now());
                    }
                }
            },
            () = tokio::time::sleep_until(next_at.unwrap_or(now)), if next_at.is_some() => {}
        }
    }
}
