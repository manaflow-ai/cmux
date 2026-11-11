//! The input half of the macOS desktop: each action picks the most
//! semantic route that can prove its target (an AX action or attribute
//! write, then events posted to the window's process) and refuses rather
//! than send input that could land in another window.

use super::ax::{Ax, ax_error};
use super::input::{self, Route};
use super::sys::Cf;
use super::{MacDesktop, Target, keymap, roles};
use crate::desktop::*;
use crate::keys::KeyCombo;
use crate::menus;

/// The AX actions a plain click maps to, in order of preference.
fn press_actions(button: Button) -> &'static [&'static str] {
    match button {
        Button::Left => &["AXPress", "AXConfirm", "AXPick"],
        Button::Right => &["AXShowMenu"],
        Button::Middle => &[],
    }
}

fn route_name(ax_action: &str) -> String {
    format!("ax_{}", roles::snake(ax_action))
}

/// `confirmed` when the element's value changed, else `delivered`.
fn outcome_after(route: &str, before: Option<String>, el: &Ax) -> ActionOutcome {
    let after = el.value_text();
    let mut out = if before.is_some() && after != before {
        ActionOutcome::confirmed(route)
    } else {
        ActionOutcome::delivered(route)
    };
    if let Some(frame) = el.frame() {
        out = out.at(roles::center(&frame));
    }
    out
}

impl MacDesktop {
    /// Raises the window and its app for a Foreground delivery. This is the
    /// only path that changes what is in front, and only when asked.
    fn raise(&self, t: &Target) -> DResult<()> {
        let (app, win) = self.ax_window(t)?;
        win.perform("AXRaise").map_err(|e| ax_error(e, "raising the window"))?;
        if let Some(yes) = Cf::boolean(true) {
            app.set("AXFrontmost", &yes).map_err(|e| ax_error(e, "bringing the app forward"))?;
        }
        Ok(())
    }

    /// The route for pointer events into a window.
    fn pointer_route(&self, t: &Target, delivery: Delivery) -> DResult<Route> {
        self.require_input()?;
        match delivery {
            Delivery::Foreground => {
                self.raise(t)?;
                Ok(Route::Hid)
            }
            Delivery::Background if t.window.on_screen => {
                Ok(Route::Pid { pid: t.window.pid, window: t.window.id })
            }
            Delivery::Background => Err(DesktopError::Unsupported(format!(
                "window {} is not on screen (minimized, hidden or on another Space); pointer events cannot reach it. Use element_id targets",
                t.window.id
            ))),
        }
    }

    /// The route for key events. Keys posted to a process go to its key
    /// window, so in the background they are sent only when the target is
    /// that window or the app's only window.
    fn key_route(&self, t: &Target, delivery: Delivery) -> DResult<Route> {
        self.require_input()?;
        if delivery == Delivery::Foreground {
            self.raise(t)?;
            return Ok(Route::Hid);
        }
        let (app, win) = self.ax_window(t)?;
        let is_key = app.element("AXFocusedWindow").is_some_and(|f| f.same(&win));
        let windows = app.elements("AXWindows").len();
        if is_key || windows <= 1 {
            return Ok(Route::Pid { pid: t.window.pid, window: t.window.id });
        }
        Err(DesktopError::Unsupported(format!(
            "the app has {windows} windows and window {} is not its key window, so keys sent in the background would reach another window. Use type_text with element_id, set_value or perform_action, or delivery foreground",
            t.window.id
        )))
    }

    /// A point of the window, or why it is not one.
    fn point_in(&self, t: &Target, p: Point) -> DResult<Point> {
        if !roles::contains(&t.window.frame, p) {
            return Err(DesktopError::TargetNotFound(format!(
                "point ({:.0}, {:.0}) is outside window {}",
                p.x, p.y, t.window.id
            )));
        }
        Ok(roles::clamp_into(&t.window.frame, p))
    }

