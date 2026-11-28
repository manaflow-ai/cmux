use crate::error::{DecodeError, Reader};

/// Most arrivals in one feedback; with the other limits a feedback payload
/// stays under 1,100 bytes, inside every session's `max_datagram`.
pub const MAX_ARRIVALS: usize = 128;
/// Most frames with NACKs in one feedback.
pub const MAX_NACK_FRAMES: usize = 4;
/// Most shard indexes per NACKed frame.
pub const MAX_NACK_INDEXES: usize = 32;

/// Arrival of one datagram at the viewer, by transport sequence number.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Arrival {
    pub transport_seq: u16,
    /// Viewer monotonic time in microseconds (wraps; only differences matter).
    pub arrival_us: u32,
}

/// A request to resend missing shards of one frame.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Nack {
    pub frame: u32,
    pub indexes: Vec<u16>,
}

/// Viewer-to-host feedback, sent once per frame and at least every 50 ms
/// while streaming.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Feedback {
    /// Newest frame the viewer completed and could decode (0 = none yet).
    pub acked_frame: u32,
    /// Median decode time in microseconds since the previous feedback.
    pub decode_us: u32,
    /// The viewer could not decode from `acked_frame` on and asks for recovery.
    pub need_recovery: bool,
    pub arrivals: Vec<Arrival>,
    pub nacks: Vec<Nack>,
}

impl Feedback {
    /// Serializes the payload.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&self.acked_frame.to_le_bytes());
        out.extend_from_slice(&self.decode_us.to_le_bytes());
        out.push(u8::from(self.need_recovery));
        let arrivals = &self.arrivals[..self.arrivals.len().min(MAX_ARRIVALS)];
        out.extend_from_slice(&(arrivals.len() as u16).to_le_bytes());
        for a in arrivals {
            out.extend_from_slice(&a.transport_seq.to_le_bytes());
            out.extend_from_slice(&a.arrival_us.to_le_bytes());
        }
        let nacks = &self.nacks[..self.nacks.len().min(MAX_NACK_FRAMES)];
        out.push(nacks.len() as u8);
        for nack in nacks {
            out.extend_from_slice(&nack.frame.to_le_bytes());
            let idx = &nack.indexes[..nack.indexes.len().min(MAX_NACK_INDEXES)];
            out.push(idx.len() as u8);
            for i in idx {
                out.extend_from_slice(&i.to_le_bytes());
            }
        }
        out
    }

    /// Parses a payload.
    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut r = Reader::new(bytes);
        let acked_frame = r.u32()?;
        let decode_us = r.u32()?;
        let need_recovery = match r.u8()? {
            0 => false,
            1 => true,
            _ => return Err(DecodeError::Invalid("bool")),
        };
        let n_arrivals = r.u16()? as usize;
        let mut arrivals = Vec::with_capacity(n_arrivals.min(1024));
        for _ in 0..n_arrivals {
            arrivals.push(Arrival { transport_seq: r.u16()?, arrival_us: r.u32()? });
        }
        let n_nacks = r.u8()? as usize;
        let mut nacks = Vec::with_capacity(n_nacks);
        for _ in 0..n_nacks {
            let frame = r.u32()?;
            let n = r.u8()? as usize;
            let mut indexes = Vec::with_capacity(n);
            for _ in 0..n {
                indexes.push(r.u16()?);
            }
            nacks.push(Nack { frame, indexes });
        }
        if !r.is_empty() {
            return Err(DecodeError::Invalid("trailing bytes"));
        }
        Ok(Self { acked_frame, decode_us, need_recovery, arrivals, nacks })
    }
}
