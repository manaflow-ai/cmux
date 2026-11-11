//! The input half of the macOS desktop: each action picks the most
//! semantic route that can prove its target (an AX action or attribute
//! write, then events posted to the window's process) and refuses rather
//! than send input that could land in another window.

use super::ax::{Ax, ax_error};
use super::input::{self, Route};
use super::sys::Cf;
use super::{MacDesktop, Target, keymap, roles, workspace};
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

    /// A menu item of the app's menu bar runs against the app's key window,
    /// so it is pressed only when the target window is that window (or keys
    /// would reach it, see key_route); one that opens a submenu is refused
    /// (it would open a menu), and one the deny list blocks is refused.
    fn check_menu_item(&self, t: &Target, el: &Ax) -> DResult<()> {
        if !super::ax::in_menu_bar(el) {
            return Ok(());
        }
        let role = el.string("AXRole").unwrap_or_default();
        let has_submenu =
            el.elements("AXChildren").iter().any(|c| c.string("AXRole").as_deref() == Some("AXMenu"));
        if let Some(why) = roles::submenu_refusal(&role, has_submenu) {
            return Err(DesktopError::Unsupported(why.into()));
        }
        if self.menu_item_blocked(el) {
            return Err(DesktopError::Unsupported(
                "this menu item would open or hand data to an app on the Computer Use deny list".into(),
            ));
        }
        // Menu commands act on the app's key window: the same rule as keys.
        self.key_route(t, Delivery::Background).map(|_| ())
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
        // Count the windows keys could go to instead: standard, not minimized.
        // Apps keep hidden helper windows (Safari lists 8 with one visible),
        // and counting those refused keys to an app's only real window.
        let windows = app
            .windows()
            .iter()
            .filter(|w| {
                w.string("AXSubrole").as_deref() == Some("AXStandardWindow")
                    && w.bool("AXMinimized") != Some(true)
            })
            .count();
        let target_is_standard = win.string("AXSubrole").as_deref() == Some("AXStandardWindow");
        // Keys go to the key window. When the target is not it, send them only
        // if the app has no key window that could take them instead: none, or
        // one that is minimized or hidden. A dialog or panel as key window (a
        // Save sheet's alert, a floating panel) would get them otherwise.
        let other_key_window = app
            .element("AXFocusedWindow")
            .is_some_and(|f| !f.same(&win) && f.bool("AXMinimized") != Some(true));
        if roles::keys_reach_target(is_key, windows, target_is_standard, other_key_window) {
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
        workspace::app_for_pid(t.window.pid).is_some_and(|a| a.active)
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
    d.check_menu_item(&t, &el)?;
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
        && select_only(&row)
    {
        let mut out = if row.bool("AXSelected") == Some(true) && only_selected(&row) {
            ActionOutcome::confirmed("ax_select")
        } else {
            ActionOutcome::delivered("ax_select")
        };
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
    // The key route first: a shortcut's menu item acts on the app's key
    // window, so it is pressed only when keys would reach the target window.
    let route = d.key_route(&t, delivery)?;
    // The deny-list checks hold for both deliveries: a foreground chord goes
    // through the same AppKit menus and Services. Any chord a menu item or a
    // Service can own: with Command, Control or Option, or a function key.
    // Not covered, as before: a plain key with no modifier (it can only be a
    // menu item's equivalent in an app that registers bare keys), and menu
    // items an app builds only when its menu opens or hides from AX.
    use crate::keys::{Key, Modifier};
    let menu_chord = combo.modifiers.iter().any(|m| matches!(m, Modifier::Meta | Modifier::Control | Modifier::Alt))
        || matches!(combo.key, Key::F(_));
    let denies_any = d.denies_any();
    let background = delivery == Delivery::Background;
    let command = combo.modifiers.contains(&Modifier::Meta);
    // With nothing denied, only a background Command chord needs the menu
    // walk (to press its item: posted, it would lose its Shift); every other
    // chord is posted as typed.
    if menu_chord && (denies_any || (background && command)) {
        // A background chord stops at the first enabled match (pressed
        // through AX, no key posted); keys that will be posted need every
        // match, since AppKit picks the item or Service at key time.
        let mut walk = shortcut_matches(d, t.window.pid, combo, background);
        let first_enabled_ok = |items: &[(Ax, roles::ShortcutMatch)], complete: bool| {
            let m: Vec<roles::ShortcutMatch> = items.iter().map(|(_, m)| m.clone()).collect();
            matches!(roles::pick_shortcut(&m), roles::ShortcutPick::Press(_)) && (complete || !denies_any)
        };
        if background && !first_enabled_ok(&walk.0, walk.1) && (denies_any || command) {
            walk = shortcut_matches(d, t.window.pid, combo, false);
        }
        let (items, complete) = walk;
        let matches: Vec<roles::ShortcutMatch> = items.iter().map(|(_, m)| m.clone()).collect();
        let press = background && first_enabled_ok(&items, complete);
        let ansi_layout = press || !denies_any || workspace::ansi_layout();
        // The person's assignments (any modifiers) are read now; the
        // services' own shortcuts (always with Command) come from the
        // background read, needed only for a Command chord.
        // Both the services' own shortcuts and the person's assignments come
        // from one background read; flags are compared exactly, so a chord
        // without Command can only match a person's assignment.
        let is_service = if denies_any && !press && ansi_layout {
            match workspace::service_shortcuts() {
                None => roles::ServiceCheck::Unread,
                Some(list) if keymap::is_service_shortcut(code, flags, &list) => roles::ServiceCheck::Match,
                Some(_) => roles::ServiceCheck::NoMatch,
            }
        } else {
            roles::ServiceCheck::NoMatch
        };
        let facts =
            roles::ChordFacts { matches: &matches, complete, background, command, denies_any, ansi_layout, is_service };
        match roles::decide_chord(&facts) {
            roles::ChordAction::PressItem(i) => {
                items[i].0.perform("AXPress").map_err(|e| ax_error(e, "press the shortcut's menu item"))?;
                return Ok(ActionOutcome::delivered("ax_menu_shortcut"));
            }
            roles::ChordAction::Refuse(why) => {
                // Name the menu item only when it is the reason.
                let item = if why == roles::REFUSE_BLOCKED {
                    matches.iter().find(|m| m.blocked)
                } else if why == roles::REFUSE_DISABLED {
                    matches.first()
                } else {
                    None
                }
                .filter(|m| !m.title.is_empty())
                .map(|m| format!(" (menu item {:?})", m.title))
                .unwrap_or_default();
                return Err(DesktopError::Unsupported(format!("{why}{item}")));
            }
            roles::ChordAction::Post => {}
        }
    }
    // Space, Return and the arrows open a focused pop-up's menu.
    if delivery == Delivery::Background
        && roles::key_opens_menu(&combo.key)
        && let Some(focused) = d.focused_in(&t)
    {
        d.refuse_menu_keys(&focused)?;
    }
    // A foreground key at the HID tap reaches every app's global hotkeys
    // (a denied password manager's cmd+\\): while something is denied, post
    // it to the raised target's process instead.
    let route = match route {
        Route::Hid if denies_any => Route::Pid { pid: t.window.pid, window: t.window.id },
        other => other,
    };
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
    if !el.settable("AXValue")
        && let Some(out) = step_to(&el, value)?
    {
        return Ok(out);
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
    d.check_menu_item(&t, &el)?;
    let before = el.value_text();
    el.perform(ax_action).map_err(|e| ax_error(e, &format!("element {element_id}")))?;
    let route = if ax_action.starts_with("Name:") {
        "ax_custom_action".into()
    } else {
        route_name(ax_action)
    };
    Ok(outcome_after(&route, before, &el))
}

/// The menu items of `pid`'s menu bar whose key equivalent is `combo`, in
/// AppKit's order (depth-first, menu order), with whether each is enabled
/// and blocked. With `stop_at_enabled` (a background AX press) the walk ends
/// at the first enabled match; otherwise it collects every match within the
/// bounds, since posted keys are routed by AppKit at key time. The bool is
/// false when the walk did not see everything: its bounds (6 levels, 2000
/// items) or any read error; a match whose title or place cannot be read
/// counts as blocked. Every submenu is walked, Services included: a Services
/// item on the chord is then one more match, held to the same rule.
fn shortcut_matches(
    d: &MacDesktop,
    pid: i32,
    combo: &KeyCombo,
    stop_at_enabled: bool,
) -> (Vec<(Ax, roles::ShortcutMatch)>, bool) {
    let Some(app) = Ax::application(pid) else { return (Vec::new(), false) };
    // No menu bar (an agent app, a helper) is an empty search; one that
    // cannot be read is an incomplete one.
    let bar = match app.attr("AXMenuBar") {
        Ok(Some(v)) => match Ax::from_cf(v) {
            Some(bar) => bar,
            None => return (Vec::new(), false),
        },
        Ok(None) => return (Vec::new(), true),
        Err(_) => return (Vec::new(), false),
    };
    let mut found = Vec::new();
    let mut complete = true;
    let mut seen = 0usize;
    // Attributes through attr(): Ok(None) when absent or unsupported, Err when
    // the read failed (which makes the walk incomplete).
    let children = |node: &Ax, complete: &mut bool| -> Vec<Ax> {
        match node.attr("AXChildren") {
            Ok(Some(list)) => list.items().into_iter().filter_map(Ax::from_cf).collect(),
            Ok(None) => Vec::new(),
            Err(_) => {
                *complete = false;
                Vec::new()
            }
        }
    };
    let text = |node: &Ax, name: &str| -> Result<Option<String>, ()> {
        node.attr(name).map(|v| v.and_then(|v| v.as_string())).map_err(|_| ())
    };
    let number = |node: &Ax, name: &str| -> Result<Option<i64>, ()> {
        node.attr(name).map(|v| v.and_then(|v| v.as_f64()).map(|v| v as i64)).map_err(|_| ())
    };
    let mut stack: Vec<(Ax, usize)> = children(&bar, &mut complete).into_iter().rev().map(|c| (c, 0)).collect();
    while let Some((node, depth)) = stack.pop() {
        seen += 1;
        if seen > 2000 {
            return (found, false);
        }
        let Ok(role) = text(&node, "AXRole") else {
            complete = false;
            continue;
        };
        if role.as_deref() == Some("AXMenuItem") {
            let (Ok(cmd_char), Ok(virtual_key), Ok(mods)) = (
                text(&node, "AXMenuItemCmdChar"),
                number(&node, "AXMenuItemCmdVirtualKey"),
                number(&node, "AXMenuItemCmdModifiers"),
            ) else {
                complete = false;
                continue;
            };
            if (cmd_char.as_deref().is_some_and(|c| !c.is_empty()) || virtual_key.is_some())
                && keymap::menu_item_matches(combo, cmd_char.as_deref(), virtual_key, mods.unwrap_or(0))
            {
                let enabled = match node.attr("AXEnabled") {
                    Ok(v) => v.and_then(|v| v.as_bool()) != Some(false),
                    Err(_) => {
                        // Unknown: it may run at key time.
                        complete = false;
                        true
                    }
                };
                let (title, blocked) = match text(&node, "AXTitle") {
                    Ok(t) => {
                        let t = t.unwrap_or_default();
                        (t, d.menu_item_blocked(&node))
                    }
                    // A title that cannot be read cannot be checked: blocked.
                    Err(()) => {
                        complete = false;
                        (String::new(), true)
                    }
                };
                found.push((node.clone(), roles::ShortcutMatch { title, enabled, blocked }));
                if stop_at_enabled && enabled {
                    return (found, complete);
                }
            }
        }
        let kids = children(&node, &mut complete);
        if depth >= 6 {
            // Too deep (a bookmark folder): skip it, keep going, and say so.
            complete &= kids.is_empty();
            continue;
        }
        for child in kids.into_iter().rev() {
            stack.push((child, depth + 1));
        }
    }
    (found, complete)
}


/// Whether `row` is its table's only selected row (true when the table does
/// not say).
fn only_selected(row: &Ax) -> bool {
    let Some(table) = row.element("AXParent") else { return true };
    let selected = table.elements("AXSelectedRows");
    selected.is_empty() || (selected.len() == 1 && selected[0].same(row))
}

/// Selects `row` alone, as a plain click does: the table's AXSelectedRows set
/// to just this row when it can be set, else the row's AXSelected (which in a
/// multi-select table may add to the selection).
fn select_only(row: &Ax) -> bool {
    let table = row.element("AXParent").filter(|p| {
        matches!(p.string("AXRole").as_deref(), Some("AXTable" | "AXOutline" | "AXList"))
    });
    if let Some(table) = table
        && table.settable("AXSelectedRows")
        && let Some(rows) = Cf::array(&[row.ptr()])
        && table.set("AXSelectedRows", &rows).is_ok()
    {
        return true;
    }
    Cf::boolean(true).is_some_and(|yes| row.set("AXSelected", &yes).is_ok())
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

/// A slider, stepper or level whose AXValue is read-only but which takes
/// AXIncrement / AXDecrement (System Settings' volume and brightness): step
/// toward `value` until the next step would pass it. Values may be given as
/// the element's own number or as a percentage of its range ("25%"). None
/// when the element cannot step or the value is not a number.
fn step_to(el: &Ax, value: &str) -> DResult<Option<ActionOutcome>> {
    let actions = el.actions();
    if !(actions.iter().any(|a| a == "AXIncrement") && actions.iter().any(|a| a == "AXDecrement")) {
        return Ok(None);
    }
    let number = |name: &str| el.attr(name).ok().flatten().and_then(|v| v.as_f64());
    let (Some(min), Some(max), Some(start)) = (number("AXMinValue"), number("AXMaxValue"), number("AXValue"))
    else {
        return Ok(None);
    };
    let Some(target) = roles::step_target(value, min, max) else { return Ok(None) };
    let mut current = start;
    let mut capped = true;
    for _ in 0..200 {
        let going_up = target > current;
        let action = if going_up { "AXIncrement" } else { "AXDecrement" };
        if (target - current).abs() < f64::EPSILON {
            capped = false;
            break;
        }
        el.perform(action).map_err(|e| ax_error(e, "step the value"))?;
        let Some(next) = number("AXValue") else { break };
        match roles::step_outcome(current, next, target, going_up) {
            roles::Step::Continue => current = next,
            roles::Step::AtEnd => {
                capped = false;
                break;
            }
            roles::Step::Away => {
                return Err(DesktopError::Unsupported(format!(
                    "stepping this element moved its value away from {target} ({current} to {next}); set it with a click or a drag instead"
                )));
            }
            roles::Step::Passed { back } => {
                if back {
                    let back = if going_up { "AXDecrement" } else { "AXIncrement" };
                    el.perform(back).map_err(|e| ax_error(e, "step the value"))?;
                }
                capped = false;
                break;
            }
        }
    }
    let read = number("AXValue").unwrap_or(current);
    let mut out = if roles::step_confirmed(capped, read, target, min, max) {
        ActionOutcome::confirmed("ax_step")
    } else {
        ActionOutcome::delivered("ax_step")
    };
    out.note = format!("stepped from {start} to {read} (asked {target}); the element moves in fixed steps");
    if let Some(frame) = el.frame() {
        out = out.at(roles::center(&frame));
    }
    Ok(Some(out))
}
