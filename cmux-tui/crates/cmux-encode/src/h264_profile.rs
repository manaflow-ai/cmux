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
#[path = "h264_profile_tests.rs"]
mod tests;
