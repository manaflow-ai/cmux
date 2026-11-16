//! The QP an H.264 encoder chose, read from its own bitstream: PPS `pic_init_qp_minus26` plus
//! each slice header's `slice_qp_delta`. VideoToolbox reports no QP, so this is how a sweep,
//! a bench or the host's stats learn whether the encoder sits at its quality floor or holds
//! back while the target goes unused. Feed it every access unit in order (Annex-B, as every
//! encoder behind `VideoEncoder` emits); it keeps the SPS and PPS it has seen by id.

use std::collections::HashMap;

/// The QPs of one access unit's slices, in order. `None` is a slice whose header uses
/// something this reader does not follow (weighted prediction tables, an unseen PPS or SPS).
pub type SliceQps = Vec<Option<i32>>;

/// Reads slice QPs from a stream of Annex-B access units.
#[derive(Default)]
pub struct QpReader {
    sps: HashMap<u64, Sps>,
    pps: HashMap<u64, Pps>,
}

#[derive(Default, Clone, Copy)]
struct Sps {
    sep_colour: bool,
    log2_frame_num: usize,
    poc_type: u64,
    log2_poc_lsb: usize,
    poc_always_zero: bool,
    frame_mbs_only: bool,
}

#[derive(Default, Clone, Copy)]
struct Pps {
    sps_id: u64,
    bottom_present: bool,
    weighted_pred: bool,
    weighted_bipred: u64,
    init_qp: i64,
    redundant: bool,
    cabac: bool,
}

impl QpReader {
    pub fn new() -> Self {
        Self::default()
    }

    /// The slice QPs of one Annex-B access unit (start codes of 3 or 4 bytes). Parameter sets
    /// in it are remembered for this and later units.
    pub fn access_unit(&mut self, au: &[u8]) -> SliceQps {
        let mut out = Vec::new();
        for nal in crate::annexb_nals(au) {
            if let Some(qp) = self.nal(nal) {
                out.push(qp);
            }
        }
        out
    }

    /// One NAL unit without its start code: `Some(qp)` for a slice, `None` for anything else.
    pub fn nal(&mut self, nal: &[u8]) -> Option<Option<i32>> {
        let header = *nal.first()?;
        match header & 0x1f {
            7 => {
                if let Some((id, sps)) = parse_sps(nal) {
                    self.sps.insert(id, sps);
                }
                None
            }
            8 => {
                if let Some((id, pps)) = parse_pps(nal) {
                    self.pps.insert(id, pps);
                }
                None
            }
            1 | 5 => Some(self.slice_qp(nal)),
            _ => None,
        }
    }

    fn slice_qp(&self, nal: &[u8]) -> Option<i32> {
        let ref_idc = (nal[0] >> 5) & 3;
        let idr = nal[0] & 0x1f == 5;
        let mut r = Bits::new(&nal[1..]);
        r.ue()?;
        let t = r.ue()? % 5;
        let pps = *self.pps.get(&r.ue()?)?;
        let sps = *self.sps.get(&pps.sps_id)?;
        if sps.sep_colour {
            r.u(2)?;
        }
        r.u(sps.log2_frame_num)?;
        let mut field = false;
        if !sps.frame_mbs_only {
            field = r.u(1)? == 1;
            if field {
                r.u(1)?;
            }
        }
        if idr {
            r.ue()?;
        }
        if sps.poc_type == 0 {
            r.u(sps.log2_poc_lsb)?;
            if pps.bottom_present && !field {
                r.se()?;
            }
        } else if sps.poc_type == 1 && !sps.poc_always_zero {
            r.se()?;
            if pps.bottom_present && !field {
                r.se()?;
            }
        }
        if pps.redundant {
            r.ue()?;
        }
        let (is_p, is_b, is_i) = (t == 0 || t == 3, t == 1, t == 2 || t == 4);
        if is_b {
            r.u(1)?;
        }
        if (is_p || is_b) && r.u(1)? == 1 {
            r.ue()?;
            if is_b {
                r.ue()?;
            }
        }
        if !is_i {
            for _ in 0..if is_b { 2 } else { 1 } {
                if r.u(1)? == 1 {
                    loop {
                        match r.ue()? {
                            3 => break,
                            0..=2 => {
                                r.ue()?;
                            }
                            // Long-term and view modifications: not followed.
                            _ => return None,
                        }
                    }
                }
            }
        }
        if (pps.weighted_pred && is_p) || (pps.weighted_bipred == 1 && is_b) {
            return None;
        }
        if ref_idc != 0 {
            if idr {
                r.u(2)?;
            } else if r.u(1)? == 1 {
                loop {
                    match r.ue()? {
                        0 => break,
                        1 | 2 | 6 => {
                            r.ue()?;
                        }
                        3 => {
                            r.ue()?;
                            r.ue()?;
                        }
                        4 => {
                            r.ue()?;
                        }
                        5 => {}
                        _ => return None,
                    }
                }
            }
        }
        if pps.cabac && !is_i {
            r.ue()?;
        }
        let qp = pps.init_qp + r.se()?;
        (0..=51).contains(&qp).then_some(qp as i32)
    }
}

