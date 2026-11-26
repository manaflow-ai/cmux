//! The Linux desktop: X damage, XShm readback of the damaged rectangle into an I420
//! picture, H.264 (openh264 by default, x264 opt-in) and XTest injection. Two X
//! connections: the loop thread's reads damage, the encode thread's reads pixels back.
//! The picture is the viewer's pick of the X screen (the whole screen, one monitor, or one
//! window followed through its moves, `x11_window`), fitted into its `max_width` ([`View`]).

use crate::capture::{readback_plan, Capturer, Rect as CapRect, WindowEvent};
use crate::desktop::{Desktop, FrameSource, Halves};
use crate::encoder::{self, EncCfg, H264Encoder};
use crate::inject::Injector;
use crate::stream::SessionCfg;
use crate::x11_view::{self, View};
use crate::x11_window::{Change, Followed};
use crate::Res;
use cmux_encode::{bgrx_rect_to_i420, I420};
use cmux_rd_core::flow::Rect;
use cmux_rd_proto::InputEvent;
use std::os::fd::RawFd;
use std::sync::{Arc, Mutex};

/// The loop thread's half: damage and XTest input.
pub struct X11Desktop {
    cap: Capturer,
    injector: Injector,
    damage: Vec<crate::capture::DamageEvent>,
    window_events: Vec<WindowEvent>,
    view: View,
    /// A one-window share: the window, how it is followed, and the view both halves read.
    window: Option<SharedWindow>,
}

struct SharedWindow {
    id: u32,
    followed: Followed,
    /// The encode thread reads the source rect from here; a move updates it.
    view: Arc<Mutex<View>>,
    /// Unmapped (minimized, another workspace): the root shows what is behind it, so no
    /// damage is sent and the viewer keeps the last picture of the window.
    hidden: bool,
}

/// The encode thread's half: XShm readback into the I420 picture and the encoder.
pub struct X11Frames {
    /// Keeps the root's damage as a server-side region too: each capture reads back exactly
    /// the rects that changed since its last one, which the persistent `pic` makes enough.
    cap: Capturer,
    enc: Box<dyn H264Encoder>,
    pic: I420,
    /// Set once the whole screen has been read back (the picture starts black).
    whole: bool,
    damage: Vec<CapRect>,
    view: View,
    /// A one-window share's view, as the loop thread last moved it.
    window_view: Option<Arc<Mutex<View>>>,
    /// The source at its own size, read back before scaling; only when the view is scaled.
    full: Option<I420>,
}

/// Opens both halves of the X display `cfg.display`.
pub fn open(cfg: &SessionCfg) -> Res<Halves> {
    let damage = Capturer::new(&cfg.display, true)?;
    let cap = Capturer::with_region(&cfg.display)?;
    // x264 and 4:2:0 need even sizes; an odd last column or row is not sent.
    let screen = (cap.width, cap.height);
    let (view, window) = match cfg.window {
        // One window: its rect on screen, followed through moves.
        Some(id) => {
            damage.watch(id)?;
            let rect = damage.window_rect(id)?;
            let (followed, view) = Followed::start(id, rect, screen, cfg.max_width)?;
            eprintln!(
                "cmux-rd host: sharing window {id:#x} ({}x{} at {},{}), streamed {}x{}",
                rect.w, rect.h, rect.x, rect.y, view.out.0, view.out.1
            );
            let shared = Arc::new(Mutex::new(view));
            (view, Some(SharedWindow { id, followed, view: shared, hidden: false }))
        }
        None => {
            let listed = x11_view::listing(screen, &cap.monitors());
            let src = x11_view::pick(cfg.display_pick.as_deref(), &listed)?;
            (View::new(src, cfg.max_width), None)
        }
    };
    let window_view = window.as_ref().map(|w| w.view.clone());
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
        sharp_text: cfg.sharp_text,
    })?;
    let desktop = X11Desktop {
        injector: Injector::new(&cfg.display)?,
        damage: Vec::new(),
        window_events: Vec::new(),
        cap: damage,
        view,
        window,
    };
    let full = view.scaled().then(|| I420::new(view.src.w as usize, view.src.h as usize));
    let pic = I420::new(w as usize, h as usize);
    let frames =
        X11Frames { pic, cap, enc, whole: false, damage: Vec::new(), view, window_view, full };
    Ok((Box::new(desktop), Box::new(frames)))
}

