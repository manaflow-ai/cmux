//! The X11 agent cursor: override-redirect, ARGB when the server has a
//! 32-bit TrueColor visual, an empty input shape (every pointer event goes
//! to the window below), and a bounding shape of the arrow when there is no
//! compositor to blend the alpha.

use std::sync::Arc;

use x11rb::connection::{Connection as _, RequestConnection as _};
use x11rb::protocol::shape::{self, ConnectionExt as _};
use x11rb::protocol::xproto::{
    ClipOrdering, ColormapAlloc, ConfigureWindowAux, ConnectionExt as _, CreateGCAux,
    CreateWindowAux, ImageFormat, Rectangle, StackMode, VisualClass, Window, WindowClass,
};
use x11rb::rust_connection::RustConnection;
use x11rb::wrapper::ConnectionExt as _;

use super::{Channel, Overlay, SIZE, arrow, channel, run};
use crate::cursor::CursorSink;
use crate::desktop::Point;

struct XOverlay {
    conn: RustConnection,
    win: Window,
    mapped: bool,
}

pub fn spawn() -> Option<Arc<dyn CursorSink>> {
    let overlay = XOverlay::create().ok()?;
    let (tx, rx) = channel();
    std::thread::Builder::new()
        .name("cmux-cu-cursor".into())
        .spawn(move || run(overlay, rx))
        .ok()?;
    Some(Arc::new(Channel(tx)))
}

impl XOverlay {
    fn create() -> Result<Self, Box<dyn std::error::Error>> {
        let (conn, screen_num) = x11rb::connect(None)?;
        conn.extension_information(shape::X11_EXTENSION_NAME)?.ok_or("no SHAPE extension")?;
        let screen = conn.setup().roots[screen_num].clone();
        let argb = screen
            .allowed_depths
            .iter()
            .filter(|d| d.depth == 32)
            .flat_map(|d| d.visuals.iter())
            .find(|v| v.class == VisualClass::TRUE_COLOR)
            .map(|v| v.visual_id);
        let (depth, visual, colormap) = match argb {
            Some(v) => {
                let cmap = conn.generate_id()?;
                conn.create_colormap(ColormapAlloc::NONE, cmap, screen.root, v)?;
                (32u8, v, cmap)
            }
            None => (screen.root_depth, screen.root_visual, screen.default_colormap),
        };
        let win = conn.generate_id()?;
        let aux = CreateWindowAux::new()
            .override_redirect(1)
            .background_pixel(0)
            .border_pixel(0)
            .colormap(colormap);
        conn.create_window(
            depth,
            win,
            screen.root,
            -100,
            -100,
            SIZE as u16,
            SIZE as u16,
            0,
            WindowClass::INPUT_OUTPUT,
            visual,
            &aux,
        )?;
        // Marks it, so the backend never takes it for a window covering a target.
        let marker =
            conn.intern_atom(false, super::super::x11::OVERLAY_ATOM.as_bytes())?.reply()?.atom;
        conn.change_property8(
            x11rb::protocol::xproto::PropMode::REPLACE,
            win,
            marker,
            x11rb::protocol::xproto::AtomEnum::STRING,
            b"1",
        )?;
        // Click-through: an empty input region.
        conn.shape_rectangles(
            shape::SO::SET,
            shape::SK::INPUT,
            ClipOrdering::UNSORTED,
            win,
            0,
            0,
            &[],
        )?;
        let (pixels, mask) = arrow();
        if argb.is_none() {
            // No alpha: cut the window to the arrow's shape.
            let rects: Vec<Rectangle> = mask
                .iter()
                .enumerate()
                .filter(|(_, on)| **on)
                .map(|(i, _)| Rectangle {
                    x: (i as u32 % SIZE) as i16,
                    y: (i as u32 / SIZE) as i16,
                    width: 1,
                    height: 1,
                })
                .collect();
            conn.shape_rectangles(
                shape::SO::SET,
                shape::SK::BOUNDING,
                ClipOrdering::UNSORTED,
                win,
                0,
                0,
                &rects,
            )?;
        }
        let pixmap = conn.generate_id()?;
        conn.create_pixmap(depth, pixmap, win, SIZE as u16, SIZE as u16)?;
        let gc = conn.generate_id()?;
        conn.create_gc(gc, pixmap, &CreateGCAux::new())?;
        let data: Vec<u8> = if depth >= 24 { pixels } else { to_depth16(&pixels) };
        conn.put_image(
            ImageFormat::Z_PIXMAP,
            pixmap,
            gc,
            SIZE as u16,
            SIZE as u16,
            0,
            0,
            0,
            depth,
            &data,
        )?;
        conn.change_window_attributes(
            win,
            &x11rb::protocol::xproto::ChangeWindowAttributesAux::new().background_pixmap(pixmap),
        )?;
        conn.free_gc(gc)?;
        conn.flush()?;
        Ok(Self { conn, win, mapped: false })
    }
}

fn to_depth16(bgra: &[u8]) -> Vec<u8> {
    bgra.chunks_exact(4)
        .flat_map(|p| {
            let v =
                (u16::from(p[2] >> 3) << 11) | (u16::from(p[1] >> 2) << 5) | u16::from(p[0] >> 3);
            v.to_le_bytes()
        })
        .collect()
}

impl Overlay for XOverlay {
    fn show_at(&mut self, p: Point) {
        // The arrow's tip is at (1,1).
        let aux = ConfigureWindowAux::new()
            .x((p.x - 1.0) as i32)
            .y((p.y - 1.0) as i32)
            .stack_mode(StackMode::ABOVE);
        let _ = self.conn.configure_window(self.win, &aux);
        if !self.mapped {
            let _ = self.conn.map_window(self.win);
            self.mapped = true;
        }
        let _ = self.conn.flush();
    }

    fn hide(&mut self) {
        if self.mapped {
            let _ = self.conn.unmap_window(self.win);
            let _ = self.conn.flush();
            self.mapped = false;
        }
    }
}
