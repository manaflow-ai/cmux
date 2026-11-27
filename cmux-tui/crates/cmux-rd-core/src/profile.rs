//! The encoder profile a session runs: the one switch between today's encoder settings and
//! "ultra" for fat links. The rate controller (cc.rs) owns which profile is current; the
//! engine copies it onto every `EncodeRequest`, and the host's encoder applies it. Ultra
//! stops saving bandwidth and holds frame rate first: frames at the session's rate (up to
//! [`ULTRA_MAX_FPS`]), each about target/fps within a per-pixel ceiling so extra rate buys
//! fps before per-frame quality and only then quality, and a refinement frame with a larger
//! budget once the screen goes still.

/// Which encoder settings a session uses. [`EncodeProfile::Standard`] is today's behavior and
/// the default; [`EncodeProfile::Ultra`] is opt-in.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum EncodeProfile {
    #[default]
    Standard,
    Ultra,
}

/// The most frames per second ultra captures and encodes (the display's refresh, at most this).
pub const ULTRA_MAX_FPS: u32 = 120;
/// The session's rate ceiling under ultra when no `--max-kbps` names one: the rate controller
/// holds its measured rate within it (standard's default ceiling is 50 Mbps).
pub const ULTRA_MAX_KBPS: u32 = 150_000;

/// The session's rate ceiling: an explicit one wins, else ultra's or `standard_default`.
pub fn max_kbps(profile: EncodeProfile, explicit: Option<u32>, standard_default: u32) -> u32 {
    explicit.unwrap_or(match profile {
        EncodeProfile::Standard => standard_default,
        EncodeProfile::Ultra => ULTRA_MAX_KBPS,
    })
}

/// How long the screen stays still after the newest frame before ultra sends a refinement frame:
/// one frame interval at `fps`, so the refinement is at most the second frame after damage stops.
pub fn refine_after_us(fps: u32) -> u64 {
    1_000_000 / u64::from(fps.max(1))
}

impl EncodeProfile {
    /// The profile a flag or setting names: `standard` (or `balanced`, `default`) and `ultra`.
    pub fn parse(s: &str) -> Option<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "standard" | "balanced" | "default" => Some(Self::Standard),
            "ultra" => Some(Self::Ultra),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Standard => "standard",
            Self::Ultra => "ultra",
        }
    }

    pub fn is_ultra(self) -> bool {
        self == Self::Ultra
    }

    /// The frame rate this profile captures and encodes at, from the session's rate (the
    /// viewer's, else the display's refresh): ultra keeps it up to [`ULTRA_MAX_FPS`]; standard
    /// keeps it as it is.
    pub fn stream_fps(self, session_fps: u32) -> u32 {
        match self {
            Self::Standard => session_fps.max(1),
            Self::Ultra => session_fps.clamp(1, ULTRA_MAX_FPS),
        }
    }
}

#[cfg(test)]
#[path = "profile_tests.rs"]
mod tests;
