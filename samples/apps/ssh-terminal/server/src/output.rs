//! The output of one terminal: bytes with offsets, then at most one end
//! event (exit or lost).
//!
//! Bounds (README, "Resume"):
//! - at most [`MAX_UNREAD`] bytes wait for the session host (one SSH packet,
//!   at most 32 KiB, is never split). When the host does not take them, the
//!   reader stops. The SSH client then fills its small channel queue and
//!   stops reading the TCP socket; TCP flow control stops the far end.
//!   Bytes are never dropped while the terminal is open.
//! - at most [`RETAINED`] already delivered bytes stay for `resume`. Older
//!   bytes are gone; a resume from before them gives `lost`.

use crate::iface::ByteEvent;
use std::collections::VecDeque;
use std::sync::{Mutex, MutexGuard};
use tokio::sync::Notify;

pub const MAX_UNREAD: usize = 64 * 1024;
pub const RETAINED: usize = 64 * 1024;

struct Log {
    bytes: VecDeque<u8>,
    /// Offset of `bytes[0]`.
    start: u64,
    /// Next offset the attached terminal gets.
    delivered: u64,
    end: Option<ByteEvent>,
    end_delivered: bool,
    attached: bool,
    /// Closed by the session host: bytes are discarded, nobody reads.
    closed: bool,
}

impl Log {
    fn end_offset(&self) -> u64 {
        self.start + self.bytes.len() as u64
    }

    fn unread(&self) -> usize {
        (self.end_offset() - self.delivered) as usize
    }

    fn trim(&mut self) {
        let kept = (self.delivered - self.start) as usize;
        if kept > RETAINED {
            let drop = kept - RETAINED;
            self.bytes.drain(..drop);
            self.start += drop as u64;
        }
    }
}

pub struct Output {
    log: Mutex<Log>,
    room: Notify,
}

impl Default for Output {
    fn default() -> Self {
        Self {
            log: Mutex::new(Log {
                bytes: VecDeque::new(),
                start: 0,
                delivered: 0,
                end: None,
                end_delivered: false,
                attached: true,
                closed: false,
            }),
            room: Notify::new(),
        }
    }
}

impl Output {
    fn lock(&self) -> MutexGuard<'_, Log> {
        // A panic while the lock was held leaves only plain data behind.
        self.log.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    /// Appends far-end bytes. Waits while too much is unread (backpressure).
    pub async fn push(&self, data: &[u8]) {
        loop {
            {
                let mut log = self.lock();
                if log.closed {
                    return;
                }
                if log.unread() == 0 || log.unread() + data.len() <= MAX_UNREAD {
                    log.bytes.extend(data);
                    return;
                }
            }
            // `notify_one` keeps a permit, so a take between the check and
            // this await is not lost.
            self.room.notified().await;
        }
    }

    /// Records the end event once. Later calls do nothing.
    pub fn finish(&self, event: ByteEvent) {
        let mut log = self.lock();
        if log.end.is_none() {
            log.end = Some(event);
        }
    }

    pub fn has_ended(&self) -> bool {
        self.lock().end.is_some()
    }

    /// Everything new for the attached terminal, in order.
    pub fn take(&self) -> Vec<ByteEvent> {
        let mut events = Vec::new();
        let mut log = self.lock();
        if !log.attached {
            return events;
        }
        if log.unread() > 0 {
            let from = (log.delivered - log.start) as usize;
            events.push(ByteEvent::Output(log.bytes.range(from..).copied().collect()));
            log.delivered = log.end_offset();
            log.trim();
        }
        if !log.end_delivered
            && let Some(end) = log.end.clone()
        {
            events.push(end);
            log.end_delivered = true;
        }
        drop(log);
        self.room.notify_one();
        events
    }

    /// The next offset the attached terminal gets (for the resume token).
    pub fn delivered(&self) -> u64 {
        self.lock().delivered
    }

    pub fn detach(&self) {
        self.lock().attached = false;
    }

    /// The terminal is closed: drop kept bytes and wake a waiting reader so
    /// it can drain the channel and end.
    pub fn close(&self) {
        {
            let mut log = self.lock();
            log.closed = true;
            log.attached = false;
            log.bytes.clear();
        }
        self.room.notify_one();
    }

    /// Bytes that arrived before the shell request was answered (bounded by
    /// the caller).
    pub fn push_early(&self, data: &[u8]) {
        self.lock().bytes.extend(data);
    }

    /// Attaches again from `offset`. False when `offset` is outside the kept
    /// bytes or a terminal is still attached.
    pub fn attach_at(&self, offset: u64) -> bool {
        let mut log = self.lock();
        if log.attached || log.closed || offset < log.start || offset > log.end_offset() {
            return false;
        }
        log.delivered = offset;
        log.end_delivered = false;
        log.attached = true;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::Arc;
    use std::time::Duration;

    fn runtime() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_multi_thread().worker_threads(1).enable_all().build().unwrap()
    }

    #[test]
    fn a_full_log_stops_the_reader_until_the_host_takes_bytes() {
        let rt = runtime();
        let out = Arc::new(Output::default());
        rt.block_on(out.push(&vec![b'a'; MAX_UNREAD]));
        let pusher = rt.spawn({
            let out = out.clone();
            async move { out.push(b"b").await }
        });
        rt.block_on(async { tokio::time::sleep(Duration::from_millis(50)).await });
        assert!(!pusher.is_finished(), "the reader waits while 64 KiB are unread");
        let first = out.take();
        assert!(matches!(first.as_slice(), [ByteEvent::Output(b)] if b.len() == MAX_UNREAD));
        rt.block_on(pusher).unwrap();
        assert_eq!(out.take(), vec![ByteEvent::Output(b"b".to_vec())], "no byte is dropped");
    }

    #[test]
    fn resume_replays_only_the_retained_window() {
        let rt = runtime();
        let out = Output::default();
        for _ in 0..3 {
            rt.block_on(out.push(&vec![b'x'; MAX_UNREAD]));
            out.take();
        }
        let end = out.delivered();
        out.detach();
        assert!(!out.attach_at(0), "bytes older than RETAINED are gone");
        assert!(out.attach_at(end - RETAINED as u64));
        assert!(!out.attach_at(end), "one terminal attached at a time");
    }

    #[test]
    fn the_end_event_comes_once_after_all_bytes() {
        let rt = runtime();
        let out = Output::default();
        rt.block_on(out.push(b"bye"));
        out.finish(ByteEvent::Exit(crate::iface::ExitStatus { code: Some(0) }));
        out.finish(ByteEvent::Lost("late".into()));
        let events = out.take();
        assert_eq!(events.len(), 2);
        assert_eq!(events[0], ByteEvent::Output(b"bye".to_vec()));
        assert!(matches!(events[1], ByteEvent::Exit(_)));
        assert!(out.take().is_empty());
    }

    #[test]
    fn close_releases_a_waiting_reader_and_discards_bytes() {
        let rt = runtime();
        let out = Arc::new(Output::default());
        rt.block_on(out.push(&vec![b'a'; MAX_UNREAD]));
        let pusher = rt.spawn({
            let out = out.clone();
            async move { out.push(b"b").await }
        });
        out.close();
        rt.block_on(pusher).unwrap();
        assert!(out.take().is_empty());
        assert!(!out.attach_at(0), "a closed terminal cannot be resumed");
    }
}
