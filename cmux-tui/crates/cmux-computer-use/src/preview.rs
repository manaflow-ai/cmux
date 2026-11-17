//! The live preview of Computer Use: while an agent's Computer Use is active
//! (its cursor shows), a live video of the window it drives, for the cmux
//! surface the agent runs in (its agent chat or its terminal pane), as the
//! Codex app shows the window its agent uses.
//!
//! The hub owns the cards; the platform only streams pixels:
//!
//! - A session's card names the window its last successful call targeted
//!   ([`PreviewHub::note_window`]); its frames are that window's stream.
//! - Running while the session is active ([`PreviewHub::activate`], from its
//!   cursor events); `done` (the last frame, dimmed by the surface) once it
//!   is not ([`PreviewHub::deactivate`]: the turn ended, the agent's session
//!   ended or its process exited, the person stopped it, a grant was
//!   revoked). A done card's later frames are the person's, never shown.
//! - Gone (`card: null`) when its window closes, when the person turns the
//!   preview off (`computerUse.livePreview`) or Computer Use off, and when
//!   more than [`MAX_CARDS`] done cards wait.
//! - The platform streams exactly the windows of the cards
//!   ([`PreviewSource::stream`], replaced as a set) while someone watches
//!   ([`PreviewHub::watch`], the worker socket's `preview/watch`) and the
//!   preview is on; nothing is captured otherwise. A window that shows no
//!   change sends no frames.
//!
//! Every change goes to the watchers as one line:
//! `{"event":"preview","session":S,"card":{session,label,app,done,frame,pointer?}|null}`,
//! where `frame` is a `data:image/jpeg;base64,` URL and `pointer` the agent's
//! cursor as a fraction of the window (`{x,y,click,windowWidth}`), the shape
//! the agent chat's card reads (webviews `computerUsePreview.ts`).

use std::collections::HashMap;
use std::sync::{Arc, Mutex, PoisonError};

use base64::Engine as _;
use serde_json::{Value, json};

use crate::cursor::CursorEvent;
use crate::desktop::{Point, Rect};

/// The stream's long side in pixels: sharp in the expanded card, scaled
/// down by the surface in the small one.
pub const LONG_SIDE: u32 = 960;
/// Frames per second at most; a still window sends none.
pub const FPS: u32 = 12;
/// The most cards kept; the oldest done ones go first.
pub const MAX_CARDS: usize = 8;

/// The platform's window streams (the macOS worker's ScreenCaptureKit
/// streams). Frames come back through [`PreviewHub::frame`]; a stream whose
/// window closed reports [`PreviewHub::window_closed`].
pub trait PreviewSource: Send + Sync {
    /// Streams exactly `windows` from now on (an empty list stops them all).
    fn stream(&self, windows: &[String], long_side: u32, fps: u32);
}

/// No streams (headless, a platform without previews, tests).
pub struct NoPreview;

impl PreviewSource for NoPreview {
    fn stream(&self, _windows: &[String], _long_side: u32, _fps: u32) {}
}

/// One watcher's sink: false once it can take no more (its peer left).
pub type Watcher = Arc<dyn Fn(&Value) -> bool + Send + Sync>;

#[derive(Clone, Debug, Default)]
struct Card {
    label: String,
    app: String,
    window: Option<String>,
    /// The window's frame in global points, for the pointer's fraction.
    rect: Option<Rect>,
    active: bool,
    frame: Option<Arc<str>>,
    /// The agent's cursor, global points, and how many clicks it made.
    pointer: Option<Point>,
    clicks: u64,
    /// When it last changed, for dropping the oldest done card.
    touched: u64,
}

#[derive(Default)]
struct State {
    enabled: bool,
    cards: HashMap<String, Card>,
    watchers: Vec<(u64, Watcher)>,
    next_watcher: u64,
    streaming: Vec<String>,
    tick: u64,
}

/// The live preview's cards and watchers (see the module docs).
pub struct PreviewHub {
    state: Mutex<State>,
    source: Arc<dyn PreviewSource>,
}

/// What one change sends: the lines for the watchers, and the stream set
/// when it changed.
#[derive(Default)]
struct Out {
    lines: Vec<Value>,
    stream: Option<Vec<String>>,
}

impl PreviewHub {
    pub fn new(source: Arc<dyn PreviewSource>, enabled: bool) -> Self {
        Self { state: Mutex::new(State { enabled, ..State::default() }), source }
    }

