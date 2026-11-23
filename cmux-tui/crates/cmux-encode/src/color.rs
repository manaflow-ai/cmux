//! The colour of a stream, end to end: what [`crate::bgrx_rect_to_i420`] writes, how every
//! encoder tags it in the H.264 VUI, and how a viewer reads the tag back from the SPS and
//! converts the decoded picture to RGB with the same matrix and range.
//!
//! Captured screens are sRGB. Hosts convert them with the BT.709 matrix in video range (what
//! ScreenCaptureKit hands the Mac host and what decoders assume for an untagged HD stream) and
//! tag primaries BT.709, transfer IEC 61966-2-1 (sRGB) and matrix BT.709, so a colour-managed
//! viewer neither shifts hue nor applies a camera gamma to screen pixels.

/// The VUI colour fields of an SPS (H.264 E.2.1; ITU-T H.273 code points). A stream without
/// `video_signal_type` reads as video range with every code point 2 (unspecified).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Vui {
    pub primaries: u8,
    pub transfer: u8,
    pub matrix: u8,
    pub full_range: bool,
}

/// H.273 code points the hosts use.
pub const PRIMARIES_BT709: u8 = 1;
pub const UNSPECIFIED: u8 = 2;
pub const TRANSFER_SRGB: u8 = 13;
pub const MATRIX_BT709: u8 = 1;
pub const MATRIX_BT470BG: u8 = 5;
pub const MATRIX_SMPTE170M: u8 = 6;

/// What [`crate::bgrx_rect_to_i420`] produces from a captured sRGB screen, and what every
/// encoder of those pictures writes into its SPS.
pub const SCREEN: Vui = Vui {
    primaries: PRIMARIES_BT709,
    transfer: TRANSFER_SRGB,
    matrix: MATRIX_BT709,
    full_range: false,
};

/// A stream with no colour description.
pub const UNTAGGED: Vui =
    Vui { primaries: UNSPECIFIED, transfer: UNSPECIFIED, matrix: UNSPECIFIED, full_range: false };

/// A YCbCr to RGB matrix.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Matrix {
    Bt601,
    Bt709,
}

/// How a viewer turns a decoded picture back into RGB.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Yuv {
    pub matrix: Matrix,
    pub full_range: bool,
}

impl Yuv {
    /// What the hosts send ([`SCREEN`]).
    pub const SCREEN: Yuv = Yuv { matrix: Matrix::Bt709, full_range: false };
}

impl Default for Yuv {
    fn default() -> Self {
        Self::SCREEN
    }
}

impl Vui {
    /// The conversion this tag asks for. An unspecified matrix is BT.601: every cmux host that
    /// sent untagged streams (OpenH264, VAAPI and Media Foundation before they tagged) converted
    /// with BT.601; the Mac host has always tagged BT.709.
    pub fn yuv(&self) -> Yuv {
        let matrix = match self.matrix {
            MATRIX_BT709 => Matrix::Bt709,
            _ => Matrix::Bt601,
        };
        Yuv { matrix, full_range: self.full_range }
    }
}

/// The colour fields of the first SPS in an Annex-B access unit, or `None` when it has no SPS
/// (or one this parser cannot read).
pub fn sps_vui(au: &[u8]) -> Option<Vui> {
    crate::annexb_nals(au).find(|n| n.first().is_some_and(|b| b & 0x1f == 7)).and_then(parse_sps)
}

/// Parses an SPS NAL unit (header byte included) as far as its VUI colour fields.
pub fn parse_sps(nal: &[u8]) -> Option<Vui> {
    let rbsp = unescape(nal.get(1..)?);
    let mut r = Bits { data: &rbsp, pos: 0 };
    let profile = r.u(8)?;
    r.u(16)?; // constraint flags, level_idc
    r.ue()?; // seq_parameter_set_id
    if matches!(profile, 100 | 110 | 122 | 244 | 44 | 83 | 86 | 118 | 128 | 138 | 139 | 134 | 135) {
        if r.ue()? == 3 {
            r.u(1)?; // separate_colour_plane_flag
        }
        r.ue()?;
        r.ue()?;
        r.u(1)?;
        if r.u(1)? == 1 {
            for i in 0..8 {
                if r.u(1)? == 1 {
                    let size = if i < 6 { 16 } else { 64 };
                    let (mut last, mut next) = (8i64, 8i64);
                    for _ in 0..size {
                        if next != 0 {
                            next = (last + r.se()? + 256) % 256;
                        }
                        last = if next == 0 { last } else { next };
                    }
                }
            }
        }
    }
    r.ue()?; // log2_max_frame_num_minus4
    match r.ue()? {
        0 => {
            r.ue()?;
        }
        1 => {
            r.u(1)?;
            r.se()?;
            r.se()?;
            for _ in 0..r.ue()? {
                r.se()?;
            }
        }
        _ => {}
    }
    r.ue()?; // max_num_ref_frames
    r.u(1)?; // gaps_in_frame_num_value_allowed_flag
    r.ue()?;
    r.ue()?;
    if r.u(1)? == 0 {
        r.u(1)?; // mb_adaptive_frame_field_flag
    }
    r.u(1)?; // direct_8x8_inference_flag
    if r.u(1)? == 1 {
        for _ in 0..4 {
            r.ue()?;
        }
    }
    if r.u(1)? == 0 {
        return Some(UNTAGGED);
    }
    if r.u(1)? == 1 && r.u(8)? == 255 {
        r.u(32)?; // sar_width, sar_height
    }
    if r.u(1)? == 1 {
        r.u(1)?; // overscan_appropriate_flag
    }
    if r.u(1)? == 0 {
        return Some(UNTAGGED);
    }
    r.u(3)?; // video_format
    let full_range = r.u(1)? == 1;
    if r.u(1)? == 0 {
        return Some(Vui { full_range, ..UNTAGGED });
    }
    let (primaries, transfer, matrix) = (r.u(8)? as u8, r.u(8)? as u8, r.u(8)? as u8);
    Some(Vui { primaries, transfer, matrix, full_range })
}

