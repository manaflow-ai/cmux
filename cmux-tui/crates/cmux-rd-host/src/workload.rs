//! Workload drawing for the test app (core X requests plus one SHM image for `motion`).

use crate::clock::Rng;
use crate::marker;
use crate::shm::ShmSeg;
use crate::Res;
use x11rb::connection::Connection;
use x11rb::protocol::shm::ConnectionExt as _;
use x11rb::protocol::xproto::{
    ConnectionExt as _, CreateGCAux, Gcontext, ImageFormat, Rectangle, Screen, Window,
};

pub const GRAY: u32 = 0x80_80_80;
const WHITE: u32 = 0xff_ff_ff;
const BLACK: u32 = 0x00_00_00;
const TEXT_TICK_NS: u64 = 33_000_000;
const MOTION_TICK_NS: u64 = 16_666_667;

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Kind {
    Marker,
    Text,
    Motion,
    Idle,
}

impl Kind {
    pub fn parse(s: &str) -> Res<Self> {
        Ok(match s {
            "marker" => Self::Marker,
            "text" => Self::Text,
            "motion" => Self::Motion,
            "idle" => Self::Idle,
            _ => return Err(format!("unknown workload {s}").into()),
        })
    }

    pub fn name(self) -> &'static str {
        match self {
            Self::Marker => "marker",
            Self::Text => "text",
            Self::Motion => "motion",
            Self::Idle => "idle",
        }
    }
}

struct TextState {
    gc: Gcontext,
    line_h: u16,
    ascent: i16,
    char_w: usize,
    cols: usize,
    rng: Rng,
}

struct MotionState {
    shm: ShmSeg,
    noise: Vec<u8>,
    frame: u32,
}

pub struct Painter<'c, C: Connection> {
    conn: &'c C,
    win: Window,
    depth: u8,
    w: u16,
    h: u16,
    kind: Kind,
    white: Gcontext,
    black: Gcontext,
    gray: Gcontext,
    text: Option<TextState>,
    motion: Option<MotionState>,
}

fn solid_gc(conn: &impl Connection, win: Window, pixel: u32) -> Res<Gcontext> {
    let gc = conn.generate_id()?;
    conn.create_gc(gc, win, &CreateGCAux::new().foreground(pixel).graphics_exposures(0))?;
    Ok(gc)
}

impl<'c, C: Connection> Painter<'c, C> {
    pub fn new(conn: &'c C, screen: &Screen, win: Window, kind: Kind) -> Res<Self> {
        let (w, h) = (screen.width_in_pixels, screen.height_in_pixels);
        let text = if kind == Kind::Text {
            let font = conn.generate_id()?;
            conn.open_font(font, b"fixed")?;
            let q = conn.query_font(font)?.reply()?;
            let gc = conn.generate_id()?;
            let aux = CreateGCAux::new()
                .foreground(BLACK)
                .background(WHITE)
                .font(font)
                .graphics_exposures(0);
            conn.create_gc(gc, win, &aux)?;
            let char_w = q.max_bounds.character_width.max(1) as usize;
            Some(TextState {
                gc,
                line_h: (q.font_ascent + q.font_descent) as u16,
                ascent: q.font_ascent,
                char_w,
                cols: w as usize / char_w + 1,
                rng: Rng::new(0x5eed_7e47),
            })
        } else {
            None
        };
        let motion = if kind == Kind::Motion {
            let shm = ShmSeg::new(conn, w as usize * h as usize * 4)?;
            let mut rng = Rng::new(0x0dd_ba11);
            let noise = (0..1024 * 1024).map(|_| (rng.next_u64() >> 56) as u8).collect();
            Some(MotionState { shm, noise, frame: 0 })
        } else {
            None
        };
        Ok(Self {
            conn,
            win,
            depth: screen.root_depth,
            w,
            h,
            kind,
            white: solid_gc(conn, win, WHITE)?,
            black: solid_gc(conn, win, BLACK)?,
            gray: solid_gc(conn, win, GRAY)?,
            text,
            motion,
        })
    }

    pub fn interval_ns(&self) -> Option<u64> {
        match self.kind {
            Kind::Text => Some(TEXT_TICK_NS),
            Kind::Motion => Some(MOTION_TICK_NS),
            Kind::Marker | Kind::Idle => None,
        }
    }

    fn full_rect(&self) -> Rectangle {
        Rectangle { x: 0, y: 0, width: self.w, height: self.h }
    }