    fn element_center(&self, t: &Target, element_id: &str) -> DResult<Point> {
        let el = self.element(t, element_id)?;
        let frame = el.frame().ok_or_else(|| {
            DesktopError::Unsupported(format!("element {element_id} has no frame to aim at"))
        })?;
        self.point_in(t, roles::center(&frame))
    }

    /// The window's focused element, when it is inside this window.
    fn focused_in(&self, t: &Target) -> Option<Ax> {
        let (app, win) = self.ax_window(t).ok()?;
        let el = app.element("AXFocusedUIElement")?;
        el.element("AXWindow").filter(|w| w.same(&win)).map(|_| el)
    }

    /// Whether the window's app is the frontmost app, where the person's
    /// keys and caret are.
    fn is_persons_app(&self, t: &Target) -> bool {
        super::workspace::app_for_pid(t.window.pid).is_some_and(|a| a.active)
    }

    /// Whether a background activation of `el` opens a menu, and whether
    /// that may happen ([`crate::menus`]): `Ok(None)` opens none,
    /// `Ok(Some(role))` opens one the setting allows; a menu bar menu, or
    /// any menu under `refuse`, is refused.
    fn menu_gate(&self, el: &Ax) -> DResult<Option<String>> {
        let Some(role) = menu_role(el) else { return Ok(None) };
        if roles::is_menu_bar(&role) {
            return Err(DesktopError::Unsupported(menus::MENU_BAR_REFUSAL.into()));
        }
        if !self.menu_policy().opens() {
            return Err(DesktopError::Unsupported(roles::menu_refusal(&role)));
        }
        Ok(Some(role))
    }

    /// Refuses a context menu under `refuse`.
    fn context_menu_allowed(&self) -> DResult<()> {
        if self.menu_policy().opens() {
            Ok(())
        } else {
            Err(DesktopError::Unsupported(roles::CONTEXT_MENU_REFUSAL.into()))
        }
    }

    /// Refuses keys or text that open a focused pop-up's menu (Space, Return,
    /// arrows) where [`Self::menu_gate`] would. An editable combo box only
    /// types them.
    fn refuse_menu_keys(&self, el: &Ax) -> DResult<()> {
        match menu_role(el) {
            Some(role) if role != "AXComboBox" => {
                // A menu opened by a key would skip the keyboard guard and
                // the open-menu record: refuse in both modes, naming what works.
                self.menu_gate(el)?;
                Err(DesktopError::Unsupported(menus::MENU_KEYS_REFUSAL.into()))
            }
            _ => Ok(()),
        }
    }

    /// The menu-opening element a background pointer click at `at` would
    /// land on (the app's own hit test, then a few ancestors: the click may
    /// hit a pop-up's inner cell or text), refused as [`Self::menu_gate`]
    /// says; a menu item there that leads to a denied app is refused too.
    fn menu_at(&self, t: &Target, at: Point) -> DResult<Option<Ax>> {
        let Some(hit) = Ax::application(t.window.pid).and_then(|app| app.element_at(at.x, at.y))
        else {
            return Ok(None);
        };
        let mut el = Some(hit);
        for _ in 0..4 {
            let Some(current) = el else { break };
            self.refuse_denied_item(&current)?;
            if self.menu_gate(&current)?.is_some() {
                return Ok(Some(current));
            }
            el = current.element("AXParent");
        }
        Ok(None)
    }

    /// Opens the menu of `el` (which [`Self::menu_gate`] allowed) and leaves
    /// it open with its items in the result.
    fn open_menu_of(&self, t: &Target, el: &Ax, element: &str) -> DResult<ActionOutcome> {
        self.refuse_left_open_in_persons_app(t)?;
        let action = roles::open_action(&el.actions()).ok_or_else(|| {
            DesktopError::Unsupported(format!(
                "element {element} has no press or show-menu action to open its menu"
            ))
        })?;
        self.open_and_list(t, el, action)
    }
}

/// Roles that might open a menu; anything else needs no further reads.
const MENU_CANDIDATES: &[&str] =
    &["AXPopUpButton", "AXMenuButton", "AXComboBox", "AXMenuBarItem", "AXMenuExtra"];

