//! Hosted input failures (`FLAG_INPUT_FAILURES`, p05-ipc-157): interactive
//! input a host's input sink refuses (its backlog is full) or never writes
//! (the PTY failed) goes back to the daemon stream that sent it, as the
//! local sink tells that stream itself.
//!
//! The daemon names each sender (one per attach stream) in the `Input`
//! frame's request id ([`InputSenders`]); the host keeps one receipt per
//! sender of a client ([`HostInputSenders`]), so its sink reports all of a
//! sender's queued bytes in one `InputFailed`, and the daemon's reader hands
//! the report to that sender. This is the receipt half of Chrome's mojo data
//! pipe for a producer in another process: the consumer's state reaches the
//! producer as a message on the same channel
//! (mojo/core/data_pipe_control_message.h, `DATA_PIPE_CONTROL_MESSAGE`).

use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Weak};

use cmux_threads::sync::Mutex;

use super::host_shared::HostShared;
use super::host_state::HostTap;
use crate::input_receipt::{InputFailure, InputReceipt};
use crate::panic_free::RecoverPoison;
use crate::terminal_host_protocol::{Frame, MessageKind, decode_input_failed, encode_input_failed};

/// The daemon side: one connection's senders by id, so the reader thread
/// hands an `InputFailed` to the stream that sent the bytes. A sender that
/// went away (its stream ended) is not kept alive and its reports drop.
#[derive(Default)]
pub(crate) struct InputSenders {
    /// Lock carve-out: held only to find or add one sender, or to find the
    /// one a report names; nothing else is locked under it, and a receipt
    /// is told after it is released.
    senders: Mutex<Vec<(u64, Weak<dyn InputReceipt>)>>,
    last: AtomicU64,
}

impl InputSenders {
    /// The id `receipt` goes under on this connection, the same for each of
    /// its sends.
    pub(crate) fn id_of(&self, receipt: &Arc<dyn InputReceipt>) -> u64 {
        let mut senders = self.senders.lock().recover_poison();
        if let Some((id, _)) = senders
            .iter()
            .find(|(_, sender)| std::ptr::addr_eq(sender.as_ptr(), Arc::as_ptr(receipt)))
        {
            return *id;
        }
        senders.retain(|(_, sender)| sender.strong_count() > 0);
        // Never 0: a zero request id is plain interactive input.
        let id = self.last.fetch_add(1, Ordering::Relaxed) + 1;
        senders.push((id, Arc::downgrade(receipt)));
        id
    }

    /// Tells the sender an `InputFailed` names; false when the frame is
    /// malformed (the connection ends, as for any bad host frame).
    pub(crate) fn report(&self, frame: &Frame, protocol_version: u16) -> bool {
        if frame.version != protocol_version
            || frame.flags != 0
            || frame.sequence != 0
            || frame.request_id == 0
        {
            return false;
        }
        let Some((reason, bytes)) = decode_input_failed(&frame.payload)
            .and_then(|(code, bytes)| Some((InputFailure::from_wire_code(code)?, bytes)))
        else {
            return false;
        };
        let sender = {
            let senders = self.senders.lock().recover_poison();
            senders.iter().find(|(id, _)| *id == frame.request_id).and_then(|(_, s)| s.upgrade())
        };
        if let Some(sender) = sender {
            sender.failed(reason, usize::try_from(bytes).unwrap_or(usize::MAX));
        }
        true
    }
}

/// The host side: one client's senders, each with the one receipt its
/// queued input goes under, so a failed PTY reports each sender once.
pub(crate) struct HostInputSenders {
    host: Weak<HostShared>,
    target: HostTap,
    /// Lock carve-out: held only to find or add one sender's receipt;
    /// nothing else is locked under it.
    senders: Mutex<Vec<(u64, Arc<dyn InputReceipt>)>>,
}

impl HostInputSenders {
    pub(crate) fn new(host: &Arc<HostShared>, target: HostTap) -> Self {
        Self { host: Arc::downgrade(host), target, senders: Mutex::new(Vec::new()) }
    }

    /// The receipt of `sender`'s input. One no queued chunk holds any more
    /// is dropped when a new sender comes: it has nothing left to report.
    pub(crate) fn receipt(&self, sender: u64) -> Arc<dyn InputReceipt> {
        let mut senders = self.senders.lock().recover_poison();
        if let Some((_, receipt)) = senders.iter().find(|(id, _)| *id == sender) {
            return receipt.clone();
        }
        senders.retain(|(_, receipt)| Arc::strong_count(receipt) > 1);
        let receipt: Arc<dyn InputReceipt> = Arc::new(InputFailedReport {
            host: self.host.clone(),
            sender,
            target: self.target.clone(),
        });
        senders.push((sender, receipt.clone()));
        receipt
    }
}

/// Sends one sender's `InputFailed` to its client.
struct InputFailedReport {
    host: Weak<HostShared>,
    sender: u64,
    target: HostTap,
}

impl InputReceipt for InputFailedReport {
    fn failed(&self, reason: InputFailure, bytes: usize) {
        let Some(host) = self.host.upgrade() else { return };
        let mut report = Frame::new(
            MessageKind::InputFailed,
            encode_input_failed(reason.wire_code(), bytes as u64),
        );
        report.request_id = self.sender;
        let _broadcast = host.broadcast_lock.lock().recover_poison();
        // A full client queue closes the client (`HostTap::try_send`).
        let _ = self.target.try_send(report);
    }
}
