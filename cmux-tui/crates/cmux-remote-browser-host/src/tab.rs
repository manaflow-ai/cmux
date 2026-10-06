//! One remote tab on the host: viewer control and input in, calls on the
//! presentation (the CEF shim) and control messages for the viewers out.
//! Pure; the shim and the transport live outside.

use cmux_remote_browser::menu::{MenuEffect, MenuInput, MenuTokens};
use cmux_remote_browser::proto::{
    Control, InputEvent, Menu, MenuChoice, MenuItem, MenuKind, Rect, RefuseReason, SessionState,
};
use cmux_remote_browser::rp_input::{InputReject, RpCall, map_input};
use cmux_remote_browser::session::{ScreenSize, Session, SessionEffect, SessionInput};

/// The CEF shim (csrc/rb_shim.h) behind a trait. Every call returns false
/// when the shim refused it.
pub trait Presentation {
    fn set_screen(&mut self, screen: ScreenSize) -> bool;
    fn open_tab(&mut self, request: i32, url: &str, screen: ScreenSize) -> bool;
    fn close_tab(&mut self, browser: i32);
    fn capture(&mut self, browser: i32, on: bool) -> bool;
    fn input(&mut self, browser: i32, call: &RpCall) -> bool;
    /// `None` cancels.
    fn context_menu_result(&mut self, fork_token: i64, command: Option<i64>) -> bool;
    /// `None` cancels.
    fn popup_menu_result(&mut self, fork_token: i64, indices: Option<&[u32]>) -> bool;
}

/// The screen a tab opens with before any viewer reported one.
pub const DEFAULT_SCREEN: ScreenSize = ScreenSize { css_width: 1200, css_height: 800, scale: 2.0 };

/// The menu Chromium has open, with the fork's own token.
#[derive(Debug, Clone, PartialEq)]
struct ForkMenu {
    rb_token: u64,
    kind: MenuKind,
    fork_token: i64,
}

#[derive(Debug)]
pub struct HostTab {
    pub request: i32,
    pub url: String,
    pub session_id: u64,
    pub browser: Option<i32>,
    pub session: Session,
    pub menus: MenuTokens,
    fork_menu: Option<ForkMenu>,
    capture_wanted: bool,
    screen: Option<ScreenSize>,
}

fn flatten_ids(items: &[MenuItem], out: &mut Vec<i64>) {
    for item in items {
        if item.item_type != "separator" && item.item_type != "submenu" {
            out.push(item.id);
        }
        flatten_ids(&item.items, out);
    }
}

impl HostTab {
    pub fn new(request: i32, session_id: u64, url: &str) -> Self {
        Self {
            request,
            url: url.to_string(),
            session_id,
            browser: None,
            session: Session::default(),
            menus: MenuTokens::default(),
            fork_menu: None,
            capture_wanted: false,
            screen: None,
        }
    }

    fn apply_screen(&mut self, screen: ScreenSize, p: &mut dyn Presentation) {
        if self.screen != Some(screen) && p.set_screen(screen) {
            self.screen = Some(screen);
        }
    }

    fn run_effects(
        &mut self,
        effects: Vec<SessionEffect>,
        p: &mut dyn Presentation,
    ) -> Vec<Control> {
        let mut out = Vec::new();
        for effect in effects {
            match effect {
                SessionEffect::StartPage => {
                    // The headless screen comes first: the window takes its DIP size.
                    let screen = self.session.canonical_screen().unwrap_or(DEFAULT_SCREEN);
                    self.apply_screen(screen, p);
                    if self.browser.is_none() {
                        p.open_tab(self.request, &self.url, screen);
                    }
                }
                SessionEffect::ApplyScreen { css_width, css_height, scale } => {
                    self.apply_screen(ScreenSize { css_width, css_height, scale }, p);
                }
                SessionEffect::StartCapture => {
                    self.capture_wanted = true;
                    if let Some(browser) = self.browser {
                        p.capture(browser, true);
                    }
                }
                SessionEffect::StopCapture => {
                    self.capture_wanted = false;
                    if let Some(browser) = self.browser {
                        p.capture(browser, false);
                    }
                }
                SessionEffect::NotifyState { state } => out.push(Control::State { state }),
                SessionEffect::StopPage => {
                    if let Some(browser) = self.browser.take() {
                        p.close_tab(browser);
                    }
                }
            }
        }
        out
    }

    /// The shim created the tab's browser.
    pub fn tab_created(&mut self, browser: i32, p: &mut dyn Presentation) {
        self.browser = Some(browser);
        if self.capture_wanted {
            p.capture(browser, true);
        }
    }

    /// The first captured frame arrived.
    pub fn first_frame(&mut self, p: &mut dyn Presentation) -> Vec<Control> {
        match self.session.apply(SessionInput::FirstFrame) {
            Ok(effects) => self.run_effects(effects, p),
            Err(_) => Vec::new(),
        }
    }

    /// The renderer crashed.
    pub fn renderer_crashed(&mut self, p: &mut dyn Presentation) -> Vec<Control> {
        match self.session.apply(SessionInput::RendererCrashed) {
            Ok(effects) => self.run_effects(effects, p),
            Err(_) => Vec::new(),
        }
    }