/// The element's role when activating it opens a menu ([`roles::opens_menu`]).
fn menu_role(el: &Ax) -> Option<String> {
    let role = el.string("AXRole")?;
    if !MENU_CANDIDATES.contains(&role.as_str()) {
        return None;
    }
    let in_web = in_web_area(el);
    let has_menu = menu_of(el).is_some();
    roles::opens_menu(&role, in_web, has_menu).then_some(role)
}

/// Whether the element sits inside web content (an `AXWebArea` ancestor).
fn in_web_area(el: &Ax) -> bool {
    let mut current = el.element("AXParent");
    for _ in 0..64 {
        let Some(node) = current else { return false };
        match node.string("AXRole").as_deref() {
            Some("AXWebArea") => return true,
            Some("AXWindow") | Some("AXApplication") | None => return false,
            _ => {}
        }
        current = node.element("AXParent");
    }
    false
}

/// The menu a pop-up or menu button holds as its child, when it shows it
/// while closed.
fn menu_of(el: &Ax) -> Option<Ax> {
    el.elements("AXChildren").into_iter().find(|c| c.string("AXRole").as_deref() == Some("AXMenu"))
}

/// Whether a click opens a context menu: a right click, or a left click
/// with Control held (AppKit's context-menu gesture).
fn opens_context_menu(spec: &ClickSpec) -> bool {
    spec.button == Button::Right
        || (spec.button == Button::Left && spec.modifiers.contains(&crate::keys::Modifier::Control))
}

fn click_point(
    d: &MacDesktop,
    t: &Target,
    point: Point,
    spec: &ClickSpec,
) -> DResult<ActionOutcome> {
    let at = d.point_in(t, point)?;
    if spec.delivery == Delivery::Background
        && let Some(el) = d.menu_at(t, at)?
    {
        return d.open_menu_of(t, &el, &format!("at ({:.0}, {:.0})", at.x, at.y));
    }
    let route = d.pointer_route(t, spec.delivery)?;
    input::click(route, at, spec.button, spec.count, keymap::flags(&spec.modifiers), spec.gap)?;
    Ok(ActionOutcome::delivered(route.name()).at(at))
}

pub(super) fn click(
    d: &MacDesktop,
    target: &PointerTarget,
    spec: &ClickSpec,
) -> DResult<ActionOutcome> {
    let t = d.target(target.window_id())?;
    if spec.delivery == Delivery::Background && opens_context_menu(spec) {
        d.context_menu_allowed()?;
        d.refuse_left_open_in_persons_app(&t)?;
        return match target {
            PointerTarget::Point { point, .. } => d.context_menu_at(&t, d.point_in(&t, *point)?),
            PointerTarget::Element { element_id, .. } => {
                let el = d.element(&t, element_id)?;
                if el.actions().iter().any(|a| a == "AXShowMenu") {
                    d.open_and_list(&t, &el, "AXShowMenu")
                } else {
                    d.context_menu_at(&t, d.element_center(&t, element_id)?)
                }
            }
        };
    }
    let element_id = match target {
        PointerTarget::Point { point, .. } => return click_point(d, &t, *point, spec),
        PointerTarget::Element { element_id, .. } => element_id,
    };
    let el = d.element(&t, element_id)?;
    if spec.delivery == Delivery::Background {
        d.refuse_denied_item(&el)?;
        if d.menu_gate(&el)?.is_some() {
            return d.open_menu_of(&t, &el, element_id);
        }
    }
    let semantic =
        spec.delivery == Delivery::Background && spec.modifiers.is_empty() && spec.count <= 1;
    if semantic {
        let available = el.actions();
        if let Some(action) =
            press_actions(spec.button).iter().find(|a| available.iter().any(|x| x == *a))
        {
            let before = el.value_text();
            el.perform(action).map_err(|e| ax_error(e, &format!("element {element_id}")))?;
            return Ok(outcome_after(&route_name(action), before, &el));
        }
    }
    let center = d.element_center(&t, element_id)?;
    let mut out = click_point(d, &t, center, spec)?;
    if semantic {
        out.note = "the element has no press action; clicked its center".into();
    }
    Ok(out)
}

