//! The Linux desktop: X damage, XShm readback of the damaged rectangle into an I420
//! picture, H.264 (openh264 by default, x264 opt-in) and XTest injection. Two X
//! connections: the loop thread's reads damage, the encode thread's reads pixels back.

use crate::capture::{Capturer, Rect as CapRect};
use crate::desktop::{Desktop, FrameSource, Halves};
use crate::encoder::{self, EncCfg, H264Encoder};
use crate::inject::Injector;
use crate::stream::SessionCfg;
use crate::Res;
use cmux_encode::{bgrx_rect_to_i420, I420};
use cmux_rd_core::flow::Rect;
use cmux_rd_proto::InputEvent;
use std::os::fd::RawFd;

/// The loop thread's half: damage and XTest input.
pub struct X11Desktop {
    cap: Capturer,
    injector: Injector,
    damage: Vec<crate::capture::DamageEvent>,
}

/// The encode thread's half: XShm readback into the I420 picture and the encoder.
pub struct X11Frames {
    cap: Capturer,
    enc: Box<dyn H264Encoder>,
    pic: I420,
}

/// Opens both halves of the X display `cfg.display`.
pub fn open(cfg: &SessionCfg) -> Res<Halves> {
    let damage = Capturer::new(&cfg.display, true)?;
    let cap = Capturer::new(&cfg.display, false)?;
    // x264 and 4:2:0 need even sizes; an odd last column or row is not sent.
    let (w, h) = (cap.width & !1, cap.height & !1);
    let enc = encoder::open(&EncCfg {
        width: w,
        height: h,
        fps: cfg.max_fps,
        kbps: cfg.start_kbps,
        threads: cfg.threads,
        codec: &cfg.codec,
        screen_content: cfg.content != "camera",
        preset: &cfg.preset,
        profile: &cfg.profile,
        openh264_lib: cfg.openh264_lib.as_deref(),
    })?;
    let desktop =
        X11Desktop { injector: Injector::new(&cfg.display)?, damage: Vec::new(), cap: damage };
    let frames = X11Frames { pic: I420::new(w as usize, h as usize), cap, enc };
    Ok((Box::new(desktop), Box::new(frames)))
}

impl Desktop for X11Desktop {
    fn size(&self) -> (u32, u32) {
        (self.cap.width & !1, self.cap.height & !1)
    }

    fn fd(&self) -> RawFd {
        self.cap.fd()
    }

    fn drain(&mut self, out: &mut Vec<Rect>) -> Res<()> {
        self.damage.clear();
        self.cap.drain(&mut self.damage)?;
        out.extend(self.damage.iter().map(|ev| Rect {
            x: ev.rect.x,
            y: ev.rect.y,
            width: ev.rect.w,
            height: ev.rect.h,
        }));
        Ok(())
    }

    fn inject(&mut self, event: &InputEvent) -> Res<()> {
        self.injector.apply(event)
    }

    fn release_all(&mut self) -> Res<()> {
        self.injector.release_all()
    }

    fn pump(&mut self) -> Res<Option<std::time::Duration>> {
        self.injector.pump()
    }
}

impl FrameSource for X11Frames {
    fn capture(&mut self, damage: Rect) -> Res<()> {
        let (w, h) = (self.cap.width & !1, self.cap.height & !1);
        let r = CapRect { x: damage.x, y: damage.y, w: damage.width, h: damage.height }
            .align_even(w, h);
        if r.w > 0 && r.h > 0 {
            let px = self.cap.grab(r)?;
            bgrx_rect_to_i420(
                px,
                &mut self.pic,
                r.x as usize,
                r.y as usize,
                r.w as usize,
                r.h as usize,
                cmux_encode::convert_threads(),
            );
        }
        Ok(())
    }

    fn encode(&mut self, force_idr: bool, pts_us: i64, out: &mut Vec<u8>) -> Res<bool> {
        self.enc.encode(&self.pic, force_idr, pts_us, out)
    }

    fn set_bitrate(&mut self, kbps: u32) {
        self.enc.set_bitrate(kbps);
    }

    fn kbps(&self) -> u32 {
        self.enc.kbps()
    }

    fn encoder_name(&self) -> String {
        self.enc.name()
    }
}
