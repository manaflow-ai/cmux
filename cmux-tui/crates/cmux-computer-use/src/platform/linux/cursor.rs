//! The agent cursor on Linux: a cmux-blue arrow in a click-through overlay.
//!
//! - X11: an override-redirect 32-bit ARGB window (falls back to a shaped
//!   opaque window with no compositor) with an empty input shape, so every
//!   click passes through; it never takes focus and is raised above
//!   everything when it moves. It glides between points on its own thread.
//! - wlroots: a wlr-layer-shell overlay surface with an empty input region,
//!   positioned by its margins.
//! - Portal desktops (GNOME, KDE): no overlay protocol for outside
//!   processes; [`NoCursor`], logged once.

use std::sync::Arc;
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

use crate::cursor::{CMUX_BLUE, CursorEvent, CursorSink, IDLE_HIDE, NoCursor, OUTLINE};
use crate::desktop::Point;

mod layer;
mod x11;

pub const SIZE: u32 = 24;
const GLIDE: Duration = Duration::from_millis(180);
const FRAME: Duration = Duration::from_millis(16);

pub fn open() -> Arc<dyn CursorSink> {
    let env = super::Env::from_process();
    if env.wayland_socket().is_some() {
        if let Some(s) = layer::spawn() {
            return s;
        }
        if env.display.is_none() {
            eprintln!(
                "cmux computer use: this Wayland compositor has no layer-shell; the agent cursor is not drawn"
            );
            return Arc::new(NoCursor);
        }
    }
    if env.display.is_some()
        && let Some(s) = x11::spawn()
    {
        return s;
    }
    Arc::new(NoCursor)
}

/// The arrow, premultiplied BGRA (the byte order of X11 ARGB visuals and
/// wl_shm ARGB8888), plus a 1-bit mask of its opaque pixels.
pub fn arrow() -> (Vec<u8>, Vec<bool>) {
    // The classic pointer outline, tip at (1,1), in a 24x24 box.
    const POLY: [(f64, f64); 7] = [
        (1.0, 1.0),
        (1.0, 19.0),
        (6.0, 14.5),
        (9.5, 22.0),
        (13.0, 20.5),
        (9.5, 13.5),
        (16.0, 13.5),
    ];
    let n = SIZE as usize;
    let mut px = vec![0u8; n * n * 4];
    let mut mask = vec![false; n * n];
    for y in 0..n {
        for x in 0..n {
            let (cx, cy) = (x as f64 + 0.5, y as f64 + 0.5);
            let inside = point_in_poly(cx, cy, &POLY);
            let near = POLY
                .iter()
                .zip(POLY.iter().cycle().skip(1))
                .map(|(a, b)| seg_dist(cx, cy, *a, *b))
                .fold(f64::MAX, f64::min);
            let color = if inside && near > 1.4 {
                Some(CMUX_BLUE)
            } else if inside || near <= 1.0 {
                Some(OUTLINE)
            } else {
                None
            };
            if let Some([r, g, b]) = color {
                let i = (y * n + x) * 4;
                px[i..i + 4].copy_from_slice(&[b, g, r, 255]);
                mask[y * n + x] = true;
            }
        }
    }
    (px, mask)
}

fn point_in_poly(x: f64, y: f64, poly: &[(f64, f64)]) -> bool {
    let mut inside = false;
    let mut j = poly.len() - 1;
    for i in 0..poly.len() {
        let (xi, yi) = poly[i];
        let (xj, yj) = poly[j];
        if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi {
            inside = !inside;
        }
        j = i;
    }
    inside
}

fn seg_dist(x: f64, y: f64, a: (f64, f64), b: (f64, f64)) -> f64 {
    let (dx, dy) = (b.0 - a.0, b.1 - a.1);
    let t = (((x - a.0) * dx + (y - a.1) * dy) / (dx * dx + dy * dy)).clamp(0.0, 1.0);
    ((x - a.0 - t * dx).powi(2) + (y - a.1 - t * dy).powi(2)).sqrt()
}

/// What an overlay can do; the shared glide loop drives it.
pub(crate) trait Overlay {
    fn show_at(&mut self, p: Point);
    fn hide(&mut self);
}

pub(crate) struct Channel(pub Sender<CursorEvent>);

impl CursorSink for Channel {
    fn show(&self, event: CursorEvent) {
        let _ = self.0.send(event);
    }
}

/// Glides the overlay to each event's point and hides it when idle or when
/// its session stops. One overlay, the latest session's position.
pub(crate) fn run(mut overlay: impl Overlay, rx: Receiver<CursorEvent>) {
    let mut at: Option<Point> = None;
    let mut glide: Option<(Point, Point, Instant)> = None;
    let mut last_event = Instant::now();
    let mut owner = String::new();
    loop {
        let wait = if glide.is_some() {
            FRAME
        } else {
            IDLE_HIDE.saturating_sub(last_event.elapsed()).max(FRAME)
        };
        match rx.recv_timeout(wait) {
            Ok(ev) => {
                last_event = Instant::now();
                if let CursorEvent::Hide { session } = &ev {
                    if *session == owner || owner.is_empty() {
                        overlay.hide();
                        at = None;
                        glide = None;
                    }
                    continue;
                }
                owner = ev.session().to_string();
                if let Some(to) = target_of(&ev) {
                    match at {
                        Some(from) if distance(from, to) > 1.0 => {
                            glide = Some((from, to, Instant::now()));
                        }
                        _ => {
                            at = Some(to);
                            overlay.show_at(to);
                        }
                    }
                }
            }
            Err(RecvTimeoutError::Timeout) => {}
            Err(RecvTimeoutError::Disconnected) => return,
        }
        if let Some((from, to, start)) = glide {
            let t = (start.elapsed().as_secs_f64() / GLIDE.as_secs_f64()).min(1.0);
            let e = 1.0 - (1.0 - t).powi(3);
            let p = Point { x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e };
            overlay.show_at(p);
            at = Some(p);
            if t >= 1.0 {
                glide = None;
            }
        }
        if at.is_some() && glide.is_none() && last_event.elapsed() >= IDLE_HIDE {
            overlay.hide();
            at = None;
        }
    }
}

fn target_of(ev: &CursorEvent) -> Option<Point> {
    match ev {
        CursorEvent::Move { at, .. }
        | CursorEvent::Click { at, .. }
        | CursorEvent::Scroll { at, .. }
        | CursorEvent::Drag { to: at, .. } => Some(*at),
        CursorEvent::Typing { at, .. }
        | CursorEvent::Keys { at, .. }
        | CursorEvent::Look { at, .. } => *at,
        CursorEvent::Hide { .. } => None,
    }
}

fn distance(a: Point, b: Point) -> f64 {
    ((a.x - b.x).powi(2) + (a.y - b.y).powi(2)).sqrt()
}

pub(crate) fn channel() -> (Sender<CursorEvent>, Receiver<CursorEvent>) {
    mpsc::channel()
}
