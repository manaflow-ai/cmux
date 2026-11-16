use crate::error::{DecodeError, Reader};

/// Most arrivals in one feedback; with the other limits a feedback payload
/// stays under 1,100 bytes, inside every session's `max_datagram`.
pub const MAX_ARRIVALS: usize = 128;
/// Most frames with NACKs in one feedback.
pub const MAX_NACK_FRAMES: usize = 4;
/// Most shard indexes per NACKed frame.
pub const MAX_NACK_INDEXES: usize = 32;
/// Most VideoToolbox LTR tokens one feedback acknowledges.
pub const MAX_LTR_TOKENS: usize = 16;
/// The largest feedback payload: the version-1 layout at its limits (128 arrivals and
/// four NACKs of 32 shards), 1,056 bytes. LTR tokens never push a payload past it:
/// [`Feedback::encode_with_ltr_tokens`] keeps the newest tokens that fit, and a sender
/// leaves room for them with [`arrivals_room_with_ltr_tokens`].
pub const MAX_FEEDBACK_PAYLOAD: usize = 4
    + 4
    + 1
    + 2
    + ARRIVAL_LEN * MAX_ARRIVALS
    + 1
    + MAX_NACK_FRAMES * (4 + 1 + 2 * MAX_NACK_INDEXES);
const ARRIVAL_LEN: usize = 6;

/// Bytes the optional LTR tail takes for `tokens` tokens (a count byte, then eight
/// bytes each); none when there are no tokens.
pub const fn ltr_tail_len(tokens: usize) -> usize {
    if tokens == 0 { 0 } else { 1 + 8 * tokens }
}

/// How many arrivals one feedback carries next to `tokens` LTR tokens and still fits
/// [`MAX_FEEDBACK_PAYLOAD`] with full NACKs. The arrivals left over go in the next feedback.
pub const fn arrivals_room_with_ltr_tokens(tokens: usize) -> usize {
    let tokens = if tokens > MAX_LTR_TOKENS { MAX_LTR_TOKENS } else { tokens };
    MAX_ARRIVALS - ltr_tail_len(tokens).div_ceil(ARRIVAL_LEN)
}

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
        let arrivals = self.arrivals.get(..MAX_ARRIVALS).unwrap_or(&self.arrivals);
        out.extend_from_slice(&(arrivals.len() as u16).to_le_bytes());
        for a in arrivals {
            out.extend_from_slice(&a.transport_seq.to_le_bytes());
            out.extend_from_slice(&a.arrival_us.to_le_bytes());
        }
        let nacks = self.nacks.get(..MAX_NACK_FRAMES).unwrap_or(&self.nacks);
        out.push(nacks.len() as u8);
        for nack in nacks {
            out.extend_from_slice(&nack.frame.to_le_bytes());
            let idx = nack.indexes.get(..MAX_NACK_INDEXES).unwrap_or(&nack.indexes);
            out.push(idx.len() as u8);
            for i in idx {
                out.extend_from_slice(&i.to_le_bytes());
            }
        }
        out
    }

    /// Serializes the payload with the viewer's acknowledged LTR tokens (oldest first) in
    /// an optional tail after the NACKs. Without tokens the bytes are exactly
    /// [`Feedback::encode`]'s. The tail keeps the newest tokens that fit
    /// [`MAX_FEEDBACK_PAYLOAD`], so the payload is never larger than a version-1 one.
    pub fn encode_with_ltr_tokens(&self, tokens: &[u64]) -> Vec<u8> {
        let mut out = self.encode();
        let room = MAX_FEEDBACK_PAYLOAD.saturating_sub(out.len());
        let fit = (0..=tokens.len().min(MAX_LTR_TOKENS))
            .rev()
            .find(|n| ltr_tail_len(*n) <= room)
            .unwrap_or(0);
        let newest = tokens.get(tokens.len() - fit..).unwrap_or_default();
        if !newest.is_empty() {
            out.push(newest.len() as u8);
            for token in newest {
                out.extend_from_slice(&token.to_le_bytes());
            }
        }
        out
    }

    /// Parses a payload, ignoring an LTR tail (see [`Feedback::decode_with_ltr_tokens`]).
    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        Self::decode_with_ltr_tokens(bytes).map(|(feedback, _)| feedback)
    }

    /// Parses a payload and its acknowledged LTR tokens (empty when it has no tail).
    pub fn decode_with_ltr_tokens(bytes: &[u8]) -> Result<(Self, Vec<u64>), DecodeError> {
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
        let mut tokens = Vec::new();
        if !r.is_empty() {
            let n = r.u8()? as usize;
            if n == 0 || n > MAX_LTR_TOKENS {
                return Err(DecodeError::Invalid("ltr token count"));
            }
            tokens.reserve(n);
            for _ in 0..n {
                tokens.push(r.u64()?);
            }
        }
        if !r.is_empty() {
            return Err(DecodeError::Invalid("trailing bytes"));
        }
        Ok((Self { acked_frame, decode_us, need_recovery, arrivals, nacks }, tokens))
    }
}