const HIGH_PROFILES: [u64; 13] = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135];

fn parse_sps(nal: &[u8]) -> Option<(u64, Sps)> {
    let mut r = Bits::new(nal.get(1..)?);
    let profile = r.u(8)?;
    r.u(16)?;
    let id = r.ue()?;
    let mut s = Sps::default();
    if HIGH_PROFILES.contains(&profile) {
        let chroma = r.ue()?;
        if chroma == 3 {
            s.sep_colour = r.u(1)? == 1;
        }
        r.ue()?;
        r.ue()?;
        r.u(1)?;
        if r.u(1)? == 1 {
            for i in 0..if chroma == 3 { 12 } else { 8 } {
                if r.u(1)? == 1 {
                    r.scaling_list(if i < 6 { 16 } else { 64 })?;
                }
            }
        }
    }
    s.log2_frame_num = r.ue()? as usize + 4;
    s.poc_type = r.ue()?;
    if s.poc_type == 0 {
        s.log2_poc_lsb = r.ue()? as usize + 4;
    } else if s.poc_type == 1 {
        s.poc_always_zero = r.u(1)? == 1;
        r.se()?;
        r.se()?;
        for _ in 0..r.ue()? {
            r.se()?;
        }
    }
    r.ue()?;
    r.u(1)?;
    r.ue()?;
    r.ue()?;
    s.frame_mbs_only = r.u(1)? == 1;
    Some((id, s))
}

fn parse_pps(nal: &[u8]) -> Option<(u64, Pps)> {
    let mut r = Bits::new(nal.get(1..)?);
    let id = r.ue()?;
    let sps_id = r.ue()?;
    let cabac = r.u(1)? == 1;
    let bottom_present = r.u(1)? == 1;
    // Slice groups (FMO, Baseline only): not followed.
    if r.ue()? != 0 {
        return None;
    }
    r.ue()?;
    r.ue()?;
    let weighted_pred = r.u(1)? == 1;
    let weighted_bipred = r.u(2)?;
    let init_qp = 26 + r.se()?;
    r.se()?;
    r.se()?;
    r.u(2)?;
    let redundant = r.u(1)? == 1;
    Some((
        id,
        Pps { sps_id, bottom_present, weighted_pred, weighted_bipred, init_qp, redundant, cabac },
    ))
}

/// An RBSP bit reader (emulation-prevention bytes removed).
struct Bits {
    b: Vec<u8>,
    at: usize,
}

impl Bits {
    fn new(nal: &[u8]) -> Self {
        let mut b = Vec::with_capacity(nal.len());
        let mut zeros = 0;
        for &v in nal {
            if zeros >= 2 && v == 3 {
                zeros = 0;
                continue;
            }
            zeros = if v == 0 { zeros + 1 } else { 0 };
            b.push(v);
        }
        Self { b, at: 0 }
    }

    fn u(&mut self, n: usize) -> Option<u64> {
        let mut v = 0u64;
        for _ in 0..n {
            let byte = *self.b.get(self.at / 8)?;
            v = (v << 1) | u64::from((byte >> (7 - self.at % 8)) & 1);
            self.at += 1;
        }
        Some(v)
    }

    fn ue(&mut self) -> Option<u64> {
        let mut zeros = 0;
        while self.u(1)? == 0 {
            zeros += 1;
            if zeros > 31 {
                return None;
            }
        }
        Some((1u64 << zeros) - 1 + self.u(zeros)?)
    }

    fn se(&mut self) -> Option<i64> {
        let k = self.ue()? as i64;
        Some(if k % 2 == 1 { (k + 1) / 2 } else { -(k / 2) })
    }

