use crate::error::{DecodeError, Reader};

/// Size of the prefix in front of the access unit in a [`FrameBody`].
pub const FRAME_PREFIX_LEN: usize = 16;
pub const FRAME_LTR_PREFIX_LEN: usize = 24;

/// `ref_frame` value of a frame that references no earlier frame (a keyframe).
pub const REF_NONE: u32 = u32::MAX;

/// The bit of the `au_len` field that says an LTR token follows `ref_frame`. An access unit is
/// never 2 GiB, so a tokenless frame never sets it and keeps the version-1 layout byte for byte.
const TOKEN_FLAG: u32 = 1 << 31;

/// One encoded video frame before it is split into shards.
///
/// Layout: `u32 au_len`, `u64 t_capture_us` (host monotonic microseconds),
/// `u32 ref_frame`, a `u64` LTR token only when `au_len`'s top bit is set, then
/// `au_len` (top bit cleared) bytes of H.264 or HEVC access unit. The
/// shards of a frame carry this body; the last data shard is zero-padded,
/// unless it is the frame's only shard and the frame has no parity.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FrameBody {
    /// Host monotonic time when the frame's pixels were read back.
    pub t_capture_us: u64,
    /// The frame this frame predicts from, or [`REF_NONE`]. A normal P-frame
    /// names the previous frame; a recovery frame names an acknowledged one.
    pub ref_frame: u32,
    /// VideoToolbox's long-term-reference acknowledgement token, when present.
    pub ltr_token: Option<u64>,
    /// The access unit (Annex-B).
    pub access_unit: Vec<u8>,
}

impl FrameBody {
    /// The length of [`Self::encode`]'s output, without serializing.
    pub fn encoded_len(&self) -> usize {
        let prefix = if self.ltr_token.is_some() { FRAME_LTR_PREFIX_LEN } else { FRAME_PREFIX_LEN };
        prefix + self.access_unit.len()
    }

    /// Serializes the body.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(self.encoded_len());
        let mut len = u32::try_from(self.access_unit.len()).unwrap_or(u32::MAX).min(!TOKEN_FLAG);
        if self.ltr_token.is_some() {
            len |= TOKEN_FLAG;
        }
        out.extend_from_slice(&len.to_le_bytes());
        out.extend_from_slice(&self.t_capture_us.to_le_bytes());
        out.extend_from_slice(&self.ref_frame.to_le_bytes());
        if let Some(token) = self.ltr_token {
            out.extend_from_slice(&token.to_le_bytes());
        }
        out.extend_from_slice(&self.access_unit);
        out
    }

    /// Parses a body; trailing zero padding after the access unit is ignored.
    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut r = Reader::new(bytes);
        let raw_len = r.u32()?;
        let len = (raw_len & !TOKEN_FLAG) as usize;
        let t_capture_us = r.u64()?;
        let ref_frame = r.u32()?;
        let ltr_token = if raw_len & TOKEN_FLAG != 0 { Some(r.u64()?) } else { None };
        let rest = r.rest();
        let access_unit =
            rest.get(..len).ok_or(DecodeError::Truncated { need: len, have: rest.len() })?.to_vec();
        Ok(Self { t_capture_us, ref_frame, ltr_token, access_unit })
    }
}
