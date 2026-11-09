//! X11 input, in the order desktop.rs asks for:
//!
//! 1. AT-SPI: press an element through its own action, insert text into
//!    an editable element. Touches nothing else; `confirmed` when the
//!    element's text reads back.
//! 2. Window-scoped events (background): XSendEvent to the exact X window
//!    under the point (or the window holding the app's focus). Nothing
//!    global moves. Apps may ignore synthetic events (xterm unless
//!    allowSendEvents is on), so the evidence is `delivered`.
//! 3. XTest (global: it moves the real pointer and types into the focused
//!    window): only with `Delivery::Foreground`, after activating the
//!    window, or on a headless server where no person shares the pointer,
//!    and then only when the target is on top at the point (pointer) or
//!    holds the input focus (keys).

use std::os::fd::AsRawFd;
use std::time::{Duration, Instant};

use x11rb::CURRENT_TIME;
use x11rb::connection::Connection as _;
use x11rb::protocol::xproto::{
    self, ButtonPressEvent, ChangeWindowAttributesAux, ClientMessageEvent, ConfigureWindowAux,
    ConnectionExt as _, EventMask, InputFocus, KeyButMask, KeyPressEvent, MotionNotifyEvent,
    StackMode, Window as XWindow,
};
use x11rb::protocol::xtest::ConnectionExt as _;

use super::super::{contains, keysym, mark_injection};
use super::{Client, X11Desktop, xerr};
use crate::desktop::*;
use crate::keys::{KeyCombo, Modifier};

/// One keystroke: keycode plus whether Shift is needed for the keysym.
#[derive(Clone, Copy, Debug)]
struct Stroke {
    code: u8,
    shift: bool,
}

impl X11Desktop {
    // ----- pointer ------------------------------------------------------

    pub(crate) fn click_impl(
        &self,
        target: &PointerTarget,
        spec: &ClickSpec,
    ) -> DResult<ActionOutcome> {
        let c = self.client(target.window_id())?;
        let simple = spec.button == Button::Left && spec.count == 1 && spec.modifiers.is_empty();
        let point = match target {
            PointerTarget::Element { window_id, element_id } => {
                let (a, _) = self.frame_obj(&c)?;
                let obj = a.element(window_id, element_id)?;
                let center = a.center(&obj, super::Coords::Screen);
                if simple && spec.delivery == Delivery::Background {
                    match a.press(&obj) {
                        Ok(name) => {
                            return Ok(with_at(
                                ActionOutcome::delivered("atspi_action"),
                                center,
                                &name,
                            ));
                        }
                        Err(DesktopError::Unsupported(_)) => {}
                        Err(e) => return Err(e),
                    }
                }
                center.ok_or_else(|| {
                    DesktopError::Unsupported(
                        "the element has no action and no position; use its window and a point"
                            .into(),
                    )
                })?
            }
            PointerTarget::Point { point, .. } => *point,
        };
        if !contains(&c.rect, point.x, point.y) {
            return Err(DesktopError::TargetNotFound("the point is outside the window".into()));
        }
        if simple
            && spec.delivery == Delivery::Background
            && matches!(target, PointerTarget::Point { .. })
            && let Some(out) = self.atspi_press_at(&c, point)
        {
            return Ok(out);
        }
        self.pointer_click(&c, point, spec)
    }

    /// Presses the actionable element under the point, when the tree has one.
    fn atspi_press_at(&self, c: &Client, point: Point) -> Option<ActionOutcome> {
        let (a, f) = self.frame_obj(c).ok()?;
        let hit = a.at_point(&f.obj, point, super::Coords::Screen)?;
        let obj = a.actionable_ancestor(&hit, &f.obj)?;
        // Only an element that sits at the point itself, not a large
        // container whose default action does something else.
        let r = a.extents(&obj, super::Coords::Screen)?;
        if !contains(&r, point.x, point.y) {
            return None;
        }
        let name = a.press(&obj).ok()?;
        Some(with_at(ActionOutcome::delivered("atspi_action"), Some(point), &name))
    }