/// Inserts text through Accessibility: at the caret (AXSelectedText), or
/// appended to the value. `None` when the element takes neither.
fn ax_insert(el: &Ax, text: &str) -> DResult<Option<ActionOutcome>> {
    let role = el.string("AXRole").unwrap_or_default();
    if !roles::is_text_input(&role) {
        return Ok(None);
    }
    let secure = roles::is_secure(&role, el.string("AXSubrole").as_deref());
    let before = el.value_text().unwrap_or_default();
    let Some(cf) = Cf::string(text) else { return Ok(None) };
    if el.settable("AXSelectedText") && el.set("AXSelectedText", &cf).is_ok() {
        if secure {
            return Ok(Some(ActionOutcome::delivered("ax_insert_text")));
        }
        let after = el.value_text().unwrap_or_default();
        if after != before && after.contains(text) {
            return Ok(Some(ActionOutcome::confirmed("ax_insert_text")));
        }
        // The app took the call but kept its value: fall back to keys.
        return Ok(None);
    }
    if !el.settable("AXValue") {
        return Ok(None);
    }
    let wanted = format!("{before}{text}");
    let Some(value) = Cf::string(&wanted) else { return Ok(None) };
    el.set("AXValue", &value).map_err(|e| ax_error(e, "setting the value"))?;
    let mut out = if !secure && el.value_text().as_deref() == Some(wanted.as_str()) {
        ActionOutcome::confirmed("ax_set_value")
    } else {
        ActionOutcome::delivered("ax_set_value")
    };
    out.note = "appended to the field's value".into();
    Ok(Some(out))
}

pub(super) fn type_text(
    d: &MacDesktop,
    window_id: &str,
    element_id: Option<&str>,
    text: &str,
    delivery: Delivery,
) -> DResult<ActionOutcome> {
    let t = d.target(window_id)?;
    let target = match element_id {
        Some(id) => Some(d.element(&t, id)?),
        None => d.focused_in(&t),
    };
    let has_keys = text.contains(['\n', '\r', '\t']);
    if let Some(el) = &target {
        if delivery == Delivery::Background
            && !has_keys
            && let Some(mut out) = ax_insert(el, text)?
        {
            if let Some(frame) = el.frame() {
                out = out.at(roles::center(&frame));
            }
            return Ok(out);
        }
        if delivery == Delivery::Background {
            // A space or newline typed into a focused pop-up opens its menu.
            if roles::text_opens_menu(text) {
                d.refuse_menu_keys(el)?;
            }
            // Focusing an element of the app the person is using moves their
            // caret, and keys sent after it would follow.
            if element_id.is_some() && el.bool("AXFocused") != Some(true) && d.is_persons_app(&t) {
                return Err(DesktopError::Unsupported(
                    "this element is in the app the person is using; focusing it would move their caret. Use set_value, type_text without newlines or tabs (inserted through accessibility), or delivery foreground".into(),
                ));
            }
        }
        // Keys go to the focused element: focus this one first (it changes
        // focus inside the app, not which app is in front).
        if element_id.is_some()
            && let Some(yes) = Cf::boolean(true)
        {
            el.set("AXFocused", &yes).map_err(|e| ax_error(e, "focusing the element"))?;
        }
    }
    let route = d.key_route(&t, delivery)?;
    input::type_text(route, text)?;
    Ok(ActionOutcome::delivered(route.name()))
}

