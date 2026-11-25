//! Which H.264 streams an OpenH264 viewer can show (cmux#50591).
//!
//! OpenH264 decodes Constrained Baseline (and Main's CABAC). Fed a High-profile stream (a
//! VideoToolbox host's default), it decodes the IDR, then returns wrong pictures for every
//! P-frame with no error: measured Mac to Linux, 39 of 40 keys lost and `decode_errors 0`.
//! [`ProfileGate`] reads each sequence parameter set the stream carries and refuses every
//! frame under one OpenH264 cannot decode, so the viewer counts and reports the error
//! instead of drawing garbage. A host that honors the `h264.baseline` cap never sends one.

use crate::annexb_nals;

/// `profile_idc` values whose streams OpenH264 decodes: Baseline, Main, Extended.
const DECODABLE: [u8; 3] = [66, 77, 88];
/// `constraint_set1_flag`: the stream also obeys Main's constraints (a Constrained Baseline
/// or Main-compatible High stream sets it).
const CONSTRAINT_SET1: u8 = 0x40;

/// The `profile_idc` of every sequence parameter set (NAL type 7) in an Annex-B access unit
/// that OpenH264 cannot decode; `Ok` for a decodable one, `None` when the unit has no SPS.
pub fn sps_verdict(au: &[u8]) -> Option<Result<(), u8>> {
    let mut verdict = None;
    for nal in annexb_nals(au) {
        let (Some(&header), Some(&profile), Some(&flags)) = (nal.first(), nal.get(1), nal.get(2))
        else {
            continue;
        };
        if header & 0x1f != 7 {
            continue;
        }
        // The newest SPS in the unit is the one its slices use.
        verdict = Some(if DECODABLE.contains(&profile) || flags & CONSTRAINT_SET1 != 0 {
            Ok(())
        } else {
            Err(profile)
        });
    }
    verdict
}

/// The profile name for a `profile_idc`, for an error a person reads.
pub fn profile_name(profile_idc: u8) -> &'static str {
    match profile_idc {
        66 => "baseline",
        77 => "main",
        88 => "extended",
        100 => "high",
        110 => "high 10",
        122 => "high 4:2:2",
        244 => "high 4:4:4",
        _ => "unknown",
    }
}

/// Remembers the stream's newest SPS verdict: once an SPS OpenH264 cannot decode arrives,
/// every frame is refused until a decodable SPS replaces it.
#[derive(Debug, Default, Clone)]
pub struct ProfileGate {
    refused: Option<u8>,
}

impl ProfileGate {
    /// `Err` (a sentence naming the profile) when this frame must not be decoded.
    pub fn check(&mut self, au: &[u8]) -> Result<(), String> {
        match sps_verdict(au) {
            Some(Ok(())) => self.refused = None,
            Some(Err(profile)) => self.refused = Some(profile),
            None => {}
        }
        match self.refused {
            None => Ok(()),
            Some(profile) => Err(format!(
                "openh264 cannot decode H.264 {} profile (profile_idc {profile}); the host \
                 must send constrained baseline (viewer cap h264.baseline)",
                profile_name(profile)
            )),
        }
    }

    /// The refused `profile_idc`, while one is in force.
    pub fn refused(&self) -> Option<u8> {
        self.refused
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An SPS NAL (start code, header 0x67, profile, constraint flags, level 3.1, one byte of
    /// the rest), as an encoder writes it.
    fn sps(profile: u8, flags: u8) -> Vec<u8> {
        vec![0, 0, 0, 1, 0x67, profile, flags, 0x1f, 0xac]
    }

    fn with_idr(mut au: Vec<u8>) -> Vec<u8> {
        au.extend([0, 0, 0, 1, 0x68, 0xee, 0x3c, 0x80, 0, 0, 0, 1, 0x65, 0x88, 0x84]);
        au
    }

    const P_FRAME: [u8; 7] = [0, 0, 0, 1, 0x41, 0x9a, 0x02];

    #[test]
    fn constrained_baseline_and_main_decode() {
        // VideoToolbox ConstrainedBaseline (66, set0+set1) and OpenH264's own SPS.
        assert_eq!(sps_verdict(&with_idr(sps(66, 0xc0))), Some(Ok(())));
        assert_eq!(sps_verdict(&with_idr(sps(66, 0x00))), Some(Ok(())));
        assert_eq!(sps_verdict(&with_idr(sps(77, 0x40))), Some(Ok(())));
        assert_eq!(sps_verdict(&P_FRAME), None);
    }

    #[test]
    fn high_profile_is_refused_unless_main_compatible() {
        // VideoToolbox's default High (100, no constraint flags): the stream of cmux#50591.
        assert_eq!(sps_verdict(&with_idr(sps(100, 0x00))), Some(Err(100)));
        assert_eq!(sps_verdict(&with_idr(sps(100, 0x40))), Some(Ok(())));
    }

    /// The bug: every P-frame after a High SPS decoded to a wrong picture with no error.
    /// The gate refuses the IDR and every frame after it, until a decodable SPS arrives.
    #[test]
    fn gate_refuses_every_frame_under_a_high_sps() {
        let mut gate = ProfileGate::default();
        let err = gate.check(&with_idr(sps(100, 0x00))).expect_err("high IDR refused");
        assert!(err.contains("high profile") && err.contains("h264.baseline"), "{err}");
        for _ in 0..3 {
            assert!(gate.check(&P_FRAME).is_err(), "P-frames under a high SPS are refused");
        }
        assert_eq!(gate.refused(), Some(100));
        // The host restarts on constrained baseline (the viewer's cap): frames decode again.
        assert!(gate.check(&with_idr(sps(66, 0xc0))).is_ok());
        assert!(gate.check(&P_FRAME).is_ok());
        assert_eq!(gate.refused(), None);
    }

    #[test]
    fn a_stream_with_no_sps_yet_is_let_through() {
        assert!(ProfileGate::default().check(&P_FRAME).is_ok());
    }
}
