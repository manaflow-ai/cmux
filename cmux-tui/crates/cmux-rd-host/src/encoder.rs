//! The H.264 encoder behind one trait (cmux-encode's `H264Encoder`), so the codec is a
//! build feature and a flag, not a code fork. Default (`openh264` feature): Cisco's
//! OpenH264 binary, downloaded from Cisco at run time by `cmux-rd openh264-install` (the
//! host enable flow) into the per-user data directory or given with `--openh264-lib PATH`,
//! loaded after its pinned SHA-256 matches (Cisco pays the H.264 patent royalties for that
//! binary); compiled from source in bench builds only. x264 (`x264` feature, opt-in) waits
//! for Lawrence's legal decision on H.264 patent royalties: dev and test builds only.
//! On Linux, `--codec auto` (opt-in until measured on GPUs, hq#12040) uses the GPU through VAAPI (cmux-encode `vaapi`, libva
//! loaded at run time) when a render node encodes H.264, else OpenH264, and logs which and why.

use crate::Res;
#[cfg(feature = "openh264")]
use std::path::{Path, PathBuf};

#[cfg(feature = "openh264")]
use cmux_encode::openh264::{load_verified, Platform};
#[cfg(any(feature = "openh264", feature = "bench"))]
use cmux_encode::openh264::{OpenH264, OpenH264Api};
pub use cmux_encode::H264Encoder;

/// Encoder settings.
// A build with no encoder feature (and no VideoToolbox) reads none of them.
#[cfg_attr(
    not(any(
        feature = "openh264",
        feature = "bench",
        feature = "x264",
        target_os = "macos",
        target_os = "linux"
    )),
    allow(dead_code)
)]
#[derive(Clone, Copy)]
pub struct EncCfg<'a> {
    pub width: u32,
    pub height: u32,
    pub fps: u32,
    pub kbps: u32,
    /// Software encoders only.
    #[cfg_attr(
        not(any(feature = "openh264", feature = "bench", feature = "x264", target_os = "linux")),
        allow(dead_code)
    )]
    pub threads: u16,
    /// `auto` (Linux: VAAPI on a GPU, else openh264), `vaapi` (Linux), `openh264`
    /// or `x264` (needs the `x264` feature).
    pub codec: &'a str,
    /// openh264 usage: screen content (default; codes scrolling text with motion search
    /// at a small fraction of the camera mode's bitrate, but turns large changes into
    /// IDRs) or camera.
    #[cfg_attr(
        not(any(feature = "openh264", feature = "bench", target_os = "linux")),
        allow(dead_code)
    )]
    pub screen_content: bool,
    /// x264 only.
    #[cfg_attr(not(feature = "x264"), allow(dead_code))]
    pub preset: &'a str,
    /// x264 and VAAPI (`high` for hardware decoders, `baseline` for the Linux bench).
    #[cfg_attr(not(any(feature = "x264", target_os = "linux")), allow(dead_code))]
    pub profile: &'a str,
    /// Cisco's OpenH264 library (`--openh264-lib`), checked against its pinned SHA-256.
    #[cfg_attr(not(any(feature = "openh264", feature = "bench")), allow(dead_code))]
    pub openh264_lib: Option<&'a str>,
}

/// The copy `cmux-rd openh264-install` put in `dir` (the per-user data
/// directory), if it is there. [`load_verified`] checks its hash on load.
#[cfg(feature = "openh264")]
fn installed_library(dir: Option<&Path>, platform: Platform) -> Option<PathBuf> {
    let path = cmux_encode::cisco::library_path(dir?, platform);
    path.is_file().then_some(path)
}

/// `cmux-rd openh264-install [--dir PATH]`: the host enable flow's step that
/// downloads Cisco's library from Cisco (never bundled, never built from
/// source for the product). Prints the installed path.
#[cfg(feature = "openh264")]
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

/// The host enable flow's OpenH264 step without a separate command (`windows-host enable`):
/// Cisco's library in the per-user data directory, downloaded from Cisco when it is not there
/// yet. Its path.
#[cfg(feature = "openh264")]
pub fn ensure_openh264() -> Res<PathBuf> {
    let platform = Platform::current().ok_or("Cisco publishes no OpenH264 for this platform")?;
    let dir = cmux_encode::cisco::default_dir().ok_or("no per-user data directory")?;
    if let Some(path) = installed_library(Some(&dir), platform) {
        return Ok(path);
    }
    Ok(cmux_encode::cisco::install(&dir, platform)?)
}

/// Cisco's library from `--openh264-lib`, else the installer's per-user copy.
#[cfg(feature = "openh264")]
fn cisco_api(lib: Option<&str>) -> Res<Option<OpenH264Api>> {
    let platform = Platform::current().ok_or("Cisco publishes no OpenH264 for this platform");
    if let Some(path) = lib {
        return Ok(Some(load_verified(path, platform?)?));
    }
    if let Ok(platform) = platform {
        let dir = cmux_encode::cisco::default_dir();
        if let Some(path) = installed_library(dir.as_deref(), platform) {
            return Ok(Some(load_verified(path, platform)?));
        }
    }
    Ok(None)
}

/// Without the `openh264` feature there is no Cisco runtime path.
#[cfg(all(feature = "bench", not(feature = "openh264")))]
fn cisco_api(lib: Option<&str>) -> Res<Option<OpenH264Api>> {
    match lib {
        Some(_) => Err("--openh264-lib needs a build with the openh264 feature".into()),
        None => Ok(None),
    }
}

