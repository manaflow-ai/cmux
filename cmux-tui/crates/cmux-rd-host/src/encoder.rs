//! The H.264 encoder behind one trait (cmux-encode's `H264Encoder`), so the codec is a
//! build feature and a flag, not a code fork. Default: x264 ultrafast zerolatency (`x264`
//! feature, on by default; GPL, so it stays in this binary): it keeps a text scroll at about
//! 39 fps and 6 Mbit/s where openh264 fell to 28 fps (screen mode) or collapsed (camera
//! mode). Alternative: OpenH264 from cmux-encode, Cisco's library loaded with
//! `--openh264-lib PATH` (pinned SHA-256), or compiled from source in bench builds only.

use crate::Res;
use cmux_encode::openh264::{load_verified, OpenH264, OpenH264Api, Platform};
pub use cmux_encode::H264Encoder;

/// Encoder settings.
pub struct EncCfg<'a> {
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub kbps: u32,
    pub threads: u16,
    /// `openh264` (default) or `x264` (needs the `x264` feature).
    pub codec: &'a str,
    /// openh264 usage: screen content (default; codes scrolling text with motion search
    /// at a small fraction of the camera mode's bitrate, but turns large changes into
    /// IDRs) or camera.
    pub screen_content: bool,
    /// x264 only.
    #[cfg_attr(not(feature = "x264"), allow(dead_code))]
    pub preset: &'a str,
    /// x264 only (`high` for hardware decoders, `baseline` for the Linux bench).
    #[cfg_attr(not(feature = "x264"), allow(dead_code))]
    pub profile: &'a str,
    /// Cisco's OpenH264 library (`--openh264-lib`), checked against its pinned SHA-256.
    pub openh264_lib: Option<&'a str>,
}

/// The OpenH264 entry points: Cisco's library when a path is given, else the
/// source build (bench builds only; a shipped host never compiles OpenH264).
fn openh264_api(lib: Option<&str>) -> Res<OpenH264Api> {
    if let Some(path) = lib {
        let platform =
            Platform::current().ok_or("Cisco publishes no OpenH264 for this platform")?;
        return Ok(load_verified(path, platform)?);
    }
    #[cfg(feature = "bench")]
    return Ok(OpenH264Api::from_source());
    #[cfg(not(feature = "bench"))]
    Err("openh264 needs --openh264-lib PATH (Cisco's library, downloaded from Cisco)".into())
}

pub fn open(cfg: &EncCfg<'_>) -> Res<Box<dyn H264Encoder>> {
    match cfg.codec {
        "openh264" => {
            let enc_cfg = cmux_encode::EncCfg {
                width: cfg.width,
                height: cfg.height,
                fps: cfg.fps,
                kbps: cfg.kbps,
                threads: cfg.threads,
                screen_content: cfg.screen_content,
            };
            Ok(Box::new(OpenH264::new(&enc_cfg, openh264_api(cfg.openh264_lib)?)?))
        }
        #[cfg(feature = "x264")]
        "x264" => Ok(Box::new(crate::x264::X264::new(
            cfg.width,
            cfg.height,
            cfg.fps,
            cfg.kbps,
            cfg.threads,
            cfg.preset,
            cfg.profile,
        )?)),
        #[cfg(target_os = "macos")]
        "videotoolbox" => Ok(Box::new(crate::vt::VideoToolbox::new(
            cfg.width,
            cfg.height,
            cfg.fps,
            cfg.kbps,
            cfg.profile == "baseline",
        )?)),
        other => Err(format!("codec {other} not available in this build").into()),
    }
}
