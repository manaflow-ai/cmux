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
    pub fn tab_created(&mut self, _browser: i32, _p: &mut dyn Presentation) {}
    pub fn first_frame(&mut self, _p: &mut dyn Presentation) -> Vec<Control> {
        Vec::new()
    }
    pub fn renderer_crashed(&mut self, _p: &mut dyn Presentation) -> Vec<Control> {
        Vec::new()
    }
    pub fn control(&mut self, _viewer: &str, _msg: &Control, _p: &mut dyn Presentation) -> Vec<Control> {
        Vec::new()
    }
    pub fn menu_opened(&mut self, _fork_token: i64, _menu: Menu, _p: &mut dyn Presentation) -> Vec<Control> {
        Vec::new()
    }
    pub fn input(&mut self, _event: &InputEvent, _p: &mut dyn Presentation) -> Result<bool, InputReject> {
        Ok(false)
    }
    pub fn anchor(x: i32, y: i32, width: i32, height: i32) -> Rect {
        Rect { x: f64::from(x), y: f64::from(y), width: f64::from(width), height: f64::from(height) }
    }
    pub fn state(&self) -> SessionState {
        self.session.state
    }
}
