//! What a desktop overlay does with the engine's cursor events, platform-free
//! so it is tested on every host: which point the cursor glides to, when it
//! hides ([`Track`]), the glide's easing ([`glide`]), and the person's
//! `computerUse.showCursor` setting in front of any overlay ([`ShowCursor`]).
//! The macOS worker's overlay (`platform/macos/overlay.rs`) draws from it.

use std::collections::BTreeSet;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, PoisonError};

use crate::cursor::{CursorEvent, CursorSink};
use crate::desktop::Point;

/// What the overlay does for one event.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum Draw {
    /// Show the cursor (if hidden) and glide its tip to this point.
    Glide(Point),
    /// No session's Computer Use is active any more: hide the cursor.
    Hide,
    /// Nothing changes on screen.
    Nothing,
}

/// The point an event acts at, if it names one.
pub fn target(event: &CursorEvent) -> Option<Point> {
    match event {
        CursorEvent::Move { at, .. }
        | CursorEvent::Click { at, .. }
        | CursorEvent::Scroll { at, .. } => Some(*at),
        CursorEvent::Drag { to, .. } => Some(*to),
        CursorEvent::Typing { at, .. }
        | CursorEvent::Keys { at, .. }
        | CursorEvent::Paused { at, .. }
        | CursorEvent::Refused { at, .. } => *at,
        CursorEvent::Look { at, rect, .. } => {
            at.or_else(|| rect.map(|r| Point { x: r.x + r.width / 2.0, y: r.y + r.height / 2.0 }))
        }
        CursorEvent::Hide { .. } => None,
    }
}

/// The sessions whose cursor is up; one cursor is drawn while any is.
#[derive(Default)]
pub struct Track {
    active: BTreeSet<String>,
    shown: bool,
}

impl Track {
    pub fn apply(&mut self, event: &CursorEvent) -> Draw {
        let ends =
            matches!(event, CursorEvent::Hide { .. } | CursorEvent::Refused { ends: true, .. });
        if ends {
            self.active.remove(event.session());
            if self.active.is_empty() && self.shown {
                self.shown = false;
                return Draw::Hide;
            }
            return Draw::Nothing;
        }
        self.active.insert(event.session().to_string());
        match target(event) {
            Some(at) => {
                self.shown = true;
                Draw::Glide(at)
            }
            None => Draw::Nothing,
        }
    }
}

/// The glide from `from` to `to` at `t` (0 to 1): ease-out cubic.
pub fn glide(from: Point, to: Point, t: f64) -> Point {
    let t = t.clamp(0.0, 1.0);
    let e = 1.0 - (1.0 - t).powi(3);
    Point { x: from.x + (to.x - from.x) * e, y: from.y + (to.y - from.y) * e }
}

/// `computerUse.showCursor` in front of the overlay: while off, no event
/// draws; turning it off hides every cursor up now. Hides always pass.
pub struct ShowCursor {
    inner: Arc<dyn CursorSink>,
    on: AtomicBool,
    up: Mutex<BTreeSet<String>>,
}

impl ShowCursor {
    pub fn new(inner: Arc<dyn CursorSink>, on: bool) -> Self {
        Self { inner, on: AtomicBool::new(on), up: Mutex::new(BTreeSet::new()) }
    }

    pub fn set(&self, on: bool) {
        if self.on.swap(on, Ordering::SeqCst) && !on {
            let up = std::mem::take(&mut *self.up.lock().unwrap_or_else(PoisonError::into_inner));
            for session in up {
                self.inner.show(CursorEvent::Hide { session });
            }
        }
    }
}

impl CursorSink for ShowCursor {
    fn show(&self, event: CursorEvent) {
        let ends =
            matches!(event, CursorEvent::Hide { .. } | CursorEvent::Refused { ends: true, .. });
        let mut up = self.up.lock().unwrap_or_else(PoisonError::into_inner);
        if ends {
            // A hide of a session never drawn (the setting was off) is still passed on:
            // harmless, and the overlay forgets it.
            up.remove(event.session());
        } else if self.on.load(Ordering::SeqCst) {
            up.insert(event.session().to_string());
        } else {
            return;
        }
        drop(up);
        self.inner.show(event);
    }
}

#[cfg(test)]
#[path = "cursor_draw_tests.rs"]
mod tests;