impl X11Desktop {
    /// Applies what happened to the shared window: a move slides the view (and the whole
    /// picture is captured again), a resize or a destroy ends the session with the reason.
    fn follow_window(&mut self, out: &mut Vec<Rect>) -> Res<()> {
        let Some(win) = self.window.as_mut() else { return Ok(()) };
        let mut reread = false;
        for ev in self.window_events.drain(..) {
            match ev {
                WindowEvent::Destroyed(id) if id == win.id => {
                    return Err(format!("the shared window {id:#x} was closed").into());
                }
                WindowEvent::Unmapped(id) if id == win.id => win.hidden = true,
                WindowEvent::Changed(_) => reread = true,
                _ => {}
            }
        }
        if !reread {
            return Ok(());
        }
        let screen = (self.cap.width, self.cap.height);
        let now = self
            .cap
            .window_rect(win.id)
            .map_err(|e| format!("the shared window {:#x} is gone: {e}", win.id))?;
        let was_hidden = win.hidden;
        win.hidden = false;
        match win.followed.on_change(now, self.view.src, screen) {
            // Restacked or configured in place: damage covers what changed.
            Change::Same if !was_hidden => return Ok(()),
            Change::Same => {}
            Change::Moved(src) => {
                self.view.src = src;
                *win.view.lock().unwrap_or_else(|p| p.into_inner()) = self.view;
            }
            Change::Resized { from, to } => {
                return Err(format!(
                    "the shared window {:#x} was resized from {}x{} to {}x{}; share it again \
                     (a session's picture size is fixed when it starts)",
                    win.id, from.0, from.1, to.0, to.1
                )
                .into());
            }
        }
        // Moved or shown again: the whole picture is new.
        let (w, h) = self.view.out;
        out.push(Rect { x: 0, y: 0, width: w, height: h });
        Ok(())
    }
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
        self.window_events.clear();
        self.cap.drain(&mut self.damage, &mut self.window_events)?;
        if !self.window_events.is_empty() {
            self.follow_window(out)?;
            // Reading the window's rect waited on a reply; events that came meanwhile wait in
            // the connection's queue, where the descriptor no longer wakes the loop.
            self.cap.drain(&mut self.damage, &mut self.window_events)?;
            self.follow_window(out)?;
        }
        if self.window.as_ref().is_some_and(|w| w.hidden) {
            return Ok(());
        }
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
        if let Some(moved) = &self.window_view {
            // Same size, maybe a new origin (the window moved).
            let now = *moved.lock().unwrap_or_else(|p| p.into_inner());
            if now.src != self.view.src {
                // The kept picture shows the old place: read the whole window again.
                self.whole = false;
            }
            self.view = now;
        }
        let view = self.view;
        let (w, h) = view.out;
        // What changed since the last readback, taken from the server in one round trip: it
        // holds every change the loop thread's connection has already reported (the engine's
        // `damage` is one union box over the same changes). A change made after the take is
        // read back now (newer pixels) and taken again next frame. In the picture's
        // coordinates: clipped to the view, scaled when it is.
        self.damage.clear();
        self.cap.take_damage(&mut self.damage)?;
        let changed: Vec<CapRect> = self
            .damage
            .iter()
            .filter_map(|&r| view.clip(r))
            .map(|r| if view.scaled() { view.to_out(r) } else { r })
            .collect();
        let gate = CapRect { x: damage.x, y: damage.y, w: damage.width, h: damage.height };
        let plan = if !self.whole {
            self.whole = true;
            vec![CapRect { x: 0, y: 0, w, h }]
        } else if changed.is_empty() {
            // A forced frame (keyframe, a dropped frame's requeue) with nothing new.
            vec![gate]
        } else {
            readback_plan(&changed, w, h)
        };
        for r in plan {
            self.read_rect(r.align_even(w, h))?;
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

    fn constrained_baseline(&self) -> bool {
        self.enc.constrained_baseline()
    }

    fn idr_cause(&self) -> Option<&'static str> {
        self.enc.idr_cause()
    }
}

impl X11Frames {
    /// Reads back the picture's rect `r` (even, in the picture's coordinates) into `pic`.
    fn read_rect(&mut self, r: CapRect) -> Res<()> {
        let view = self.view;
        let (w, h) = view.out;
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
}
