//! The Linux desktop: X damage, XShm readback of the damaged rectangle into an I420
//! picture, H.264 (openh264 by default, x264 opt-in) and XTest injection.

use crate::capture::{Capturer, Rect as CapRect};
use crate::desktop::Desktop;
use crate::encoder::{self, EncCfg, H264Encoder};
use crate::inject::Injector;
use crate::stream::SessionCfg;
use crate::Res;
use cmux_encode::{bgrx_rect_to_i420, I420};
use cmux_rd_core::flow::Rect;
use cmux_rd_proto::InputEvent;
use std::os::fd::RawFd;

pub struct X11Desktop {
    cap: Capturer,
    injector: Injector,
    enc: Box<dyn H264Encoder>,
    pic: I420,
    damage: Vec<crate::capture::DamageEvent>,
}

impl X11Desktop {
    pub fn open(cfg: &SessionCfg) -> Res<Self> {
        let cap = Capturer::new(&cfg.display, true)?;
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
        Ok(Self {
            injector: Injector::new(&cfg.display)?,
            pic: I420::new(w as usize, h as usize),
            damage: Vec::new(),
            cap,
            enc,
        })
    }
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

    fn capture(&mut self, damage: Rect) -> Res<()> {
        let (w, h) = self.size();
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
                2,
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

    fn inject(&mut self, event: &InputEvent) -> Res<()> {
        self.injector.apply(event)
    }

    fn release_all(&mut self) -> Res<()> {
        self.injector.release_all()
    }
}
