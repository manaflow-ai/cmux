//! Screen capture: XShm GetImage on the root window, driven by XDamage raw rectangles.

use crate::shm::ShmSeg;
use crate::Res;
use std::os::fd::{AsRawFd, RawFd};
use x11rb::connection::Connection;
use x11rb::protocol::damage::{ConnectionExt as _, ReportLevel};
use x11rb::protocol::shm::ConnectionExt as _;
use x11rb::protocol::xproto::{ImageFormat, Window};
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

pub struct Capturer {
    conn: RustConnection,
    root: Window,
    pub width: u32,
    pub height: u32,
    shm: ShmSeg,
}

impl Capturer {
    /// Opens a capture connection. With `damage`, subscribes to raw damage rectangles on the root.
    pub fn new(display: &str, damage: bool) -> Res<Self> {
        let (conn, screen_num) = x11rb::connect(Some(display))?;
        let screen = conn.setup().roots[screen_num].clone();
        if screen.root_depth != 24 {
            return Err(format!("root depth {} unsupported (need 24, 32 bpp)", screen.root_depth).into());
        }
        let (width, height) = (u32::from(screen.width_in_pixels), u32::from(screen.height_in_pixels));
        let shm = ShmSeg::new(&conn, (width * height * 4) as usize)?;
        if damage {
            conn.damage_query_version(1, 1)?.reply()?;
            let id = conn.generate_id()?;
            conn.damage_create(id, screen.root, ReportLevel::RAW_RECTANGLES)?.check()?;
        }
        Ok(Self { conn, root: screen.root, width, height, shm })
    }

    pub fn fd(&self) -> RawFd {
        self.conn.stream().as_raw_fd()
    }

    /// Drains every queued X event without blocking; returns damage reports.
    pub fn drain(&self, out: &mut Vec<DamageEvent>) -> Res<()> {
        while let Some(ev) = self.conn.poll_for_event()? {
            if let Event::DamageNotify(d) = ev {
                let a = d.area;
                let rect = Rect { x: a.x.max(0) as u32, y: a.y.max(0) as u32, w: u32::from(a.width), h: u32::from(a.height) };
                out.push(DamageEvent { rect });
            }
        }
        Ok(())
    }

    /// Reads back `r` (even-aligned) into the shared segment; returns BGRX rows with stride `r.w * 4`.
    pub fn grab(&mut self, r: Rect) -> Res<&[u8]> {
        let fmt = u8::from(ImageFormat::Z_PIXMAP);
        self.conn
            .shm_get_image(self.root, r.x as i16, r.y as i16, r.w as u16, r.h as u16, !0, fmt, self.shm.seg, 0)?
            .reply()?;
        Ok(&self.shm.as_slice()[..(r.w * r.h * 4) as usize])
    }
}