pub(super) fn press_keys(
    d: &MacDesktop,
    window_id: &str,
    combo: &KeyCombo,
    delivery: Delivery,
) -> DResult<ActionOutcome> {
    let t = d.target(window_id)?;
    let (code, shift) = keymap::key_code(&combo.key).ok_or_else(|| {
        DesktopError::Unsupported(format!(
            "{:?} has no key on the macOS keyboard; type it with type_text",
            combo.key
        ))
    })?;
    let mut flags = keymap::flags(&combo.modifiers);
    if shift {
        flags |= keymap::FLAG_SHIFT;
    }
    // Return or Space would activate the highlighted item of a menu left
    // open, which may be one hidden from the tree (a denied app's).
    if delivery == Delivery::Background
        && matches!(combo.key, crate::keys::Key::Return | crate::keys::Key::Space)
        && d.opened_menu_for(&t.id()).is_some()
    {
        return Err(DesktopError::Unsupported(menus::OPEN_MENU_KEYS_REFUSAL.into()));
    }
    // Escape closes the menu a call left open for this window, through
    // accessibility (a posted Escape does not reach every app's menu).
    if delivery == Delivery::Background
        && combo.key == crate::keys::Key::Escape
        && combo.modifiers.is_empty()
        && d.opened_menu_for(&t.id()).is_some()
        && d.close_opened()
    {
        return Ok(ActionOutcome::confirmed("ax_cancel_menu"));
    }
    let route = d.key_route(&t, delivery)?;
    // Space, Return and the arrows open a focused pop-up's menu.
    if delivery == Delivery::Background
        && roles::key_opens_menu(&combo.key)
        && let Some(focused) = d.focused_in(&t)
    {
        d.refuse_menu_keys(&focused)?;
    }
    input::key(route, code, flags, keymap::carries_text(&combo.key, flags))?;
    Ok(ActionOutcome::delivered(route.name()))
}

pub(super) fn scroll(
    d: &MacDesktop,
    target: &PointerTarget,
    dx: f64,
    dy: f64,
) -> DResult<ActionOutcome> {
    let t = d.target(target.window_id())?;
    let at = match target {
        PointerTarget::Point { point, .. } => d.point_in(&t, *point)?,
        PointerTarget::Element { element_id, .. } => d.element_center(&t, element_id)?,
    };
    let route = d.pointer_route(&t, Delivery::Background)?;
    input::scroll(route, at, dx, dy)?;
    Ok(ActionOutcome::delivered(route.name()).at(at))
}

pub(super) fn drag(
    d: &MacDesktop,
    window_id: &str,
    from: Point,
    to: Point,
    button: Button,
    delivery: Delivery,
) -> DResult<ActionOutcome> {
    let t = d.target(window_id)?;
    let from = d.point_in(&t, from)?;
    let route = d.pointer_route(&t, delivery)?;
    input::drag(route, from, to, button)?;
    Ok(ActionOutcome::delivered(route.name()).at(to))
}

/// The CF value to write: a number when the element's value is one.
fn value_for(el: &Ax, value: &str) -> DResult<Cf> {
    let current_is_number = el.attr("AXValue").ok().flatten().is_some_and(|v| v.is_number());
    let cf = if current_is_number {
        let n: f64 = match value.trim() {
            "true" | "on" => 1.0,
            "false" | "off" => 0.0,
            s => s.parse().map_err(|_| {
                DesktopError::Unsupported(format!("this element takes a number, not {value:?}"))
            })?,
        };
        Cf::number_f64(n)
    } else {
        Cf::string(value)
    };
    cf.ok_or_else(|| DesktopError::Failed("could not build the value".into()))
}

fn same_value(read: &str, wanted: &str) -> bool {
    if read == wanted {
        return true;
    }
    match (read.trim().parse::<f64>(), wanted.trim().parse::<f64>()) {
        (Ok(a), Ok(b)) => (a - b).abs() < 1e-6,
        _ => false,
    }
}

