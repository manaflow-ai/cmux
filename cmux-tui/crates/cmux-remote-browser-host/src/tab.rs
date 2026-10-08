//! One remote tab on the host: viewer control and input in, calls on the
//! presentation (the CEF shim) and control messages for the viewers out.
//! Pure; the shim and the transport live outside.

use std::collections::{BTreeMap, BTreeSet};

use cmux_remote_browser::menu::{MenuEffect, MenuInput, MenuReject, MenuTokens, command_ids};
use cmux_remote_browser::proto::{
    Control, Dialog, HistoryOp, InputEvent, Menu, MenuChoice, MenuKind, PointerKind, Rect,
    RefuseReason, SessionState, SurfaceKind,
};
use cmux_remote_browser::rp_input::{InputReject, RpCall, map_input};
use cmux_remote_browser::session::{ScreenSize, Session, SessionEffect, SessionInput};

pub use crate::page::PageChange;
use crate::page::{PageState, css_cursor, cursor_message, disposition};

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
    /// Answers the JS dialog with the fork's token (`text` for a prompt).
    fn dialog_result(&mut self, fork_token: i64, accept: bool, text: Option<&str>) -> bool;
    /// The viewer's window is active or not (page popups open only in an
    /// active widget; `cmux_rp_set_active`).
    fn set_active(&mut self, browser: i32, active: bool) -> bool;
    /// Captures popup surface `surface` (its frames name the surface).
    fn surface_capture(&mut self, surface: u32) -> bool;
    /// Closes popup surface `surface`; the fork then reports it hidden.
    fn surface_close(&mut self, surface: u32);
    /// Loads `url` in the tab's main frame (`rb.navigate`).
    fn load_url(&mut self, browser: i32, url: &str) -> bool;
    /// Back, forward, reload or stop (`rb.history`).
    fn history(&mut self, browser: i32, op: HistoryOp) -> bool;
}

/// What the host does for a popup surface (RP7) besides the shim calls.
#[derive(Debug, Clone, PartialEq)]
pub enum SurfaceOut {
    /// Send to the viewers.
    Control(Control),
    /// Encode `surface`'s frames on `stream` (`width` x `height` pixels)
    /// with an encoder of their own. Comes before the `rb.surface.show`
    /// that names the stream.
    AddStream { surface: u32, stream: u16, width: u32, height: u32 },
    /// Stop encoding `stream` and give its held frame back.
    RemoveStream { stream: u16 },
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
    /// The shim accepted the capture (it refuses while the tab has no view).
    capture_on: bool,
    screen: Option<ScreenSize>,
    /// Each open viewer's last screen seq (`rb.open` is seq 0).
    viewer_seqs: BTreeMap<String, u32>,
    /// The token the next JS dialog gets (tokens start at 1, never repeat).
    next_dialog: u64,
    fork_dialog: Option<ForkDialog>,
    /// The rd input seq of the last key-down applied, until the page
    /// reports a key unhandled.
    last_key_down: Option<u32>,
    /// `rb.page` facts as last sent.
    page: PageState,
    /// The CSS cursor last sent (`rb.cursor`).
    cursor: Option<&'static str>,
    /// A URL a viewer navigated to before the browser existed.
    pending_url: Option<String>,
    /// The request the next `rb.open_tab` gets (from 1).
    next_open_tab: u64,
    /// `rb.open_tab` requests the App has not answered.
    open_tabs: BTreeSet<u64>,
    /// Keys a viewer holds down (DOM code to DOM key), from its input.
    held_keys: BTreeMap<String, String>,
    /// Mouse buttons a viewer holds down, per surface (0 = page).
    held_buttons: BTreeSet<(u32, u8)>,
    /// The last pointer position per surface: a released button goes up there.
    pointer_at: BTreeMap<u32, (f64, f64)>,
    /// Open popup surfaces (RP7) by the fork's surface id.
    surfaces: BTreeMap<u32, HostSurface>,
    /// The stream the next shown surface gets (never 0, the page's).
    next_stream: u16,
}

