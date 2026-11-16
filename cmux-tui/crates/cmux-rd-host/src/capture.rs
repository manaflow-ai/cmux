//! Screen capture: XShm GetImage on the root window, driven by XDamage raw rectangles.

use crate::shm::ShmSeg;
use crate::Res;
use std::os::fd::{AsRawFd, RawFd};
use x11rb::connection::Connection;
use x11rb::protocol::damage::{ConnectionExt as _, ReportLevel};
use x11rb::protocol::shm::ConnectionExt as _;
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

/// One damage report.
pub struct DamageEvent {
    pub rect: Rect,
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
    ShmSeg::new(conn, len)
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
}

impl Capturer {
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
        })
    }

    pub fn fd(&self) -> RawFd {
        self.conn.stream().as_raw_fd()
    }

    /// Drains every queued X event without blocking; returns damage reports.
    pub fn drain(&self, out: &mut Vec<DamageEvent>) -> Res<()> {
        while let Some(ev) = self.conn.poll_for_event()? {
            if let Event::DamageNotify(d) = ev {
                let a = d.area;
                let rect = Rect {
                    x: a.x.max(0) as u32,
                    y: a.y.max(0) as u32,
                    w: u32::from(a.width),
                    h: u32::from(a.height),
                };
                out.push(DamageEvent { rect });
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
        if let Some(shm) = self.shm.as_ref() {
            self.conn.shm_get_image(self.root, x, y, w, h, !0, fmt.into(), shm.seg, 0)?.reply()?;
            return Ok(&shm.as_slice()[..len]);
        }
        let reply = self.conn.get_image(fmt, self.root, x, y, w, h, !0)?.reply()?;
        if reply.data.len() < len {
            return Err(format!("GetImage returned {} bytes, want {len}", reply.data.len()).into());
        }
        self.core = reply.data;
        Ok(&self.core[..len])
    }
}
