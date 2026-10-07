use crate::error::{DecodeError, Reader};

/// Size of the prefix in front of the access unit in a [`FrameBody`].
pub const FRAME_PREFIX_LEN: usize = 16;

/// `ref_frame` value of a frame that references no earlier frame (a keyframe).
pub const REF_NONE: u32 = u32::MAX;

/// One encoded video frame before it is split into shards.
///
/// Layout: `u32 au_len`, `u64 t_capture_us` (host monotonic microseconds),
/// `u32 ref_frame`, then `au_len` bytes of H.264 or HEVC access unit. The
/// shards of a frame carry this body; the last data shard is zero-padded.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FrameBody {
    /// Host monotonic time when the frame's pixels were read back.
    pub t_capture_us: u64,
    /// The frame this frame predicts from, or [`REF_NONE`]. A normal P-frame
    /// names the previous frame; a recovery frame names an acknowledged one.
    pub ref_frame: u32,
    /// The access unit (Annex-B).
    pub access_unit: Vec<u8>,
}

impl FrameBody {
    /// Serializes the body.
    pub fn encode(&self) -> Vec<u8> {
        let mut out = Vec::with_capacity(FRAME_PREFIX_LEN + self.access_unit.len());
        let len = u32::try_from(self.access_unit.len()).unwrap_or(u32::MAX);
        out.extend_from_slice(&len.to_le_bytes());
        out.extend_from_slice(&self.t_capture_us.to_le_bytes());
        out.extend_from_slice(&self.ref_frame.to_le_bytes());
        out.extend_from_slice(&self.access_unit);
        out
    }

    /// Parses a body; trailing zero padding after the access unit is ignored.
    pub fn decode(bytes: &[u8]) -> Result<Self, DecodeError> {
        let mut r = Reader::new(bytes);
        let len = r.u32()? as usize;
        let t_capture_us = r.u64()?;
        let ref_frame = r.u32()?;
        let access_unit = r.take(len)?.to_vec();
        Ok(Self { t_capture_us, ref_frame, access_unit })
    }
}
