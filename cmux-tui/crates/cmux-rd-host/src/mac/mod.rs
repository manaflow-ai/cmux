//! The macOS desktop: one display through ScreenCaptureKit, encoded by VideoToolbox from the
//! captured IOSurface with no CPU copy, and viewer input posted as CGEvents. Design:
//! plans/cmux-next/remote-desktop-mac-host.md. Needs Screen Recording and Accessibility for
//! the host process or the app that launched it.

pub(crate) mod capture;
#[cfg(feature = "bench")]
pub(crate) mod cpu;
pub(crate) mod cursor;
mod input;
mod keys;
#[cfg(feature = "bench")]
pub(crate) mod observe;
mod sys;

use crate::desktop::{Desktop, FrameSource, Halves};
use crate::stream::SessionCfg;
use crate::Res;
use capture::Capture;
use cmux_encode::videotoolbox::{
    ColorTag, SurfaceEncoder, SurfaceFormat, SurfaceFrame, SurfaceRect, VideoToolbox,
};
use cmux_rd_core::flow::Rect;
use cmux_rd_core::profile::EncodeProfile;
use cmux_rd_proto::InputEvent;
use input::Injector;
use std::os::fd::RawFd;

/// How long the host waits for the display's first frame before it gives up on a session.
const FIRST_FRAME_TIMEOUT_NS: u64 = 3_000_000_000;
/// H.264 level 5.2's macroblock rate (ITU-T H.264 Table A-1), the most the viewer decodes.
const LEVEL_52_MACROBLOCKS_PER_S: u64 = 2_073_600;

/// The highest frame rate H.264 level 5.2 allows at this size, at most `fps`: VideoToolbox
/// refuses a session above it (-12902), for example a 120 Hz display at 3342x2160.
fn encoder_fps(width: u32, height: u32, fps: u32) -> u32 {
    let macroblocks = u64::from(width.div_ceil(16)) * u64::from(height.div_ceil(16));
    let limit = (LEVEL_52_MACROBLOCKS_PER_S / macroblocks.max(1)).max(1);
    fps.min(limit as u32)
}

/// The loop thread's half: the capture's damage, CGEvent input, and the cursor.
pub struct MacDesktop {
    capture: Capture,
    injector: Injector,
    /// The cursor as metadata (cap `cursor`): the pictures leave it out.
    cursor: Option<cursor::CursorReader>,
}

/// The encode thread's half: picks the newest captured frame and encodes it with VideoToolbox.
pub struct MacFrames {
    frames: capture::Frames,
    size: (u32, u32),
    /// The frame [`FrameSource::capture`] picked and its damage, for the next encode.
    picked: Option<(capture::PixelBuffer, Rect)>,
    /// The picked frame's display and arrival times (measurement only).
    picked_times: Option<(u64, u64)>,
    encoder: VideoToolbox,
    name: String,
    #[cfg(feature = "bench")]
    quality: Option<crate::eval::Quality>,
}

/// Starts the display's capture and opens both halves of the session's desktop.
/// `cursor_metadata`: capture without the cursor and report it through `Desktop::cursor`.
pub fn open(cfg: &SessionCfg, cursor_metadata: bool) -> Res<Halves> {
    if cfg.codec != "videotoolbox" {
        return Err(format!(
            "codec {} is not available on a macOS host (it encodes captured surfaces with videotoolbox)",
            cfg.codec
        )
        .into());
    }
    let cursor_metadata = cursor_metadata && cursor::available();
    let capture =
        Capture::start_for_session(&cfg.display, cfg.max_fps, cfg.max_width, !cursor_metadata)?;
    capture.wait_first_frame(FIRST_FRAME_TIMEOUT_NS)?;
    let (width, height) = capture.size();
    let encoder = VideoToolbox::new(
        width,
        height,
        encoder_fps(width, height, cfg.max_fps),
        cfg.start_kbps,
        cfg.profile == "baseline",
    )?;
    let name =
        format!("{} from screencapturekit iosurface", cmux_encode::H264Encoder::name(&encoder));
    let injector = Injector::new(capture.bounds(), (width, height))?;
    let frames = MacFrames {
        frames: capture.frames(),
        size: (width, height),
        picked: None,
        picked_times: None,
        encoder,
        name,
        #[cfg(feature = "bench")]
        quality: crate::eval::Quality::from_env(),
    };
    let cursor =
        cursor_metadata.then(|| cursor::CursorReader::new(capture.bounds(), (width, height)));
    Ok((Box::new(MacDesktop { capture, injector, cursor }), Box::new(frames)))
}

impl Desktop for MacDesktop {
    fn size(&self) -> (u32, u32) {
        self.capture.size()
    }

    fn fd(&self) -> RawFd {
        self.capture.fd()
    }

    fn drain(&mut self, out: &mut Vec<Rect>) -> Res<()> {
        self.capture.drain(out);
        Ok(())
    }

    fn inject(&mut self, event: &InputEvent) -> Res<()> {
        self.injector.apply(event);
        Ok(())
    }

    fn release_all(&mut self) -> Res<()> {
        self.injector.release_all();
        Ok(())
    }

    fn cursor(&mut self) -> Option<crate::cursor::CursorSample> {
        self.cursor.as_mut()?.sample()
    }
}

impl FrameSource for MacFrames {
    /// Picks the newest complete frame; ScreenCaptureKit already holds the pixels.
    fn capture(&mut self, damage: Rect) -> Res<()> {
        let (frame, times) = self.frames.newest().ok_or("no captured frame yet")?;
        self.picked = Some((frame, damage));
        self.picked_times = times;
        Ok(())
    }

    fn picked_times(&self) -> Option<(u64, u64)> {
        self.picked_times
    }

    fn encode(&mut self, force_idr: bool, pts_us: i64, out: &mut Vec<u8>) -> Res<bool> {
        let (width, height) = self.size;
        let (frame, damage) = self.picked.take().ok_or("encode before capture")?;
        let surface = frame.io_surface().ok_or("the captured frame has no IOSurface")?;
        // SAFETY: `frame` holds the pixel buffer and with it the IOSurface until this
        // function returns, which is after encode_surface returns.
        let picture = unsafe {
            SurfaceFrame::new(surface, SurfaceFormat::Nv12, width, height, ColorTag::Srgb)
        };
        let hint =
            SurfaceRect { x: damage.x, y: damage.y, width: damage.width, height: damage.height };
        let idr = self.encoder.encode_surface(&picture, hint, force_idr, pts_us, out)?;
        #[cfg(feature = "bench")]
        if let Some(quality) = self.quality.as_mut() {
            if quality.wants_source(pts_us as u64, out) {
                if let Some(pixels) = frame.eval_roi() {
                    quality.source(pts_us as u64, out, &pixels);
                }
            }
        }
        Ok(idr)
    }

    fn set_bitrate(&mut self, kbps: u32) {
        SurfaceEncoder::set_bitrate(&mut self.encoder, kbps);
    }

    fn set_profile(&mut self, profile: EncodeProfile, refine: bool) {
        self.encoder.set_ultra(profile.is_ultra());
        self.encoder.set_refine(refine);
    }

    fn kbps(&self) -> u32 {
        SurfaceEncoder::kbps(&self.encoder)
    }

    fn encoder_name(&self) -> String {
        self.name.clone()
    }
}
