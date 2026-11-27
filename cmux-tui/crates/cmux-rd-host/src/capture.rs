//! Screen capture: XShm GetImage on the root window, driven by XDamage raw rectangles.

use crate::shm::{ServerAccess, ShmSeg};
use crate::Res;
use std::os::fd::{AsRawFd, RawFd};
use x11rb::connection::Connection;
use x11rb::protocol::damage::{ConnectionExt as _, Damage, ReportLevel};
use x11rb::protocol::xfixes::{ConnectionExt as _, Region};
use x11rb::protocol::xproto::{ConnectionExt as _, ImageFormat, Window};
use x11rb::protocol::Event;
use x11rb::rust_connection::RustConnection;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Rect {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

impl Rect {
    /// Grows the rect to even coordinates and sizes (4:2:0 chroma), clamped to the screen.
    pub fn align_even(self, sw: u32, sh: u32) -> Rect {
        let x0 = self.x & !1;
        let y0 = self.y & !1;
        let x1 = ((self.x + self.w + 1) & !1).min(sw);
        let y1 = ((self.y + self.h + 1) & !1).min(sh);
        Rect { x: x0, y: y0, w: x1.saturating_sub(x0), h: y1.saturating_sub(y0) }
    }
}

/// At most this many rects are read back one by one; more fall back to their bounding box.
const MAX_RECTS: usize = 16;

/// What to read back for one frame: the rects the X server reported since the last readback,
/// each even-aligned and clipped to `sw`x`sh`, or their bounding box when the pieces are many or
/// cover most of it (a readback has a per-request cost, so near-full boxes go as one). Two small
/// changes at opposite corners are two small readbacks, not the whole screen between them (the
/// engine's gate hands the frame source one union rect, which this replaces).
pub fn readback_plan(damage: &[Rect], sw: u32, sh: u32) -> Vec<Rect> {
    let rects: Vec<Rect> =
        damage.iter().map(|r| r.align_even(sw, sh)).filter(|r| r.w > 0 && r.h > 0).collect();
    let Some(&first) = rects.first() else { return Vec::new() };
    let bbox = rects.iter().skip(1).fold(first, |a, b| {
        let (x1, y1) = ((a.x + a.w).max(b.x + b.w), (a.y + a.h).max(b.y + b.h));
        let (x0, y0) = (a.x.min(b.x), a.y.min(b.y));
        Rect { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }
    });
    let area = |r: &Rect| u64::from(r.w) * u64::from(r.h);
    let pieces: u64 = rects.iter().map(area).sum();
    if rects.len() > MAX_RECTS || pieces * 2 >= area(&bbox) {
        return vec![bbox];
    }
    rects
}

/// One damage report.
pub struct DamageEvent {
    pub rect: Rect,
}

/// What happened to a window a [`Capturer`] watches ([`Capturer::watch`]).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WindowEvent {
    /// Moved, resized, reparented or mapped: read its rect again.
    Changed(Window),
    Unmapped(Window),
    Destroyed(Window),
}

/// How pixels come back from the X server.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Readback {
    /// MIT-SHM into a segment both sides map: 0.96 ms p50 to capture and convert a 1080p
    /// frame on a local Xvfb (fleet Linux pool, cmux#44552).
    Shm,
    /// The core protocol's GetImage, every pixel through the X socket: 2.14 ms for the same
    /// frame on the same Xvfb, and more on a busy or remote server. Only when the server
    /// refuses a shared segment (a display over TCP, no MIT-SHM, a sandbox that blocks memfd).
    Core,
}

impl Readback {
    /// The host status's `capture_backend` word.
    pub fn name(self) -> &'static str {
        match self {
            Readback::Shm => "xshm",
            Readback::Core => "getimage",
        }
    }
}

/// Whether the X server on `conn` takes a shared segment; `Err` says why not.
pub fn shm_works(conn: &RustConnection, len: usize) -> Res<ShmSeg> {
    ShmSeg::new(conn, len, ServerAccess::ReadWrite)
}

