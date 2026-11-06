//! X11 pixels.
//!
//! A display shot reads the root window. A window shot reads the window's
//! own pixels even when it is covered: from the compositing manager's
//! pixmap of its frame when one runs, else by asking the server to keep the
//! frame's contents off screen (Composite automatic redirection, which shows
//! nothing different to the person) and reading that. An uncovered window
//! with no Composite extension is read straight from the screen; a covered
//! one is then refused, since the screen holds other windows' pixels there.

use std::collections::HashSet;
use std::sync::Mutex;

use x11rb::connection::{Connection as _, RequestConnection as _};
use x11rb::protocol::composite::{ConnectionExt as _, Redirect};
use x11rb::protocol::xproto::{ConnectionExt as _, Drawable, ImageFormat, ImageOrder};

use super::{Client, X11Desktop, xerr};
use crate::desktop::*;

/// Frames this process redirected (kept for the process lifetime; the
/// server undoes it when the connection closes).
static REDIRECTED: Mutex<Option<HashSet<u32>>> = Mutex::new(None);

impl X11Desktop {
    pub(crate) fn capture_display(&self, name: Option<&str>) -> DResult<RawFrame> {
        let monitors = self.monitors();
        let rect = match name {
            Some(n) => monitors
                .iter()
                .find(|m| m.name == n)
                .map(|m| m.rect)
                .ok_or_else(|| {
                    let names: Vec<&str> = monitors.iter().map(|m| m.name.as_str()).collect();
                    DesktopError::TargetNotFound(format!("display {n:?}; displays: {names:?}"))
                })?,
            None => monitors
                .iter()
                .find(|m| m.primary)
                .or(monitors.first())
                .map(|m| m.rect)
                .unwrap_or_else(|| self.root_rect()),
        };
        let (rgba, w, h) = self.read(self.root, rect.x as i16, rect.y as i16, rect.width as u16, rect.height as u16)?;
        Ok(RawFrame { width: w, height: h, rgba, scale: 1.0, origin: Point { x: rect.x, y: rect.y } })
    }

    fn root_rect(&self) -> Rect {
        let s = &self.conn.setup().roots[0];
        Rect { x: 0.0, y: 0.0, width: f64::from(s.width_in_pixels), height: f64::from(s.height_in_pixels) }
    }

    pub(crate) fn capture_window(&self, c: &Client) -> DResult<RawFrame> {
        if !c.viewable || c.hidden {
            return Err(DesktopError::Unsupported(
                "the window is minimized or not mapped, so X11 holds no pixels for it".into(),
            ));
        }
        if self.compositor_running() || (self.has_composite && self.covered(c)) {
            return self.capture_offscreen(c);
        }
        if self.covered(c) {
            return Err(DesktopError::Unsupported(
                "the window is covered and this X server has no Composite extension; take a display screenshot".into(),
            ));
        }
        let root = self.root_rect();
        let r = clip(&c.rect, &root).ok_or_else(|| DesktopError::Unsupported("the window is off screen".into()))?;
        let (rgba, w, h) = self.read(self.root, r.x as i16, r.y as i16, r.width as u16, r.height as u16)?;
        Ok(RawFrame { width: w, height: h, rgba, scale: 1.0, origin: Point { x: r.x, y: r.y } })
    }

    fn compositor_running(&self) -> bool {
        self.conn
            .get_selection_owner(self.atoms.net_wm_cm_s0)
            .ok()
            .and_then(|c| c.reply().ok())
            .is_some_and(|r| r.owner != 0)
    }

    /// True when a mapped root child above the window's frame overlaps it.
    pub(crate) fn covered(&self, c: &Client) -> bool {
        let Ok(Ok(tree)) = self.conn.query_tree(self.root).map(|q| q.reply()) else { return true };
        let Some(pos) = tree.children.iter().position(|w| *w == c.frame_win) else { return true };
        tree.children[pos + 1..]
            .iter()
            .any(|w| self.stacks(*w) && self.rect_of(*w).is_some_and(|r| r.intersects(&c.rect)))
    }