/// The OpenH264 entry points: Cisco's library (`cisco_api`), else the source
/// build (bench builds only; a shipped host never compiles OpenH264). A
/// session never downloads.
#[cfg(any(feature = "openh264", feature = "bench"))]
fn openh264_api(lib: Option<&str>) -> Res<OpenH264Api> {
    if let Some(api) = cisco_api(lib)? {
        return Ok(api);
    }
    #[cfg(feature = "bench")]
    return Ok(OpenH264Api::from_source());
    #[cfg(not(feature = "bench"))]
    Err("openh264 is not installed: run `cmux-rd openh264-install` (downloads Cisco's library from Cisco)".into())
}

/// The software encoder's threads (and OpenH264's slices) for this machine:
/// [`threads_for_cores`] of the cores this process may run on.
pub fn default_threads() -> u16 {
    threads_for_cores(std::thread::available_parallelism().map_or(1, |n| n.get()))
}

/// Two below 8 cores, four from 8. Measured with Cisco's OpenH264 at 1080p
/// (`scripts/encode-matrix.sh`, cmux#44552): one thread is slower than two even on a 2-vCPU
/// VM; four gain 5-10% from 8 cores and lose at 4, where they compete with capture and the
/// session's loop thread.
pub fn threads_for_cores(cores: usize) -> u16 {
    if cores >= 8 {
        4
    } else {
        2
    }
}

/// [`open`], with OpenH264 coded under the bench's `key=value` settings when given
/// (`cmux-rd encode-selftest --openh264-options`; cmux-encode `OpenH264Options::parse`).
pub fn open_with(cfg: &EncCfg<'_>, openh264_options: Option<&str>) -> Res<Box<dyn H264Encoder>> {
    #[cfg(any(feature = "openh264", feature = "bench"))]
    if let (Some(options), "openh264") = (openh264_options, cfg.codec) {
        let enc_cfg = cmux_encode::EncCfg {
            width: cfg.width,
            height: cfg.height,
            fps: cfg.fps,
            kbps: cfg.kbps,
            threads: cfg.threads,
            screen_content: cfg.screen_content,
        };
        let options = cmux_encode::openh264::OpenH264Options::parse(options)?;
        let api = openh264_api(cfg.openh264_lib)?;
        return Ok(Box::new(OpenH264::with_options(&enc_cfg, api, &options)?));
    }
    if openh264_options.is_some() && cfg.codec != "openh264" {
        return Err("--openh264-options needs --codec openh264".into());
    }
    open(cfg)
}

/// The encoder `--codec auto` (the Linux default) picks: the GPU's through VAAPI when a
/// render node's driver encodes H.264, else OpenH264. The log line says which and why.
#[cfg(target_os = "linux")]
fn open_auto(cfg: &EncCfg<'_>) -> Res<Box<dyn H264Encoder>> {
    match open_vaapi(cfg) {
        Ok(enc) => {
            eprintln!("cmux-rd: encoder: {} (hardware: VAAPI probe passed)", enc.name());
            Ok(enc)
        }
        Err(why) => {
            let enc = open(&EncCfg { codec: "openh264", ..*cfg })?;
            eprintln!("cmux-rd: encoder: {} (software: VAAPI unavailable: {why})", enc.name());
            Ok(enc)
        }
    }
}

#[cfg(target_os = "linux")]
fn open_vaapi(cfg: &EncCfg<'_>) -> Res<Box<dyn H264Encoder>> {
    let enc_cfg = cmux_encode::EncCfg {
        width: cfg.width,
        height: cfg.height,
        fps: cfg.fps,
        kbps: cfg.kbps,
        threads: cfg.threads,
        screen_content: cfg.screen_content,
    };
    Ok(Box::new(cmux_encode::vaapi::Vaapi::new(&enc_cfg, cfg.profile == "baseline")?))
}

pub fn open(cfg: &EncCfg<'_>) -> Res<Box<dyn H264Encoder>> {
    match cfg.codec {
        #[cfg(target_os = "linux")]
        "auto" => open_auto(cfg),
        #[cfg(target_os = "linux")]
        "vaapi" => open_vaapi(cfg),
        #[cfg(any(feature = "openh264", feature = "bench"))]
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
        #[cfg(any(feature = "vp9", feature = "av1"))]
        "vp9" | "av1" => {
            let codec = cmux_encode::Codec::parse(cfg.codec).ok_or("codec")?;
            let enc_cfg = cmux_encode::EncCfg {
                width: cfg.width,
                height: cfg.height,
                fps: cfg.fps,
                kbps: cfg.kbps,
                threads: cfg.threads,
                screen_content: cfg.screen_content,
            };
            cmux_codecs::open_encoder(codec, &enc_cfg)?
                .ok_or_else(|| format!("codec {} not available in this build", cfg.codec).into())
        }
        other => Err(format!("codec {other} not available in this build").into()),
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn eight_cores_encode_on_four_threads_and_fewer_on_two() {
        let threads: Vec<u16> = [1, 2, 4, 6, 8, 16].map(super::threads_for_cores).to_vec();
        assert_eq!(threads, [2, 2, 2, 2, 4, 4]);
    }
}