pub(super) fn set_value(
    d: &MacDesktop,
    window_id: &str,
    element_id: &str,
    value: &str,
) -> DResult<ActionOutcome> {
    let t = d.target(window_id)?;
    let el = d.element(&t, element_id)?;
    let role = el.string("AXRole").unwrap_or_default();
    if !el.settable("AXValue")
        && matches!(role.as_str(), "AXPopUpButton" | "AXMenuButton" | "AXComboBox")
    {
        return choose_menu_item(d, &t, &el, element_id, value);
    }
    if !el.settable("AXValue") {
        return Err(DesktopError::Unsupported(format!(
            "element {element_id}'s value cannot be set; use type_text or click"
        )));
    }
    el.set("AXValue", &value_for(&el, value)?)
        .map_err(|e| ax_error(e, &format!("element {element_id}")))?;
    let secure = roles::is_secure(&role, el.string("AXSubrole").as_deref());
    let read = el.value_text();
    let mut out = match &read {
        Some(r) if !secure && same_value(r, value) => ActionOutcome::confirmed("ax_set_value"),
        _ => ActionOutcome::delivered("ax_set_value"),
    };
    if !secure && read.as_deref().is_some_and(|r| !same_value(r, value)) {
        out.note = "the element reads back a different value".into();
    }
    if let Some(frame) = el.frame() {
        out = out.at(roles::center(&frame));
    }
    Ok(out)
}

/// Picks the item titled `value` of a pop-up or menu button. A pop-up that
/// lists its items while closed is set by pressing that item's element, so
/// the menu never opens (AppKit performs a menu item's press as
/// `performActionForItemAtIndex:`; Chromium as a `<select>` option's default
/// action). Otherwise, as `computerUse.menus` allows, the menu is opened,
/// the item pressed and the menu closed in this one call.
fn choose_menu_item(
    d: &MacDesktop,
    t: &Target,
    el: &Ax,
    element_id: &str,
    value: &str,
) -> DResult<ActionOutcome> {
    if let Some(out) = pick_closed(d, el, element_id, value)? {
        return Ok(out);
    }
    if roles::is_menu_bar(&el.string("AXRole").unwrap_or_default()) {
        return Err(DesktopError::Unsupported(menus::MENU_BAR_REFUSAL.into()));
    }
    if !d.menu_policy().opens() {
        return Err(DesktopError::Unsupported(menus::refused_by_setting(&format!(
            "element {element_id} lists no items while closed, and choosing one"
        ))));
    }
    d.pick_by_opening(t, el, element_id, value)
}

/// How long a closed pop-up gets to show a pressed item.
const CLOSED_PICK_WAIT: std::time::Duration = std::time::Duration::from_millis(400);

/// The closed-menu pick: `None` when the pop-up shows no items while
/// closed, or the press left its value as it was (then it is opened).
fn pick_closed(
    d: &MacDesktop,
    el: &Ax,
    element_id: &str,
    value: &str,
) -> DResult<Option<ActionOutcome>> {
    let Some(menu) = menu_of(el) else { return Ok(None) };
    let items = super::menus::items(d, &menu, &[]);
    if items.is_empty() {
        return Ok(None);
    }
    let titles: Vec<String> = items.iter().map(|i| i.info.title.clone()).collect();
    let item = match menus::match_item(&titles, value) {
        menus::ItemMatch::Found(i) => &items[i],
        _ => {
            let shown: Vec<String> =
                items.iter().filter(|i| i.denied.is_none()).map(|i| i.info.title.clone()).collect();
            let found = menus::match_item(&shown, value);
            return Err(DesktopError::Unsupported(format!(
                "element {element_id}: {}",
                menus::not_found(value, &found, &shown).replace(" (it was closed again)", "")
            )));
        }
    };
    if let Some(app) = &item.denied {
        return Err(DesktopError::Unsupported(menus::denied_item_refusal(&item.info.title, app)));
    }
    if item.info.disabled {
        return Err(DesktopError::Unsupported(format!(
            "the item {:?} is disabled",
            item.info.title
        )));
    }
    let title = item.info.title.clone();
    let before = el.value_text();
    item.el.perform("AXPress").map_err(|e| ax_error(e, &format!("the item {title:?}")))?;
    // Some pop-ups show the item a little after the press.
    let mut after = el.value_text();
    super::menus::wait_for(CLOSED_PICK_WAIT, || {
        after = el.value_text();
        after != before
    });
    let confirmed = after.as_deref().is_some_and(|a| roles::same_title(a, &title));
    let mut out = if confirmed {
        ActionOutcome::confirmed("ax_menu_item")
    } else {
        ActionOutcome::delivered("ax_menu_item")
    };
    if after == before && !confirmed {
        out.note = "pressed the item; the pop-up reads back its old value".into();
    }
    out.menu = Some(menus::MenuReport::picked(&title, None));
    if let Some(frame) = el.frame() {
        out = out.at(roles::center(&frame));
    }
    Ok(Some(out))
}

