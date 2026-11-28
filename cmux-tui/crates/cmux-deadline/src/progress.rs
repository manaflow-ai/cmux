//! A deadline measured from the last progress, not from the start: an operation that keeps
//! moving (bytes written, frames read, a page answered, a phase reached) is never cut off, and
//! one that goes silent for `idle` ends.
//!
//! Why: a fixed wall-clock bound fails a slow send that is going fine. Leo, 2026-11-24: "10s
//! timeout for messages being sendsble is a shame. if it's making good progress, it shiukd be
//! allowed to keep going?" A 1 GB upload over a 1 MB/s link needs 17 minutes and is alive every
//! one of them; a 10 s or 10 min bound fails it, a 10 s silence bound does not.
//!
//! The pieces:
//!
//! - [`Progress`]: a counter any task bumps when the work advances. Cheap to clone and share.
//! - [`IdleDeadline`]: the clock math. It ends `idle` after the last progress it saw, or at an
//!   optional total `cap` (a much larger backstop with its own recovery edge, never the
//!   person-facing failure of a moving operation). Sync code (a `recv_timeout` loop) uses it with
//!   `std::time::Instant`.
//! - With the `tokio` feature, [`progress_timeout`] runs a future under an [`IdleDeadline`] fed
//!   by a [`Progress`], and [`ProgressIo`] wraps a reader or writer so every byte through it is
//!   progress.
//!
//! In a `cmux-bounded`-style state machine, a state whose bound is "silence since the last
//! progress" carries the progress count, so each bump is a new state and re-arms the bound.

use std::fmt;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use crate::{Clock, Deadline};

/// A progress counter: bump it whenever the work advances.
#[derive(Clone, Default)]
pub struct Progress {
    inner: Arc<Inner>,
}

#[derive(Default)]
struct Inner {
    count: AtomicU64,
    #[cfg(feature = "tokio")]
    notify: tokio::sync::Notify,
}

impl fmt::Debug for Progress {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Progress").field("count", &self.count()).finish()
    }
}

impl Progress {
    pub fn new() -> Self {
        Self::default()
    }

    /// One step of progress.
    pub fn bump(&self) {
        self.bump_by(1);
    }

    /// `n` steps (bytes, frames) of progress. Zero is no progress.
    pub fn bump_by(&self, n: u64) {
        if n == 0 {
            return;
        }
        self.inner.count.fetch_add(n, Ordering::Relaxed);
        #[cfg(feature = "tokio")]
        self.inner.notify.notify_waiters();
    }

    /// The total so far: compare two reads to see whether anything moved.
    pub fn count(&self) -> u64 {
        self.inner.count.load(Ordering::Relaxed)
    }
}

/// Why an [`IdleDeadline`] ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Stalled {
    /// No progress for `silent` (at least the idle bound).
    Idle { silent: Duration },
    /// The total cap passed although progress went on.
    Cap { elapsed: Duration },
}

impl Stalled {
    pub fn is_idle(&self) -> bool {
        matches!(self, Self::Idle { .. })
    }
}

impl fmt::Display for Stalled {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Idle { silent } => write!(f, "no progress for {} s", silent.as_secs()),
            Self::Cap { elapsed } => write!(f, "still going after {} s", elapsed.as_secs()),
        }
    }
}

impl std::error::Error for Stalled {}

/// A deadline `idle` after the last progress, and optionally never past a total cap.
#[derive(Debug, Clone, Copy)]
pub struct IdleDeadline<I: Clock = std::time::Instant> {
    idle: Duration,
    last: I,
    seen: u64,
    cap: Option<Deadline<I>>,
}

impl<I: Clock> IdleDeadline<I> {
    /// Starts now, with no progress seen yet.
    pub fn new(idle: Duration, cap: Option<Duration>) -> Self {
        Self::new_at(I::now(), idle, cap)
    }

    pub fn new_at(now: I, idle: Duration, cap: Option<Duration>) -> Self {
        Self { idle, last: now, seen: 0, cap: cap.map(|cap| Deadline::starting(now, cap)) }
    }

    /// Starts from a [`Progress`]'s current count, so only later bumps count.
    pub fn watching(progress: &Progress, idle: Duration, cap: Option<Duration>) -> Self {
        let mut deadline = Self::new(idle, cap);
        deadline.seen = progress.count();
        deadline
    }

    /// The silence bound.
    pub fn idle(&self) -> Duration {
        self.idle
    }

    /// Progress happened at `now`: the idle bound restarts.
    pub fn progressed_at(&mut self, now: I) {
        self.last = now;
    }

    pub fn progressed(&mut self) {
        self.progressed_at(I::now());
    }

    /// Reads a progress `count` at `now`: a count past the last one seen is progress. Returns
    /// whether it moved.
    pub fn observe_at(&mut self, now: I, count: u64) -> bool {
        if count == self.seen {
            return false;
        }
        self.seen = count;
        self.last = now;
        true
    }

    pub fn observe(&mut self, progress: &Progress) -> bool {
        self.observe_at(I::now(), progress.count())
    }

