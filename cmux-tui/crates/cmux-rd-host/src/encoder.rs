//! The H.264 encoder behind one trait (cmux-encode's `H264Encoder`), so the codec is a
//! build feature and a flag, not a code fork. Default: x264 ultrafast zerolatency (`x264`
//! feature, on by default; GPL, so it stays in this binary): it keeps a text scroll at about
//! 39 fps and 6 Mbit/s where openh264 fell to 28 fps (screen mode) or collapsed (camera
//! mode). Alternative: OpenH264 from cmux-encode: Cisco's library, downloaded from Cisco
//! by `cmux-rd openh264-install` (the host enable flow) into the per-user data directory
//! or given with `--openh264-lib PATH`, loaded after its pinned SHA-256 matches; compiled
//! from source in bench builds only.

use crate::Res;
use std::path::{Path, PathBuf};

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

/// The copy `cmux-rd openh264-install` put in `dir` (the per-user data
/// directory), if it is there. [`load_verified`] checks its hash on load.
fn installed_library(dir: Option<&Path>, platform: Platform) -> Option<PathBuf> {
    let path = cmux_encode::cisco::library_path(dir?, platform);
    path.is_file().then_some(path)
}

/// `cmux-rd openh264-install [--dir PATH]`: the host enable flow's step that
/// downloads Cisco's library from Cisco (never bundled, never built from
/// source for the product). Prints the installed path.
pub fn install_openh264(opts: &crate::args::Opts) -> Res<()> {
    let platform = Platform::current().ok_or("Cisco publishes no OpenH264 for this platform")?;
    let dir = match opts.get("dir") {
        Some(dir) => PathBuf::from(dir),
        None => cmux_encode::cisco::default_dir().ok_or("no per-user data directory (set HOME)")?,
    };
    let path = cmux_encode::cisco::install(&dir, platform)?;
    println!("{}", path.display());
    Ok(())
}

/// The OpenH264 entry points: Cisco's library from `--openh264-lib`, else
/// the installer's per-user copy, else the source build (bench builds only;
/// a shipped host never compiles OpenH264). A session never downloads.
fn openh264_api(lib: Option<&str>) -> Res<OpenH264Api> {
    let platform = Platform::current().ok_or("Cisco publishes no OpenH264 for this platform");
    if let Some(path) = lib {
        return Ok(load_verified(path, platform?)?);
    }
    if let Ok(platform) = platform {
        let dir = cmux_encode::cisco::default_dir();
        if let Some(path) = installed_library(dir.as_deref(), platform) {
            return Ok(load_verified(path, platform)?);
        }
    }
    #[cfg(feature = "bench")]
    return Ok(OpenH264Api::from_source());
    #[cfg(not(feature = "bench"))]
    Err("openh264 is not installed: run `cmux-rd openh264-install` (downloads Cisco's library from Cisco)".into())
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
        "videotoolbox" => Ok(Box::new(cmux_encode::videotoolbox::VideoToolbox::new(
            cfg.width,
            cfg.height,
            cfg.fps,
            cfg.kbps,
            cfg.profile == "baseline",
        )?)),
        other => Err(format!("codec {other} not available in this build").into()),
    }
}

#[cfg(test)]
mod tests {
    use super::installed_library;
    use cmux_encode::openh264::{CiscoBinary, Platform};

    #[test]
    fn openh264_without_a_path_uses_the_installers_per_user_copy() {
        let dir = std::env::temp_dir().join(format!("cmux-rd-installed-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        assert_eq!(installed_library(Some(&dir), Platform::LinuxX64), None, "not installed");
        std::fs::create_dir_all(&dir).expect("dir");
        let file = dir.join(CiscoBinary::for_platform(Platform::LinuxX64).file_name);
        std::fs::write(&file, b"x").expect("write");
        assert_eq!(installed_library(Some(&dir), Platform::LinuxX64), Some(file));
        assert_eq!(installed_library(None, Platform::LinuxX64), None, "no data directory");
        let _ = std::fs::remove_dir_all(dir);
    }
}
