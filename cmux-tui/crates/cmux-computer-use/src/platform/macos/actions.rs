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

    /// Refuses, in the background, an element whose activation opens a menu
    /// that takes the person's pointer and keyboard ([`roles::opens_menu`]).
    fn refuse_menu(&self, el: &Ax) -> DResult<()> {
        if let Some(role) = menu_role(el) {
            return Err(DesktopError::Unsupported(roles::menu_refusal(&role)));
        }
        Ok(())
    }

    /// Refuses keys or text that open a focused pop-up's menu (Space, Return,
    /// arrows). An editable combo box only types them.
    fn refuse_menu_keys(&self, el: &Ax) -> DResult<()> {
        match menu_role(el) {
            Some(role) if role != "AXComboBox" => {
                Err(DesktopError::Unsupported(roles::menu_refusal(&role)))
            }
            _ => Ok(()),
        }
    }

    /// Refuses a background pointer click at `at` that would land on a
    /// menu-opening element (the app's own hit test, then a few ancestors:
    /// the click may hit a pop-up's inner cell or text).
    fn refuse_menu_at(&self, t: &Target, at: Point) -> DResult<()> {
        let Some(hit) = Ax::application(t.window.pid).and_then(|app| app.element_at(at.x, at.y))
        else {
            return Ok(());
        };
        let mut el = Some(hit);
        for _ in 0..4 {
            let Some(current) = el else { break };
            self.refuse_menu(&current)?;
            el = current.element("AXParent");
        }
        Ok(())
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
    if spec.delivery == Delivery::Background {
        d.refuse_menu_at(t, at)?;
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
        return Err(DesktopError::Unsupported(roles::CONTEXT_MENU_REFUSAL.into()));
    }
    let element_id = match target {
        PointerTarget::Point { point, .. } => return click_point(d, &t, *point, spec),
        PointerTarget::Element { element_id, .. } => element_id,
    };
    let el = d.element(&t, element_id)?;
    if spec.delivery == Delivery::Background {
        d.refuse_menu(&el)?;
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
    // A row or cell with no press action (System Settings' sidebar, Finder
    // lists, tables): select it through accessibility. A background window
    // drops pid-posted mouse events, so its center click did nothing.
    if semantic
        && spec.button == Button::Left
        && let Some(row) = selectable(&el)
        && let Some(yes) = Cf::boolean(true)
        && row.set("AXSelected", &yes).is_ok()
    {
        let mut out = ActionOutcome::delivered("ax_select");
        if let Some(frame) = row.frame() {
            out = out.at(roles::center(&frame));
        }
        return Ok(out);
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
    // A shortcut with Command in the background: press the app's menu item
    // with that key equivalent through accessibility. AppKit matches posted
    // key events to menu items by the event's characters, which a synthetic
    // event fills from the key code without Shift, so cmd+shift+t reached
    // TextEdit as cmd+t (Show Fonts) and its menu item never ran.
    if delivery == Delivery::Background
        && combo.modifiers.contains(&crate::keys::Modifier::Meta)
        && let Some(item) = menu_item_for(t.window.pid, combo)
    {
        if item.bool("AXEnabled") == Some(false) {
            let title = item.string("AXTitle").unwrap_or_default();
            return Err(DesktopError::Unsupported(format!(
                "the menu item for this shortcut ({title:?}) is disabled right now"
            )));
        }
        item.perform("AXPress").map_err(|e| ax_error(e, "press the shortcut's menu item"))?;
        return Ok(ActionOutcome::delivered("ax_menu_shortcut"));
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
    if !el.settable("AXValue") && matches!(role.as_str(), "AXPopUpButton" | "AXMenuButton") {
        return choose_menu_item(&el, element_id, value);
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

/// Picks the item titled `value` of a closed pop-up or menu button by
/// pressing that item's accessibility element, so the menu never opens
/// (AppKit performs a menu item's press as `performActionForItemAtIndex:`;
/// Chromium as a `<select>` option's default action).
fn choose_menu_item(el: &Ax, element_id: &str, value: &str) -> DResult<ActionOutcome> {
    let Some(menu) = menu_of(el) else {
        return Err(DesktopError::Unsupported(format!(
            "element {element_id} does not show its menu items while closed, so none can be chosen without opening the menu (which takes the person's pointer and keyboard); click it with delivery foreground"
        )));
    };
    let items: Vec<(Ax, String)> = menu
        .elements("AXChildren")
        .into_iter()
        .filter(|i| i.string("AXRole").as_deref() == Some("AXMenuItem"))
        .filter_map(|i| {
            let title = i.string("AXTitle").filter(|t| !t.is_empty())?;
            Some((i, title))
        })
        .collect();
    let Some((item, title)) = items.iter().find(|(_, t)| roles::same_title(t, value)) else {
        let titles: Vec<&str> = items.iter().map(|(_, t)| t.as_str()).take(40).collect();
        return Err(DesktopError::Unsupported(format!(
            "element {element_id} has no item titled {value:?}; its items: {}",
            if titles.is_empty() { "none".into() } else { titles.join(", ") }
        )));
    };
    if item.bool("AXEnabled") == Some(false) {
        return Err(DesktopError::Unsupported(format!("the item {title:?} is disabled")));
    }
    let before = el.value_text();
    item.perform("AXPress").map_err(|e| ax_error(e, &format!("the item {title:?}")))?;
    let after = el.value_text();
    let mut out = if after.as_deref().is_some_and(|a| roles::same_title(a, title)) {
        ActionOutcome::confirmed("ax_menu_item")
    } else {
        ActionOutcome::delivered("ax_menu_item")
    };
    if after == before && out.evidence != "confirmed" {
        out.note = "pressed the item; the pop-up reads back its old value".into();
    }
    if let Some(frame) = el.frame() {
        out = out.at(roles::center(&frame));
    }
    Ok(out)
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
            // Expanding a pop-up or combo box opens its menu or list.
            if attr == "AXExpanded" && value {
                d.refuse_menu(&el)?;
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
    if ax_action == "AXShowMenu" {
        return Err(DesktopError::Unsupported(roles::CONTEXT_MENU_REFUSAL.into()));
    }
    if roles::is_foreground_action(ax_action) {
        return Err(DesktopError::Unsupported(
            "raise brings the window in front of the person's work; use a click or key with delivery foreground".into(),
        ));
    }
    // A press (or pick) on a pop-up opens its menu.
    if matches!(ax_action.as_str(), "AXPress" | "AXPick") {
        d.refuse_menu(&el)?;
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

/// The enabled-or-not menu item of `pid`'s menu bar whose key equivalent is
/// `combo`, searched breadth-first through submenus (bounded), or None.
fn menu_item_for(pid: i32, combo: &KeyCombo) -> Option<Ax> {
    let bar = Ax::application(pid)?.element("AXMenuBar")?;
    let mut menus: Vec<Ax> =
        bar.elements("AXChildren").iter().flat_map(|top| top.elements("AXChildren")).collect();
    let mut seen = 0usize;
    for _depth in 0..4 {
        let mut next = Vec::new();
        for menu in &menus {
            for item in menu.elements("AXChildren") {
                seen += 1;
                if seen > 2000 {
                    return None;
                }
                let number = |name: &str| item.attr(name).ok().flatten().and_then(|v| v.as_f64()).map(|v| v as i64);
                let cmd_char = item.string("AXMenuItemCmdChar");
                let virtual_key = number("AXMenuItemCmdVirtualKey");
                if (cmd_char.as_deref().is_some_and(|c| !c.is_empty()) || virtual_key.is_some())
                    && keymap::menu_item_matches(combo, cmd_char.as_deref(), virtual_key, number("AXMenuItemCmdModifiers").unwrap_or(0))
                {
                    return Some(item);
                }
                next.extend(item.elements("AXChildren"));
            }
        }
        if next.is_empty() {
            break;
        }
        menus = next;
    }
    None
}

/// The element, or its nearest row or cell ancestor (at most 4 up), whose
/// AXSelected can be set: what a click selects in a list, table or outline.
fn selectable(el: &Ax) -> Option<Ax> {
    let mut current = Some(el.clone());
    for _ in 0..5 {
        let node = current?;
        let role = node.string("AXRole").unwrap_or_default();
        if matches!(role.as_str(), "AXRow" | "AXCell" | "AXOutlineRow") && node.settable("AXSelected") {
            return Some(node);
        }
        if matches!(role.as_str(), "AXWindow" | "AXTable" | "AXOutline" | "AXList") {
            return None;
        }
        current = node.element("AXParent");
    }
    None
}
