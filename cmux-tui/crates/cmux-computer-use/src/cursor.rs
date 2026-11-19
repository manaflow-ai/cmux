//! The agent cursor: a cmux-blue pointer drawn over the desktop wherever an
//! agent acts, so the person always sees that an agent (and which one) is
//! working, without the real pointer ever moving. Each platform draws it in
//! a click-through, always-on-top, non-activating overlay window
//! (AppKit panel on macOS, a layered WS_EX_TRANSPARENT window on Windows,
//! an override-redirect ARGB window with an empty input shape on X11; on
//! Wayland the portal's own pointer is used).
//!
//! The engine emits [`CursorEvent`]s before and after each action; the
//! overlay glides between points. As in Codex, the cursor stays on screen for
//! as long as the agent's Computer Use is active, through the model's
//! thinking between actions, and hides only on [`CursorEvent::Hide`]: the
//! agent's turn ended, its session ended, its process exited, the person
//! stopped it, or Computer Use or its grants were turned off
//! ([`Lifecycle`]). No timer decides that.

use serde::{Deserialize, Serialize};

use crate::desktop::Point;

/// cmux's accent blue (`--cmux-accent`, #0A84FF), the cursor's fill.
pub const CMUX_BLUE: [u8; 3] = [0x0A, 0x84, 0xFF];
/// The outline, for contrast on blue and dark content.
pub const OUTLINE: [u8; 3] = [0xFF, 0xFF, 0xFF];

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum CursorEvent {
    /// Glide to a point (global desktop points) before acting there.
    Move { session: String, label: String, at: Point },
    /// A click landed: a ripple at the point (two for a double click, three
    /// for a triple; right and middle clicks look different).
    Click {
        session: String,
        label: String,
        at: Point,
        button: String,
        #[serde(default = "one")]
        count: u8,
    },
    /// Text is being typed (a caption next to the cursor).
    Typing { session: String, label: String, at: Option<Point>, text: String },
    /// A key combo was pressed ("cmd+s"): shown as key caps.
    Keys { session: String, label: String, at: Option<Point>, keys: String },
    /// A scroll at a point, in lines (dy > 0 down).
    Scroll { session: String, label: String, at: Point, dx: f64, dy: f64 },
    /// A drag from one point to another: a trail between them.
    Drag { session: String, label: String, from: Point, to: Point },
    /// The agent is looking (a screenshot or tree read): the window's frame
    /// (global desktop points) is marked briefly.
    Look {
        session: String,
        label: String,
        at: Option<Point>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        rect: Option<crate::desktop::Rect>,
    },
    /// The person is using the mouse or keyboard where the agent would act:
    /// the agent waits until they stop ("Paused").
    Paused { session: String, label: String, at: Option<Point> },
    /// An acting call was refused (policy, deny list, the person kept
    /// control); `reason` is a short caption for the cursor. `ends`: the
    /// session's Computer Use ended with it (the person stopped it): the
    /// overlay shows the caption, then hides the cursor.
    Refused {
        session: String,
        label: String,
        at: Option<Point>,
        reason: String,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        ends: bool,
    },
    /// The session's Computer Use ended (turn, session, process, revoke):
    /// hide its cursor now.
    Hide { session: String },
}

fn one() -> u8 {
    1
}

impl CursorEvent {
    pub fn session(&self) -> &str {
        match self {
            CursorEvent::Move { session, .. }
            | CursorEvent::Click { session, .. }
            | CursorEvent::Typing { session, .. }
            | CursorEvent::Keys { session, .. }
            | CursorEvent::Scroll { session, .. }
            | CursorEvent::Drag { session, .. }
            | CursorEvent::Look { session, .. }
            | CursorEvent::Paused { session, .. }
            | CursorEvent::Refused { session, .. }
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

/// Which sessions' Computer Use is active, from the events themselves: any
/// event but [`CursorEvent::Hide`] (and a refusal that `ends`) makes its
/// session active; those end it. Every engine event passes through, so the
/// live preview's cards ([`crate::preview::PreviewHub`]) follow the same
/// lifecycle as the cursor, and [`Lifecycle::end_where`] hides the cursors of
/// sessions whose turn or grants ended.
pub struct Lifecycle {
    inner: std::sync::Arc<dyn CursorSink>,
    preview: std::sync::Arc<crate::preview::PreviewHub>,
    active: std::sync::Mutex<std::collections::BTreeSet<String>>,
}

impl Lifecycle {
    pub fn new(
        inner: std::sync::Arc<dyn CursorSink>,
        preview: std::sync::Arc<crate::preview::PreviewHub>,
    ) -> Self {
        Self { inner, preview, active: std::sync::Mutex::new(Default::default()) }
    }

    fn active_set(&self) -> std::sync::MutexGuard<'_, std::collections::BTreeSet<String>> {
        self.active.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// The sessions whose Computer Use is active now, sorted.
    pub fn active(&self) -> Vec<String> {
        self.active_set().iter().cloned().collect()
    }

    /// Ends every active session `matches` accepts (its cursor hides, its
    /// preview turns done); the sessions it ended.
    pub fn end_where(&self, matches: impl Fn(&str) -> bool) -> Vec<String> {
        let ended: Vec<String> = self.active_set().iter().filter(|s| matches(s)).cloned().collect();
        for session in &ended {
            self.show(CursorEvent::Hide { session: session.clone() });
        }
        ended
    }
}

impl CursorSink for Lifecycle {
    fn show(&self, event: CursorEvent) {
        let session = event.session().to_string();
        let ends =
            matches!(event, CursorEvent::Hide { .. } | CursorEvent::Refused { ends: true, .. });
        if ends {
            self.active_set().remove(&session);
            self.preview.deactivate(&session);
        } else {
            let label = match &event {
                CursorEvent::Move { label, .. }
                | CursorEvent::Click { label, .. }
                | CursorEvent::Typing { label, .. }
                | CursorEvent::Keys { label, .. }
                | CursorEvent::Scroll { label, .. }
                | CursorEvent::Drag { label, .. }
                | CursorEvent::Look { label, .. }
                | CursorEvent::Paused { label, .. }
                | CursorEvent::Refused { label, .. } => label.clone(),
                CursorEvent::Hide { .. } => String::new(),
            };
            self.active_set().insert(session.clone());
            self.preview.activate(&session, &label);
            self.preview.cursor(&event);
        }
        self.inner.show(event);
    }
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
