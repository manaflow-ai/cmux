//! Bulk transfers (rd change C5): a service's file bytes (uploads and
//! downloads) on the reliable stream, without hurting interactivity. The
//! sender sends at most one [`MAX_BULK_CHUNK`] frame per media frame
//! interval, none while a media frame waits for the carrier, and never past
//! the receiver's credit; the receiver takes chunks strictly in order and
//! grants [`INITIAL_CREDIT`] more bytes each time half of it has arrived.
//! Credit travels as the control message `bulk_credit {transfer, offset}`.
//! Pure: no I/O, the caller's clock.

use std::collections::{BTreeMap, BTreeSet, VecDeque};

use cmux_rd_proto::{BulkFrame, MAX_BULK_CHUNK};

/// Bytes a sender may send on a new transfer before any credit arrives.
pub const INITIAL_CREDIT: u64 = 1 << 20;

/// The receiver allows the sender this far past what it has received.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct BulkCredit {
    pub transfer: u64,
    /// The sender may send bytes before this offset.
    pub offset: u64,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum BulkError {
    /// The transfer id is already queued.
    Duplicate(u64),
    /// A chunk that does not start where the last one ended.
    OutOfOrder { transfer: u64, expected: u64, got: u64 },
    /// The transfer is finished or cancelled.
    Finished(u64),
}

#[derive(Debug)]
struct Outgoing {
    transfer: u64,
    data: Vec<u8>,
    sent: u64,
    credit: u64,
}

impl Outgoing {
    fn sendable(&self) -> bool {
        self.sent < self.data.len() as u64 && self.sent < self.credit
    }
}

/// The sending side of every transfer of one session.
#[derive(Debug)]
pub struct BulkSender {
    interval_us: u64,
    next_at_us: u64,
    queue: VecDeque<Outgoing>,
}

impl BulkSender {
    /// `interval_us`: the media frame interval (at most one chunk per interval).
    pub fn new(interval_us: u64) -> Self {
        Self { interval_us, next_at_us: 0, queue: VecDeque::new() }
    }

    /// Queues a transfer's bytes.
    pub fn queue(&mut self, transfer: u64, data: Vec<u8>) -> Result<(), BulkError> {
        if self.queue.iter().any(|o| o.transfer == transfer) {
            return Err(BulkError::Duplicate(transfer));
        }
        self.queue.push_back(Outgoing { transfer, data, sent: 0, credit: INITIAL_CREDIT });
        Ok(())
    }

    /// Applies a credit from the receiver (credit only grows).
    pub fn on_credit(&mut self, transfer: u64, offset: u64) {
        if let Some(o) = self.queue.iter_mut().find(|o| o.transfer == transfer) {
            o.credit = o.credit.max(offset);
        }
    }

    /// Drops a transfer (the user cancelled it).
    pub fn cancel(&mut self, transfer: u64) {
        self.queue.retain(|o| o.transfer != transfer);
    }

    /// The next chunk to send at `now_us`, or `None` while a media frame
    /// waits (`media_waiting`), before the interval elapsed, or when every
    /// transfer waits for credit. Transfers take turns.
    pub fn next_frame(&mut self, now_us: u64, media_waiting: bool) -> Option<BulkFrame> {
        if media_waiting || now_us < self.next_at_us {
            return None;
        }
        let i = self.queue.iter().position(Outgoing::sendable)?;
        let mut o = self.queue.remove(i)?;
        let end = (o.sent + MAX_BULK_CHUNK as u64).min(o.credit).min(o.data.len() as u64);
        let bytes = o.data[o.sent as usize..end as usize].to_vec();
        let frame = BulkFrame { transfer: o.transfer, offset: o.sent, bytes };
        o.sent = end;
        if o.sent < o.data.len() as u64 {
            self.queue.push_back(o);
        }
        self.next_at_us = now_us.saturating_add(self.interval_us);
        Some(frame)
    }

    /// When a chunk can go next; `None` when nothing can be sent (idle or
    /// blocked on credit), so an idle session has no wakeup.
    pub fn next_deadline_us(&self) -> Option<u64> {
        self.queue.iter().any(Outgoing::sendable).then_some(self.next_at_us)
    }

    /// True when no transfer is queued.
    pub fn is_idle(&self) -> bool {
        self.queue.is_empty()
    }
}

/// One chunk taken by the receiver, and a credit to send back if due.
#[derive(Debug)]
pub struct Accepted {
    pub bytes: Vec<u8>,
    pub credit: Option<BulkCredit>,
}

#[derive(Debug, Default)]
struct Incoming {
    received: u64,
    granted: u64,
}

/// The receiving side of every transfer of one session.
#[derive(Debug, Default)]
pub struct BulkReceiver {
    transfers: BTreeMap<u64, Incoming>,
    finished: BTreeSet<u64>,
}

impl BulkReceiver {
    pub fn new() -> Self {
        Self::default()
    }

    /// Takes one chunk; chunks of a transfer must arrive in order (the
    /// stream is reliable, so a gap or overlap is a protocol error).
    pub fn accept(&mut self, frame: &BulkFrame) -> Result<Accepted, BulkError> {
        if self.finished.contains(&frame.transfer) {
            return Err(BulkError::Finished(frame.transfer));
        }
        let t = self
            .transfers
            .entry(frame.transfer)
            .or_insert(Incoming { received: 0, granted: INITIAL_CREDIT });
        if frame.offset != t.received {
            return Err(BulkError::OutOfOrder {
                transfer: frame.transfer,
                expected: t.received,
                got: frame.offset,
            });
        }
        let end = t.received + frame.bytes.len() as u64;
        if end > t.granted {
            return Err(BulkError::OutOfOrder {
                transfer: frame.transfer,
                expected: t.granted,
                got: end,
            });
        }
        t.received = end;
        let credit = (t.granted - t.received <= INITIAL_CREDIT / 2).then(|| {
            t.granted = t.received + INITIAL_CREDIT;
            BulkCredit { transfer: frame.transfer, offset: t.granted }
        });
        Ok(Accepted { bytes: frame.bytes.clone(), credit })
    }

    /// Ends a transfer (complete or cancelled); later chunks are refused.
    pub fn finish(&mut self, transfer: u64) {
        self.transfers.remove(&transfer);
        self.finished.insert(transfer);
    }
}
