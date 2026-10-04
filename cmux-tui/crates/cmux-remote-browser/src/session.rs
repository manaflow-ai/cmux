//! Host session state of one remote tab (remote-tab-protocol.md section 5.1,
//! vectors `schemas/remote-tab/session.json`).
//!
//! The remote browser host owns the stream session: which viewers watch,
//! the canonical screen (smallest visible viewer), whether the page is
//! captured. The page runtime and the tab record are owned elsewhere; this
//! reducer only says what the host must do next.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::proto::{ScreenInfo, SessionState};

/// The size the page renders at: CSS size and backing scale.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
pub struct ScreenSize {
    pub css_width: u32,
    pub css_height: u32,
    pub scale: f64,
}

impl From<&ScreenInfo> for ScreenSize {
    fn from(info: &ScreenInfo) -> Self {
        Self { css_width: info.css_width, css_height: info.css_height, scale: info.scale }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Viewer {
    pub screen: ScreenSize,
    pub visible: bool,
}

/// One input of the session reducer.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum SessionInput {
    Open { viewer: String, screen: ScreenSize },
    FirstFrame,
    Visibility { viewer: String, visible: bool },
    Screen { viewer: String, screen: ScreenSize },
    Leave { viewer: String },
    RendererCrashed,
    Reload,
    Close,
}

/// What the host must do, in this order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "effect", rename_all = "snake_case")]
pub enum SessionEffect {
    StartPage,
    ApplyScreen { css_width: u32, css_height: u32, scale: f64 },
    StartCapture,
    StopCapture,
    NotifyState { state: SessionState },
    StopPage,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum SessionReject {
    Closed,
    NotOpen,
    UnknownViewer,
    Unexpected,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Session {
    pub state: SessionState,
    pub viewers: BTreeMap<String, Viewer>,
    /// The screen last sent to the page, if any.
    pub applied: Option<ScreenSize>,
    pub capturing: bool,
}

impl Default for Session {
    fn default() -> Self {
        Self { state: SessionState::Idle, viewers: BTreeMap::new(), applied: None, capturing: false }
    }
}

impl Session {
    /// The canonical screen: among visible viewers (all viewers when none is
    /// visible) the smallest CSS width and height, independently, and the
    /// largest scale. `None` without viewers.
    pub fn canonical_screen(&self) -> Option<ScreenSize> {
        let any_visible = self.viewers.values().any(|v| v.visible);
        self.viewers
            .values()
            .filter(|v| v.visible || !any_visible)
            .map(|v| v.screen)
            .reduce(|a, b| ScreenSize {
                css_width: a.css_width.min(b.css_width),
                css_height: a.css_height.min(b.css_height),
                scale: a.scale.max(b.scale),
            })
    }

    fn any_visible(&self) -> bool {
        self.viewers.values().any(|v| v.visible)
    }

    fn push_screen_if_changed(&mut self, effects: &mut Vec<SessionEffect>) {
        let Some(canonical) = self.canonical_screen() else { return };
        if self.applied != Some(canonical) {
            self.applied = Some(canonical);
            effects.push(SessionEffect::ApplyScreen {
                css_width: canonical.css_width,
                css_height: canonical.css_height,
                scale: canonical.scale,
            });
        }
    }

    fn set_capture(&mut self, on: bool, effects: &mut Vec<SessionEffect>) {
        if self.capturing != on {
            self.capturing = on;
            effects.push(if on { SessionEffect::StartCapture } else { SessionEffect::StopCapture });
        }
    }

    fn enter(&mut self, state: SessionState, effects: &mut Vec<SessionEffect>) {
        self.state = state;
        effects.push(SessionEffect::NotifyState { state });
    }

    /// Live and paused follow the visible viewers; other states are unchanged.
    fn follow_visibility(&mut self, effects: &mut Vec<SessionEffect>) {
        match (self.state, self.any_visible()) {
            (SessionState::Live, false) => {
                self.set_capture(false, effects);
                self.enter(SessionState::Paused, effects);
            }
            (SessionState::Paused, true) => {
                self.set_capture(true, effects);
                self.enter(SessionState::Live, effects);
            }
            _ => {}
        }
    }

    /// Applies one input. On a reject the session is unchanged.
    pub fn apply(&mut self, input: SessionInput) -> Result<Vec<SessionEffect>, SessionReject> {
        let _ = input;
        Ok(Vec::new())
    }

    fn step(&mut self, input: SessionInput) -> Result<Vec<SessionEffect>, SessionReject> {
        let mut effects = Vec::new();
        if self.state == SessionState::Idle
            && !matches!(input, SessionInput::Open { .. } | SessionInput::Close)
        {
            return Err(SessionReject::NotOpen);
        }
        match input {
            SessionInput::Open { viewer, screen } => {
                self.viewers.insert(viewer, Viewer { screen, visible: true });
                if self.state == SessionState::Idle {
                    self.state = SessionState::Opening;
                    effects.push(SessionEffect::StartPage);
                    self.push_screen_if_changed(&mut effects);
                    self.set_capture(true, &mut effects);
                } else {
                    self.push_screen_if_changed(&mut effects);
                    self.follow_visibility(&mut effects);
                }
            }
            SessionInput::FirstFrame => {
                if self.state != SessionState::Opening {
                    return Err(SessionReject::Unexpected);
                }
                if self.any_visible() {
                    self.enter(SessionState::Live, &mut effects);
                } else {
                    self.set_capture(false, &mut effects);
                    self.enter(SessionState::Paused, &mut effects);
                }
            }
            SessionInput::Visibility { viewer, visible } => {
                self.viewers.get_mut(&viewer).ok_or(SessionReject::UnknownViewer)?.visible = visible;
                self.push_screen_if_changed(&mut effects);
                self.follow_visibility(&mut effects);
            }
            SessionInput::Screen { viewer, screen } => {
                self.viewers.get_mut(&viewer).ok_or(SessionReject::UnknownViewer)?.screen = screen;
                self.push_screen_if_changed(&mut effects);
            }
            SessionInput::Leave { viewer } => {
                self.viewers.remove(&viewer).ok_or(SessionReject::UnknownViewer)?;
                self.push_screen_if_changed(&mut effects);
                self.follow_visibility(&mut effects);
            }
            SessionInput::RendererCrashed => {
                if !matches!(
                    self.state,
                    SessionState::Opening | SessionState::Live | SessionState::Paused
                ) {
                    return Err(SessionReject::Unexpected);
                }
                self.set_capture(false, &mut effects);
                self.enter(SessionState::Crashed, &mut effects);
            }
            SessionInput::Reload => {
                if self.state != SessionState::Crashed {
                    return Err(SessionReject::Unexpected);
                }
                self.state = SessionState::Opening;
                effects.push(SessionEffect::StartPage);
                self.set_capture(true, &mut effects);
            }
            SessionInput::Close => {
                let page_started = self.state != SessionState::Idle;
                self.set_capture(false, &mut effects);
                if page_started {
                    effects.push(SessionEffect::StopPage);
                }
                self.state = SessionState::Closed;
            }
        }
        Ok(effects)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn size(w: u32, h: u32, scale: f64) -> ScreenSize {
        ScreenSize { css_width: w, css_height: h, scale }
    }

    #[test]
    fn canonical_screen_uses_only_visible_viewers() {
        let mut s = Session::default();
        s.apply(SessionInput::Open { viewer: "a".into(), screen: size(1000, 800, 2.0) }).unwrap();
        s.apply(SessionInput::Open { viewer: "b".into(), screen: size(600, 900, 1.0) }).unwrap();
        assert_eq!(s.canonical_screen(), Some(size(600, 800, 2.0)));
        s.apply(SessionInput::Visibility { viewer: "b".into(), visible: false }).unwrap();
        assert_eq!(s.canonical_screen(), Some(size(1000, 800, 2.0)));
    }

    #[test]
    fn reject_leaves_state_unchanged() {
        let mut s = Session::default();
        s.apply(SessionInput::Open { viewer: "a".into(), screen: size(800, 600, 2.0) }).unwrap();
        let before = s.clone();
        assert_eq!(
            s.apply(SessionInput::Visibility { viewer: "x".into(), visible: true }),
            Err(SessionReject::UnknownViewer)
        );
        assert_eq!(s, before);
    }
}