    fn change(&self, f: impl FnOnce(&mut State, &mut Out)) {
        let (lines, stream, watchers) = {
            let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            let mut out = Out::default();
            f(&mut state, &mut out);
            let wanted = wanted_windows(&state);
            if wanted != state.streaming {
                state.streaming = wanted.clone();
                out.stream = Some(wanted);
            }
            let watchers: Vec<Watcher> = state.watchers.iter().map(|(_, w)| w.clone()).collect();
            (out.lines, out.stream, watchers)
        };
        if let Some(windows) = stream {
            self.source.stream(&windows, LONG_SIDE, FPS);
        }
        if lines.is_empty() {
            return;
        }
        // A watcher whose peer left refuses lines until its connection's end
        // drops it ([`Self::unwatch`]).
        for line in &lines {
            for watcher in &watchers {
                watcher(line);
            }
        }
    }

    /// `computerUse.livePreview` (and Computer Use's mode): off drops every
    /// card and stops every stream.
    pub fn set_enabled(&self, enabled: bool) {
        self.change(|state, out| {
            if state.enabled == enabled {
                return;
            }
            state.enabled = enabled;
            if !enabled {
                let mut sessions: Vec<String> = state.cards.keys().cloned().collect();
                sessions.sort();
                for session in sessions {
                    let card = state.cards.get_mut(&session).expect("listed");
                    let shown = card.frame.take().is_some();
                    card.window = None;
                    card.rect = None;
                    card.pointer = None;
                    if shown {
                        out.lines.push(line(&session, None));
                    }
                }
                state.cards.retain(|_, c| c.active);
            }
        });
    }

    pub fn enabled(&self) -> bool {
        self.state.lock().unwrap_or_else(PoisonError::into_inner).enabled
    }

    /// Whether a window is worth resolving for a card now (someone watches
    /// and the preview is on).
    pub fn wanted(&self) -> bool {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.enabled && !state.watchers.is_empty()
    }

    /// A new watcher: it gets every card shown now, then each change.
    /// Returns its id for [`Self::unwatch`].
    pub fn watch(&self, watcher: Watcher) -> u64 {
        let (id, snapshot) = {
            let mut state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
            state.next_watcher += 1;
            let id = state.next_watcher;
            state.watchers.push((id, watcher.clone()));
            let mut sessions: Vec<&String> =
                state.cards.iter().filter(|(_, c)| c.frame.is_some()).map(|(s, _)| s).collect();
            sessions.sort();
            (id, sessions.into_iter().map(|s| line(s, state.cards.get(s))).collect::<Vec<_>>())
        };
        for line in &snapshot {
            watcher(line);
        }
        // The first watcher starts the streams.
        self.change(|_, _| {});
        id
    }

    pub fn unwatch(&self, id: u64) {
        self.change(|state, _| state.watchers.retain(|(w, _)| *w != id));
    }

    /// The session's Computer Use is active (its cursor shows): its card runs.
    pub fn activate(&self, session: &str, label: &str) {
        self.change(|state, out| {
            state.tick += 1;
            let tick = state.tick;
            let card = state.cards.entry(session.to_string()).or_default();
            if !label.is_empty() {
                card.label = label.to_string();
            }
            card.touched = tick;
            if !card.active {
                card.active = true;
                if card.frame.is_some() {
                    out.lines.push(line(session, Some(card)));
                }
            }
        });
    }

    /// The session's Computer Use ended (turn, session, process, stop,
    /// revoke): its card shows done, with its last frame.
    pub fn deactivate(&self, session: &str) {
        self.change(|state, out| {
            state.tick += 1;
            let tick = state.tick;
            let Some(card) = state.cards.get_mut(session) else { return };
            if !card.active {
                return;
            }
            card.active = false;
            card.touched = tick;
            if card.frame.is_some() {
                out.lines.push(line(session, Some(card)));
            } else {
                state.cards.remove(session);
            }
            trim(state, out);
        });
    }

    /// The session's call targeted `window` (resolved: its frame and app):
    /// the card shows it from its next frame. Only after the call passed the
    /// policy, so a denied window is never streamed.
    pub fn note_window(&self, session: &str, label: &str, window: &str, rect: Rect, app: &str) {
        self.change(|state, _| {
            if !state.enabled {
                return;
            }
            state.tick += 1;
            let tick = state.tick;
            let card = state.cards.entry(session.to_string()).or_default();
            if !label.is_empty() {
                card.label = label.to_string();
            }
            if !app.is_empty() {
                card.app = app.to_string();
            }
            card.window = Some(window.to_string());
            card.rect = Some(rect);
            card.touched = tick;
        });
    }