fn write_attribute(el: &Ax, element_id: &str, attr: &str, value: bool) -> DResult<ActionOutcome> {
    if !el.settable(attr) {
        return Err(DesktopError::Unsupported(format!(
            "element {element_id} cannot change {}",
            roles::snake(attr)
        )));
    }
    let cf = Cf::boolean(value).ok_or_else(|| DesktopError::Failed("no boolean".into()))?;
    el.set(attr, &cf).map_err(|e| ax_error(e, &format!("element {element_id}")))?;
    let route = format!("ax_set_{}", roles::snake(attr));
    Ok(if el.bool(attr) == Some(value) {
        ActionOutcome::confirmed(&route)
    } else {
        ActionOutcome::delivered(&route)
    })
}

pub(super) fn perform_action(
    d: &MacDesktop,
    window_id: &str,
    element_id: &str,
    action: &str,
) -> DResult<ActionOutcome> {
    let t = d.target(window_id)?;
    let el = d.element(&t, element_id)?;
    let available = el.actions();
    let Some(ax_action) = roles::resolve_action(action, &available) else {
        if let Some((attr, value)) = roles::attribute_action(action.trim()) {
            d.refuse_denied_item(&el)?;
            // Expanding a pop-up or combo box opens its menu or list.
            if attr == "AXExpanded" && value && d.menu_gate(&el)?.is_some() {
                return d.open_menu_of(&t, &el, element_id);
            }
            if attr == "AXFocused" && d.is_persons_app(&t) {
                return Err(DesktopError::Unsupported(
                    "this element is in the app the person is using; focusing it would move their caret. Use set_value or type_text with element_id, or a click with delivery foreground".into(),
                ));
            }
            return write_attribute(&el, element_id, attr, value);
        }
        let offered: Vec<String> = available
            .iter()
            .filter(|a| !roles::is_foreground_action(a))
            .map(|a| roles::action_name(a))
            .collect();
        return Err(DesktopError::Unsupported(format!(
            "element {element_id} has no {action:?} action; it offers: {}",
            if offered.is_empty() { "none".into() } else { offered.join(", ") }
        )));
    };
    d.refuse_denied_item(&el)?;
    if ax_action == "AXShowMenu" {
        if roles::is_menu_bar(&el.string("AXRole").unwrap_or_default()) {
            return Err(DesktopError::Unsupported(menus::MENU_BAR_REFUSAL.into()));
        }
        d.context_menu_allowed()?;
        d.refuse_left_open_in_persons_app(&t)?;
        return d.open_and_list(&t, &el, "AXShowMenu");
    }
    if roles::is_foreground_action(ax_action) {
        return Err(DesktopError::Unsupported(
            "raise brings the window in front of the person's work; use a click or key with delivery foreground".into(),
        ));
    }
    // A press (or pick) on a pop-up opens its menu.
    if matches!(ax_action.as_str(), "AXPress" | "AXPick") && d.menu_gate(&el)?.is_some() {
        d.refuse_left_open_in_persons_app(&t)?;
        return d.open_and_list(&t, &el, ax_action);
    }
    let before = el.value_text();
    el.perform(ax_action).map_err(|e| ax_error(e, &format!("element {element_id}")))?;
    let route = if ax_action.starts_with("Name:") {
        "ax_custom_action".into()
    } else {
        route_name(ax_action)
    };
    Ok(outcome_after(&route, before, &el))
}
