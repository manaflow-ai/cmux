//! One frame's host times for the stage ledger (screen-share-under-100ms.md
//! decision D8; cap `ledger`). The host sends them in a
//! [`crate::DatagramKind::FrameTimes`] datagram after the frame's last shard,
//! because the send times are known only then; the datagram header names the
//! stream and frame. A viewer that did not offer `ledger` never gets one.

use crate::datagram::{DatagramHeader, DatagramKind};
use crate::error::{DecodeError, Reader};

/// Size of a [`FrameTimes`] payload.
pub const FRAME_TIMES_LEN: usize = 40;

/// Host monotonic microseconds (the protocol clock); 0 when the host does not
/// know the time (a capture backend without a display time).
///
/// Layout: `u64 display_us`, `u64 encode_start_us`, `u64 encoded_us`,
/// `u64 first_sent_us`, `u64 last_sent_us`.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct FrameTimes {
    /// When the display showed the picture (ScreenCaptureKit's display time).
    pub display_us: u64,
    /// When the encoder was handed the picture.
    pub encode_start_us: u64,
    /// When the bitstream was ready.
    pub encoded_us: u64,
    /// When the frame's first datagram was handed to the carrier.
    pub first_sent_us: u64,
    /// When its last datagram was handed to the carrier.
    pub last_sent_us: u64,
}

impl FrameTimes {
    pub fn encode(&self) -> [u8; FRAME_TIMES_LEN] {
        let mut out = [0u8; FRAME_TIMES_LEN];
        let fields = [
            self.display_us,
            self.encode_start_us,
            self.encoded_us,
            self.first_sent_us,
            self.last_sent_us,
        ];
        for (chunk, value) in out.chunks_exact_mut(8).zip(fields) {
            chunk.copy_from_slice(&value.to_le_bytes());
        }
        out
    }

    /// Parses a payload. Longer payloads are accepted (a later version may
    /// append fields); shorter ones are refused.
    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut r = Reader::new(bytes);
        Ok(Self {
            display_us: r.u64()?,
            encode_start_us: r.u64()?,
            encoded_us: r.u64()?,
            first_sent_us: r.u64()?,
            last_sent_us: r.u64()?,
        })
    }

    /// The whole datagram for frame `frame` of display stream `stream`.
    pub fn datagram(&self, stream: u16, frame: u32) -> Vec<u8> {
        let mut out = Vec::with_capacity(crate::HEADER_LEN + FRAME_TIMES_LEN);
        DatagramHeader {
            flags: 0,
            kind: DatagramKind::FrameTimes,
            stream,
            frame,
            index: 0,
            count: 0,
            fec_count: 0,
            transport_seq: 0,
        }
        .encode_into(&mut out);
        out.extend_from_slice(&self.encode());
        out
    }
}

#[cfg(test)]
#[path = "frame_times_tests.rs"]
mod tests;
