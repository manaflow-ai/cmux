//! The macOS desktop: one display (or one window, `window.rs`) through ScreenCaptureKit, encoded by VideoToolbox from the
//! captured IOSurface with no CPU copy, and viewer input posted as CGEvents. Design:
//! plans/cmux-next/remote-desktop-mac-host.md. Needs Screen Recording and Accessibility for
//! the host process or the app that launched it.

pub(crate) mod capture;
#[cfg(feature = "bench")]
pub(crate) mod cpu;
#[cfg(feature = "computer-use")]
pub(crate) mod cu_host;
#[cfg(feature = "computer-use")]
pub(crate) mod cu_record;
pub(crate) mod cursor;
mod display_pick;
mod input;
mod keys;
#[cfg(feature = "bench")]
pub(crate) mod observe;
pub(crate) mod pasteboard;
#[cfg(feature = "bench")]
pub(crate) mod synthetic;
mod sys;
pub(crate) mod window;

use crate::desktop::{Desktop, FrameSource, Halves};
use crate::stream::SessionCfg;
use crate::Res;
use capture::Capture;
use cmux_encode::videotoolbox::{
    ColorTag, SurfaceEncoder, SurfaceFormat, SurfaceFrame, SurfaceRect, VideoToolbox,
};
use cmux_rd_core::flow::Rect;
use cmux_rd_core::profile::EncodeProfile;
use cmux_rd_core::resolution::Picture;
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
    /// The resolution ladder's picture is smaller than the stream (the encode scales).
    #[cfg_attr(not(feature = "bench"), allow(dead_code))] // read by the bench's quality check
    scaled: bool,
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
    // The cursor is in the pictures unless the viewer draws it or asked for none at all.
    let in_pictures = !cursor_metadata && cfg.show_cursor;
    let capture = match window::session_window(cfg.window, &cfg.display)? {
        // One window, captured alone; a close or resize ends the session (`drain`).
        Some(id) => Capture::start_window(id, cfg.max_fps, cfg.max_width, in_pictures)?,
        None => Capture::start_for_session(&cfg.display, cfg.max_fps, cfg.max_width, in_pictures)?,
    };
    capture.wait_first_frame(FIRST_FRAME_TIMEOUT_NS)?;
    let (width, height) = capture.size();
    let mut encoder = VideoToolbox::new(
        width,
        height,
        encoder_fps(width, height, cfg.max_fps),
        cfg.start_kbps,
        cfg.profile == "baseline",
    )?;
    // The session's profile and the encoder's resources now, not on the first frame: an ultra
    // session would otherwise rebuild the encoder inside the session's first keyframe.
    encoder.set_ultra(cfg.encode_profile.is_ultra());
    encoder.prepare()?;
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
        scaled: false,
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
        // A closed or resized window ends the session with that reason, before a restart of
        // the stream ScreenCaptureKit stopped for it is tried.
        let news = self.capture.window_news();
        if let Some(reason) = news.ended {
            return Err(reason.into());
        }
        self.capture.recover()?;
        self.capture.drain(out);
        // The shared window moved: the picture is the same, the pointer maps through its new
        // frame.
        if let Some(bounds) = news.moved {
            self.injector.move_to(bounds);
            if let Some(cursor) = self.cursor.as_mut() {
                cursor.move_to(bounds);
            }
        }
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
        // The bench's quality check compares the decoded frame with the full-size source, so
        // it skips frames the resolution ladder scaled down.
        #[cfg(feature = "bench")]
        if let (Some(quality), false) = (self.quality.as_mut(), self.scaled) {
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

    fn applies_profile(&self) -> bool {
        true
    }

    fn set_changed_pixels(&mut self, pixels: u64) {
        self.encoder.set_changed_pixels(pixels);
    }

    fn kbps(&self) -> u32 {
        SurfaceEncoder::kbps(&self.encoder)
    }

    fn encoder_name(&self) -> String {
        self.name.clone()
    }

    /// The resolution ladder's picture: a size smaller than the stream is scaled down on the
    /// GPU before the encode (cmux-encode's surface path), and its QP ceiling goes to the
    /// encoder. `None`: the full stream, no ceiling.
    fn set_picture(&mut self, picture: Option<Picture>) {
        let size = picture.map(|p| (p.width, p.height));
        self.scaled = size.is_some_and(|s| s != self.size);
        self.encoder.set_picture_size(size);
        self.encoder.set_max_qp(picture.and_then(|p| p.max_qp));
    }

    fn idr_cause(&self) -> Option<&'static str> {
        cmux_encode::H264Encoder::idr_cause(&self.encoder)
    }
}