    /// A cursor event of `session`: the card's pointer follows it.
    pub fn cursor(&self, event: &CursorEvent) {
        let (at, click) = match event {
            CursorEvent::Move { at, .. } | CursorEvent::Scroll { at, .. } => (*at, false),
            CursorEvent::Click { at, .. } => (*at, true),
            CursorEvent::Drag { to, .. } => (*to, false),
            _ => return,
        };
        let session = event.session();
        self.change(|state, out| {
            let Some(card) = state.cards.get_mut(session) else { return };
            card.pointer = Some(at);
            if click {
                card.clicks += 1;
            }
            if card.active && card.frame.is_some() {
                out.lines.push(line(session, Some(card)));
            }
        });
    }

    /// A new frame of `window` (JPEG): the running cards that show it.
    pub fn frame(&self, window: &str, jpeg: &[u8]) {
        if jpeg.is_empty() {
            return;
        }
        let url: Arc<str> = Arc::from(format!(
            "data:image/jpeg;base64,{}",
            base64::engine::general_purpose::STANDARD.encode(jpeg)
        ));
        self.change(|state, out| {
            if !state.enabled {
                return;
            }
            let mut sessions: Vec<String> = state
                .cards
                .iter()
                .filter(|(_, c)| c.active && c.window.as_deref() == Some(window))
                .map(|(s, _)| s.clone())
                .collect();
            sessions.sort();
            for session in sessions {
                let card = state.cards.get_mut(&session).expect("listed");
                card.frame = Some(url.clone());
                out.lines.push(line(&session, Some(card)));
            }
        });
    }

    /// `window` closed (its stream ended): its cards go.
    pub fn window_closed(&self, window: &str) {
        self.change(|state, out| {
            let mut sessions: Vec<String> = state
                .cards
                .iter()
                .filter(|(_, c)| c.window.as_deref() == Some(window))
                .map(|(s, _)| s.clone())
                .collect();
            sessions.sort();
            for session in sessions {
                let card = state.cards.get_mut(&session).expect("listed");
                let shown = card.frame.take().is_some();
                card.window = None;
                card.rect = None;
                card.pointer = None;
                if shown {
                    out.lines.push(line(&session, None));
                }
                if !card.active {
                    state.cards.remove(&session);
                }
            }
        });
    }

    /// The card of `session` as the watchers last got it (tests, status).
    pub fn card(&self, session: &str) -> Option<Value> {
        let state = self.state.lock().unwrap_or_else(PoisonError::into_inner);
        state.cards.get(session).filter(|c| c.frame.is_some()).map(|c| card_json(session, c))
    }

    /// The windows streamed now.
    pub fn streaming(&self) -> Vec<String> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner).streaming.clone()
    }
}

/// The windows to stream: every card's, while the preview is on and watched.
fn wanted_windows(state: &State) -> Vec<String> {
    if !state.enabled || state.watchers.is_empty() {
        return Vec::new();
    }
    let mut windows: Vec<String> = state.cards.values().filter_map(|c| c.window.clone()).collect();
    windows.sort();
    windows.dedup();
    windows
}

/// Drops the oldest done cards beyond [`MAX_CARDS`].
fn trim(state: &mut State, out: &mut Out) {
    while state.cards.len() > MAX_CARDS {
        let Some(oldest) = state
            .cards
            .iter()
            .filter(|(_, c)| !c.active)
            .min_by_key(|(_, c)| c.touched)
            .map(|(s, _)| s.clone())
        else {
            return;
        };
        if state.cards.remove(&oldest).is_some_and(|c| c.frame.is_some()) {
            out.lines.push(line(&oldest, None));
        }
    }
}

fn line(session: &str, card: Option<&Card>) -> Value {
    let card = card.filter(|c| c.frame.is_some()).map(|c| card_json(session, c));
    json!({"event": "preview", "session": session, "card": card.unwrap_or(Value::Null)})
}

fn card_json(session: &str, card: &Card) -> Value {
    let mut value = json!({
        "session": session,
        "label": card.label,
        "app": card.app,
        "done": !card.active,
        "frame": card.frame.as_deref().unwrap_or_default(),
    });
    if card.active
        && let (Some(at), Some(rect)) = (card.pointer, card.rect)
        && rect.width > 0.0
        && rect.height > 0.0
    {
        let x = (at.x - rect.x) / rect.width;
        let y = (at.y - rect.y) / rect.height;
        if (0.0..=1.0).contains(&x) && (0.0..=1.0).contains(&y) {
            value["pointer"] =
                json!({"x": x, "y": y, "click": card.clicks, "windowWidth": rect.width});
        }
    }
    value
}

#[cfg(test)]
#[path = "preview_tests.rs"]
mod tests;
