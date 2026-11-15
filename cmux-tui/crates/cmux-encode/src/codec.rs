//! The codec seam: one encoder trait, one decoder trait and one framing per
//! codec, so a source or a bench picks H.264, VP9 or AV1 by value instead of
//! by code fork. cmux.rd/1 carries an access unit as opaque bytes (the
//! packetizer shards and protects it the same way for every codec); what
//! differs per codec is the bitstream framing the encoder emits, which
//! [`Codec::is_keyframe`] reads, and the name `stream_open` announces.
//!
//! Framing per codec:
//! - H.264: Annex-B (start codes, then NAL units); an IDR slice is a keyframe.
//! - VP9: one frame or superframe as libvpx emits it (the VP8/VP9 RTP payload
//!   minus its descriptor); a keyframe has frame_type 0 in the first frame's
//!   uncompressed header.
//! - AV1: one temporal unit in the low-overhead bitstream format (AV1 spec
//!   section 5, `obu_has_size_field` set); a keyframe carries a sequence
//!   header and a frame header with frame_type KEY_FRAME.

use crate::{I420, Res};

/// A codec cmux.rd can carry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Codec {
    H264,
    Vp9,
    Av1,
}

impl Codec {
    pub const ALL: [Codec; 3] = [Codec::H264, Codec::Vp9, Codec::Av1];

    /// The name `stream_open` and the flags use (`h264`, `vp9`, `av1`).
    pub fn wire_name(self) -> &'static str {
        match self {
            Codec::H264 => "h264",
            Codec::Vp9 => "vp9",
            Codec::Av1 => "av1",
        }
    }

    pub fn parse(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|c| c.wire_name() == name)
    }

    /// True when `au`, one access unit in this codec's framing, decodes on
    /// its own (an H.264 IDR, a VP9 or AV1 key frame).
    pub fn is_keyframe(self, au: &[u8]) -> bool {
        match self {
            Codec::H264 => h264_is_idr(au),
            Codec::Vp9 => vp9_is_keyframe(au),
            Codec::Av1 => av1_is_keyframe(au),
        }
    }
}

/// One in-process low-latency video encoder producing access units in its
/// codec's framing (module docs).
pub trait VideoEncoder: Send {
    /// Encodes one picture into `out` (empty when the encoder skipped the frame).
    /// `pts` is the capture time in microseconds. Returns true for a keyframe.
    fn encode(&mut self, pic: &I420, force_idr: bool, pts: i64, out: &mut Vec<u8>) -> Res<bool>;
    /// Retargets the bitrate (congestion control); small changes may be ignored.
    fn set_bitrate(&mut self, kbps: u32);
    fn kbps(&self) -> u32;
    fn name(&self) -> String;
    /// The codec of the access units [`VideoEncoder::encode`] emits.
    fn codec(&self) -> Codec {
        Codec::H264
    }
    /// The capture time (`pts`) of the picture the last [`VideoEncoder::encode`]
    /// returned, when the encoder holds pictures back (lookahead); `None` means
    /// the picture just given.
    fn output_pts(&self) -> Option<i64> {
        None
    }
}

/// One video decoder for access units in its codec's framing.
pub trait VideoDecoder {
    /// Decodes one access unit. Returns true and fills `out` (resized to the
    /// stream's size) when a picture came out; false when the decoder holds
    /// it or the unit carried no picture.
    fn decode(&mut self, au: &[u8], out: &mut I420) -> Res<bool>;
    fn codec(&self) -> Codec;
    fn name(&self) -> String;
}

/// Annex-B NAL units of `au` (start codes 00 00 01 or 00 00 00 01).
pub fn annexb_nals(au: &[u8]) -> impl Iterator<Item = &[u8]> {
    // Payload starts: the byte after each 00 00 01 (start codes never overlap).
    let mut starts = Vec::new();
    let mut skip_to = 0;
    for (i, w) in au.windows(3).enumerate() {
        if i >= skip_to && w == [0, 0, 1] {
            starts.push(i + 3);
            skip_to = i + 3;
        }
    }
    let ends: Vec<usize> = starts
        .iter()
        .skip(1)
        .map(|&s| {
            // The next start code begins 3 bytes before its payload, 4 with a leading zero.
            let e = s.saturating_sub(3);
            if e > 0 && au.get(e - 1) == Some(&0) { e - 1 } else { e }
        })
        .chain(std::iter::once(au.len()))
        .collect();
    starts.into_iter().zip(ends).filter_map(move |(s, e)| au.get(s..e.max(s)))
}

fn h264_is_idr(au: &[u8]) -> bool {
    annexb_nals(au).any(|nal| nal.first().is_some_and(|b| b & 0x1f == 5))
}

