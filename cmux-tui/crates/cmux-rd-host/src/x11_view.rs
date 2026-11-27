//! What a Linux X11 share shows: the whole X screen or one of its monitors (the viewer's
//! display picker), fitted into the viewer's `max_width` (its quality menu and the pane's own
//! width), the way the macOS host fits a display. Pure geometry plus the RandR monitor list;
//! `x11.rs` applies it to capture, damage and input.

use crate::capture::Rect;

/// The part of the X screen a session streams (`src`, in screen pixels) and the picture it
/// encodes (`out`): `src` itself, or `src` scaled down to fit `max_width`, keeping its aspect.
/// Every size and origin is even, as 4:2:0 needs.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct View {
    pub src: Rect,
    pub out: (u32, u32),
}

impl View {
    /// `src` fitted into `max_width`. No `max_width` (or a wider one) streams `src` at its own
    /// size, as before the viewer could ask.
    pub fn new(src: Rect, max_width: Option<u32>) -> View {
        let src = Rect { x: src.x & !1, y: src.y & !1, w: src.w & !1, h: src.h & !1 };
        let out = match max_width {
            Some(limit) if limit >= 2 && limit < src.w => {
                let w = limit & !1;
                let h = ((u64::from(src.h) * u64::from(w) + u64::from(src.w) / 2)
                    / u64::from(src.w)) as u32
                    & !1;
                (w, h.max(2))
            }
            _ => (src.w, src.h),
        };
        View { src, out }
    }

    pub fn scaled(&self) -> bool {
        self.out != (self.src.w, self.src.h)
    }

    /// A damage report in screen pixels, clipped to `src` and moved to `src`'s origin; None
    /// when it misses `src` (another monitor changed).
    pub fn clip(&self, r: Rect) -> Option<Rect> {
        let (x0, y0) = (r.x.max(self.src.x), r.y.max(self.src.y));
        let x1 = (r.x + r.w).min(self.src.x + self.src.w);
        let y1 = (r.y + r.h).min(self.src.y + self.src.h);
        (x1 > x0 && y1 > y0).then(|| Rect {
            x: x0 - self.src.x,
            y: y0 - self.src.y,
            w: x1 - x0,
            h: y1 - y0,
        })
    }

    /// A rect of `src` (origin at `src`'s corner) as the rect of the picture it lands in,
    /// grown to whole even pixels.
    pub fn to_out(self, r: Rect) -> Rect {
        let (ow, oh) = self.out;
        let x0 = (u64::from(r.x) * u64::from(ow) / u64::from(self.src.w)) as u32;
        let y0 = (u64::from(r.y) * u64::from(oh) / u64::from(self.src.h)) as u32;
        let x1 = (u64::from(r.x + r.w) * u64::from(ow)).div_ceil(u64::from(self.src.w)) as u32;
        let y1 = (u64::from(r.y + r.h) * u64::from(oh)).div_ceil(u64::from(self.src.h)) as u32;
        Rect { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }.align_even(ow, oh)
    }

    /// A rect of the picture as the rect of `src` it is made from (origin at `src`'s corner),
    /// grown to whole even pixels.
    pub fn to_src(self, r: Rect) -> Rect {
        let (ow, oh) = self.out;
        let (sw, sh) = (self.src.w, self.src.h);
        let x0 = (u64::from(r.x) * u64::from(sw) / u64::from(ow)) as u32;
        let y0 = (u64::from(r.y) * u64::from(sh) / u64::from(oh)) as u32;
        let x1 = (u64::from(r.x + r.w) * u64::from(sw)).div_ceil(u64::from(ow)) as u32;
        let y1 = (u64::from(r.y + r.h) * u64::from(sh)).div_ceil(u64::from(oh)) as u32;
        Rect { x: x0, y: y0, w: x1 - x0, h: y1 - y0 }.align_even(sw, sh)
    }

    /// A pointer position in picture pixels (what the viewer sends) as a screen position.
    pub fn pointer(&self, x: i32, y: i32) -> (i32, i32) {
        let map = |v: i32, out: u32, src: u32, origin: u32| {
            let v = i64::from(v.clamp(0, out.saturating_sub(1) as i32));
            (i64::from(origin) + v * i64::from(src) / i64::from(out.max(1))) as i32
        };
        (map(x, self.out.0, self.src.w, self.src.x), map(y, self.out.1, self.src.h, self.src.y))
    }
}