/// What the capture logs once when XShm is refused.
pub fn core_fallback_warning(display: &str, why: &dyn std::fmt::Display) -> String {
    format!(
        "cmux-rd: warning: XShm refused on {display} ({why}); capturing with core GetImage, \
         which copies every pixel through the X socket (2.2x the capture time on a local \
         Xvfb at 1080p, more on a busy or remote server). Run the host on the display's own \
         machine with MIT-SHM enabled."
    )
}

pub struct Capturer {
    conn: RustConnection,
    root: Window,
    display: String,
    pub width: u32,
    pub height: u32,
    /// Made at the first grab: a damage-only connection never reads pixels back.
    shm: Option<ShmSeg>,
    /// Set at the first grab.
    readback: Option<Readback>,
    /// Core GetImage's copy of the last rect.
    core: Vec<u8>,
    /// With [`Capturer::with_region`]: the damage object that accumulates the root's changes
    /// in the server, and the XFixes region [`Capturer::take_damage`] moves them into.
    region: Option<(Damage, Region)>,
}

impl Capturer {
    /// Opens a pixel connection whose damage the server keeps as one region (`NON_EMPTY`: at
    /// most one event between takes), so nothing queues while frames are not being captured,
    /// and [`Capturer::take_damage`] returns every change made before it was called.
    pub fn with_region(display: &str) -> Res<Self> {
        let mut this = Self::new(display, false)?;
        this.conn.xfixes_query_version(5, 0)?.reply()?;
        this.conn.damage_query_version(1, 1)?.reply()?;
        let damage = this.conn.generate_id()?;
        this.conn.damage_create(damage, this.root, ReportLevel::NON_EMPTY)?.check()?;
        let region = this.conn.generate_id()?;
        this.conn.xfixes_create_region(region, &[])?.check()?;
        this.region = Some((damage, region));
        Ok(this)
    }

    /// Every rect the root changed in since the last take, and clears it. A round trip, so a
    /// change the server applied before this request (any change another connection has
    /// already seen) is in it. Empty without [`Capturer::with_region`].
    pub fn take_damage(&mut self, out: &mut Vec<Rect>) -> Res<()> {
        let Some((damage, region)) = self.region else { return Ok(()) };
        self.conn.damage_subtract(damage, x11rb::NONE, region)?;
        let reply = self.conn.xfixes_fetch_region(region)?.reply()?;
        // The NON_EMPTY notifications only say "something changed"; the region holds what.
        while self.conn.poll_for_event()?.is_some() {}
        out.extend(reply.rectangles.iter().map(|a| Rect {
            x: a.x.max(0) as u32,
            y: a.y.max(0) as u32,
            w: u32::from(a.width),
            h: u32::from(a.height),
        }));
        Ok(())
    }

    /// Opens a capture connection. With `damage`, subscribes to raw damage rectangles on the root.
    pub fn new(display: &str, damage: bool) -> Res<Self> {
        let (conn, screen_num) = x11rb::connect(Some(display))?;
        let screen = conn.setup().roots[screen_num].clone();
        if screen.root_depth != 24 {
            return Err(
                format!("root depth {} unsupported (need 24, 32 bpp)", screen.root_depth).into()
            );
        }
        let (width, height) =
            (u32::from(screen.width_in_pixels), u32::from(screen.height_in_pixels));
        if damage {
            conn.damage_query_version(1, 1)?.reply()?;
            let id = conn.generate_id()?;
            conn.damage_create(id, screen.root, ReportLevel::RAW_RECTANGLES)?.check()?;
        }
        Ok(Self {
            conn,
            root: screen.root,
            display: display.to_owned(),
            width,
            height,
            shm: None,
            readback: None,
            core: Vec::new(),
            region: None,
        })
    }