    fn pointer_click(&self, c: &Client, p: Point, spec: &ClickSpec) -> DResult<ActionOutcome> {
        let button = button_code(spec.button);
        if let Some(route) = self.xtest_route(c, spec.delivery, Some(p))? {
            let mods = self.modifier_codes(&spec.modifiers)?;
            self.xtest_motion(p)?;
            for m in &mods {
                self.fake(xproto::KEY_PRESS_EVENT, *m)?;
            }
            for _ in 0..spec.count {
                self.fake(xproto::BUTTON_PRESS_EVENT, button)?;
                self.fake(xproto::BUTTON_RELEASE_EVENT, button)?;
            }
            for m in mods.iter().rev() {
                self.fake(xproto::KEY_RELEASE_EVENT, *m)?;
            }
            self.flush()?;
            return Ok(ActionOutcome::delivered(route).at(p));
        }
        let state = modifier_mask(&spec.modifiers);
        let (win, local) = self.deepest_at(c, p)?;
        for _ in 0..spec.count {
            self.send_button(win, p, local, button, true, state)?;
            self.send_button(win, p, local, button, false, state | button_mask(button))?;
        }
        self.flush()?;
        Ok(synthetic_note(ActionOutcome::delivered("xsendevent").at(p)))
    }

    pub(crate) fn scroll_impl(
        &self,
        target: &PointerTarget,
        dx: f64,
        dy: f64,
    ) -> DResult<ActionOutcome> {
        let c = self.client(target.window_id())?;
        let p = self.point_of(&c, target)?;
        let mut steps: Vec<(u8, u32)> = Vec::new();
        let lines = |v: f64| (v.abs().round() as u32).clamp(u32::from(v != 0.0), 50);
        if dy != 0.0 {
            steps.push((if dy > 0.0 { 5 } else { 4 }, lines(dy)));
        }
        if dx != 0.0 {
            steps.push((if dx > 0.0 { 7 } else { 6 }, lines(dx)));
        }
        if let Some(route) = self.xtest_route(&c, Delivery::Background, Some(p))? {
            self.xtest_motion(p)?;
            for (b, n) in &steps {
                for _ in 0..*n {
                    self.fake(xproto::BUTTON_PRESS_EVENT, *b)?;
                    self.fake(xproto::BUTTON_RELEASE_EVENT, *b)?;
                }
            }
            self.flush()?;
            return Ok(ActionOutcome::delivered(route).at(p));
        }
        let (win, local) = self.deepest_at(&c, p)?;
        for (b, n) in &steps {
            for _ in 0..*n {
                self.send_button(win, p, local, *b, true, 0)?;
                self.send_button(win, p, local, *b, false, button_mask(*b))?;
            }
        }
        self.flush()?;
        Ok(synthetic_note(ActionOutcome::delivered("xsendevent").at(p)))
    }

    pub(crate) fn drag_impl(
        &self,
        window_id: &str,
        from: Point,
        to: Point,
        button: Button,
        delivery: Delivery,
    ) -> DResult<ActionOutcome> {
        let c = self.client(window_id)?;
        if !contains(&c.rect, from.x, from.y) || !contains(&c.rect, to.x, to.y) {
            return Err(DesktopError::TargetNotFound("the drag leaves the window".into()));
        }
        let b = button_code(button);
        let steps = 12;
        let lerp = |i: u32| Point {
            x: from.x + (to.x - from.x) * f64::from(i) / f64::from(steps),
            y: from.y + (to.y - from.y) * f64::from(i) / f64::from(steps),
        };
        if let Some(route) = self.xtest_route(&c, delivery, Some(from))? {
            self.xtest_motion(from)?;
            self.fake(xproto::BUTTON_PRESS_EVENT, b)?;
            for i in 1..=steps {
                self.xtest_motion(lerp(i))?;
            }
            self.fake(xproto::BUTTON_RELEASE_EVENT, b)?;
            self.flush()?;
            return Ok(ActionOutcome::delivered(route).at(to));
        }
        // The press window keeps every event of the drag (an implicit grab).
        let (win, local) = self.deepest_at(&c, from)?;
        let off = Point { x: from.x - f64::from(local.0), y: from.y - f64::from(local.1) };
        self.send_button(win, from, local, b, true, 0)?;
        for i in 1..=steps {
            let p = lerp(i);
            self.send_motion(win, p, ((p.x - off.x) as i16, (p.y - off.y) as i16), button_mask(b))?;
        }
        self.send_button(
            win,
            to,
            ((to.x - off.x) as i16, (to.y - off.y) as i16),
            b,
            false,
            button_mask(b),
        )?;
        self.flush()?;
        Ok(synthetic_note(ActionOutcome::delivered("xsendevent").at(to)))
    }

