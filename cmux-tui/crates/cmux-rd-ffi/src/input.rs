//! The viewer's input channel in safe Rust: events in, `Input` datagrams out,
//! `InputAck` datagrams in. Wraps `cmux_rd_core::input::InputSender` (repeat
//! until acknowledged, exactly once at the host) and adds the resend timer, so
//! a lost last event (a key release) goes out again without new input. The C
//! ABI in `input_ffi.rs` is a thin shell over this type.

use cmux_rd_core::input::InputSender;
use cmux_rd_proto::{
    DatagramHeader, DatagramKind, DecodeError, HEADER_LEN, InputEvent, STREAM_DATAGRAM,
    encode_stream_frame,
};

use crate::receiver::{Carrier, ReceiverError};

/// Viewer input state for one session.
#[derive(Debug)]
pub struct InputChannel {
    carrier: Carrier,
    resend_us: u64,
    sender: InputSender,
    last_sent_us: u64,
}

impl InputChannel {
    /// `resend_us`: how long unacknowledged events wait before they go out
    /// again when no new input arrives (about one RTT; at least 1).
    pub fn new(carrier: Carrier, resend_us: u64) -> Self {
        Self { carrier, resend_us: resend_us.max(1), sender: InputSender::new(), last_sent_us: 0 }
    }

    /// Queues an event and returns its sequence number. The next
    /// [`Self::packet`] call sends it.
    pub fn push(&mut self, event: InputEvent) -> u32 {
        self.sender.push(event)
    }

    /// Applies an `InputAck` datagram from the host (header included, as the
    /// receiver hands it out). On the stream carrier pass the datagram without
    /// its stream frame prefix (the receiver already removed it).
    pub fn on_ack(&mut self, datagram: &[u8]) -> Result<(), ReceiverError> {
        let (header, payload) = DatagramHeader::decode(datagram).map_err(ReceiverError::Invalid)?;
        let applied: [u8; 4] = match (header.kind, payload.try_into()) {
            (DatagramKind::InputAck, Ok(bytes)) => bytes,
            _ => return Err(ReceiverError::Invalid(DecodeError::Invalid("input ack"))),
        };
        self.sender.ack(u32::from_le_bytes(applied));
        Ok(())
    }

    /// When [`Self::packet`] must run next: `Some(0)` when an event was never
    /// sent, the resend time while events wait for an acknowledgement, `None`
    /// when nothing is queued.
    pub fn next_deadline_us(&self) -> Option<u64> {
        if self.sender.has_unsent() {
            Some(0)
        } else if self.sender.is_empty() {
            None
        } else {
            Some(self.last_sent_us.saturating_add(self.resend_us))
        }
    }

    /// The next `Input` datagram (stream-framed on the stream carrier), or
    /// `None` when nothing is due. Call again until it returns `None`: one
    /// datagram holds at most `MAX_PACKET_PAYLOAD` bytes of events.
    pub fn packet(&mut self, now_us: u64) -> Option<Vec<u8>> {
        let due = self.next_deadline_us().is_some_and(|at| at <= now_us);
        if !due {
            return None;
        }
        let packet = self.sender.packet()?;
        self.last_sent_us = now_us;
        let mut datagram = Vec::with_capacity(HEADER_LEN + 64);
        DatagramHeader {
            flags: 0,
            kind: DatagramKind::Input,
            stream: 0,
            frame: 0,
            index: 0,
            count: 0,
            fec_count: 0,
            transport_seq: 0,
        }
        .encode_into(&mut datagram);
        datagram.extend_from_slice(&packet.encode());
        Some(match self.carrier {
            Carrier::Datagram => datagram,
            Carrier::Stream => {
                let mut out = Vec::with_capacity(datagram.len() + 5);
                // An input datagram is far below the stream frame limit.
                let _ = encode_stream_frame(STREAM_DATAGRAM, &datagram, &mut out);
                out
            }
        })
    }
}