/// Drops the emulation-prevention bytes (00 00 03 -> 00 00).
fn unescape(data: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(data.len());
    let mut zeros = 0;
    for &b in data {
        if zeros >= 2 && b == 3 {
            zeros = 0;
            continue;
        }
        zeros = if b == 0 { zeros + 1 } else { 0 };
        out.push(b);
    }
    out
}

struct Bits<'a> {
    data: &'a [u8],
    pos: usize,
}

impl Bits<'_> {
    fn u(&mut self, n: u32) -> Option<u32> {
        let mut v = 0u32;
        for _ in 0..n {
            let byte = *self.data.get(self.pos / 8)?;
            v = (v << 1) | u32::from((byte >> (7 - self.pos % 8)) & 1);
            self.pos += 1;
        }
        Some(v)
    }

    fn ue(&mut self) -> Option<u32> {
        let mut zeros = 0;
        while self.u(1)? == 0 {
            zeros += 1;
            if zeros > 31 {
                return None;
            }
        }
        Some((1u32 << zeros) - 1 + self.u(zeros)?)
    }

    fn se(&mut self) -> Option<i64> {
        let k = i64::from(self.ue()?);
        Some(if k % 2 == 1 { (k + 1) / 2 } else { -(k / 2) })
    }
}

/// 16-bit fixed point coefficients: luma scale, Cr to R, Cb to G, Cr to G, Cb to B.
const fn coefficients(yuv: Yuv) -> (i32, i32, i32, i32, i32) {
    match (yuv.matrix, yuv.full_range) {
        (Matrix::Bt601, false) => (76309, 104597, 25675, 53279, 132201),
        (Matrix::Bt601, true) => (65536, 91881, 22553, 46802, 116130),
        (Matrix::Bt709, false) => (76309, 117489, 13975, 34925, 138438),
        (Matrix::Bt709, true) => (65536, 103206, 12276, 30679, 121609),
    }
}

/// Planar 4:2:0 to BGRX with `yuv`'s matrix and range (integer math, rounded), `w` x `h`
/// pixels; `strides` are the Y, U and V row strides; `out` holds `w * h * 4` bytes.
#[allow(clippy::too_many_arguments)]
pub fn i420_to_bgrx(
    y: &[u8],
    u: &[u8],
    v: &[u8],
    strides: (usize, usize, usize),
    w: usize,
    h: usize,
    yuv: Yuv,
    out: &mut [u8],
) {
    let (ky, rv, gu, gv, bu) = coefficients(yuv);
    let y0 = if yuv.full_range { 0 } else { 16 };
    // A plane shorter than `w` x `h` says stops the conversion there (no panic).
    for (row, o) in out.chunks_exact_mut(w * 4).take(h).enumerate() {
        let (Some(yr), Some(ur), Some(vr)) = (
            y.get(row * strides.0..).and_then(|r| r.get(..w)),
            u.get((row / 2) * strides.1..),
            v.get((row / 2) * strides.2..),
        ) else {
            return;
        };
        for (col, (px, &luma)) in o.chunks_exact_mut(4).zip(yr).enumerate() {
            let (Some(&cb), Some(&cr)) = (ur.get(col / 2), vr.get(col / 2)) else {
                return;
            };
            let c = (i32::from(luma) - y0) * ky + 32768;
            let d = i32::from(cb) - 128;
            let e = i32::from(cr) - 128;
            px.copy_from_slice(&[code(c + bu * d), code(c - gu * d - gv * e), code(c + rv * e), 0]);
        }
    }
}