    fn point_of(&self, c: &Client, target: &PointerTarget) -> DResult<Point> {
        let p = match target {
            PointerTarget::Point { point, .. } => *point,
            PointerTarget::Element { window_id, element_id } => {
                let (a, _) = self.frame_obj(c)?;
                let obj = a.element(window_id, element_id)?;
                a.center(&obj, super::Coords::Screen).ok_or_else(|| {
                    DesktopError::Unsupported("the element has no position".into())
                })?
            }
        };
        if !contains(&c.rect, p.x, p.y) {
            return Err(DesktopError::TargetNotFound("the point is outside the window".into()));
        }
        Ok(p)
    }

    // ----- keyboard -----------------------------------------------------

    pub(crate) fn type_impl(
        &self,
        window_id: &str,
        element_id: Option<&str>,
        text: &str,
        delivery: Delivery,
    ) -> DResult<ActionOutcome> {
        let c = self.client(window_id)?;
        if delivery == Delivery::Background
            && let Some(out) = self.atspi_type(&c, window_id, element_id, text)?
        {
            return Ok(out);
        }
        let syms: Vec<u32> = text.chars().map(keysym::of_char).collect();
        self.key_route(&c, delivery, |me, route| {
            for sym in &syms {
                me.stroke(route, *sym, 0)?;
            }
            Ok(())
        })
    }

    /// AT-SPI text insert; `None` when the window has no editable target
    /// (then keys are sent).
    fn atspi_type(
        &self,
        c: &Client,
        window_id: &str,
        element_id: Option<&str>,
        text: &str,
    ) -> DResult<Option<ActionOutcome>> {
        let Ok((a, f)) = self.frame_obj(c) else {
            return if element_id.is_some() {
                Err(DesktopError::Unsupported(
                    "element_id needs the accessibility tree, which this app does not expose"
                        .into(),
                ))
            } else {
                Ok(None)
            };
        };
        let obj = match element_id {
            Some(id) => Some(a.element(window_id, id)?),
            None => a.typing_target(&f.obj)?,
        };
        let Some(obj) = obj else { return Ok(None) };
        match a.insert_text(&obj, text) {
            Ok(confirmed) => {
                let route = "atspi_insert_text";
                let out = if confirmed {
                    ActionOutcome::confirmed(route)
                } else {
                    ActionOutcome::delivered(route)
                };
                Ok(Some(with_at(out, a.center(&obj, super::Coords::Screen), "")))
            }
            Err(DesktopError::Unsupported(_)) if element_id.is_none() => Ok(None),
            Err(DesktopError::Unsupported(_)) => {
                // Not editable text (a terminal, a canvas): focus it in its
                // app and send keys there.
                let _ = a.perform(&obj, "focus");
                Ok(None)
            }
            Err(e) => Err(e),
        }
    }