    /// The X screen's monitors (RandR), left to right; empty without RandR 1.5.
    pub fn monitors(&self) -> Vec<Rect> {
        crate::x11_view::monitors(&self.conn, self.root, (self.width, self.height))
    }

    pub fn fd(&self) -> RawFd {
        self.conn.stream().as_raw_fd()
    }

    /// `window`'s rect in root coordinates; Err when it does not exist.
    pub fn window_rect(&self, window: Window) -> Res<crate::x11_window::WinRect> {
        crate::x11_window::rect(&self.conn, self.root, window)
    }

    /// Reports `window`'s structure changes (and its window manager frame's) through
    /// [`Capturer::drain`]. Only this connection's own event mask changes.
    pub fn watch(&self, window: Window) -> Res<()> {
        use x11rb::protocol::xproto::{ChangeWindowAttributesAux, EventMask};
        let aux = ChangeWindowAttributesAux::new().event_mask(EventMask::STRUCTURE_NOTIFY);
        self.conn
            .change_window_attributes(window, &aux)?
            .check()
            .map_err(|e| format!("window {window:#x} is not on this X display: {e}"))?;
        let frame = crate::x11_window::frame(&self.conn, self.root, window)?;
        if frame != window {
            self.conn.change_window_attributes(frame, &aux)?.check()?;
        }
        Ok(())
    }

    /// Drains every queued X event without blocking; returns damage reports, and in `windows`
    /// what happened to watched windows.
    pub fn drain(&self, out: &mut Vec<DamageEvent>, windows: &mut Vec<WindowEvent>) -> Res<()> {
        while let Some(ev) = self.conn.poll_for_event()? {
            match ev {
                Event::DamageNotify(d) => {
                    let a = d.area;
                    let rect = Rect {
                        x: a.x.max(0) as u32,
                        y: a.y.max(0) as u32,
                        w: u32::from(a.width),
                        h: u32::from(a.height),
                    };
                    out.push(DamageEvent { rect });
                }
                Event::ConfigureNotify(e) => windows.push(WindowEvent::Changed(e.window)),
                Event::ReparentNotify(e) => windows.push(WindowEvent::Changed(e.window)),
                Event::MapNotify(e) => windows.push(WindowEvent::Changed(e.window)),
                Event::UnmapNotify(e) => windows.push(WindowEvent::Unmapped(e.window)),
                Event::DestroyNotify(e) => windows.push(WindowEvent::Destroyed(e.window)),
                _ => {}
            }
        }
        Ok(())
    }

    /// Reads back `r` (even-aligned); returns BGRX rows with stride `r.w * 4`. The first grab
    /// picks the readback: XShm, else core GetImage with a warning on stderr.
    pub fn grab(&mut self, r: Rect) -> Res<&[u8]> {
        if self.readback.is_none() {
            let len = self.width as usize * self.height as usize * 4;
            self.readback = Some(match shm_works(&self.conn, len) {
                Ok(seg) => {
                    self.shm = Some(seg);
                    Readback::Shm
                }
                Err(e) => {
                    eprintln!("{}", core_fallback_warning(&self.display, &e));
                    Readback::Core
                }
            });
        }
        let len = (r.w * r.h * 4) as usize;
        let fmt = ImageFormat::Z_PIXMAP;
        let (x, y, w, h) = (r.x as i16, r.y as i16, r.w as u16, r.h as u16);
        if let Some(shm) = self.shm.as_mut() {
            return shm.get_image(&self.conn, self.root, (x, y), (w, h));
        }
        let reply = self.conn.get_image(fmt, self.root, x, y, w, h, !0)?.reply()?;
        if reply.data.len() < len {
            return Err(format!("GetImage returned {} bytes, want {len}", reply.data.len()).into());
        }
        self.core = reply.data;
        Ok(&self.core[..len])
    }
}

#[cfg(test)]
#[path = "capture_tests.rs"]
mod tests;
