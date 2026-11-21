//! The little H.264 a recording needs (`record.rs`): Annex-B NAL units, and
//! the fields of a sequence parameter set an MP4 sample entry repeats
//! (profile, level, chroma format, bit depths, cropped picture size).

/// NAL unit types the recorder looks at.
pub const NAL_IDR: u8 = 5;
pub const NAL_SPS: u8 = 7;
pub const NAL_PPS: u8 = 8;
pub const NAL_AUD: u8 = 9;

/// The NAL units of an Annex-B access unit (start codes and trailing zero
/// bytes removed; empty units skipped).
pub fn nal_units(au: &[u8]) -> Vec<&[u8]> {
    let mut starts = Vec::new();
    let mut i = 0;
    while i + 3 <= au.len() {
        if au[i] == 0 && au[i + 1] == 0 && au[i + 2] == 1 {
            starts.push(i + 3);
            i += 3;
        } else {
            i += 1;
        }
    }
    let mut out = Vec::with_capacity(starts.len());
    for (n, &start) in starts.iter().enumerate() {
        // The next unit's 00 00 01 begins 3 bytes before its payload.
        let mut end = starts.get(n + 1).map_or(au.len(), |next| next - 3);
        while end > start && au[end - 1] == 0 {
            end -= 1;
        }
        if end > start {
            out.push(&au[start..end]);
        }
    }
    out
}

/// The type of a NAL unit (its low five bits).
pub fn nal_type(nal: &[u8]) -> u8 {
    nal.first().map_or(0, |b| b & 0x1f)
}

/// What an MP4 `avc1`/`avcC` entry repeats from a sequence parameter set.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct SpsInfo {
    pub profile_idc: u8,
    pub constraint_flags: u8,
    pub level_idc: u8,
    pub chroma_format_idc: u32,
    pub bit_depth_luma: u32,
    pub bit_depth_chroma: u32,
    pub width: u32,
    pub height: u32,
}

impl SpsInfo {
    /// The profiles whose SPS carries chroma format and bit depths (and
    /// whose `avcC` must repeat them).
    pub fn high_profile(profile_idc: u8) -> bool {
        matches!(
            profile_idc,
            100 | 110 | 122 | 244 | 44 | 83 | 86 | 118 | 128 | 138 | 139 | 134 | 135
        )
    }
}

/// Reads exp-Golomb and fixed-width fields from an RBSP.
struct Bits {
    data: Vec<u8>,
    pos: usize,
}

impl Bits {
    /// Bits of a NAL payload with emulation prevention bytes (00 00 03) removed.
    fn rbsp(payload: &[u8]) -> Self {
        let mut data = Vec::with_capacity(payload.len());
        let mut zeros = 0;
        for &b in payload {
            if zeros >= 2 && b == 3 {
                zeros = 0;
                continue;
            }
            zeros = if b == 0 { zeros + 1 } else { 0 };
            data.push(b);
        }
        Self { data, pos: 0 }
    }

    fn bit(&mut self) -> Option<u32> {
        let byte = *self.data.get(self.pos / 8)?;
        let bit = (byte >> (7 - self.pos % 8)) & 1;
        self.pos += 1;
        Some(u32::from(bit))
    }

    fn bits(&mut self, n: u32) -> Option<u32> {
        (0..n).try_fold(0u32, |acc, _| Some((acc << 1) | self.bit()?))
    }

    fn ue(&mut self) -> Option<u32> {
        let mut zeros = 0;
        while self.bit()? == 0 {
            zeros += 1;
            if zeros > 31 {
                return None;
            }
        }
        Some(((1u64 << zeros) - 1 + u64::from(self.bits(zeros)?)) as u32)
    }

    fn se(&mut self) -> Option<i64> {
        let k = i64::from(self.ue()?);
        Some(if k % 2 == 1 { (k + 1) / 2 } else { -(k / 2) })
    }

    fn skip_scaling_list(&mut self, size: usize) -> Option<()> {
        let (mut last, mut next) = (8i64, 8i64);
        for _ in 0..size {
            if next != 0 {
                next = (last + self.se()? + 256) % 256;
            }
            if next != 0 {
                last = next;
            }
        }
        Some(())
    }
}

/// The fields of a sequence parameter set NAL unit (header byte included);
/// `None` when it is not an SPS or ends early.
pub fn parse_sps(nal: &[u8]) -> Option<SpsInfo> {
    if nal_type(nal) != NAL_SPS || nal.len() < 4 {
        return None;
    }
    let (profile_idc, constraint_flags, level_idc) = (nal[1], nal[2], nal[3]);
    let mut r = Bits::rbsp(&nal[4..]);
    r.ue()?; // seq_parameter_set_id
    let (mut chroma, mut luma, mut chroma_depth, mut separate) = (1, 8, 8, 0);
    if SpsInfo::high_profile(profile_idc) {
        chroma = r.ue()?;
        if chroma == 3 {
            separate = r.bit()?;
        }
        luma = r.ue()? + 8;
        chroma_depth = r.ue()? + 8;
        r.bit()?; // qpprime_y_zero_transform_bypass_flag
        if r.bit()? == 1 {
            for i in 0..if chroma == 3 { 12 } else { 8 } {
                if r.bit()? == 1 {
                    r.skip_scaling_list(if i < 6 { 16 } else { 64 })?;
                }
            }
        }
    }
    r.ue()?; // log2_max_frame_num_minus4
    match r.ue()? {
        0 => {
            r.ue()?; // log2_max_pic_order_cnt_lsb_minus4
        }
        1 => {
            r.bit()?;
            r.se()?;
            r.se()?;
            for _ in 0..r.ue()? {
                r.se()?;
            }
        }
        _ => {}
    }
    r.ue()?; // max_num_ref_frames
    r.bit()?; // gaps_in_frame_num_value_allowed_flag
    let width_mbs = r.ue()? + 1;
    let height_units = r.ue()? + 1;
    let frame_mbs_only = r.bit()?;
    if frame_mbs_only == 0 {
        r.bit()?; // mb_adaptive_frame_field_flag
    }
    r.bit()?; // direct_8x8_inference_flag
    let (mut left, mut right, mut top, mut bottom) = (0, 0, 0, 0);
    if r.bit()? == 1 {
        (left, right, top, bottom) = (r.ue()?, r.ue()?, r.ue()?, r.ue()?);
    }
    // Crop units (H.264 7.4.2.1.1): ChromaArrayType 0 counts luma samples.
    let array_type = if separate == 1 { 0 } else { chroma };
    let (sub_w, sub_h) = match array_type {
        1 => (2, 2),
        2 => (2, 1),
        _ => (1, 1),
    };
    let unit_x = if array_type == 0 { 1 } else { sub_w };
    let unit_y = (2 - frame_mbs_only) * if array_type == 0 { 1 } else { sub_h };
    let width = (width_mbs * 16).checked_sub(unit_x * (left + right))?;
    let height = ((2 - frame_mbs_only) * height_units * 16).checked_sub(unit_y * (top + bottom))?;
    Some(SpsInfo {
        profile_idc,
        constraint_flags,
        level_idc,
        chroma_format_idc: chroma,
        bit_depth_luma: luma,
        bit_depth_chroma: chroma_depth,
        width,
        height,
    })
}