    pub(crate) fn keys_impl(
        &self,
        window_id: &str,
        combo: &KeyCombo,
        delivery: Delivery,
    ) -> DResult<ActionOutcome> {
        let c = self.client(window_id)?;
        let sym = keysym::of_key(&combo.key);
        let mods: Vec<Modifier> =
            combo.modifiers.iter().copied().filter(|m| *m != Modifier::Fn).collect();
        self.key_route(&c, delivery, |me, route| {
            if matches!(route, Route::Send(_)) {
                return me.stroke(route, sym, modifier_mask(&mods));
            }
            let codes = me.modifier_codes(&mods)?;
            for m in &codes {
                me.fake(xproto::KEY_PRESS_EVENT, *m)?;
            }
            me.stroke(route, sym, 0)?;
            for m in codes.iter().rev() {
                me.fake(xproto::KEY_RELEASE_EVENT, *m)?;
            }
            Ok(())
        })
    }

    fn key_route(
        &self,
        c: &Client,
        delivery: Delivery,
        f: impl FnOnce(&Self, Route) -> DResult<()>,
    ) -> DResult<ActionOutcome> {
        let (route, name, lend_focus) = match self.xtest_route(c, delivery, None)? {
            Some(name) => (Route::XTest, name, false),
            None => match self.focus_in(c) {
                Some(focus) => (Route::Send(focus), "xsendevent", false),
                None => (Route::Send(c.win), "xsendevent", self.needs_lent_focus(c)),
            },
        };
        // A window without the keyboard focus whose toolkit tracks focus from
        // FocusIn (Tk, Motif) drops keys it gets while it thinks it lacks it.
        // Tell only this window it has the focus for these keys, then take it
        // back; the server's real focus, the person's, never moves.
        if lend_focus {
            self.send_focus(c.win, true)?;
        }
        let result = f(self, route);
        if lend_focus {
            let _ = self.send_focus(c.win, false);
            // The person moved the real focus to the target meanwhile: it holds
            // it, so it hears that again after the FocusOut above.
            if self.focus_in(c).is_some() {
                let _ = self.send_focus(c.win, true);
            }
        }
        self.restore_keymap();
        result?;
        self.flush()?;
        let out = ActionOutcome::delivered(name);
        Ok(if matches!(route, Route::Send(_)) { synthetic_note(out) } else { out })
    }

    fn stroke(&self, route: Route, sym: u32, state: u32) -> DResult<()> {
        let s = match self.lookup(sym) {
            Some(s) => s,
            None if route == Route::XTest => self.remap_spare(sym)?,
            None => {
                return Err(DesktopError::Unsupported(format!(
                    "keysym 0x{sym:x} is not on this keyboard map; use set_value or type_text into an editable element"
                )));
            }
        };
        match route {
            Route::XTest => {
                let shift = self.lookup(keysym::SHIFT_L).map(|s| s.code);
                if s.shift
                    && let Some(sh) = shift
                {
                    self.fake(xproto::KEY_PRESS_EVENT, sh)?;
                }
                self.fake(xproto::KEY_PRESS_EVENT, s.code)?;
                self.fake(xproto::KEY_RELEASE_EVENT, s.code)?;
                if s.shift
                    && let Some(sh) = shift
                {
                    self.fake(xproto::KEY_RELEASE_EVENT, sh)?;
                }
                Ok(())
            }
            Route::Send(win) => {
                let state = state | if s.shift { 1 } else { 0 };
                self.send_key(win, s.code, state, true)?;
                self.send_key(win, s.code, state, false)
            }
        }
    }

