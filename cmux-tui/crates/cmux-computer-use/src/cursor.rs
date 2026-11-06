//! The agent cursor: a cmux-blue pointer drawn over the desktop wherever an
//! agent acts, so the person always sees that an agent (and which one) is
//! working, without the real pointer ever moving. Each platform draws it in
//! a click-through, always-on-top, non-activating overlay window
//! (AppKit panel on macOS, a layered WS_EX_TRANSPARENT window on Windows,
//! an override-redirect ARGB window with an empty input shape on X11; on
//! Wayland the portal's own pointer is used).
//!
//! The engine emits [`CursorEvent`]s before and after each action; the
//! overlay glides between points and fades out after [`IDLE_HIDE`].

use serde::{Deserialize, Serialize};

use crate::desktop::Point;

/// cmux's accent blue (`--cmux-accent`, #0A84FF), the cursor's fill.
pub const CMUX_BLUE: [u8; 3] = [0x0A, 0x84, 0xFF];
/// The outline, for contrast on blue and dark content.
pub const OUTLINE: [u8; 3] = [0xFF, 0xFF, 0xFF];
/// The overlay hides when no event came for this long.
pub const IDLE_HIDE: std::time::Duration = std::time::Duration::from_secs(4);

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum CursorEvent {
    /// Glide to a point (global desktop points) before acting there.
    Move { session: String, label: String, at: Point },
    /// A click landed (a ripple at the point).
    Click { session: String, label: String, at: Point, button: String },
    /// Text is being typed (a small caption under the cursor).
    Typing { session: String, label: String, at: Option<Point>, text: String },
    /// The agent is looking (a screenshot or tree read): a soft pulse.
    Look { session: String, label: String, at: Option<Point> },
    /// The session stopped or its grant was revoked: hide its cursor now.
    Hide { session: String },
}

impl CursorEvent {
    pub fn session(&self) -> &str {
        match self {
            CursorEvent::Move { session, .. }
            | CursorEvent::Click { session, .. }
            | CursorEvent::Typing { session, .. }
            | CursorEvent::Look { session, .. }
            | CursorEvent::Hide { session } => session,
        }
    }
}

/// Where cursor events go. The worker forwards them to its overlay.
pub trait CursorSink: Send + Sync {
    fn show(&self, event: CursorEvent);
}

/// No overlay (headless, or the person turned the cursor off).
pub struct NoCursor;

impl CursorSink for NoCursor {
    fn show(&self, _event: CursorEvent) {}
}

/// Keeps a short caption for typing (no secrets in full on screen).
pub fn caption(text: &str) -> String {
    const MAX: usize = 24;
    let one_line: String = text.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    if one_line.chars().count() <= MAX {
        one_line
    } else {
        let mut s: String = one_line.chars().take(MAX - 1).collect();
        s.push('\u{2026}');
        s
    }
}
