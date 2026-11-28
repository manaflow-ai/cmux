//! Session clock probes (rd change C8): the viewer pings, the host answers
//! with its receive and send times, and the viewer estimates the offset of
//! the host clock from its own (NTP style, minimum-RTT sample). Each ping
//! carries the viewer's current estimate, so the host's sources know it too
//! (remote-tab-r2.md B3.4: viewer vsync times converted to host time).

use crate::error::{DecodeError, Reader};

/// The offset of the host's monotonic clock from the viewer's
/// (`host = viewer + offset_us`) and the round trip of the best sample.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClockEstimate {
    pub offset_us: i64,
    pub rtt_us: u32,
}

/// `DatagramKind::ClockPing` payload: `u32 seq`, `u64 t_viewer_us`, `u8
/// has_estimate`, `i64 offset_us`, `u32 rtt_us`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClockPing {
    pub seq: u32,
    pub t_viewer_us: u64,
    pub estimate: Option<ClockEstimate>,
}

/// `DatagramKind::ClockPong` payload: `u32 seq`, `u64 t_viewer_us` (echoed),
/// `u64 t_host_rx_us`, `u64 t_host_tx_us`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClockPong {
    pub seq: u32,
    pub t_viewer_us: u64,
    pub t_host_rx_us: u64,
    pub t_host_tx_us: u64,
}

impl ClockPing {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(25);
        out.extend_from_slice(&self.seq.to_le_bytes());
        out.extend_from_slice(&self.t_viewer_us.to_le_bytes());
        let e = self.estimate.unwrap_or(ClockEstimate { offset_us: 0, rtt_us: 0 });
        out.push(u8::from(self.estimate.is_some()));
        out.extend_from_slice(&e.offset_us.to_le_bytes());
        out.extend_from_slice(&e.rtt_us.to_le_bytes());
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut r = Reader::new(bytes);
        let seq = r.u32()?;
        let t_viewer_us = r.u64()?;
        let has = r.u8()?;
        let offset_us = r.u64()? as i64;
        let rtt_us = r.u32()?;
        if !r.is_empty() || has > 1 {
            return Err(DecodeError::Invalid("clock ping"));
        }
        let estimate = (has == 1).then_some(ClockEstimate { offset_us, rtt_us });
        Ok(Self { seq, t_viewer_us, estimate })
    }
}

impl ClockPong {
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(28);
        out.extend_from_slice(&self.seq.to_le_bytes());
        out.extend_from_slice(&self.t_viewer_us.to_le_bytes());
        out.extend_from_slice(&self.t_host_rx_us.to_le_bytes());
        out.extend_from_slice(&self.t_host_tx_us.to_le_bytes());
        out
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut r = Reader::new(bytes);
        let pong = Self {
            seq: r.u32()?,
            t_viewer_us: r.u64()?,
            t_host_rx_us: r.u64()?,
            t_host_tx_us: r.u64()?,
        };
        if !r.is_empty() {
            return Err(DecodeError::Invalid("clock pong"));
        }
        Ok(pong)
    }
}
