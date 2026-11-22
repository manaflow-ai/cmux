//! The Linux desktop: X damage, XShm readback of the damaged rectangle into an I420
//! picture, H.264 (openh264 by default, x264 opt-in) and XTest injection. Two X
//! connections: the loop thread's reads damage, the encode thread's reads pixels back.
//! The picture is the viewer's pick of the X screen (the whole screen or one monitor),
//! fitted into its `max_width` ([`View`]).

use crate::capture::{Capturer, Rect as CapRect};
use crate::desktop::{Desktop, FrameSource, Halves};
use crate::encoder::{self, EncCfg, H264Encoder};
use crate::inject::Injector;
use crate::stream::SessionCfg;
use crate::x11_view::{self, View};
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
    view: View,
}

/// The encode thread's half: XShm readback into the I420 picture and the encoder.
pub struct X11Frames {
    cap: Capturer,
    enc: Box<dyn H264Encoder>,
    pic: I420,
    view: View,
    /// The source at its own size, read back before scaling; only when the view is scaled.
    full: Option<I420>,
}

/// Opens both halves of the X display `cfg.display`.
pub fn open(cfg: &SessionCfg) -> Res<Halves> {
    let damage = Capturer::new(&cfg.display, true)?;
    let cap = Capturer::new(&cfg.display, false)?;
    // x264 and 4:2:0 need even sizes; an odd last column or row is not sent.
    let listed = x11_view::listing((cap.width, cap.height), &cap.monitors());
    let view = View::new(x11_view::pick(cfg.display_pick.as_deref(), &listed)?, cfg.max_width);
    let (w, h) = view.out;
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
    let desktop = X11Desktop {
        injector: Injector::new(&cfg.display)?,
        damage: Vec::new(),
        cap: damage,
        view,
    };
    let full = view.scaled().then(|| I420::new(view.src.w as usize, view.src.h as usize));
    let frames = X11Frames { pic: I420::new(w as usize, h as usize), cap, enc, view, full };
    Ok((Box::new(desktop), Box::new(frames)))
}

impl Desktop for X11Desktop {
    fn size(&self) -> (u32, u32) {
        self.view.out
    }

    fn fd(&self) -> RawFd {
        self.cap.fd()
    }

    fn drain(&mut self, out: &mut Vec<Rect>) -> Res<()> {
        self.damage.clear();
        self.cap.drain(&mut self.damage)?;
        let view = self.view;
        out.extend(self.damage.iter().filter_map(|ev| view.clip(ev.rect)).map(|r| {
            let r = if view.scaled() { view.to_out(r) } else { r };
            Rect { x: r.x, y: r.y, width: r.w, height: r.h }
        }));
        Ok(())
    }

    fn inject(&mut self, event: &InputEvent) -> Res<()> {
        match *event {
            InputEvent::Pointer { x, y } => {
                let (x, y) = self.view.pointer(x, y);
                self.injector.apply(&InputEvent::Pointer { x, y })
            }
            _ => self.injector.apply(event),
        }
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
        let view = self.view;
        let (w, h) = view.out;
        let r = CapRect { x: damage.x, y: damage.y, w: damage.width, h: damage.height }
            .align_even(w, h);
        if r.w == 0 || r.h == 0 {
            return Ok(());
        }
        // The rect of the source this part of the picture is made from.
        let s = if view.scaled() { view.to_src(r) } else { r };
        let on_screen = CapRect { x: view.src.x + s.x, y: view.src.y + s.y, w: s.w, h: s.h };
        let px = self.cap.grab(on_screen)?;
        let threads = cmux_encode::convert_threads();
        let (sx, sy, sw, sh) = (s.x as usize, s.y as usize, s.w as usize, s.h as usize);
        let Some(full) = self.full.as_mut() else {
            bgrx_rect_to_i420(px, &mut self.pic, sx, sy, sw, sh, threads);
            return Ok(());
        };
        bgrx_rect_to_i420(px, full, sx, sy, sw, sh, threads);
        let o = view.to_out(s);
        let src = (view.src.w as usize, view.src.h as usize);
        let out = (w as usize, h as usize);
        let rect = (o.x as usize, o.y as usize, o.w as usize, o.h as usize);
        x11_view::scale_plane(&full.y, src, &mut self.pic.y, out, rect);
        let half = |(a, b): (usize, usize)| (a / 2, b / 2);
        let chroma = (rect.0 / 2, rect.1 / 2, rect.2 / 2, rect.3 / 2);
        x11_view::scale_plane(&full.u, half(src), &mut self.pic.u, half(out), chroma);
        x11_view::scale_plane(&full.v, half(src), &mut self.pic.v, half(out), chroma);
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

    fn idr_cause(&self) -> Option<&'static str> {
        self.enc.idr_cause()
    }
}
