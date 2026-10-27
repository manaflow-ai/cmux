//! A one-slot wake for a task that reads the latest state when woken.
//!
//! A wake carries no data: the task rereads what changed, so one queued
//! wake covers every later one until the task takes it. The queue holds one
//! wake at most and a wake on a full queue is dropped, as Chromium's
//! `WorkDeduplicator` asks the message pump for one wake while one is
//! pending (base/task/sequence_manager/work_deduplicator.h).

use tokio::sync::mpsc::error::TrySendError;
use tokio::sync::mpsc::{Receiver, Sender, channel};

/// A one-slot wake queue.
pub(crate) fn wake_channel() -> (Sender<()>, Receiver<()>) {
    channel(1)
}

/// Wakes the task without waiting. False once the task is gone.
pub(crate) fn wake(signal: &Sender<()>) -> bool {
    !matches!(signal.try_send(()), Err(TrySendError::Closed(())))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wakes_coalesce_into_one_and_report_a_gone_task() {
        let (signal, mut wakes) = wake_channel();
        assert!(wake(&signal));
        assert!(wake(&signal), "a wake on a full queue is dropped, not an error");
        assert!(wakes.try_recv().is_ok());
        assert!(wakes.try_recv().is_err(), "one queued wake at most");
        drop(wakes);
        assert!(!wake(&signal));
    }
}