    pub fn full_redraw(&mut self, counter: u32) -> Res<()> {
        match self.kind {
            Kind::Marker | Kind::Idle => {
                self.conn.poly_fill_rectangle(self.win, self.gray, &[self.full_rect()])?;
            }
            Kind::Text => {
                self.conn.poly_fill_rectangle(self.win, self.white, &[self.full_rect()])?;
                let lines = self.h / self.text.as_ref().map_or(1, |t| t.line_h.max(1));
                for i in 0..lines {
                    self.text_line(i)?;
                }
            }
            Kind::Motion => return self.motion_frame(counter),
        }
        self.marker(counter)
    }

    /// Draws the marker cells for `counter` (two fill requests).
    pub fn marker(&self, counter: u32) -> Res<()> {
        let (mut white, mut black) = (Vec::new(), Vec::new());
        for (i, on) in marker::cells(counter).iter().enumerate() {
            let r = Rectangle {
                x: (i as u32 * marker::CELL) as i16,
                y: 0,
                width: marker::CELL as u16,
                height: marker::CELL as u16,
            };
            if *on {
                white.push(r)
            } else {
                black.push(r)
            }
        }
        self.conn.poly_fill_rectangle(self.win, self.white, &white)?;
        self.conn.poly_fill_rectangle(self.win, self.black, &black)?;
        Ok(())
    }

    pub fn tick(&mut self, counter: u32) -> Res<()> {
        match self.kind {
            Kind::Text => {
                let line_h = self.text.as_ref().map_or(13, |t| t.line_h);
                let rows = self.h / line_h;
                // Scroll up one line, as a terminal does, then draw the new bottom line.
                self.conn.copy_area(
                    self.win,
                    self.win,
                    self.white,
                    0,
                    line_h as i16,
                    0,
                    0,
                    self.w,
                    (rows - 1) * line_h,
                )?;
                self.text_line(rows - 1)?;
                self.marker(counter)
            }
            Kind::Motion => self.motion_frame(counter),
            Kind::Marker | Kind::Idle => Ok(()),
        }
    }

    fn text_line(&mut self, row: u16) -> Res<()> {
        let Some(t) = self.text.as_mut() else { return Ok(()) };
        let mut line = Vec::with_capacity(t.cols);
        while line.len() < t.cols {
            let len = t.rng.range(2, 9) as usize;
            for _ in 0..len {
                line.push(b'a' + t.rng.range(0, 25) as u8);
            }
            line.push(b' ');
        }
        line.truncate(t.cols);
        let y = row as i16 * t.line_h as i16;
        self.conn.poly_fill_rectangle(
            self.win,
            self.white,
            &[Rectangle { x: 0, y, width: self.w, height: t.line_h }],
        )?;
        for (i, chunk) in line.chunks(255).enumerate() {
            self.conn.image_text8(
                self.win,
                t.gc,
                (i * 255 * t.char_w) as i16,
                y + t.ascent,
                chunk,
            )?;
        }
        Ok(())
    }

    /// Full-screen moving gradient plus moving noise texture, marker painted into the image.
    fn motion_frame(&mut self, counter: u32) -> Res<()> {
        let (w, h) = (self.w as usize, self.h as usize);
        let Some(m) = self.motion.as_mut() else { return Ok(()) };
        m.frame = m.frame.wrapping_add(1);
        let t = m.frame as usize;
        let (dx, dy) = (t * 7, t * 3);
        let stride = w * 4;
        let col: Vec<u8> = (0..w).map(|x| (x * 255 / w) as u8).collect();
        {
            let buf = m.shm.as_mut_slice();
            for y in 0..h {
                let ny = ((y + dy) & 1023) * 1024;
                let gy = ((y * 255 / h) + t * 3) as u8;
                let row = &mut buf[y * stride..(y + 1) * stride];
                for (x, px) in row.chunks_exact_mut(4).enumerate() {
                    let n = m.noise[ny + ((x + dx) & 1023)] >> 2;
                    let r = col[x].wrapping_add((t * 2) as u8);
                    let b = col[x].wrapping_add(gy).wrapping_sub(t as u8);
                    px[0] = b.wrapping_add(n);
                    px[1] = gy.wrapping_add(n);
                    px[2] = r.wrapping_add(n);
                    px[3] = 0;
                }
            }
            marker::paint_bgrx(buf, stride, counter);
        }
        let fmt = u8::from(ImageFormat::Z_PIXMAP);
        self.conn.shm_put_image(
            self.win, self.gray, self.w, self.h, 0, 0, self.w, self.h, 0, 0, self.depth, fmt,
            false, m.shm.seg, 0,
        )?;
        // Round trip so the server has read the segment before we overwrite it next tick.
        self.conn.get_input_focus()?.reply()?;
        Ok(())
    }
}