    /// The window's pixels from its frame's off-screen pixmap.
    fn capture_offscreen(&self, c: &Client) -> DResult<RawFrame> {
        if !self.compositor_running() {
            let mut g = REDIRECTED.lock().unwrap_or_else(|e| e.into_inner());
            let set = g.get_or_insert_with(HashSet::new);
            if set.insert(c.frame_win) {
                self.conn.composite_redirect_window(c.frame_win, Redirect::AUTOMATIC).map_err(xerr)?;
                // A round trip so the server allocated the pixmap and
                // exposed the covered parts before we read it.
                self.conn.get_input_focus().map_err(xerr)?.reply().map_err(xerr)?;
            }
        }
        let pixmap = self.conn.generate_id().map_err(xerr)?;
        self.conn.composite_name_window_pixmap(c.frame_win, pixmap).map_err(xerr)?;
        let frame = self.rect_of(c.frame_win).ok_or_else(|| DesktopError::TargetNotFound("the window is gone".into()))?;
        // The frame's border is outside its geometry; the pixmap includes it.
        let border = self
            .conn
            .get_geometry(c.frame_win)
            .ok()
            .and_then(|q| q.reply().ok())
            .map(|g| f64::from(g.border_width))
            .unwrap_or(0.0);
        let (ox, oy) = (c.rect.x - frame.x + border, c.rect.y - frame.y + border);
        let read = self.read(pixmap, ox as i16, oy as i16, c.rect.width as u16, c.rect.height as u16);
        let _ = self.conn.free_pixmap(pixmap);
        let (rgba, w, h) = read?;
        Ok(RawFrame { width: w, height: h, rgba, scale: 1.0, origin: Point { x: c.rect.x, y: c.rect.y } })
    }

    /// Reads a rectangle of a drawable as RGBA, in bands so one request
    /// stays under the server's maximum request size.
    fn read(&self, d: Drawable, x: i16, y: i16, w: u16, h: u16) -> DResult<(Vec<u8>, u32, u32)> {
        if w == 0 || h == 0 {
            return Err(DesktopError::Unsupported("the area is empty".into()));
        }
        if self.conn.setup().image_byte_order != ImageOrder::LSB_FIRST {
            return Err(DesktopError::Unsupported("big-endian X servers are not supported".into()));
        }
        let max_bytes = (self.conn.maximum_request_bytes().max(1 << 18)) as u64;
        let band = ((max_bytes / 2) / (u64::from(w) * 4)).clamp(1, u64::from(h)) as u16;
        let mut rgba = Vec::with_capacity(usize::from(w) * usize::from(h) * 4);
        let mut row = 0u16;
        while row < h {
            let rows = band.min(h - row);
            let img = self
                .conn
                .get_image(ImageFormat::Z_PIXMAP, d, x, y + row as i16, w, rows, !0)
                .map_err(xerr)?
                .reply()
                .map_err(xerr)?;
            let bpp = self.bits_per_pixel(img.depth);
            convert(&img.data, img.depth, bpp, w, rows, self.scanline_pad(img.depth), &mut rgba)?;
            row += rows;
        }
        Ok((rgba, u32::from(w), u32::from(h)))
    }

    fn bits_per_pixel(&self, depth: u8) -> u8 {
        self.conn.setup().pixmap_formats.iter().find(|f| f.depth == depth).map(|f| f.bits_per_pixel).unwrap_or(32)
    }

    fn scanline_pad(&self, depth: u8) -> u8 {
        self.conn.setup().pixmap_formats.iter().find(|f| f.depth == depth).map(|f| f.scanline_pad).unwrap_or(32)
    }
}

fn clip(r: &Rect, bounds: &Rect) -> Option<Rect> {
    let x0 = r.x.max(bounds.x);
    let y0 = r.y.max(bounds.y);
    let x1 = (r.x + r.width).min(bounds.x + bounds.width);
    let y1 = (r.y + r.height).min(bounds.y + bounds.height);
    if x1 <= x0 || y1 <= y0 { None } else { Some(Rect { x: x0, y: y0, width: x1 - x0, height: y1 - y0 }) }
}

/// ZPixmap (LSB first) to RGBA8, opaque.
pub(crate) fn convert(data: &[u8], depth: u8, bpp: u8, w: u16, h: u16, pad: u8, out: &mut Vec<u8>) -> DResult<()> {
    let pad_bytes = usize::from(pad.max(8) / 8);
    let row_bytes = (usize::from(w) * usize::from(bpp)).div_ceil(8).div_ceil(pad_bytes) * pad_bytes;
    if data.len() < row_bytes * usize::from(h) {
        return Err(DesktopError::Failed("X11 returned a short image".into()));
    }
    for y in 0..usize::from(h) {
        let line = &data[y * row_bytes..];
        for x in 0..usize::from(w) {
            match (depth, bpp) {
                (24 | 32, 32) => {
                    let p = &line[x * 4..x * 4 + 4];
                    out.extend_from_slice(&[p[2], p[1], p[0], 255]);
                }
                (16, 16) => {
                    let v = u16::from_le_bytes([line[x * 2], line[x * 2 + 1]]);
                    let r = ((v >> 11) & 0x1f) as u8;
                    let g = ((v >> 5) & 0x3f) as u8;
                    let b = (v & 0x1f) as u8;
                    out.extend_from_slice(&[(r << 3) | (r >> 2), (g << 2) | (g >> 4), (b << 3) | (b >> 2), 255]);
                }
                _ => {
                    return Err(DesktopError::Unsupported(format!("X11 depth {depth} at {bpp} bits per pixel")));
                }
            }
        }
    }
    Ok(())
}