    /// A control message from `viewer`; returns the messages to send back.
    pub fn control(
        &mut self,
        viewer: &str,
        msg: &Control,
        p: &mut dyn Presentation,
    ) -> Vec<Control> {
        match msg {
            Control::Open { screen, .. } => {
                let input =
                    SessionInput::Open { viewer: viewer.to_string(), screen: screen.into() };
                match self.session.apply(input) {
                    Ok(effects) => {
                        let mut out =
                            vec![Control::Opened { session: self.session_id, main_stream: 0 }];
                        out.extend(self.run_effects(effects, p));
                        out
                    }
                    Err(_) => vec![Control::Refused { reason: RefuseReason::Busy }],
                }
            }
            Control::Visibility { visible } => {
                let input =
                    SessionInput::Visibility { viewer: viewer.to_string(), visible: *visible };
                match self.session.apply(input) {
                    Ok(effects) => self.run_effects(effects, p),
                    Err(_) => Vec::new(),
                }
            }
            Control::Screen { seq, screen } => {
                let input =
                    SessionInput::Screen { viewer: viewer.to_string(), screen: screen.into() };
                match self.session.apply(input) {
                    Ok(effects) => {
                        let mut out = self.run_effects(effects, p);
                        if let Some(applied) = self.screen {
                            out.push(Control::ScreenApplied {
                                seq: *seq,
                                pixel_width: (f64::from(applied.css_width) * applied.scale).ceil()
                                    as u32,
                                pixel_height: (f64::from(applied.css_height) * applied.scale).ceil()
                                    as u32,
                                scale: applied.scale,
                            });
                        }
                        out
                    }
                    Err(_) => Vec::new(),
                }
            }
            Control::Close => {
                match self.session.apply(SessionInput::Leave { viewer: viewer.to_string() }) {
                    Ok(effects) => {
                        let mut out = self.run_effects(effects, p);
                        out.push(Control::Closed { reason: "viewer_closed".to_string() });
                        out
                    }
                    Err(_) => Vec::new(),
                }
            }
            Control::MenuResult { token, choice } => {
                let Ok(outcome) =
                    self.menus.apply(MenuInput::Result { token: *token, choice: choice.clone() })
                else {
                    return Vec::new();
                };
                for effect in outcome.effects {
                    if let MenuEffect::ChromeContinue { token, choice } = effect {
                        self.answer_fork(token, &choice, p);
                    }
                }
                Vec::new()
            }
            _ => Vec::new(),
        }
    }

    fn answer_fork(&mut self, rb_token: u64, choice: &MenuChoice, p: &mut dyn Presentation) {
        let Some(menu) = self.fork_menu.take_if(|m| m.rb_token == rb_token) else { return };
        match (menu.kind, choice) {
            (MenuKind::Context, MenuChoice::Command { id }) => {
                p.context_menu_result(menu.fork_token, Some(*id));
            }
            (MenuKind::Select, MenuChoice::Indices { indices }) => {
                p.popup_menu_result(menu.fork_token, Some(indices));
            }
            (MenuKind::Context, _) => {
                p.context_menu_result(menu.fork_token, None);
            }
            (MenuKind::Select, _) => {
                p.popup_menu_result(menu.fork_token, None);
            }
        }
    }

    /// Chromium opened a context menu or a `<select>` popup (fork token);
    /// returns the messages for the viewers.
    pub fn menu_opened(
        &mut self,
        fork_token: i64,
        menu: Menu,
        p: &mut dyn Presentation,
    ) -> Vec<Control> {
        let mut item_ids = Vec::new();
        flatten_ids(&menu.items, &mut item_ids);
        let item_count = u32::try_from(menu.items.len()).unwrap_or(u32::MAX);
        let Ok(outcome) = self.menus.apply(MenuInput::Show {
            kind: menu.kind,
            item_ids,
            item_count,
            multiple: menu.multiple,
        }) else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for effect in outcome.effects {
            match effect {
                MenuEffect::ChromeCancel { token } => {
                    self.answer_fork(token, &MenuChoice::Cancel, p);
                }
                MenuEffect::ViewerCancel { token } => out.push(Control::MenuCancel { token }),
                MenuEffect::ViewerShow { token } => {
                    self.fork_menu =
                        Some(ForkMenu { rb_token: token, kind: menu.kind, fork_token });
                    out.push(Control::MenuShow { token, menu: menu.clone() });
                }
                MenuEffect::ChromeContinue { token, choice } => self.answer_fork(token, &choice, p),
            }
        }
        out
    }

    /// One viewer input event. `Ok(false)` while the tab has no browser yet.
    pub fn input(
        &mut self,
        event: &InputEvent,
        p: &mut dyn Presentation,
    ) -> Result<bool, InputReject> {
        let call = map_input(event)?;
        match self.browser {
            Some(browser) => Ok(p.input(browser, &call)),
            None => Ok(false),
        }
    }

    /// The anchor of a `<select>` popup in the page (helper for the shim's
    /// callback, which gives integers).
    pub fn anchor(x: i32, y: i32, width: i32, height: i32) -> Rect {
        Rect {
            x: f64::from(x),
            y: f64::from(y),
            width: f64::from(width),
            height: f64::from(height),
        }
    }

    pub fn state(&self) -> SessionState {
        self.session.state
    }
}
