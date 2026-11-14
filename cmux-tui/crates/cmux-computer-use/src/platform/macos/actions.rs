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

/// How long a foreground action waits for its app to become the active app.
const RAISE_WAIT: std::time::Duration = std::time::Duration::from_millis(1000);

impl MacDesktop {
    /// Raises the window and its app for a Foreground delivery. This is the
    /// only path that changes what is in front, and only when asked.
    fn raise(&self, t: &Target) -> DResult<()> {
        let (app, win) = self.ax_window(t)?;
        win.perform("AXRaise").map_err(|e| ax_error(e, "raising the window"))?;
        if let Some(yes) = Cf::boolean(true) {
            app.set("AXFrontmost", &yes).map_err(|e| ax_error(e, "bringing the app forward"))?;
        }
        // AXFrontmost asks the app to activate; the window server makes it
        // the active app a little later (and may refuse under cooperative
        // activation). System-wide input (the HID tap) goes to whatever is
        // really active, so wait for the app's activation notification, up to
        // RAISE_WAIT, and refuse rather than send input elsewhere.
        let pid = t.window.pid;
        if super::ax::wait_activated(pid, RAISE_WAIT, &|| super::frontmost_pid() == Some(pid)) {
            return Ok(());
        }
        Err(DesktopError::Unsupported(format!(
            "window {}'s app did not come to the front when asked, so system-wide input would reach another app; try again, or use delivery background",
            t.window.id
        )))
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
    fn check_menu_item(&self, t: &Target, el: &Ax, delivery: Delivery) -> DResult<()> {
        if !super::ax::in_menu_bar(el) {
            return Ok(());
        }
        let role = el.string("AXRole").unwrap_or_default();
        let has_submenu = el
            .elements("AXChildren")
            .iter()
            .any(|c| c.string("AXRole").as_deref() == Some("AXMenu"));
        if let Some(why) = roles::submenu_refusal(&role, has_submenu) {
            return Err(DesktopError::Unsupported(why.into()));
        }
        let check = match el.attr("AXTitle") {
            Ok(v) => {
                self.menu_item_check_titled(el, &v.and_then(|v| v.as_string()).unwrap_or_default())
            }
            // Unreadable: refused, whatever the deny list, with its own reason.
            Err(_) => {
                return Err(DesktopError::Unsupported(menus::UNREADABLE_ITEM_REFUSAL.into()));
            }
        };
        if check == roles::ItemCheck::Unknown {
            return Err(DesktopError::Unsupported(menus::APP_NAMES_LOADING.into()));
        }
        if check == roles::ItemCheck::Unplaced {
            return Err(DesktopError::Unsupported(menus::UNREADABLE_ITEM_REFUSAL.into()));
        }
        if check == roles::ItemCheck::Blocked {
            return Err(DesktopError::Unsupported(menus::block_message(
                menus::BlockReason::Denied,
                None,
            )));
        }
        // Menu commands act on the app's key window: the same rule as keys.
        // In the foreground the window is raised first (it becomes the key
        // window), as for keys.
        self.key_route(t, delivery).map(|_| ())
    }

    /// The route for key events. Keys posted to a process go to its key
    /// window, so in the background they are sent only when the target is
    /// that window or the app's only window.
    fn key_route(&self, t: &Target, delivery: Delivery) -> DResult<Route> {
        self.require_input()?;
        if delivery == Delivery::Foreground {
            self.raise(t)?;
            // Raising does not prove the window takes keys: an app-modal alert,
            // a sheet or a floating panel of the app can stay its key window,
            // and keys (or a menu command such as Close or Delete) would act
            // there instead. Refused only when the app names a different focused
            // window: an app just activated may report none yet, and some apps
            // (not AppKit) do not report one at all; those are typed into, as
            // the person's keys would be.
            let (app, win) = self.ax_window(t)?;
            if app.element("AXFocusedWindow").is_some_and(|f| !f.same(&win)) {
                return Err(DesktopError::Unsupported(format!(
                    "window {} did not become the app's key window when raised (an alert, sheet or panel of the app has it), so keys would reach another window; take a screenshot of the app and deal with that window first",
                    t.window.id
                )));
            }
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

    /// Refuses a point whose element (or an ancestor) is a menu item that
    /// leads to a denied app.
    fn refuse_denied_at(&self, t: &Target, at: Point) -> DResult<()> {
        // A point on the recorded menu's window is hit-tested in that
        // window's owner (a System Settings pane draws its menus in a
        // helper process); there, a point that reaches no readable menu
        // item is refused, whatever the deny list.
        // A submenu opened later shows in a window of the same owner at the
        // menu layer: it counts as the menu's too.
        let on_menu = self.recorded_menu().and_then(|(_, windows)| {
            let screen = super::cgwindows::on_screen();
            let owners: Vec<i32> =
                screen.iter().filter(|w| windows.contains(&w.id)).map(|w| w.pid).collect();
            screen.into_iter().find(|w| {
                (windows.contains(&w.id) || (w.layer == MENU_LAYER && owners.contains(&w.pid)))
                    && roles::contains(&w.frame, at)
            })
        });
        let pid = on_menu.as_ref().map_or(t.window.pid, |w| w.pid);
        let mut el = Ax::application(pid).and_then(|app| app.element_at(at.x, at.y));
        let mut found_item = false;
        for _ in 0..4 {
            let Some(current) = el else { break };
            found_item |= current.string("AXRole").as_deref() == Some("AXMenuItem");
            self.refuse_denied_item(&current)?;
            self.refuse_submenu_open(&current)?;
            el = current.element("AXParent");
        }
        if on_menu.is_some() && !found_item {
            return Err(DesktopError::Unsupported(menus::NO_MENU_ITEM_AT_POINT.into()));
        }
        Ok(())
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

/// The window layer of pop-up and context menus (`NSPopUpMenuWindowLevel`).
const MENU_LAYER: i64 = 101;

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
/// A click with `menu_item`: the menu it opens (a context menu for a right
/// click or control-click, else a pop-up's or menu button's) has the item
/// pressed and is closed in this one call. Pressed through accessibility
/// in either delivery: the menu is never left open.
fn click_menu_item(
    d: &MacDesktop,
    t: &Target,
    target: &PointerTarget,
    spec: &ClickSpec,
    value: &str,
) -> DResult<ActionOutcome> {
    if opens_context_menu(spec) {
        d.context_menu_allowed()?;
        return match target {
            PointerTarget::Point { point, .. } => {
                d.context_pick_at(t, d.point_in(t, *point)?, value)
            }
            PointerTarget::Element { element_id, .. } => {
                let el = d.element(t, element_id)?;
                if roles::is_menu_bar(&el.string("AXRole").unwrap_or_default()) {
                    return Err(DesktopError::Unsupported(menus::MENU_BAR_REFUSAL.into()));
                }
                if el.actions().iter().any(|a| a == "AXShowMenu") {
                    d.element_menu_pick(t, &el, value)
                } else {
                    d.context_pick_at(t, d.element_center(t, element_id)?, value)
                }
            }
        };
    }
    let (el, element_id) = match target {
        PointerTarget::Element { element_id, .. } => {
            (d.element(t, element_id)?, element_id.clone())
        }
        PointerTarget::Point { point, .. } => {
            let at = d.point_in(t, *point)?;
            let el = d.menu_at(t, at)?.ok_or_else(|| {
                DesktopError::Unsupported(
                    "menu_item needs a click that opens a menu: a right click or control-click, or a click on a pop-up or menu button".into(),
                )
            })?;
            (el, format!("at ({:.0}, {:.0})", at.x, at.y))
        }
    };
    if d.menu_gate(&el)?.is_none() {
        return Err(DesktopError::Unsupported(format!(
            "element {element_id} opens no menu; menu_item needs a right click or control-click, or a pop-up or menu button"
        )));
    }
    choose_menu_item(d, t, &el, &element_id, value)
}

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
    // A foreground click first closes a menu left open in another app; one
    // that stays (Finder's context menu ignores Escape) floats over the
    // point. A click on a menu left open presses the item under it in either
    // delivery: a point there that is (or may be) a hidden item is refused.
    if spec.delivery != Delivery::Background {
        d.close_other_menus(t);
    }
    if spec.delivery != Delivery::Background || d.menu_open_in(t.window.pid) {
        d.refuse_denied_at(t, at)?;
    }
    if spec.delivery == Delivery::Background
        && let Some(el) = d.menu_at(t, at)?
    {
        return d.open_menu_of(t, &el, &format!("at ({:.0}, {:.0})", at.x, at.y));
    }
    // A plain background click on a control or a list row: what the point
    // hits is pressed or selected through accessibility, as cua-driver
    // does. A background window takes no first click on a control that does
    // not accept first mouse (Finder's list selects nothing), and AX needs no
    // pointer. Anything else (text, canvas, web content) gets the events.
    if spec.delivery == Delivery::Background
        && spec.button == Button::Left
        && spec.count <= 1
        && spec.modifiers.is_empty()
        && let Some(out) = ax_click_at(d, t, at)?
    {
        return Ok(out);
    }
    let route = d.pointer_route(t, spec.delivery)?;
    input::click(route, at, spec.button, spec.count, keymap::flags(&spec.modifiers), spec.gap)?;
    Ok(ActionOutcome::delivered(route.name()).at(at))
}

/// The element a background click at `at` acts on through accessibility:
/// the app's hit test at the point, kept only when it is inside the target
/// window. A label or image inside a control counts as the control.
fn ax_click_at(d: &MacDesktop, t: &Target, at: Point) -> DResult<Option<ActionOutcome>> {
    let Ok((app, win)) = d.ax_window(t) else { return Ok(None) };
    let Some(hit) = app.element_at(at.x, at.y) else { return Ok(None) };
    if !hit.element("AXWindow").is_some_and(|w| w.same(&win)) {
        return Ok(None);
    }
    let mut el = hit;
    for _ in 0..2 {
        let role = el.string("AXRole").unwrap_or_default();
        if !roles::is_label_role(&role) {
            break;
        }
        match el.element("AXParent") {
            Some(parent) if roles::is_press_role(&parent.string("AXRole").unwrap_or_default()) => {
                el = parent;
            }
            _ => break,
        }
    }
    let role = el.string("AXRole").unwrap_or_default();
    let actions = el.actions();
    match roles::hit_click(&role, actions.iter().any(|a| a == "AXPress"), selectable(&el).is_some())
    {
        roles::HitClick::Press => {
            d.refuse_denied_item(&el)?;
            d.refuse_submenu_open(&el)?;
            let before = el.value_text();
            el.perform("AXPress").map_err(|e| ax_error(e, "pressing the element at the point"))?;
            let mut out = outcome_after("ax_hit_press", before, &el);
            out.cursor_at = Some(at);
            Ok(Some(out))
        }
        roles::HitClick::Select => {
            let Some(row) = selectable(&el) else { return Ok(None) };
            if !select_only(&row) {
                return Ok(None);
            }
            let mut out = select_outcome(&row);
            out.cursor_at = Some(at);
            Ok(Some(out))
        }
        roles::HitClick::Events => Ok(None),
    }
}

/// Makes a background app validate its menus against `t`'s window
/// ([`super::activation`]) and waits for `item` to be enabled; the scope
/// hands the window back when dropped. Refused (nothing pressed) when the
/// item stays disabled: the command does not apply to that window.
fn enable_menu_item(
    t: &Target,
    item: &Ax,
    element_id: &str,
) -> DResult<super::activation::KeyInApp> {
    let title = item.string("AXTitle").unwrap_or_default();
    let key = super::activation::KeyInApp::enter(t.window.id).ok_or_else(|| {
        DesktopError::Unsupported(format!(
            "menu item {title:?} ({element_id}) is disabled while its app is in the background, and the window could not be made the app's key window; nothing was pressed. Use delivery foreground if it is allowed"
        ))
    })?;
    if super::activation::wait_until(super::activation::VALIDATE_WAIT, &|| {
        item.bool("AXEnabled") != Some(false)
    }) {
        return Ok(key);
    }
    Err(DesktopError::Unsupported(format!(
        "menu item {title:?} ({element_id}) stays disabled with window {} as the app's key window: the command does not apply to it now, so nothing was pressed",
        t.window.id
    )))
}

/// `confirmed` when the row reads back as the only selected one.
fn select_outcome(row: &Ax) -> ActionOutcome {
    let mut out = if row.bool("AXSelected") == Some(true) && only_selected(row) {
        ActionOutcome::confirmed("ax_select")
    } else {
        ActionOutcome::delivered("ax_select")
    };
    if let Some(frame) = row.frame() {
        out = out.at(roles::center(&frame));
    }
    out
}

pub(super) fn click(
    d: &MacDesktop,
    target: &PointerTarget,
    spec: &ClickSpec,
) -> DResult<ActionOutcome> {
    let t = d.target(target.window_id())?;
    // menu_item: open the menu, press the item, close it, in this call.
    if let Some(value) = spec.menu_item.as_deref() {
        return click_menu_item(d, &t, target, spec, value);
    }
    if spec.delivery == Delivery::Background && opens_context_menu(spec) {
        d.context_menu_allowed()?;
        d.refuse_left_open_in_persons_app(&t)?;
        return match target {
            PointerTarget::Point { point, .. } => d.context_menu_at(&t, d.point_in(&t, *point)?),
            PointerTarget::Element { element_id, .. } => {
                let el = d.element(&t, element_id)?;
                if roles::is_menu_bar(&el.string("AXRole").unwrap_or_default()) {
                    return Err(DesktopError::Unsupported(menus::MENU_BAR_REFUSAL.into()));
                }
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
    d.refuse_submenu_open(&el)?;
    if spec.delivery == Delivery::Background {
        d.refuse_denied_item(&el)?;
        if d.menu_gate(&el)?.is_some() {
            return d.open_menu_of(&t, &el, element_id);
        }
    } else {
        d.refuse_denied_item(&el)?;
        d.close_other_menus(&t);
        // A menu that stays open may float over the element's center.
        if let Some(frame) = el.frame() {
            d.refuse_denied_at(&t, roles::center(&frame))?;
        }
    }
    d.check_menu_item(&t, &el, spec.delivery)?;
    // A menu bar item has no screen frame to click while its menu is closed:
    // after check_menu_item raised the window (foreground) it is pressed
    // through AX in either delivery.
    let in_menu_bar = super::ax::in_menu_bar(&el);
    // A background app has no key window, so a menu item that acts on one is
    // disabled; the target window is made the app's key window (to the app
    // only) until the press is done.
    let _key = if spec.delivery == Delivery::Background
        && in_menu_bar
        && el.bool("AXEnabled") == Some(false)
    {
        Some(enable_menu_item(&t, &el, element_id)?)
    } else {
        None
    };
    let semantic = (spec.delivery == Delivery::Background || in_menu_bar)
        && spec.modifiers.is_empty()
        && spec.count <= 1;
    let available = if semantic { el.actions() } else { Vec::new() };
    // An element in a row or cell that has no press action (a Finder file
    // name, System Settings' sidebar, table cells): a plain click selects
    // its row, so the row is selected through accessibility. Before the
    // element's own AXConfirm or AXOpen: those confirm an edit or open the
    // item, which a single click does not (Finder's AXConfirm on a name did
    // nothing at all).
    if semantic
        && spec.button == Button::Left
        && !available.iter().any(|a| a == "AXPress")
        && let Some(row) = selectable(&el)
        && select_only(&row)
    {
        return Ok(select_outcome(&row));
    }
    if semantic
        && let Some(action) =
            press_actions(spec.button).iter().find(|a| available.iter().any(|x| x == *a))
    {
        let before = el.value_text();
        el.perform(action).map_err(|e| ax_error(e, &format!("element {element_id}")))?;
        let mut out = outcome_after(&route_name(action), before, &el);
        // A menu bar item's frame while its menu is closed is off screen
        // (Safari's View items report y 900): no cursor there.
        if in_menu_bar {
            out.cursor_at = None;
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

/// Key codes of the net-zero edit below.
const KEY_SPACE: u16 = 49;
const KEY_DELETE: u16 = 51;

/// Text written through accessibility into a document's text view is not an
/// edit as far as the document knows: it stays unmodified and File > Save
/// writes nothing (TextEdit, eval: cmd+s after type_text left the file as it
/// was). A space and a Delete typed at the caret right after make it one,
/// as cua-driver does. Only when the element is focused, keys reach its
/// window and it is not the app the person is typing in.
fn mark_document_edited(d: &MacDesktop, t: &Target, el: &Ax, out: &mut ActionOutcome) {
    if out.evidence != "confirmed"
        || el.bool("AXFocused") != Some(true)
        || el.string("AXRole").as_deref() != Some("AXTextArea")
        || d.is_persons_app(t)
    {
        return;
    }
    let Ok((_, win)) = d.ax_window(t) else { return };
    if win.string("AXDocument").is_none() {
        return;
    }
    let Ok(route @ Route::Pid { .. }) = d.key_route(t, Delivery::Background) else { return };
    let before = el.value_text();
    if input::key(route, KEY_SPACE, 0, Some(' ')).is_ok()
        && input::key(route, KEY_DELETE, 0, None).is_ok()
    {
        out.note = "a space and a Delete were typed after the text so the document counts it as an edit (an accessibility write alone leaves it unmodified, and Save would write nothing)".into();
    }
    // The pair is net zero; anything else is said.
    std::thread::sleep(std::time::Duration::from_millis(60));
    if el.value_text() != before {
        out.note = "a space and a Delete were typed after the text to mark the document edited, but its text changed: check it".into();
    }
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
            mark_document_edited(d, &t, el, &mut out);
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
        // Typed keys would type-select (and with a newline, run) an item of a
        // menu left open in this app, a hidden one too: refused before the
        // element is focused.
        if d.menu_open_in(t.window.pid) {
            return Err(DesktopError::Unsupported(menus::OPEN_MENU_KEYS_REFUSAL.into()));
        }
        if delivery == Delivery::Foreground {
            d.refuse_other_menus(&t)?;
        }
        // Keys go to the focused element: focus this one first (it changes
        // focus inside the app, not which app is in front).
        if element_id.is_some()
            && let Some(yes) = Cf::boolean(true)
        {
            el.set("AXFocused", &yes).map_err(|e| ax_error(e, "focusing the element"))?;
        }
    }
    if d.menu_open_in(t.window.pid) {
        return Err(DesktopError::Unsupported(menus::OPEN_MENU_KEYS_REFUSAL.into()));
    }
    // Foreground keys go where the keyboard is: a menu left open in another
    // app may hold it.
    if delivery == Delivery::Foreground {
        d.refuse_other_menus(&t)?;
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
    // Foreground keys go where the keyboard is: a menu left open in another
    // app may hold it (always on the fallback path).
    if delivery == Delivery::Foreground {
        d.refuse_other_menus(&t)?;
    }
    // While a menu this desktop left open shows, every key posted to its
    // app reaches the menu, whichever window it is aimed at: Return or Space
    // runs the highlighted item and letters type-select one, either may be
    // an item hidden from the tree (a denied app's). Only Escape (it closes
    // the menu, through accessibility: a posted Escape does not reach every
    // app's menu) and the bare arrows (they only move the highlight) are
    // taken, in either delivery.
    if d.menu_open_in(t.window.pid) {
        match roles::key_with_open_menu(combo) {
            roles::OpenMenuKey::Close => {
                if d.close_opened() {
                    return Ok(ActionOutcome::confirmed("ax_cancel_menu"));
                }
                return Err(DesktopError::Failed(menus::MENU_DID_NOT_CLOSE.into()));
            }
            // Arrows could park the highlight on a hidden item.
            roles::OpenMenuKey::Post
                if d.open_menu_hides_items(t.window.pid) || d.held_menu_guards_keys() =>
            {
                return Err(DesktopError::Unsupported(menus::OPEN_MENU_KEYS_REFUSAL.into()));
            }
            roles::OpenMenuKey::Post => {}
            roles::OpenMenuKey::Refuse => {
                return Err(DesktopError::Unsupported(menus::OPEN_MENU_KEYS_REFUSAL.into()));
            }
        }
    }
    // A chord a menu item or a Service can own (Command, Control or Option,
    // or a function key), in either delivery: the app's menus are searched
    // in AppKit's order. An enabled, unblocked first match is pressed through
    // accessibility instead of posting the key, so no Service, other item or
    // key-time revalidation can take it. A posted chord keeps its Shift on
    // every route (checked on macOS 26.6 with TextEdit and Terminal, the app
    // active or not: pid with or without the window fields, and the HID
    // tap); Shift is lost only when the event carries a character string,
    // which a chord with Command, Control or Option never does (carries_text).
    // The key route first: a menu item acts on the app's key window, so it
    // is pressed only when keys would reach the target window.
    // Not covered: a plain key with no modifier (only an app that registers
    // bare keys gives it a menu item) and items an app builds only when its
    // menu opens or hides from AX.
    let route = d.key_route(&t, delivery)?;
    use crate::keys::{Key, Modifier};
    let mut disabled_item: Option<String> = None;
    let menu_chord = combo
        .modifiers
        .iter()
        .any(|m| matches!(m, Modifier::Meta | Modifier::Control | Modifier::Alt))
        || matches!(combo.key, Key::F(_));
    let denies_any = d.denies_any();
    if menu_chord {
        // In the background the walk stops at the first enabled match (it is
        // pressed or refused); a foreground chord may be posted, which needs
        // every match.
        let background = delivery == Delivery::Background;
        let (mut items, mut complete) = shortcut_matches(d, t.window.pid, combo, background);
        // Every match disabled in a background app: its menus validate as if
        // it had no key window (it has none). Key events never reach a
        // background app's menus, so the target window is made the app's key
        // window (to the app only) and the menus are searched again once an
        // item validates; the scope lasts until the press below.
        let _key = if background
            && roles::needs_menu_validation(
                &items.iter().map(|(_, m)| m.clone()).collect::<Vec<_>>(),
            ) {
            let key = super::activation::KeyInApp::enter(t.window.id);
            if key.is_some()
                && super::activation::wait_until(super::activation::VALIDATE_WAIT, &|| {
                    items.iter().any(|(el, _)| el.bool("AXEnabled") != Some(false))
                })
            {
                (items, complete) = shortcut_matches(d, t.window.pid, combo, background);
            }
            key
        } else {
            None
        };
        let matches: Vec<roles::ShortcutMatch> = items.iter().map(|(_, m)| m.clone()).collect();
        // The layout and Services are read only when the rule needs them.
        let checks = roles::needs_key_checks(&matches, denies_any, background) && complete;
        let shift = flags & keymap::FLAG_SHIFT != 0;
        let layout_known =
            !checks || roles::layout_places(&combo.key, shift, workspace::keyboard_layout());
        let is_service = if checks && layout_known {
            match workspace::service_shortcuts() {
                None => roles::ServiceCheck::Unread,
                Some(list) if keymap::is_service_shortcut(code, flags, &list) => {
                    roles::ServiceCheck::Match
                }
                Some(_) => roles::ServiceCheck::NoMatch,
            }
        } else {
            roles::ServiceCheck::NoMatch
        };
        let facts = roles::ChordFacts {
            matches: &matches,
            complete,
            background,
            denies_any,
            layout_known,
            is_service,
        };
        match roles::decide_chord(&facts) {
            roles::ChordAction::PressItem(i) => {
                items[i]
                    .0
                    .perform("AXPress")
                    .map_err(|e| ax_error(e, "press the shortcut's menu item"))?;
                return Ok(ActionOutcome::delivered("ax_menu_shortcut"));
            }
            roles::ChordAction::Refuse(why) => {
                // A block that only stands because names are still loading
                // says so, not "the deny list".
                let blocking = matches.iter().find(|m| m.blocked);
                if let Some(loading) =
                    roles::loading_instead(why, blocking.is_some_and(|m| m.unknown))
                {
                    return Err(DesktopError::Unsupported(loading.into()));
                }
                // Blocked because an item above it cannot be read: say so.
                if why == roles::REFUSE_BLOCKED && blocking.is_some_and(|m| m.unplaced) {
                    return Err(DesktopError::Unsupported(menus::UNREADABLE_ITEM_REFUSAL.into()));
                }
                // Name the menu item only when it is the reason.
                let item = (why == roles::REFUSE_BLOCKED)
                    .then(|| matches.iter().find(|m| m.blocked))
                    .flatten()
                    .filter(|m| !m.title.is_empty())
                    .map(|m| format!(" (menu item {:?})", m.title))
                    .unwrap_or_default();
                return Err(DesktopError::Unsupported(format!("{why}{item}")));
            }
            roles::ChordAction::Post => {
                if background && roles::needs_menu_validation(&matches) {
                    disabled_item = matches.first().map(|m| m.title.clone());
                }
            }
        }
    }
    // Space, Return and the arrows open a focused pop-up's menu.
    // (Not while that menu is open: its arrows only move the highlight.)
    if delivery == Delivery::Background
        && roles::key_opens_menu(&combo.key)
        && !d.menu_open_in(t.window.pid)
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
    let mut out = ActionOutcome::delivered(route.name());
    if let Some(title) = disabled_item {
        out.note = format!(
            "the chord is the key equivalent of menu item {title:?}, which stays disabled in this background app, so the key was posted to the window; posted keys never run a background app's menu commands"
        );
    }
    Ok(out)
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
    // A drag that starts or ends on a menu left open runs the item under
    // its end (a hidden one too): refused while one shows in this app.
    if d.menu_open_in(t.window.pid) {
        return Err(DesktopError::Unsupported(menus::OPEN_MENU_DRAG_REFUSAL.into()));
    }
    let from = d.point_in(&t, from)?;
    let to = d.point_in(&t, to)?;
    if delivery != Delivery::Background {
        d.close_other_menus(&t);
        // A menu in another app that would not close floats over the screen.
        if d.recorded_menu().is_some() {
            return Err(DesktopError::Unsupported(menus::OPEN_MENU_DRAG_REFUSAL.into()));
        }
    }
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

/// The closed-menu pick: `None` when the pop-up shows no items while closed
/// (then it is opened); else the pick, with a note when the pop-up reads
/// back its old value.
fn pick_closed(
    d: &MacDesktop,
    el: &Ax,
    element_id: &str,
    value: &str,
) -> DResult<Option<ActionOutcome>> {
    let Some(menu) = menu_of(el) else { return Ok(None) };
    let items = super::menus::items(d, &menu);
    if items.is_empty() {
        return Ok(None);
    }
    let titles: Vec<String> = items.iter().map(|i| i.info.title.clone()).collect();
    let hidden: Vec<bool> = items.iter().map(|i| i.denied).collect();
    let mut items = items;
    // Items are checked against the app names: none is chosen while they
    // load (the protected apps always apply).
    let picked = super::menus::gated_pick(workspace::app_names_ready(), &titles, &hidden, value)
        .map_err(|why| DesktopError::Unsupported(why.into()))?;
    let item = match picked {
        menus::Pick::Item(i) => {
            items[i].detail();
            &items[i]
        }
        menus::Pick::Hidden => {
            return Err(DesktopError::Unsupported(menus::denied_item_refusal(Some(value))));
        }
        menus::Pick::Missing(found) => {
            let shown: Vec<String> =
                items.iter().filter(|i| !i.denied).map(|i| i.info.title.clone()).collect();
            return Err(DesktopError::Unsupported(format!(
                "element {element_id}: {}",
                menus::not_found(value, &found, &shown).replace(" (it was closed again)", "")
            )));
        }
    };
    if item.info.disabled {
        return Err(DesktopError::Unsupported(format!(
            "the item {:?} is disabled",
            item.info.title
        )));
    }
    // The full check (LaunchServices names too) on the one item pressed.
    if let Some(reason) = d.opened_item_reason(&item.el) {
        return Err(DesktopError::Unsupported(menus::block_message(reason, Some(value))));
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
    d.refuse_submenu_open(&el)?;
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
    d.check_menu_item(&t, &el, Delivery::Background)?;
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
/// and blocked. With `stop_at_enabled` (a background chord, pressed or
/// refused at its first enabled match) the walk ends there; otherwise (a
/// foreground chord, which may be posted and is then routed by AppKit at key
/// time) it collects every match within the bounds. The bool is
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
    let mut stack: Vec<(Ax, usize)> =
        children(&bar, &mut complete).into_iter().rev().map(|c| (c, 0)).collect();
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
            let (Ok(cmd_char), Ok(virtual_key), Ok(glyph), Ok(mods)) = (
                text(&node, "AXMenuItemCmdChar"),
                number(&node, "AXMenuItemCmdVirtualKey"),
                number(&node, "AXMenuItemCmdGlyph"),
                number(&node, "AXMenuItemCmdModifiers"),
            ) else {
                complete = false;
                continue;
            };
            let key = keymap::menu_item_key(cmd_char.as_deref(), virtual_key, glyph);
            // While something is denied, a key equivalent this walk cannot
            // place could be the chord, unless its Option, Control and
            // Command already rule it out; and a key with no modifiers
            // reported cannot be compared at all. Either makes the walk
            // incomplete.
            if d.denies_any() && !key.is_empty() {
                match mods {
                    Some(m) if key.unplaceable && keymap::menu_mods_match(combo, m) => {
                        complete = false;
                    }
                    None => complete = false,
                    Some(_) => {}
                }
            }
            if !key.is_empty() && keymap::menu_item_matches(combo, &key, mods.unwrap_or(0)) {
                let enabled = match node.attr("AXEnabled") {
                    Ok(v) => v.and_then(|v| v.as_bool()) != Some(false),
                    Err(_) => {
                        // Unknown: it may run at key time.
                        complete = false;
                        true
                    }
                };
                let (title, blocked, checked, unknown, unplaced) = match text(&node, "AXTitle") {
                    Ok(t) => {
                        let t = t.unwrap_or_default();
                        let check = d.menu_item_check_titled(&node, &t);
                        let unknown = check == roles::ItemCheck::Unknown;
                        let unplaced = check == roles::ItemCheck::Unplaced;
                        (t, check != roles::ItemCheck::Allowed, true, unknown, unplaced)
                    }
                    // A title that cannot be read cannot be checked: blocked
                    // while something is denied, and never pressed; with
                    // nothing denied the key is posted, as Codex does (a
                    // posted chord leaves no menu under the person's keys).
                    Err(()) => {
                        complete = false;
                        (String::new(), d.denies_any(), false, false, false)
                    }
                };
                found.push((
                    node.clone(),
                    roles::ShortcutMatch { title, enabled, blocked, checked, unknown, unplaced },
                ));
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
        if matches!(role.as_str(), "AXRow" | "AXCell" | "AXOutlineRow")
            && node.settable("AXSelected")
        {
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
    let (Some(min), Some(max), Some(start)) =
        (number("AXMinValue"), number("AXMaxValue"), number("AXValue"))
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
    out.note = format!(
        "stepped from {start} to {read} (asked {target}); the element moves in fixed steps"
    );
    if let Some(frame) = el.frame() {
        out = out.at(roles::center(&frame));
    }
    Ok(Some(out))
}
