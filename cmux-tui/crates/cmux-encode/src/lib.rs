//! Video encoders every rd source shares (rd change C7 step 3;
//! plans/cmux-next/remote-desktop-c7.md): the I420 picture and its BGRX
//! conversion, the `H264Encoder` trait, and OpenH264 under the binary rule in
//! [`openh264`]. x264 (GPL) stays in the cmux-rd host binary and never enters
//! this crate; macOS hosts use VideoToolbox (module `videotoolbox`, macOS only).

mod picture;

#[cfg(any(feature = "openh264-source", feature = "openh264-runtime"))]
pub mod openh264;

/// The host installer's step that downloads Cisco's OpenH264 from Cisco.
#[cfg(feature = "openh264-download")]
pub mod cisco;

#[cfg(target_os = "macos")]
pub mod videotoolbox;

pub use picture::{I420, bgrx_rect_to_i420};

pub type Res<T> = Result<T, Box<dyn std::error::Error + Send + Sync>>;

/// Settings every encoder takes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct EncCfg {
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub kbps: u32,
    pub threads: u16,
    /// Screen content (text, UI) rather than camera video.
    pub screen_content: bool,
}

/// One in-process low-latency H.264 encoder producing Annex-B access units.
pub trait H264Encoder: Send {
    /// Encodes one picture into `out` (empty when the encoder skipped the frame).
    /// `pts` is the capture time in microseconds. Returns true for an IDR.
    fn encode(&mut self, pic: &I420, force_idr: bool, pts: i64, out: &mut Vec<u8>) -> Res<bool>;
    /// Retargets the bitrate (congestion control); small changes may be ignored.
    fn set_bitrate(&mut self, kbps: u32);
    fn kbps(&self) -> u32;
    fn name(&self) -> String;
}
