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