/// A 16.16 fixed-point value as an 8-bit code, clamped.
fn code(v: i32) -> u8 {
    u8::try_from((v >> 16).clamp(0, 255)).unwrap_or(u8::MAX)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{I420, bgrx_rect_to_i420};

    #[derive(Default)]
    struct W(Vec<bool>);
    impl W {
        fn put(&mut self, v: u32, n: u32) {
            (0..n).rev().for_each(|i| self.0.push((v >> i) & 1 == 1));
        }
        fn ue(&mut self, v: u32) {
            let bits = 32 - (v + 1).leading_zeros();
            self.put(0, bits - 1);
            self.put(v + 1, bits);
        }
        fn nal(&self) -> Vec<u8> {
            let mut bits = self.0.clone();
            bits.push(true);
            while !bits.len().is_multiple_of(8) {
                bits.push(false);
            }
            let mut out = vec![0x67];
            out.extend(bits.chunks(8).map(|c| c.iter().fold(0u8, |a, &b| (a << 1) | u8::from(b))));
            out
        }
    }

    fn sps(high: bool, vui: Option<Option<Vui>>) -> Vec<u8> {
        let mut w = W::default();
        w.put(if high { 100 } else { 66 }, 8);
        w.put(0xc0, 8);
        w.put(31, 8);
        w.ue(0);
        if high {
            w.ue(1);
            w.ue(0);
            w.ue(0);
            w.put(0, 1);
            w.put(0, 1);
        }
        w.ue(0);
        w.ue(2);
        w.ue(1);
        w.put(0, 1);
        w.ue(79);
        w.ue(44);
        w.put(1, 1);
        w.put(1, 1);
        w.put(0, 1);
        let Some(signal) = vui else {
            w.put(0, 1);
            return w.nal();
        };
        w.put(1, 1);
        w.put(0, 1);
        w.put(0, 1);
        match signal {
            None => w.put(0, 1),
            Some(c) => {
                w.put(1, 1);
                w.put(5, 3);
                w.put(u32::from(c.full_range), 1);
                w.put(1, 1);
                w.put(c.primaries.into(), 8);
                w.put(c.transfer.into(), 8);
                w.put(c.matrix.into(), 8);
            }
        }
        w.put(0, 6);
        w.nal()
    }

    #[test]
    fn the_sps_colour_fields_read_back() {
        for high in [false, true] {
            assert_eq!(parse_sps(&sps(high, None)), Some(UNTAGGED));
            assert_eq!(parse_sps(&sps(high, Some(None))), Some(UNTAGGED));
            assert_eq!(parse_sps(&sps(high, Some(Some(SCREEN)))), Some(SCREEN));
            let full = Vui { full_range: true, matrix: MATRIX_SMPTE170M, ..SCREEN };
            assert_eq!(parse_sps(&sps(high, Some(Some(full)))), Some(full));
        }
        let mut au = vec![0, 0, 0, 1];
        au.extend(sps(false, Some(Some(SCREEN))));
        au.extend([0, 0, 0, 1, 0x68, 0xce, 0x3c, 0x80]);
        assert_eq!(sps_vui(&au), Some(SCREEN));
        assert_eq!(sps_vui(&[0, 0, 0, 1, 0x65, 0x88]), None);
    }

    #[test]
    fn untagged_means_bt601_and_bt709_is_honored() {
        assert_eq!(UNTAGGED.yuv(), Yuv { matrix: Matrix::Bt601, full_range: false });
        assert_eq!(SCREEN.yuv(), Yuv::SCREEN);
    }

    /// The host's conversion and the viewer's are inverses: a flat patch of every primary,
    /// secondary and grey comes back within 2 of the source on each channel.
    #[test]
    fn the_host_conversion_round_trips_through_the_viewer_conversion() {
        let colors: [[u8; 3]; 9] = [
            [0, 0, 0],
            [16, 16, 16],
            [128, 128, 128],
            [255, 255, 255],
            [255, 0, 0],
            [0, 255, 0],
            [0, 0, 255],
            [0, 128, 128],
            [255, 255, 0],
        ];
        for rgb in colors {
            let src: Vec<u8> = (0..16).flat_map(|_| [rgb[2], rgb[1], rgb[0], 0]).collect();
            let mut pic = I420::new(4, 4);
            bgrx_rect_to_i420(&src, &mut pic, 0, 0, 4, 4, 1);
            let mut out = vec![0; 64];
            i420_to_bgrx(&pic.y, &pic.u, &pic.v, (4, 2, 2), 4, 4, SCREEN.yuv(), &mut out);
            for (a, b) in out.iter().zip(&src) {
                assert!(a.abs_diff(*b) <= 2, "{rgb:?}: {:?}", &out[..4]);
            }
        }
    }
}