/// One open popup surface.
#[derive(Debug, Clone, Copy, PartialEq)]
struct HostSurface {
    kind: SurfaceKind,
    /// Its rect in the page (DIP).
    anchor: Rect,
    /// Its stream and pixel size once a frame arrived.
    shown: Option<(u16, u32, u32)>,
}

/// The JS dialog Chromium has open, with the fork's own token.
#[derive(Debug, Clone, Copy, PartialEq)]
struct ForkDialog {
    rb_token: u64,
    fork_token: i64,
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
            capture_on: false,
            screen: None,
            viewer_seqs: BTreeMap::new(),
            next_dialog: 1,
            fork_dialog: None,
            last_key_down: None,
            page: PageState::default(),
            cursor: None,
            pending_url: None,
            next_open_tab: 1,
            open_tabs: BTreeSet::new(),
            held_keys: BTreeMap::new(),
            held_buttons: BTreeSet::new(),
            pointer_at: BTreeMap::new(),
            surfaces: BTreeMap::new(),
            next_stream: 1,
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
                        self.start_capture(browser, p);
                    }
                }
                SessionEffect::StopCapture => {
                    self.capture_wanted = false;
                    if let Some(browser) = self.browser {
                        // No viewer sees the popups: close them (the fork
                        // reports each hidden, which hides it on the viewers).
                        for &surface in self.surfaces.keys() {
                            p.surface_close(surface);
                        }
                        p.capture(browser, false);
                        p.set_active(browser, false);
                    }
                    self.capture_on = false;
                }
                SessionEffect::NotifyState { state } => out.push(Control::State { state }),
                SessionEffect::StopPage => {
                    if let Some(browser) = self.browser.take() {
                        p.close_tab(browser);
                    }
                    self.capture_on = false;
                }
            }
        }
        out
    }

    /// The shim created the tab's browser.
    pub fn tab_created(&mut self, browser: i32, p: &mut dyn Presentation) {
        self.browser = Some(browser);
        if let Some(url) = self.pending_url.take() {
            p.load_url(browser, &url);
        }
        if self.capture_wanted {
            self.start_capture(browser, p);
        }
    }

    /// Captures the page; a captured tab is active (a viewer sees it), so
    /// its page popups can open.
    fn start_capture(&mut self, browser: i32, p: &mut dyn Presentation) {
        self.capture_on = p.capture(browser, true);
        if self.capture_on {
            p.set_active(browser, true);
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
                // A viewer that is open already (the stream carrier opens
                // its viewer on join) re-opens: its screen applies and its
                // screen seq restarts at 0, with no second `rb.opened`.
                let reopen = self.viewer_seqs.contains_key(viewer);
                let input =
                    SessionInput::Open { viewer: viewer.to_string(), screen: screen.into() };
                match self.session.apply(input) {
                    Ok(effects) => {
                        self.viewer_seqs.insert(viewer.to_string(), 0);
                        let mut out = Vec::new();
                        if !reopen {
                            out.push(Control::Opened { session: self.session_id, main_stream: 0 });
                        }
                        out.extend(self.run_effects(effects, p));
                        out.extend(self.screen_applied(viewer));
                        out.extend(self.page.snapshot());
                        if let Some(kind) = self.cursor {
                            out.push(cursor_message(kind));
                        }
                        out
                    }
                    Err(_) => vec![Control::Refused { reason: RefuseReason::Busy }],
                }
            }
            Control::Navigate { url } => {
                match self.browser {
                    Some(browser) => {
                        p.load_url(browser, url);
                    }
                    None => self.pending_url = Some(url.clone()),
                }
                Vec::new()
            }
            Control::History { op } => {
                if let Some(browser) = self.browser {
                    p.history(browser, *op);
                }
                Vec::new()
            }
            Control::OpenTabResult { request, .. } => {
                // The App opened the tab on a host of its own (or refused);
                // nothing waits for it here.
                self.open_tabs.remove(request);
                Vec::new()
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
                        self.viewer_seqs.insert(viewer.to_string(), *seq);
                        let mut out = self.run_effects(effects, p);
                        out.extend(self.screen_applied(viewer));
                        out
                    }
                    Err(_) => Vec::new(),
                }
            }
            Control::Close => {
                // A viewer that leaves cannot send the releases of what it held.
                self.release_all(p);
                match self.session.apply(SessionInput::Leave { viewer: viewer.to_string() }) {
                    Ok(effects) => {
                        self.viewer_seqs.remove(viewer);
                        let mut out = self.run_effects(effects, p);
                        out.push(Control::Closed { reason: "viewer_closed".to_string() });
                        out
                    }
                    Err(_) => Vec::new(),
                }
            }
            Control::MenuResult { token, choice } => {
                let outcome = match self
                    .menus
                    .apply(MenuInput::Result { token: *token, choice: choice.clone() })
                {
                    Ok(outcome) => outcome,
                    // A choice the menu never offered: cancel the menu rather
                    // than leave Chromium waiting (remote-tab-protocol.md 5.2).
                    Err(MenuReject::InvalidChoice) => {
                        return self.cancel_menu(*token, p);
                    }
                    Err(MenuReject::UnknownToken) => return Vec::new(),
                };
                for effect in outcome.effects {
                    if let MenuEffect::ChromeContinue { token, choice } = effect {
                        self.answer_fork(token, &choice, p);
                    }
                }
                Vec::new()
            }
            Control::DialogResult { token, accept, text } => {
                if let Some(open) = self.fork_dialog.take_if(|d| d.rb_token == *token) {
                    p.dialog_result(open.fork_token, *accept, text.as_deref());
                }
                Vec::new()
            }
            _ => Vec::new(),
        }
    }

    /// Closes the open menu `token` on both sides: Chromium gets cancel,
    /// the viewers get `rb.menu.cancel`.
    fn cancel_menu(&mut self, token: u64, p: &mut dyn Presentation) -> Vec<Control> {
        let Ok(outcome) = self.menus.apply(MenuInput::PageCancel { token }) else {
            return Vec::new();
        };
        let mut out = Vec::new();
        for effect in outcome.effects {
            if let MenuEffect::ViewerCancel { token } = effect {
                self.answer_fork(token, &MenuChoice::Cancel, p);
                out.push(Control::MenuCancel { token });
            }
        }
        out
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

    /// Chromium closed its menu itself (the `<select>` went away or the
    /// page navigated): the viewers get `rb.menu.cancel`, Chromium gets no
    /// answer.
    pub fn menu_closed_by_page(&mut self, fork_token: i64) -> Vec<Control> {
        let Some(open) = self.fork_menu.take_if(|m| m.fork_token == fork_token) else {
            return Vec::new();
        };
        let Ok(outcome) = self.menus.apply(MenuInput::PageCancel { token: open.rb_token }) else {
            return Vec::new();
        };
        outcome
            .effects
            .into_iter()
            .filter_map(|e| match e {
                MenuEffect::ViewerCancel { token } => Some(Control::MenuCancel { token }),
                _ => None,
            })
            .collect()
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
        command_ids(&menu.items, &mut item_ids);
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
        let Some(browser) = self.browser else { return Ok(false) };
        if let RpCall::SurfaceMouse { surface, .. } = call
            && !self.surfaces.contains_key(&surface)
        {
            return Ok(false);
        }
        self.note_held(event);
        Ok(p.input(browser, &call))
    }

    /// One viewer input event with its rd input seq (`None` when unknown):
    /// a key-down's seq is what `rb.key_unhandled` names.
    pub fn input_seq(
        &mut self,
        event: &InputEvent,
        seq: Option<u32>,
        p: &mut dyn Presentation,
    ) -> Result<bool, InputReject> {
        let sent = self.input(event, p)?;
        if sent && let InputEvent::Key { down: true, .. } = event {
            self.last_key_down = seq;
        }
        Ok(sent)
    }

    /// The page did not handle the last key-down: `rb.key_unhandled`
    /// naming its seq (once).
    pub fn key_unhandled(&mut self) -> Option<Control> {
        self.last_key_down.take().map(|input_seq| Control::KeyUnhandled { input_seq })
    }

    /// A page fact changed: `rb.page` with every fact, when one moved.
    pub fn page_changed(&mut self, change: PageChange) -> Option<Control> {
        self.page.apply(change)
    }

    /// The page's cursor changed (`cef_cursor_type_t`): `rb.cursor` when
    /// the shape moved.
    pub fn cursor_changed(&mut self, cef_type: i32) -> Option<Control> {
        let kind = css_cursor(cef_type)?;
        if self.cursor == Some(kind) {
            return None;
        }
        self.cursor = Some(kind);
        Some(cursor_message(kind))
    }

    /// The page asked for a new tab or window (`cef_window_open_disposition_t`):
    /// `rb.open_tab` for the App, or `None` for a disposition that opens nothing.
    pub fn popup_requested(
        &mut self,
        url: &str,
        cef_disposition: i32,
        user_gesture: bool,
    ) -> Option<Control> {
        let disposition = disposition(cef_disposition)?;
        let request = self.next_open_tab;
        self.next_open_tab = self.next_open_tab.wrapping_add(1).max(1);
        self.open_tabs.insert(request);
        Some(Control::OpenTab { request, url: url.to_string(), disposition, user_gesture })
    }

    /// Records which keys and buttons the viewer holds after `event`.
    fn note_held(&mut self, event: &InputEvent) {
        match event {
            InputEvent::Key { down: true, code, key, .. } => {
                self.held_keys.insert(code.clone(), key.clone());
            }
            InputEvent::Key { down: false, code, .. } => {
                self.held_keys.remove(code);
            }
            InputEvent::Pointer { surface, kind, x, y, button, .. } => {
                self.pointer_at.insert(*surface, (*x, *y));
                match kind {
                    PointerKind::Down => {
                        self.held_buttons.insert((*surface, *button));
                    }
                    PointerKind::Up => {
                        self.held_buttons.remove(&(*surface, *button));
                    }
                    PointerKind::Move | PointerKind::Enter | PointerKind::Leave => {}
                }
            }
            _ => {}
        }
    }

    /// The engine's "release all keys and buttons" signal (the input
    /// skipped a gap, so a release may be lost): a key-up for every key and
    /// a button-up for every button a viewer holds down, then none is held.
    pub fn release_all(&mut self, p: &mut dyn Presentation) {
        let keys = std::mem::take(&mut self.held_keys);
        let buttons = std::mem::take(&mut self.held_buttons);
        let Some(browser) = self.browser else { return };
        for (code, key) in keys {
            let up = RpCall::SendKey {
                down: false,
                code,
                key,
                text: String::new(),
                unmodified_text: String::new(),
                modifiers: 0,
                commands: Vec::new(),
            };
            p.input(browser, &up);
        }
        for (surface, button) in buttons {
            let (x, y) = self.pointer_at.get(&surface).copied().unwrap_or((0.0, 0.0));
            let (kind, button, click_count, modifiers) = (2, i32::from(button), 1, 0);
            let up = if surface == 0 {
                RpCall::PageMouse { kind, x, y, button, click_count, modifiers }
            } else {
                RpCall::SurfaceMouse { surface, kind, x, y, button, click_count, modifiers }
            };
            p.input(browser, &up);
        }
    }

    /// Keys and buttons a viewer holds down now.
    pub fn held(&self) -> (usize, usize) {
        (self.held_keys.len(), self.held_buttons.len())
    }

    /// The fork opened (`visible`) or moved popup surface `surface` at
    /// `anchor` (page DIP), or closed it.
    pub fn surface_changed(
        &mut self,
        surface: u32,
        kind: SurfaceKind,
        visible: bool,
        anchor: Rect,
        p: &mut dyn Presentation,
    ) -> Vec<SurfaceOut> {
        if !visible {
            let Some(gone) = self.surfaces.remove(&surface) else { return Vec::new() };
            self.held_buttons.retain(|&(s, _)| s != surface);
            self.pointer_at.remove(&surface);
            return match gone.shown {
                Some((stream, _, _)) => vec![
                    SurfaceOut::Control(Control::SurfaceHide { surface }),
                    SurfaceOut::RemoveStream { stream },
                ],
                None => Vec::new(),
            };
        }
        if let Some(open) = self.surfaces.get_mut(&surface) {
            if open.anchor == anchor {
                return Vec::new();
            }
            open.anchor = anchor;
            return match open.shown {
                Some((_, width, height)) => vec![SurfaceOut::Control(Control::SurfaceUpdate {
                    surface,
                    anchor,
                    width,
                    height,
                })],
                None => Vec::new(),
            };
        }
        if p.surface_capture(surface) {
            self.surfaces.insert(surface, HostSurface { kind, anchor, shown: None });
        } else {
            // A surface no viewer can see would trap the page's focus.
            p.surface_close(surface);
        }
        Vec::new()
    }

    /// A captured frame of `surface` with its pixel size: the first one
    /// (or one of a new size) gives the surface a stream and shows it.
    pub fn surface_frame(&mut self, surface: u32, width: u32, height: u32) -> Vec<SurfaceOut> {
        let Some(open) = self.surfaces.get(&surface).copied() else { return Vec::new() };
        let mut out = Vec::new();
        match open.shown {
            Some((_, w, h)) if (w, h) == (width, height) => return out,
            // A new size is a new encoder: the old stream ends, a new one starts.
            Some((stream, _, _)) => {
                out.push(SurfaceOut::Control(Control::SurfaceHide { surface }));
                out.push(SurfaceOut::RemoveStream { stream });
            }
            None => {}
        }
        let stream = self.next_stream;
        self.next_stream = self.next_stream.checked_add(1).unwrap_or(1);
        if let Some(entry) = self.surfaces.get_mut(&surface) {
            entry.shown = Some((stream, width, height));
        }
        out.push(SurfaceOut::AddStream { surface, stream, width, height });
        out.push(SurfaceOut::Control(Control::SurfaceShow {
            surface,
            stream,
            kind: open.kind,
            anchor: open.anchor,
            width,
            height,
        }));
        out
    }

    /// The stream that carries `surface`, once it is shown.
    pub fn surface_stream(&self, surface: u32) -> Option<u16> {
        self.surfaces.get(&surface)?.shown.map(|(stream, _, _)| stream)
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

    /// `rb.screen_applied` for `viewer`: the applied size under that
    /// viewer's own last seq. The host loop sends it to every open viewer
    /// when one viewer's change moves the applied size. `None` for an
    /// unknown viewer or before a screen was applied.
    pub fn screen_applied(&self, viewer: &str) -> Option<Control> {
        let seq = *self.viewer_seqs.get(viewer)?;
        let applied = self.screen?;
        Some(Control::ScreenApplied {
            seq,
            pixel_width: (f64::from(applied.css_width) * applied.scale).ceil() as u32,
            pixel_height: (f64::from(applied.css_height) * applied.scale).ceil() as u32,
            scale: applied.scale,
        })
    }

    /// Chromium opened a JS dialog (alert, confirm, prompt, beforeunload)
    /// with the fork's token; returns the messages for the viewers. A
    /// dialog still open on the viewers is cancelled first (Chromium shows
    /// one at a time, so a new one means the old one is gone).
    pub fn dialog_opened(
        &mut self,
        fork_token: i64,
        dialog: Dialog,
        _p: &mut dyn Presentation,
    ) -> Vec<Control> {
        let mut out = self.dialog_reset();
        let token = self.next_dialog;
        self.next_dialog += 1;
        self.fork_dialog = Some(ForkDialog { rb_token: token, fork_token });
        out.push(Control::DialogShow { token, dialog });
        out
    }

    /// Chromium reset its dialog state (the page navigated away or closed):
    /// its callback is gone, so the open dialog is cancelled on the viewers
    /// (`rb.dialog.cancel`) and a late answer reaches nothing.
    pub fn dialog_reset(&mut self) -> Vec<Control> {
        match self.fork_dialog.take() {
            Some(open) => vec![Control::DialogCancel { token: open.rb_token }],
            None => Vec::new(),
        }
    }

    /// Starts the wanted capture that the shim refused before (call it on
    /// the tab's later shim callbacks: title, URL, load).
    pub fn retry_capture(&mut self, p: &mut dyn Presentation) {
        if let (true, false, Some(browser)) = (self.capture_wanted, self.capture_on, self.browser) {
            self.start_capture(browser, p);
        }
    }

    /// The shim captures this tab now.
    pub fn capturing(&self) -> bool {
        self.capture_on
    }

    pub fn state(&self) -> SessionState {
        self.session.state
    }
}