    fn scaling_list(&mut self, size: usize) -> Option<()> {
        let (mut last, mut next) = (8i64, 8i64);
        for _ in 0..size {
            if next != 0 {
                next = (last + self.se()? + 256) % 256;
            }
            last = if next == 0 { last } else { next };
        }
        Some(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A bit writer for hand-made parameter sets and slice headers.
    #[derive(Default)]
    struct W {
        bits: Vec<bool>,
    }
    impl W {
        fn u(&mut self, n: usize, v: u64) -> &mut Self {
            for i in (0..n).rev() {
                self.bits.push((v >> i) & 1 == 1);
            }
            self
        }
        fn ue(&mut self, v: u64) -> &mut Self {
            let x = v + 1;
            let len = 64 - x.leading_zeros() as usize;
            self.u(len - 1, 0).u(len, x)
        }
        fn se(&mut self, v: i64) -> &mut Self {
            self.ue(if v > 0 { (2 * v - 1) as u64 } else { (-2 * v) as u64 })
        }
        fn nal(&mut self, header: u8) -> Vec<u8> {
            self.bits.push(true);
            while self.bits.len() % 8 != 0 {
                self.bits.push(false);
            }
            let mut out = vec![0, 0, 0, 1, header];
            out.extend(
                self.bits.chunks(8).map(|c| c.iter().fold(0u8, |a, &b| (a << 1) | u8::from(b))),
            );
            out
        }
    }

    /// High-profile SPS (POC type 0) and a CABAC PPS with `init_qp`.
    fn params(init_qp: i64) -> Vec<u8> {
        let mut sps = W::default();
        sps.u(8, 100).u(16, 0).ue(0); // profile, constraints+level, id
        sps.ue(1).ue(0).ue(0).u(1, 0).u(1, 0); // 4:2:0, depths, bypass, no scaling
        sps.ue(0).ue(0).ue(0); // log2_frame_num 4, poc type 0, log2_poc_lsb 4
        sps.ue(1).u(1, 0).ue(119).ue(67).u(1, 1); // refs, gaps, size, frame_mbs_only
        sps.u(1, 1).u(1, 0).u(1, 0); // direct_8x8, no crop, no vui
        let mut pps = W::default();
        pps.ue(0).ue(0).u(1, 1).u(1, 0).ue(0).ue(0).ue(0).u(1, 0).u(2, 0);
        pps.se(init_qp - 26).se(0).se(0).u(1, 1).u(1, 0).u(1, 0);
        let mut au = sps.nal(0x67);
        au.extend(pps.nal(0x68));
        au
    }

    fn idr(delta: i64) -> Vec<u8> {
        let mut s = W::default();
        s.ue(0).ue(7).ue(0).u(4, 0).ue(0).u(4, 0); // first_mb, I, pps, frame_num, idr_id, poc
        s.u(1, 0).u(1, 0); // no_output_of_prior_pics, long_term_reference
        s.se(delta);
        s.nal(0x65)
    }

    fn p_slice(delta: i64) -> Vec<u8> {
        let mut s = W::default();
        s.ue(0).ue(5).ue(0).u(4, 1).u(4, 2); // first_mb, P, pps, frame_num, poc
        s.u(1, 0); // no num_ref_idx override
        s.u(1, 0); // no ref list modification
        s.u(1, 0); // no adaptive ref pic marking
        s.ue(0); // cabac_init_idc
        s.se(delta);
        s.nal(0x41)
    }

    #[test]
    fn reads_init_qp_plus_slice_delta_for_idr_and_p_slices() {
        let mut r = QpReader::new();
        let mut au = params(30);
        au.extend(idr(-8));
        assert_eq!(r.access_unit(&au), vec![Some(22)]);
        assert_eq!(r.access_unit(&p_slice(5)), vec![Some(35)]);
        let mut two = p_slice(0);
        two.extend(p_slice(-4));
        assert_eq!(r.access_unit(&two), vec![Some(30), Some(26)], "every slice of a frame");
    }

    #[test]
    fn a_slice_before_its_parameter_sets_reads_none() {
        let mut r = QpReader::new();
        assert_eq!(r.access_unit(&p_slice(0)), vec![None]);
        assert!(r.access_unit(&params(26)).is_empty(), "parameter sets are not slices");
        assert_eq!(r.access_unit(&p_slice(-26)), vec![Some(0)]);
    }

    #[test]
    fn emulation_prevention_bytes_are_removed() {
        let mut b = Bits::new(&[0, 0, 3, 1, 0x80]);
        assert_eq!(b.u(24), Some(1));
        assert_eq!(b.u(1), Some(1));
        assert_eq!(Bits::new(&[]).ue(), None, "a short header reads None, never panics");
    }

    /// An encoder's own stream: OpenH264 from source, every frame's slices read a QP in range.
    #[cfg(feature = "openh264-source")]
    #[test]
    fn openh264_frames_read_a_qp() {
        use crate::openh264::{OpenH264, OpenH264Api};
        use crate::{EncCfg, H264Encoder, I420};
        let cfg =
            EncCfg { width: 128, height: 64, fps: 30, kbps: 300, threads: 1, screen_content: true };
        let mut enc = OpenH264::new(&cfg, OpenH264Api::from_source()).expect("encoder");
        let mut r = QpReader::new();
        let mut pic = I420::new(128, 64);
        let mut au = Vec::new();
        for i in 0..6u8 {
            pic.y
                .iter_mut()
                .enumerate()
                .for_each(|(n, p)| *p = 16 + ((n as u8) ^ i.wrapping_mul(37)) % 200);
            enc.encode(&pic, i == 0, i64::from(i) * 33_000, &mut au).expect("encode");
            if au.is_empty() {
                continue;
            }
            let qps = r.access_unit(&au);
            assert!(!qps.is_empty(), "frame {i} has slices");
            assert!(
                qps.iter().all(|q| q.is_some_and(|q| (0..=51).contains(&q))),
                "frame {i}: {qps:?}"
            );
        }
    }
}
