//! Video encoders every rd source shares (rd change C7 step 3;
//! plans/cmux-next/remote-desktop-c7.md): the I420 picture and its BGRX
//! conversion, the codec seam (module `codec`: [`VideoEncoder`], [`VideoDecoder`]
//! and each codec's framing; [`H264Encoder`] is the encoder trait's older name),
//! and OpenH264 under the binary rule in [`openh264`]. x264 (GPL) stays in the cmux-rd host binary and never enters
//! this crate; macOS hosts use VideoToolbox (module `videotoolbox`, macOS only).

mod codec;
mod picture;

#[cfg(any(feature = "openh264-source", feature = "openh264-runtime"))]
pub mod openh264;

/// The host installer's step that downloads Cisco's OpenH264 from Cisco.
#[cfg(feature = "openh264-download")]
pub mod cisco;

/// Apple frameworks bound at run time, so a binary links none of them (macOS only).
#[cfg(target_os = "macos")]
pub mod dynlib;

#[cfg(target_os = "macos")]
pub mod videotoolbox;

/// The encoder trait's name from before VP9 and AV1 (every H.264 source still uses it).
pub use codec::VideoEncoder as H264Encoder;
pub use codec::{Codec, VideoDecoder, VideoEncoder, annexb_nals, av1_obus};
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
