use std::cell::Cell;
use std::time::Duration;

thread_local!(static AHEAD: Cell<Duration> = const { Cell::new(Duration::ZERO) });

/// Moves this thread's wall clock `by` forward; the monotonic clock stays.
pub(crate) fn jump(by: Duration) {
    AHEAD.with(|a| a.set(a.get() + by));
}

pub(crate) fn ahead() -> Duration {
    AHEAD.with(Cell::get)
}