    /// The XTest route name when XTest may be used for this target now,
    /// `None` for window-scoped events, or a refusal.
    fn xtest_route(
        &self,
        c: &Client,
        delivery: Delivery,
        at: Option<Point>,
    ) -> DResult<Option<&'static str>> {
        if delivery == Delivery::Foreground {
            if !self.has_xtest {
                return Err(DesktopError::Unsupported(
                    "this X server has no XTest extension".into(),
                ));
            }
            self.activate(c)?;
            return Ok(Some("xtest"));
        }
        if !(self.headless && self.has_xtest) {
            return Ok(None);
        }
        match at {
            Some(p) if self.top_at(p) != Some(c.frame_win) => Err(DesktopError::Unsupported(
                "another window covers that point; take a fresh screenshot, or use delivery foreground".into(),
            )),
            Some(_) => Ok(Some("xtest_headless")),
            None => {
                // Headless: no person's focus to take; give the window the
                // keyboard so XTest keys reach it and nothing else.
                if self.focus_in(c).is_none() {
                    self.conn.set_input_focus(InputFocus::PARENT, c.win, CURRENT_TIME).map_err(xerr)?;
                    self.conn.get_input_focus().map_err(xerr)?.reply().map_err(xerr)?;
                }
                Ok(Some("xtest_headless"))
            }
        }
    }

    /// The focused X window when it is inside the client.
    fn focus_in(&self, c: &Client) -> Option<XWindow> {
        let focus = self.conn.get_input_focus().ok()?.reply().ok()?.focus;
        if focus <= 1 {
            return None;
        }
        if focus == c.win || self.top_of(focus) == c.frame_win { Some(focus) } else { None }
    }

    /// The top-most mapped root child at a point.
    fn top_at(&self, p: Point) -> Option<XWindow> {
        let tree = self.conn.query_tree(self.root).ok()?.reply().ok()?;
        tree.children
            .into_iter()
            .rev()
            .find(|w| self.stacks(*w) && self.rect_of(*w).is_some_and(|r| contains(&r, p.x, p.y)))
    }

    /// Raises and focuses the window (Foreground only), waiting for the WM.
    fn activate(&self, c: &Client) -> DResult<()> {
        if self.active_window() == Some(c.win) {
            return Ok(());
        }
        let wm = !self
            .prop32(self.root, self.atoms.net_supporting_wm_check, xproto::AtomEnum::WINDOW)
            .is_empty();
        if !wm {
            let aux = ConfigureWindowAux::new().stack_mode(StackMode::ABOVE);
            self.conn.configure_window(c.frame_win, &aux).map_err(xerr)?;
            self.conn.set_input_focus(InputFocus::PARENT, c.win, CURRENT_TIME).map_err(xerr)?;
            self.conn.get_input_focus().map_err(xerr)?.reply().map_err(xerr)?;
            self.invalidate();
            return Ok(());
        }
        let mask = ChangeWindowAttributesAux::new().event_mask(EventMask::PROPERTY_CHANGE);
        self.conn.change_window_attributes(self.root, &mask).map_err(xerr)?;
        let ev = ClientMessageEvent::new(
            32,
            c.win,
            self.atoms.net_active_window,
            [2, CURRENT_TIME, 0, 0, 0],
        );
        let redirect = EventMask::SUBSTRUCTURE_REDIRECT | EventMask::SUBSTRUCTURE_NOTIFY;
        self.conn.send_event(false, self.root, redirect, ev).map_err(xerr)?;
        self.flush()?;
        let ok =
            self.wait_until(Duration::from_millis(800), || self.active_window() == Some(c.win));
        let none = ChangeWindowAttributesAux::new().event_mask(EventMask::NO_EVENT);
        let _ = self.conn.change_window_attributes(self.root, &none);
        self.invalidate();
        if ok {
            Ok(())
        } else {
            Err(DesktopError::Failed("the window manager did not activate the window".into()))
        }
    }

    /// Waits for X events until `done` holds or the deadline passes.
    fn wait_until(&self, limit: Duration, done: impl Fn() -> bool) -> bool {
        self.wait_loop(limit, |_| false, done)
    }

    /// Waits until an X event matches, up to `limit`.
    pub(crate) fn wait_event(
        &self,
        limit: Duration,
        matches: impl Fn(&x11rb::protocol::Event) -> bool,
    ) -> bool {
        self.wait_loop(limit, matches, || false)
    }

    fn wait_loop(
        &self,
        limit: Duration,
        matches: impl Fn(&x11rb::protocol::Event) -> bool,
        done: impl Fn() -> bool,
    ) -> bool {
        let deadline = Instant::now() + limit;
        loop {
            let mut hit = false;
            while let Ok(Some(e)) = self.conn.poll_for_event() {
                hit |= matches(&e);
            }
            if hit || done() {
                return true;
            }
            let left = deadline.saturating_duration_since(Instant::now());
            if left.is_zero() {
                return false;
            }
            let mut fds = libc::pollfd {
                fd: self.conn.stream().as_raw_fd(),
                events: libc::POLLIN,
                revents: 0,
            };
            // SAFETY: one valid pollfd for the duration of the call.
            unsafe { libc::poll(&mut fds, 1, left.as_millis().min(1000) as i32) };
        }
    }

    // ----- raw events ---------------------------------------------------

    fn fake(&self, kind: u8, detail: u8) -> DResult<()> {
        mark_injection();
        self.conn.xtest_fake_input(kind, detail, CURRENT_TIME, self.root, 0, 0, 0).map_err(xerr)?;
        Ok(())
    }

    fn xtest_motion(&self, p: Point) -> DResult<()> {
        mark_injection();
        self.conn
            .xtest_fake_input(
                xproto::MOTION_NOTIFY_EVENT,
                0,
                CURRENT_TIME,
                self.root,
                p.x as i16,
                p.y as i16,
                0,
            )
            .map_err(xerr)?;
        Ok(())
    }

    pub(crate) fn flush(&self) -> DResult<()> {
        self.conn.flush().map_err(xerr)?;
        // A round trip, so the server processed the input before we report.
        self.conn.get_input_focus().map_err(xerr)?.reply().map_err(xerr)?;
        Ok(())
    }

    /// The deepest X window of the client at a global point, and the point
    /// in its coordinates.
    fn deepest_at(&self, c: &Client, p: Point) -> DResult<(XWindow, (i16, i16))> {
        let (mut win, mut x, mut y) = (c.win, p.x as i16, p.y as i16);
        let mut src = self.root;
        for _ in 0..32 {
            let t = self
                .conn
                .translate_coordinates(src, win, x, y)
                .map_err(xerr)?
                .reply()
                .map_err(xerr)?;
            (x, y, src) = (t.dst_x, t.dst_y, win);
            if t.child == 0 {
                break;
            }
            win = t.child;
        }
        Ok((win, (x, y)))
    }

    fn send_button(
        &self,
        win: XWindow,
        p: Point,
        local: (i16, i16),
        button: u8,
        press: bool,
        state: u32,
    ) -> DResult<()> {
        let ev = ButtonPressEvent {
            response_type: if press {
                xproto::BUTTON_PRESS_EVENT
            } else {
                xproto::BUTTON_RELEASE_EVENT
            },
            detail: button,
            sequence: 0,
            time: CURRENT_TIME,
            root: self.root,
            event: win,
            child: 0,
            root_x: p.x as i16,
            root_y: p.y as i16,
            event_x: local.0,
            event_y: local.1,
            state: KeyButMask::from(state as u16),
            same_screen: true,
        };
        let mask = if press { EventMask::BUTTON_PRESS } else { EventMask::BUTTON_RELEASE };
        self.conn.send_event(true, win, mask, ev).map_err(xerr)?;
        Ok(())
    }

    fn send_motion(&self, win: XWindow, p: Point, local: (i16, i16), state: u32) -> DResult<()> {
        let ev = MotionNotifyEvent {
            response_type: xproto::MOTION_NOTIFY_EVENT,
            detail: xproto::Motion::NORMAL,
            sequence: 0,
            time: CURRENT_TIME,
            root: self.root,
            event: win,
            child: 0,
            root_x: p.x as i16,
            root_y: p.y as i16,
            event_x: local.0,
            event_y: local.1,
            state: KeyButMask::from(state as u16),
            same_screen: true,
        };
        let mask = EventMask::POINTER_MOTION | EventMask::BUTTON_MOTION;
        self.conn.send_event(true, win, mask, ev).map_err(xerr)?;
        Ok(())
    }

    /// Whether keys for `c` (which does not hold the keyboard focus) need a
    /// lent FocusIn. Only when it is safe for the person:
    /// - the client tracks focus from events (its `WM_PROTOCOLS` read worked
    ///   and has neither `WM_TAKE_FOCUS` nor `_NET_WM_PING`: Tk, Xt/Motif,
    ///   plain Xlib), and is not xterm (it ignores synthetic keys anyway);
    /// - no input method server runs (`XIM_SERVERS`): XIM clients move the
    ///   one focused input context on FocusIn, away from the person's app;
    /// - the window that really gets the person's keys (the focus owner, or
    ///   with PointerRoot or root focus the window under the pointer) is not
    ///   of the same process: Tk keeps one focus record per application, so
    ///   a lend would send the person's keys to the target or drop them.
    fn needs_lent_focus(&self, c: &Client) -> bool {
        let a = &self.atoms;
        let Some(protocols) = super::read_protocols(&self.conn, c.win, a.wm_protocols) else {
            return false;
        };
        if !super::tracks_focus_from_events(&protocols, a.wm_take_focus, a.net_wm_ping)
            || matches!(c.class.as_str(), "XTerm" | "UXTerm")
        {
            return false;
        }
        if !self.prop32(self.root, a.xim_servers, xproto::AtomEnum::ATOM).is_empty() {
            return false;
        }
        let Some(focus) = self.conn.get_input_focus().ok().and_then(|r| r.reply().ok()) else {
            return false;
        };
        let receiver = if focus.focus <= 1 || focus.focus == self.root {
            let Some(p) = self.conn.query_pointer(self.root).ok().and_then(|r| r.reply().ok())
            else {
                return false;
            };
            match self.top_at(Point { x: f64::from(p.root_x), y: f64::from(p.root_y) }) {
                Some(frame) => frame,
                None => return true,
            }
        } else {
            self.top_of(focus.focus)
        };
        if receiver == c.frame_win {
            return false;
        }
        let Ok(clients) = self.clients() else { return false };
        match clients.iter().find(|o| o.frame_win == receiver) {
            Some(owner) => owner.pid == 0 || owner.pid != c.pid,
            // Not a managed client (a panel, our overlay): no app focus record to break.
            None => true,
        }
    }

    /// A synthetic FocusIn (or FocusOut) to one window only.
    fn send_focus(&self, win: XWindow, focus_in: bool) -> DResult<()> {
        let ev = xproto::FocusInEvent {
            response_type: if focus_in { xproto::FOCUS_IN_EVENT } else { xproto::FOCUS_OUT_EVENT },
            detail: xproto::NotifyDetail::NONLINEAR,
            sequence: 0,
            event: win,
            mode: xproto::NotifyMode::NORMAL,
        };
        self.conn.send_event(false, win, EventMask::FOCUS_CHANGE, ev).map_err(xerr)?;
        Ok(())
    }

    fn send_key(&self, win: XWindow, code: u8, state: u32, press: bool) -> DResult<()> {
        let ev = KeyPressEvent {
            response_type: if press { xproto::KEY_PRESS_EVENT } else { xproto::KEY_RELEASE_EVENT },
            detail: code,
            sequence: 0,
            time: CURRENT_TIME,
            root: self.root,
            event: win,
            child: 0,
            root_x: 1,
            root_y: 1,
            event_x: 1,
            event_y: 1,
            state: KeyButMask::from(state as u16),
            same_screen: true,
        };
        let mask = if press { EventMask::KEY_PRESS } else { EventMask::KEY_RELEASE };
        self.conn.send_event(true, win, mask, ev).map_err(xerr)?;
        Ok(())
    }

    // ----- keyboard map -------------------------------------------------

    fn mapping(&self) -> DResult<(u8, u8, Vec<u32>)> {
        let setup = self.conn.setup();
        let (min, max) = (setup.min_keycode, setup.max_keycode);
        let r = self
            .conn
            .get_keyboard_mapping(min, max - min + 1)
            .map_err(xerr)?
            .reply()
            .map_err(xerr)?;
        Ok((min, r.keysyms_per_keycode, r.keysyms))
    }

    fn lookup(&self, sym: u32) -> Option<Stroke> {
        let (min, per, syms) = self.mapping().ok()?;
        let per = usize::from(per.max(1));
        // Unshifted first, so 'a' never comes out as 'A'.
        for col in 0..per.min(2) {
            for (i, chunk) in syms.chunks(per).enumerate() {
                if chunk.get(col) == Some(&sym) {
                    return Some(Stroke { code: min + i as u8, shift: col == 1 });
                }
            }
        }
        // Lowercase-only maps list 'a' once; X shifts it to 'A'.
        if let Some(c) = char::from_u32(sym).filter(|c| c.is_ascii_uppercase()) {
            let lower = c.to_ascii_lowercase() as u32;
            for (i, chunk) in syms.chunks(per).enumerate() {
                if chunk.first() == Some(&lower) && chunk.get(1).is_none_or(|s| *s == 0) {
                    return Some(Stroke { code: min + i as u8, shift: true });
                }
            }
        }
        None
    }

    /// Maps a keysym the keyboard lacks onto an unused keycode (XTest
    /// routes only; [`Self::restore_keymap`] clears it after the call).
    fn remap_spare(&self, sym: u32) -> DResult<Stroke> {
        let (min, per, syms) = self.mapping()?;
        let per_u = usize::from(per.max(1));
        let spare = syms
            .chunks(per_u)
            .enumerate()
            .rev()
            .find(|(_, k)| k.iter().all(|s| *s == 0))
            .map(|(i, _)| min + i as u8)
            .ok_or_else(|| {
                DesktopError::Unsupported("no free keycode to type this character".into())
            })?;
        let mut row = vec![sym; per_u];
        row.truncate(per_u);
        self.conn.change_keyboard_mapping(1, spare, per, &row).map_err(xerr)?;
        self.conn.get_input_focus().map_err(xerr)?.reply().map_err(xerr)?;
        REMAPPED.with(|r| r.borrow_mut().push((spare, per)));
        Ok(Stroke { code: spare, shift: false })
    }

    fn restore_keymap(&self) {
        let codes: Vec<(u8, u8)> = REMAPPED.with(|r| std::mem::take(&mut *r.borrow_mut()));
        if codes.is_empty() {
            return;
        }
        let _ = self.conn.flush();
        let _ = self.conn.get_input_focus().map(|c| c.reply());
        for (code, per) in codes {
            let _ = self.conn.change_keyboard_mapping(
                1,
                code,
                per,
                &vec![0u32; usize::from(per.max(1))],
            );
        }
        let _ = self.conn.flush();
    }

    fn modifier_codes(&self, mods: &[Modifier]) -> DResult<Vec<u8>> {
        mods.iter()
            .filter_map(|m| keysym::of_modifier(*m))
            .map(|s| {
                self.lookup(s).map(|k| k.code).ok_or_else(|| {
                    DesktopError::Unsupported(format!(
                        "modifier keysym 0x{s:x} is not on the keyboard map"
                    ))
                })
            })
            .collect()
    }
}

thread_local! {
    static REMAPPED: std::cell::RefCell<Vec<(u8, u8)>> = const { std::cell::RefCell::new(Vec::new()) };
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Route {
    XTest,
    Send(XWindow),
}

fn button_code(b: Button) -> u8 {
    match b {
        Button::Left => 1,
        Button::Middle => 2,
        Button::Right => 3,
    }
}

fn button_mask(b: u8) -> u32 {
    match b {
        1..=5 => 1 << (7 + u32::from(b)),
        _ => 0,
    }
}

fn modifier_mask(mods: &[Modifier]) -> u32 {
    mods.iter().map(|m| keysym::mask_of(*m)).fold(0, |a, b| a | b)
}

fn with_at(out: ActionOutcome, at: Option<Point>, note: &str) -> ActionOutcome {
    let mut out = match at {
        Some(p) => out.at(p),
        None => out,
    };
    if !note.is_empty() {
        out.note = format!("accessibility action {note:?}");
    }
    out
}

fn synthetic_note(mut out: ActionOutcome) -> ActionOutcome {
    out.note =
        "sent to the window as synthetic X events; some apps ignore them (check with a screenshot)"
            .into();
    out
}
