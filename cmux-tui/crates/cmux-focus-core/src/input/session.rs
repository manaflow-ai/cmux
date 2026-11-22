//! Key sessions (DESIGN.md sections 4.7 and 4.8, I4 and I5): a mode in which
//! the keys of one window belong to the session, so none of them reaches a
//! sink, and at most one session runs in the process.
//!
//! A session starts when the platform says so ([`InputEvent::SessionStarted`],
//! sent by the action that starts it in the same turn as its key or click).
//! While it runs, a key-down of its window is the session's when its rule
//! takes the key; any other key, a key of another window, a focus move off
//! its target, its window closing or a newer session ends it, and that key
//! then routes as usual in the same call. The platform ends it too
//! ([`InputEvent::SessionEnded`]: a pick, no labels left).
//!
//! [`InputEvent::SessionStarted`]: super::InputEvent::SessionStarted
//! [`InputEvent::SessionEnded`]: super::InputEvent::SessionEnded

use super::key::{KeyRecord, WindowRole};
use super::router::{InputRouter, is_user_move};
use super::sink::Sink;
use super::{InputEffect, InputId};
use crate::event::FocusEvent;
use std::sync::Arc;

/// The virtual key code of Escape.
pub(super) const ESCAPE: u16 = 53;
/// The virtual key code of Delete (Backspace).
pub(super) const BACKSPACE: u16 = 51;

/// What a session is.
#[derive(Clone, Debug, PartialEq, Eq, Hash)]
pub enum SessionKind {
    /// Link hints on a browser tab's page, started by the person (a binding or
    /// the palette): its letters label and pick the page's links. A session a
    /// bare `f` starts from inside the page is the page's own (stage S6).
    LinkHints { tab: Arc<str> },
    /// Click by Hint: the window's controls get labels.
    WindowHints,
    /// The Keyboard Shortcuts recorder takes the window's keys.
    Recorder,
}

/// A key a session takes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SessionKey {
    /// A letter (lowercase), typed with or without Shift.
    Letter {
        /// The letter, lowercase.
        letter: char,
        /// Shift was held.
        shift: bool,
    },
    /// Delete (Backspace): the hint session takes back its last letter.
    Backspace,
    /// Escape: the session ends with it.
    Escape,
    /// Any key (the recorder records each).
    Any,
}

/// Why a session ended.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum SessionEnd {
    /// Escape.
    Escape,
    /// A key the session does not take; it routes as usual.
    OtherKey,
    /// A key of another window or panel.
    OtherWindow,
    /// The window's focus left the session's target.
    FocusLeft,
    /// A newer session started.
    Replaced,
    /// Its window closed.
    WindowClosed,
    /// The platform ended it (a pick, nothing left to label).
    Finished,
}

/// The session that runs.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct Session {
    pub(super) kind: SessionKind,
    pub(super) window: Arc<str>,
}

impl InputRouter {
    /// A session starts in `window`; one that runs ends first (I5). A window
    /// that is not open starts none.
    /// Link hints start only on the page the window's keys go to; a session
    /// that cannot start ends at once, so the platform takes its labels down.
    pub(super) fn start_session(&mut self, kind: &SessionKind, window: &Arc<str>) {
        self.end_session(SessionEnd::Replaced);
        let refused = if !self.windows.contains_key(window) {
            Some(SessionEnd::WindowClosed)
        } else if let SessionKind::LinkHints { tab } = kind {
            (self.aim(window).as_ref() != Some(&Sink::Content(tab.clone())))
                .then_some(SessionEnd::FocusLeft)
        } else {
            None
        };
        match refused {
            Some(reason) => self.push(InputEffect::SessionEnded { kind: kind.clone(), reason }),
            None => self.session = Some(Session { kind: kind.clone(), window: window.clone() }),
        }
    }

    /// Ends the session that runs, if any.
    pub(super) fn end_session(&mut self, reason: SessionEnd) {
        if let Some(session) = self.session.take() {
            self.push(InputEffect::SessionEnded { kind: session.kind, reason });
        }
    }

    /// A key of another window or panel ends the running session, before any
    /// other rule reads the key (it then routes as usual).
    pub(super) fn end_session_of_other_window(&mut self, key: &KeyRecord) {
        let other = self
            .session
            .as_ref()
            .is_some_and(|session| key.role != WindowRole::Main || key.window != session.window);
        if other {
            self.end_session(SessionEnd::OtherWindow);
        }
    }

    /// Key-down `id` while a session runs: true when the session took it.
    /// False when no session runs, or when the key ended the session (it then
    /// routes as usual).
    pub(super) fn session_takes(&mut self, id: InputId, key: &KeyRecord) -> bool {
        let Some(session) = &self.session else { return false };
        if key.role != WindowRole::Main || key.window != session.window {
            self.end_session(SessionEnd::OtherWindow);
            return false;
        }
        let step = match session.kind {
            SessionKind::Recorder => Some(SessionKey::Any),
            SessionKind::LinkHints { .. } | SessionKind::WindowHints => hint_key(key),
        };
        match step {
            Some(SessionKey::Escape) => {
                self.push(InputEffect::SessionKey { id, key: SessionKey::Escape });
                self.end_session(SessionEnd::Escape);
                true
            }
            Some(step) => {
                self.push(InputEffect::SessionKey { id, key: step });
                true
            }
            None => {
                self.end_session(SessionEnd::OtherKey);
                false
            }
        }
    }

    /// After `event` (none: a topology report) changed `window`'s focus: link
    /// hints end when the window's keys no longer go to their page, and window
    /// hints end on the person's own focus move (a click, a drag) in their
    /// window.
    pub(super) fn session_after_focus(&mut self, window: &Arc<str>, event: Option<&FocusEvent>) {
        let Some(session) = &self.session else { return };
        if session.window != *window {
            return;
        }
        let left = match &session.kind {
            SessionKind::LinkHints { tab } => {
                self.aim(window).as_ref() != Some(&Sink::Content(tab.clone()))
            }
            SessionKind::WindowHints => event.is_some_and(|event| {
                is_user_move(event) || matches!(event, FocusEvent::DragBegan { .. })
            }),
            SessionKind::Recorder => false,
        };
        if left {
            self.end_session(SessionEnd::FocusLeft);
        }
    }
}

/// The hint session's reading of a key: Escape, Backspace or a letter typed
/// with no Command, Control or Option; none for any other key.
fn hint_key(key: &KeyRecord) -> Option<SessionKey> {
    let m = key.modifiers;
    if m.command || m.control || m.option {
        return (key.code == ESCAPE).then_some(SessionKey::Escape);
    }
    match (key.code, key.letter) {
        (ESCAPE, _) => Some(SessionKey::Escape),
        (BACKSPACE, _) => Some(SessionKey::Backspace),
        (_, Some(letter)) => Some(SessionKey::Letter { letter, shift: m.shift }),
        _ => None,
    }
}