    /// When it ends if nothing moves: what a `sleep_until` or `recv_timeout` waits for.
    pub fn end(&self) -> I {
        let idle_end = crate::end_of(self.last, self.idle);
        match &self.cap {
            Some(cap) => idle_end.min(cap.end()),
            None => idle_end,
        }
    }

    /// Time left before it ends, never negative.
    pub fn remaining_at(&self, now: I) -> Duration {
        self.end().saturating_duration_since(now)
    }

    pub fn remaining(&self) -> Duration {
        self.remaining_at(I::now())
    }

    /// Whether it has ended at `now`, and why.
    pub fn stalled_at(&self, now: I) -> Option<Stalled> {
        if let Some(cap) = &self.cap
            && cap.expired_at(now)
        {
            return Some(Stalled::Cap { elapsed: cap.elapsed_at(now) });
        }
        let silent = now.saturating_duration_since(self.last);
        (silent >= self.idle).then_some(Stalled::Idle { silent })
    }

    pub fn stalled(&self) -> Option<Stalled> {
        self.stalled_at(I::now())
    }
}

#[cfg(feature = "tokio")]
mod tokio_side {
    use std::future::Future;
    use std::io;
    use std::pin::Pin;
    use std::task::{Context, Poll};
    use std::time::Duration;

    use tokio::io::{AsyncRead, AsyncWrite, ReadBuf};

    use super::{IdleDeadline, Progress, Stalled};

    /// Runs `fut` until it finishes, or until `progress` has not moved for `idle` (or the total
    /// `cap` passes). The silence bound restarts on every bump, so a send or a stream that keeps
    /// moving is never cut off. Measured on tokio's clock, so a paused test clock moves it.
    pub async fn progress_timeout<F: Future>(
        idle: Duration,
        cap: Option<Duration>,
        progress: &Progress,
        fut: F,
    ) -> Result<F::Output, Stalled> {
        let mut deadline = IdleDeadline::<tokio::time::Instant>::new(idle, cap);
        deadline.seen = progress.count();
        let mut fut = std::pin::pin!(fut);
        loop {
            // Registered before the count is read, so a bump between the read and the wait still
            // wakes it.
            let notified = progress.inner.notify.notified();
            let mut notified = std::pin::pin!(notified);
            notified.as_mut().enable();
            let now = tokio::time::Instant::now();
            deadline.observe_at(now, progress.count());
            if let Some(stalled) = deadline.stalled_at(now) {
                return Err(stalled);
            }
            tokio::select! {
                biased;
                output = &mut fut => return Ok(output),
                () = notified => {}
                () = tokio::time::sleep_until(deadline.end()) => {}
            }
        }
    }

    /// A reader or writer whose every byte through it bumps a [`Progress`].
    #[derive(Debug)]
    pub struct ProgressIo<T> {
        inner: T,
        progress: Progress,
    }

    impl<T> ProgressIo<T> {
        pub fn new(inner: T, progress: Progress) -> Self {
            Self { inner, progress }
        }

        pub fn progress(&self) -> &Progress {
            &self.progress
        }

        pub fn get_ref(&self) -> &T {
            &self.inner
        }

        pub fn get_mut(&mut self) -> &mut T {
            &mut self.inner
        }

        pub fn into_inner(self) -> T {
            self.inner
        }
    }

    impl<T: AsyncRead + Unpin> AsyncRead for ProgressIo<T> {
        fn poll_read(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            let before = buf.filled().len();
            let poll = Pin::new(&mut self.inner).poll_read(cx, buf);
            if let Poll::Ready(Ok(())) = &poll {
                self.progress.bump_by((buf.filled().len() - before) as u64);
            }
            poll
        }
    }

    impl<T: AsyncWrite + Unpin> AsyncWrite for ProgressIo<T> {
        fn poll_write(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            buf: &[u8],
        ) -> Poll<io::Result<usize>> {
            let poll = Pin::new(&mut self.inner).poll_write(cx, buf);
            if let Poll::Ready(Ok(n)) = &poll {
                self.progress.bump_by(*n as u64);
            }
            poll
        }

        fn poll_flush(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Pin::new(&mut self.inner).poll_flush(cx)
        }

        fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<io::Result<()>> {
            Pin::new(&mut self.inner).poll_shutdown(cx)
        }

        fn poll_write_vectored(
            mut self: Pin<&mut Self>,
            cx: &mut Context<'_>,
            bufs: &[io::IoSlice<'_>],
        ) -> Poll<io::Result<usize>> {
            let poll = Pin::new(&mut self.inner).poll_write_vectored(cx, bufs);
            if let Poll::Ready(Ok(n)) = &poll {
                self.progress.bump_by(*n as u64);
            }
            poll
        }

        fn is_write_vectored(&self) -> bool {
            self.inner.is_write_vectored()
        }
    }
}

#[cfg(feature = "tokio")]
pub use tokio_side::{ProgressIo, progress_timeout};

#[cfg(test)]
#[path = "progress_tests.rs"]
mod tests;