/// The displays a viewer may pick on an X screen of `screen` size with `monitors`: the whole
/// screen first (index 0, today's share), then each monitor when there are two or more (one
/// monitor is the whole screen again).
pub fn listing(screen: (u32, u32), monitors: &[Rect]) -> Vec<Rect> {
    let mut all = vec![Rect { x: 0, y: 0, w: screen.0, h: screen.1 }];
    if monitors.len() >= 2 {
        all.extend_from_slice(monitors);
    }
    all
}

/// The viewer's display word against [`listing`]: `main`, nothing or a word that is no index
/// (an X display name such as `:99`) is the whole screen; an index picks that entry, and an
/// index past the list is refused with the count, so a stale pick never shows another monitor.
pub fn pick(word: Option<&str>, listed: &[Rect]) -> Result<Rect, String> {
    let whole = listed.first().copied().ok_or("the X screen lists no display")?;
    match word.map(str::trim).and_then(|w| w.parse::<usize>().ok()) {
        None => Ok(whole),
        Some(i) => listed.get(i).copied().ok_or_else(|| {
            format!("display {i} is not on this X screen ({} listed)", listed.len())
        }),
    }
}

/// The X screen's monitors (RandR 1.5 GetMonitors, active ones), clipped to the screen; empty
/// when the server has no RandR 1.5 (then only the whole screen is offered).
pub fn monitors(
    conn: &impl x11rb::connection::Connection,
    root: u32,
    screen: (u32, u32),
) -> Vec<Rect> {
    use x11rb::protocol::randr::ConnectionExt as _;
    let Ok(Ok(reply)) = conn.randr_get_monitors(root, true).map(|c| c.reply()) else {
        return Vec::new();
    };
    let whole = View { src: Rect { x: 0, y: 0, w: screen.0, h: screen.1 }, out: screen };
    let list: Vec<Rect> = reply
        .monitors
        .iter()
        .filter_map(|m| {
            whole.clip(Rect {
                x: m.x.max(0) as u32,
                y: m.y.max(0) as u32,
                w: u32::from(m.width),
                h: u32::from(m.height),
            })
        })
        .filter(|r| r.w >= 2 && r.h >= 2)
        .collect();
    distinct_monitors(list, screen)
}

/// Left to right, then top to bottom, as the macOS host orders displays; a monitor that is the
/// whole screen (the picker's first entry already) or repeats another (mirrored outputs) is
/// listed once.
fn distinct_monitors(mut list: Vec<Rect>, screen: (u32, u32)) -> Vec<Rect> {
    let whole = Rect { x: 0, y: 0, w: screen.0, h: screen.1 };
    list.retain(|r| *r != whole);
    list.sort_by_key(|r| (r.x, r.y, r.w, r.h));
    list.dedup();
    list
}

/// Scales the `out` rect `r` of one plane from `src` (size `sw` x `sh`) into `dst` (size
/// `dw` x `dh`), averaging the source pixels each destination pixel covers.
pub fn scale_plane(
    src: &[u8],
    (sw, sh): (usize, usize),
    dst: &mut [u8],
    (dw, dh): (usize, usize),
    (rx, ry, rw, rh): (usize, usize, usize, usize),
) {
    for oy in ry..(ry + rh).min(dh) {
        let y0 = oy * sh / dh;
        let y1 = ((oy + 1) * sh / dh).max(y0 + 1).min(sh);
        let row = &mut dst[oy * dw..(oy + 1) * dw];
        for (ox, px) in row.iter_mut().enumerate().take((rx + rw).min(dw)).skip(rx) {
            let x0 = ox * sw / dw;
            let x1 = ((ox + 1) * sw / dw).max(x0 + 1).min(sw);
            let mut sum = 0u32;
            for line in src[y0 * sw..y1 * sw].chunks_exact(sw) {
                sum += line[x0..x1].iter().map(|&v| u32::from(v)).sum::<u32>();
            }
            let n = ((y1 - y0) * (x1 - x0)) as u32;
            *px = ((sum + n / 2) / n) as u8;
        }
    }
}

#[cfg(test)]
#[path = "x11_view_tests.rs"]
mod tests;
