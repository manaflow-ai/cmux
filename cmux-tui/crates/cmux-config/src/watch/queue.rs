//! A bounded queue from notify's event thread to a watch thread.
//!
//! notify calls its handler on its own event thread, and `watch` / `unwatch`
//! wait for that thread, so the handler must never block: a watch thread
//! that re-arms its watches while the queue is full would wait on the event
//! thread, which would wait on it. The queue therefore never blocks the
//! producer and keeps at most `capacity` events. When it is full, the event
//! is dropped and the consumer gets one rescan event (`Flag::Rescan`, what
//! notify itself reports when the kernel's queue overflowed) before it waits
//! again. Chromium does the same on inotify's `IN_Q_OVERFLOW`: every watch is
//! told its path changed (base/files/file_path_watcher_inotify.cc,
//! `InotifyReaderThreadDelegate`). Every consumer here already treats a
//! rescan as "read everything again".

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{
    Receiver, RecvError, RecvTimeoutError, SyncSender, TryRecvError, TrySendError, sync_channel,
};
use std::time::Duration;

use notify::event::{Event, EventKind, Flag};

/// What notify hands a handler.
pub type WatchEvent = notify::Result<Event>;

/// Events a watch thread holds between two reads: enough for a burst of
/// saves, a git checkout or an editor's swap files, about 1 MB at most.
pub const DEFAULT_CAPACITY: usize = 1024;

/// The receiver is gone: the watch ended.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Disconnected;

/// A bounded event queue holding at most `capacity` events (at least one).
pub fn event_queue(capacity: usize) -> (EventSender, EventReceiver) {
    let (sender, receiver) = sync_channel(capacity.max(1));
    let overflowed = Arc::new(AtomicBool::new(false));
    (
        EventSender { sender, overflowed: Arc::clone(&overflowed) },
        EventReceiver { receiver, overflowed },
    )
}

/// The rescan event an overflow turns into.
pub fn rescan_event() -> WatchEvent {
    Ok(Event::new(EventKind::Other).set_flag(Flag::Rescan))
}

/// The producer side; pass it to `notify::recommended_watcher` directly.
#[derive(Clone)]
pub struct EventSender {
    sender: SyncSender<WatchEvent>,
    overflowed: Arc<AtomicBool>,
}

impl EventSender {
    /// Queues `event` without waiting. On a full queue the event is dropped
    /// and the consumer's next read is a rescan.
    pub fn send(&self, event: WatchEvent) -> Result<(), Disconnected> {
        match self.sender.try_send(event) {
            Ok(()) => Ok(()),
            Err(TrySendError::Disconnected(_)) => Err(Disconnected),
            Err(TrySendError::Full(_)) => {
                self.overflowed.store(true, Ordering::Release);
                // The consumer may have emptied the queue since the failed
                // send and be waiting: wake it. When the queue is still full,
                // the consumer reads a queued event and then sees the flag.
                match self.sender.try_send(rescan_event()) {
                    Err(TrySendError::Disconnected(_)) => Err(Disconnected),
                    Ok(()) | Err(TrySendError::Full(_)) => Ok(()),
                }
            }
        }
    }
}

impl notify::EventHandler for EventSender {
    fn handle_event(&mut self, event: WatchEvent) {
        let _ = self.send(event);
    }
}

/// The consumer side. Each read returns the pending rescan first, if any.
pub struct EventReceiver {
    receiver: Receiver<WatchEvent>,
    overflowed: Arc<AtomicBool>,
}

impl EventReceiver {
    /// Waits for the next event.
    pub fn recv(&self) -> Result<WatchEvent, RecvError> {
        self.recv_with(Receiver::recv)
    }

    /// Waits at most `timeout` for the next event.
    pub fn recv_timeout(&self, timeout: Duration) -> Result<WatchEvent, RecvTimeoutError> {
        self.recv_with(|receiver| receiver.recv_timeout(timeout))
    }

    /// The next event when one is queued.
    pub fn try_recv(&self) -> Result<WatchEvent, TryRecvError> {
        self.recv_with(Receiver::try_recv)
    }

    /// The next event, read by `wait` (a checked wait, for example) unless a
    /// rescan is pending.
    pub fn recv_with<E>(
        &self,
        wait: impl FnOnce(&Receiver<WatchEvent>) -> Result<WatchEvent, E>,
    ) -> Result<WatchEvent, E> {
        if self.overflowed.swap(false, Ordering::AcqRel) {
            return Ok(rescan_event());
        }
        wait(&self.receiver)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn change(name: &str) -> WatchEvent {
        Ok(Event::new(EventKind::Any).add_path(PathBuf::from(name)))
    }

    fn is_rescan(event: &WatchEvent) -> bool {
        event.as_ref().is_ok_and(Event::need_rescan)
    }

    #[test]
    fn a_full_queue_drops_the_event_and_reads_a_rescan_first() {
        let (sender, receiver) = event_queue(2);
        for name in ["a", "b", "c", "d"] {
            assert_eq!(sender.send(change(name)), Ok(()));
        }
        assert!(is_rescan(&receiver.recv().expect("rescan")));
        let mut rest = Vec::new();
        while let Ok(event) = receiver.try_recv() {
            assert!(!is_rescan(&event), "one rescan covers every dropped event");
            rest.push(event);
        }
        assert_eq!(rest.len(), 2, "never more than the capacity is held");
    }

    #[test]
    fn a_rescan_queued_behind_a_full_queue_is_read_after_the_flag() {
        let (sender, receiver) = event_queue(1);
        assert_eq!(sender.send(change("a")), Ok(()));
        assert_eq!(sender.send(change("b")), Ok(()));
        assert!(is_rescan(&receiver.recv().expect("flag")));
        assert!(!is_rescan(&receiver.recv().expect("a")));
        assert!(matches!(receiver.try_recv(), Err(TryRecvError::Empty)));
    }

    #[test]
    fn a_send_after_the_receiver_is_gone_fails() {
        let (sender, receiver) = event_queue(1);
        drop(receiver);
        assert_eq!(sender.send(change("a")), Err(Disconnected));
    }
}
