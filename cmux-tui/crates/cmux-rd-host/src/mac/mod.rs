//! The macOS desktop: one display through ScreenCaptureKit, encoded by VideoToolbox from the
//! captured IOSurface with no CPU copy, and viewer input posted as CGEvents. Design:
//! plans/cmux-next/remote-desktop-mac-host.md. Needs Screen Recording and Accessibility for
//! the host process or the app that launched it.

mod capture;
mod input;
mod keys;

use crate::desktop::Desktop;
use crate::stream::SessionCfg;
use crate::Res;
use capture::Capture;
use cmux_encode::videotoolbox::{
    ColorTag, SurfaceEncoder, SurfaceFormat, SurfaceFrame, SurfaceRect, VideoToolbox,
};
use cmux_rd_core::flow::Rect;
use cmux_rd_proto::InputEvent;
use input::Injector;
use std::os::fd::RawFd;

/// How long the host waits for the display's first frame before it gives up on a session.
const FIRST_FRAME_TIMEOUT_NS: u64 = 3_000_000_000;

pub struct MacDesktop {
    capture: Capture,
    encoder: VideoToolbox,
    injector: Injector,
    name: String,
}

impl MacDesktop {
    pub fn open(cfg: &SessionCfg) -> Res<Self> {
        if cfg.codec != "videotoolbox" {
            return Err(format!(
                "codec {} is not available on a macOS host (it encodes captured surfaces with videotoolbox)",
                cfg.codec
            )
            .into());
        }
        let capture = Capture::start(&cfg.display, cfg.max_fps)?;
        capture.wait_first_frame(FIRST_FRAME_TIMEOUT_NS)?;
        let (width, height) = capture.size();
        let encoder = VideoToolbox::new(
            width,
            height,
            cfg.max_fps,
            cfg.start_kbps,
            cfg.profile == "baseline",
        )?;
        let name =
            format!("{} from screencapturekit iosurface", cmux_encode::H264Encoder::name(&encoder));
        let injector = Injector::new(capture.bounds(), (width, height))?;
        Ok(Self { capture, encoder, injector, name })
    }
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

    fn encode(
        &mut self,
        damage: Rect,
        force_idr: bool,
        pts_us: i64,
        out: &mut Vec<u8>,
    ) -> Res<bool> {
        let (width, height) = self.capture.size();
        let frame = self.capture.newest().ok_or("no captured frame yet")?;
        let surface = frame.io_surface().ok_or("the captured frame has no IOSurface")?;
        // SAFETY: `frame` holds the pixel buffer and with it the IOSurface until this
        // function returns, which is after encode_surface returns.
        let picture = unsafe {
            SurfaceFrame::new(surface.as_ptr(), SurfaceFormat::Nv12, width, height, ColorTag::Srgb)
        };
        let hint =
            SurfaceRect { x: damage.x, y: damage.y, width: damage.width, height: damage.height };
        self.encoder.encode_surface(&picture, hint, force_idr, pts_us, out)
    }

    fn set_bitrate(&mut self, kbps: u32) {
        SurfaceEncoder::set_bitrate(&mut self.encoder, kbps);
    }

    fn kbps(&self) -> u32 {
        SurfaceEncoder::kbps(&self.encoder)
    }

    fn encoder_name(&self) -> String {
        self.name.clone()
    }

    fn inject(&mut self, event: &InputEvent) -> Res<()> {
        self.injector.apply(event);
        Ok(())
    }

    fn release_all(&mut self) -> Res<()> {
        self.injector.release_all();
        Ok(())
    }
}