fn vp9_is_keyframe(au: &[u8]) -> bool {
    // Uncompressed header: frame_marker(2) = 2, profile_low_bit, profile_high_bit,
    // [reserved_zero for profile 3], show_existing_frame, frame_type (0 = key).
    let Some(&b) = au.first() else { return false };
    if b >> 6 != 2 {
        return false;
    }
    let profile = ((b >> 5) & 1) | (((b >> 4) & 1) << 1);
    let mut bit = 4;
    if profile == 3 {
        bit -= 1;
    }
    let show_existing = (b >> (bit - 1)) & 1;
    if show_existing == 1 {
        return false;
    }
    (b >> (bit - 2)) & 1 == 0
}

/// Reads one LEB128 value from `data` at `*pos`.
fn leb128(data: &[u8], pos: &mut usize) -> Option<u64> {
    let mut value = 0u64;
    for i in 0..8 {
        let byte = *data.get(*pos)?;
        *pos += 1;
        value |= u64::from(byte & 0x7f) << (i * 7);
        if byte & 0x80 == 0 {
            return Some(value);
        }
    }
    None
}

/// AV1 OBUs of a low-overhead temporal unit: (obu_type, payload).
pub fn av1_obus(au: &[u8]) -> impl Iterator<Item = (u8, &[u8])> {
    let mut pos = 0;
    std::iter::from_fn(move || {
        let header = *au.get(pos)?;
        let obu_type = (header >> 3) & 0x0f;
        let has_extension = header & 0x04 != 0;
        let has_size = header & 0x02 != 0;
        pos += 1 + usize::from(has_extension);
        let size =
            if has_size { leb128(au, &mut pos)? as usize } else { au.len().checked_sub(pos)? };
        let payload = au.get(pos..pos.checked_add(size)?)?;
        pos += size;
        Some((obu_type, payload))
    })
}

const OBU_SEQUENCE_HEADER: u8 = 1;
const OBU_FRAME_HEADER: u8 = 3;
const OBU_FRAME: u8 = 6;

fn av1_is_keyframe(au: &[u8]) -> bool {
    // A key frame's temporal unit starts with a sequence header, and its frame
    // header begins show_existing_frame = 0, frame_type = KEY_FRAME (0). Encoders
    // that emit reduced_still_picture_header streams are not used here.
    let mut sequence_header = false;
    for (obu_type, payload) in av1_obus(au) {
        match obu_type {
            OBU_SEQUENCE_HEADER => sequence_header = true,
            OBU_FRAME_HEADER | OBU_FRAME => {
                let Some(&b) = payload.first() else { return false };
                let show_existing = b >> 7;
                let frame_type = (b >> 5) & 0x03;
                return sequence_header && show_existing == 0 && frame_type == 0;
            }
            _ => {}
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn h264_idr_and_p() {
        let idr = [0, 0, 0, 1, 0x67, 1, 2, 0, 0, 1, 0x68, 3, 0, 0, 0, 1, 0x65, 0x88];
        let p = [0, 0, 0, 1, 0x41, 0x9a, 0x22];
        assert!(Codec::H264.is_keyframe(&idr));
        assert!(!Codec::H264.is_keyframe(&p));
        let nals: Vec<&[u8]> = annexb_nals(&idr).collect();
        assert_eq!(nals, vec![&[0x67, 1, 2][..], &[0x68, 3][..], &[0x65, 0x88][..]]);
    }

    #[test]
    fn vp9_frame_type() {
        // frame_marker 10, profile 0, show_existing 0, frame_type 0 (key), show_frame 1.
        assert!(Codec::Vp9.is_keyframe(&[0b1000_0010]));
        // frame_type 1 (inter).
        assert!(!Codec::Vp9.is_keyframe(&[0b1000_0110]));
        // Not a VP9 frame marker.
        assert!(!Codec::Vp9.is_keyframe(&[0b0100_0010]));
    }

    #[test]
    fn av1_key_and_inter() {
        // Temporal delimiter, sequence header (2 bytes), frame OBU whose header byte has
        // show_existing_frame 0 and frame_type 0.
        let key = [0x12, 0x00, 0x0a, 0x02, 0xaa, 0xbb, 0x32, 0x02, 0x10, 0x00];
        // Temporal delimiter, frame OBU with frame_type 1 (inter).
        let inter = [0x12, 0x00, 0x32, 0x02, 0x30, 0x00];
        assert!(Codec::Av1.is_keyframe(&key));
        assert!(!Codec::Av1.is_keyframe(&inter));
        assert_eq!(av1_obus(&key).map(|(t, _)| t).collect::<Vec<_>>(), vec![2, 1, 6]);
    }

    #[test]
    fn names_round_trip() {
        for c in Codec::ALL {
            assert_eq!(Codec::parse(c.wire_name()), Some(c));
        }
    }
}
