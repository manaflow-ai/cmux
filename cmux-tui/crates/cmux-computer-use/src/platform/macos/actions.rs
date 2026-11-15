//! The input half of the macOS desktop: each action picks the most
//! semantic route that can prove its target (an AX action or attribute
//! write, then events posted to the window's process) and refuses rather
//! than send input that could land in another window.

use super::ax::{Ax, ax_error};
use super::input::{self, Route};
use super::sys::Cf;
use super::{MacDesktop, Target, keymap, readback, roles, workspace};
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

/// `confirmed` when the element's value changed (read again after the
/// settle), else `delivered`.
/// `effects`: what a press on it must show elsewhere, read before the
/// press ([`press_effects`]).
fn outcome_after(
    d: &MacDesktop,
    route: &str,
    action: &str,
    before: Option<readback::Known<String>>,
    el: &Ax,
    effects: Option<readback::Check>,
) -> ActionOutcome {
    // Read strictly: a failed read is no value change and no baseline.
    let after = el.try_value_text().ok().flatten();
    let role = el.string("AXRole").unwrap_or_default();
    // What the press asks of the value: a direction for increment and
    // decrement, a selected radio button, else any other value (a toggle).
    let wanted = match action {
        "AXIncrement" => readback::Wanted::Direction(1.0),
        "AXDecrement" => readback::Wanted::Direction(-1.0),
        _ if role == "AXRadioButton" => readback::Wanted::from_request("1"),
        _ => readback::Wanted::Other,
    };
    let baseline = before.as_ref().filter(|b| !b.get().is_empty());
    let mut out = match (baseline, &after) {
        (Some(b), Some(a))
            if readback::wanted_reached(b.get(), a, &wanted, 0.0) && a != b.get() =>
        {
            let mut out = ActionOutcome::confirmed(route);
            out.expect = d.expect(Some(readback::Check::value_from(el, b, wanted, 0.0)));
            out
        }
        // A radio button already on stays on when pressed: done already,
        // not "no effect" (the read-back states no change).
        (Some(b), _) if roles::press_already_done(&role, action, b.get()) => {
            let mut out = ActionOutcome::delivered(route);
            out.expect = d.expect(Some(readback::Check::value_from(el, b, wanted, 0.0)));
            out
        }
        _ => {
            let mut out = ActionOutcome::delivered(route);
            out.expect = d.expect(effects);
            out
        }
    };
    // A value control (a checkbox, radio button, switch, disclosure
    // triangle, stepper, slider) pressed, incremented or decremented shows
    // it in its value; a button, a confirm or cancel, a custom action may
    // act where nothing shows.
    if baseline.is_some()
        && roles::press_shows_value(&role, el.string("AXSubrole").as_deref(), action)
    {
        out = out.showing("value");
    }
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
    pub(super) fn is_persons_app(&self, t: &Target) -> bool {
        // The person's app: the active app or the one with the keyboard (a
        // non-activating panel); either unreadable counts as the person's
        // (fail closed).
        let pid = t.window.pid;
        super::active_pid().is_none_or(|p| p == pid)
            || super::frontmost_pid().is_none_or(|p| p == pid)
    }

    /// Whether a background activation of `el` opens a menu, and whether
    /// that may happen ([`crate::menus`]): `Ok(None)` opens none,
    /// `Ok(Some(role))` opens one the setting allows; a menu bar menu, or
    /// any menu under `refuse`, is refused.
    fn menu_gate(&self, el: &Ax) -> DResult<Option<String>> {
        let Some(role) = menu_role(el)? else { return Ok(None) };
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
        match menu_role(el)? {
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
        // A hit test that fails says nothing about a menu there: refused.
        let Some(hit) = Ax::application(t.window.pid).and_then(|app| app.element_at(at.x, at.y))
        else {
            return Err(DesktopError::Unsupported(roles::MENU_UNREAD_REFUSAL.into()));
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
/// Read strictly: an unreadable role, or children that cannot be read, may
/// be a menu opener, and are refused (`Err`) rather than let through.
fn menu_role(el: &Ax) -> DResult<Option<String>> {
    let unread = || DesktopError::Unsupported(roles::MENU_UNREAD_REFUSAL.into());
    let Some(role) = el.try_string("AXRole").map_err(|_| unread())? else { return Ok(None) };
    if !MENU_CANDIDATES.contains(&role.as_str()) {
        return Ok(None);
    }
    let in_web = roles::menu_gate_web(in_web_area(el));
    let has_menu = menu_of(el).ok_or_else(unread)?.is_some();
    Ok(roles::opens_menu(&role, in_web, has_menu).then_some(role))
}

/// Whether the element is, or sits inside, web content (an `AXWebArea`),
/// read strictly: a read that fails on the way, or a walk past its bound,
/// is `Unknown`, which each caller takes on its safe side.
fn in_web_area(el: &Ax) -> roles::Web {
    roles::web_content(web_walk(el))
}

/// The roles from `el` up to its window (inclusive), or `None` when a read
/// failed or the walk ran past its bound.
/// Ends only at the window or the app: a missing parent or an unreadable
/// role on the way is unknown.
fn web_walk(el: &Ax) -> Option<Vec<String>> {
    let mut roles = Vec::new();
    let mut current = el.clone();
    for _ in 0..64 {
        let role = current.try_string("AXRole").ok()??;
        let end = matches!(role.as_str(), "AXWindow" | "AXApplication");
        roles.push(role);
        if end {
            return Some(roles);
        }
        current = current.try_element("AXParent").ok()??;
    }
    None
}

/// The menu a pop-up or menu button holds as its child, when it shows it
/// while closed.
/// `None` when the children or a role cannot be read; `Some(None)`: no menu.
fn menu_of(el: &Ax) -> Option<Option<Ax>> {
    for c in el.try_elements("AXChildren").ok()? {
        if c.try_string("AXRole").ok()?.as_deref() == Some("AXMenu") {
            return Some(Some(c));
        }
    }
    Some(None)
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
    let pid = t.window.pid;
    unprimed(route, |p| {
        let flags = keymap::flags(&spec.modifiers);
        // Read under the posting lock, right before the post; readings that
        // disagree post nothing.
        let front = super::aimed(pid)?;
        input::click(p, at, spec.button, spec.count, flags, spec.gap, front)
    })?;
    Ok(ActionOutcome::delivered(route.name()).at(at))
}

/// The element a background click at `at` acts on through accessibility:
/// the app's hit test at the point, kept only when it is inside the target
/// window. A label or image inside a control counts as the control.
fn ax_click_at(d: &MacDesktop, t: &Target, at: Point) -> DResult<Option<ActionOutcome>> {
    // A window off screen keeps refusing point clicks (pointer_route).
    if !roles::hit_usable(t.window.on_screen, true) {
        return Ok(None);
    }
    let Ok((app, win)) = d.ax_window(t) else { return Ok(None) };
    let Some(hit) = app.element_at(at.x, at.y) else { return Ok(None) };
    if !roles::hit_usable(true, hit.element("AXWindow").is_some_and(|w| w.same(&win))) {
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
    // A row already selected takes the click itself (an editable cell gets
    // its caret from the events); only an unselected row is selected.
    let unselected_row = selectable(&el).is_some_and(|row| row.bool("AXSelected") != Some(true));
    let denied = d.refuse_denied_item(&el);
    let blocked = denied.is_err();
    // Text: the caret goes where the click is, through accessibility; not
    // in a row (a click there selects the row, it does not start editing)
    // and not in the person's app (it would move their caret).
    if roles::caret_click_allowed(blocked, selectable(&el).is_some(), d.is_persons_app(t))
        && let Some(out) = caret_click(d, t, &el, at)?
    {
        return Ok(Some(out));
    }
    match roles::hit_click(&role, actions.iter().any(|a| a == "AXPress"), unselected_row, blocked) {
        roles::HitClick::Refuse => denied.map(|()| None),
        roles::HitClick::Press => {
            d.refuse_submenu_open(&el)?;
            let holder = value_holder(&el);
            let before = readback::Known::value(&holder);
            let effects = press_effects(&el, "AXPress");
            let mut out = match el.perform("AXPress") {
                Ok(()) => outcome_after(d, "ax_hit_press", "AXPress", before, &holder, effects),
                // Not taken at all: the events.
                Err(e) if roles::press_error_falls_back(e) => return Ok(None),
                // It may have run (a modal loop, a popped menu): no second click.
                Err(_) => {
                    let mut out = ActionOutcome::delivered("ax_hit_press");
                    out.note = "the app did not answer the press in time; it may have run (a dialog or menu it opened would hold it), so no click was posted after it".into();
                    out
                }
            };
            out.cursor_at = Some(at);
            Ok(Some(out))
        }
        roles::HitClick::Select => {
            let Some(row) = selectable(&el) else { return Ok(None) };
            let check = select_check(&row);
            if !select_only(&row) {
                return Ok(None);
            }
            let mut out = select_outcome(d, &row, check);
            out.cursor_at = Some(at);
            Ok(Some(out))
        }
        roles::HitClick::Events => Ok(None),
    }
}

/// The element whose value shows a press on `el`: `el` when it has a value,
/// else its stepper (an arrow of an AXIncrementor has none; the stepper's
/// value changes).
fn value_holder(el: &Ax) -> Ax {
    if el.value_text().is_some() {
        return el.clone();
    }
    el.element("AXParent")
        .filter(|p| p.string("AXRole").as_deref() == Some("AXIncrementor"))
        .unwrap_or_else(|| el.clone())
}

/// An editable text element (a text field or area, not a secure field, not
/// web content, whose page may handle clicks itself) that takes a selection
/// through accessibility.
fn ax_text(el: &Ax) -> bool {
    let role = el.string("AXRole").unwrap_or_default();
    roles::is_text_input(&role)
        && !roles::is_secure(&role, el.string("AXSubrole").as_deref())
        && el.settable("AXSelectedTextRange")
        && roles::native_route(in_web_area(el))
}

/// Runs AX writes to `pid`'s app while no other session's key-in-app scope
/// is open on it (under the same lock input takes): refused when one stays
/// open past the bound, nothing written.
fn ax_unprimed<T>(pid: i32, write: impl FnOnce() -> T) -> DResult<T> {
    super::activation::post_unprimed(Route::Pid { pid, window: 0 }, |_| write())
        .ok_or_else(|| DesktopError::Unsupported(super::activation::PRIMED_KEYS_REFUSAL.into()))
}

/// Read-backs of a delivered press on a button, after the settle: a sheet
/// or popover opening in its window, the sheet it is in closing, or a
/// digit button's digit ending the one text that changed (a calculator).
fn press_effects(el: &Ax, action: &str) -> Option<readback::Check> {
    if el.string("AXRole").as_deref() != Some("AXButton") || action != "AXPress" {
        return None;
    }
    let mut checks = Vec::new();
    if let Some(gone) = readback::Check::gone_of(el) {
        checks.push(gone);
    }
    if let Some(win) = el.element("AXWindow") {
        if let Some(opened) = readback::Check::opened(&win) {
            checks.push(opened);
        }
        // A "New …" button (Notes' New Note) adds a row to a list.
        let named_new = [el.string("AXTitle"), el.string("AXDescription")]
            .into_iter()
            .flatten()
            .any(|t| t.trim().starts_with("New "));
        if named_new && let Some(grew) = readback::Check::rows_grew_in(&win) {
            checks.push(grew);
        }
        if let Some(ch) = digit_of(el)
            && let Some(digit) = readback::Check::digit(&win, ch)
        {
            checks.push(digit);
        }
    }
    readback::Check::any(checks)
}

/// What a menu item titled `title` must show, read before it is pressed:
/// Save writes the window's document file; an item that makes something
/// new in a focused list leaves one new row selected.
fn item_effect(d: &MacDesktop, t: &Target, title: Option<&str>) -> Option<readback::Check> {
    let title = title?.trim();
    if title == "Save" {
        let (_, win) = d.ax_window(t).ok()?;
        return readback::Check::saved_doc(&win);
    }
    if title.starts_with("New ") {
        let list = d.focused_in(t).filter(|el| {
            matches!(el.string("AXRole").as_deref(), Some("AXTable" | "AXOutline" | "AXList"))
        })?;
        return readback::Check::new_row(&list);
    }
    None
}

/// A menu item's toggle read-back joined with what its title must show;
/// `None` when neither has a known baseline.
fn menu_checks(
    toggle: Option<readback::Check>,
    effect: Option<readback::Check>,
) -> Option<readback::Check> {
    readback::Check::any(toggle.into_iter().chain(effect).collect())
}

/// The digit a button types: its title or description is one digit.
fn digit_of(el: &Ax) -> Option<char> {
    [el.string("AXTitle"), el.string("AXDescription")]
        .into_iter()
        .flatten()
        .find_map(|t| roles::single_digit(&t))
}

/// What a pointer gesture done through AX writes (a caret, a text
/// selection, a scroll, a slider) may do in `pid`'s app.
#[derive(Debug, PartialEq, Eq)]
pub(super) enum AxWrite<T> {
    /// Written; the write's result.
    Done(T),
    /// The app is the person's front app (or that cannot be read): nothing
    /// written, the events run instead (their caret or view would move).
    PersonsApp,
}

/// Runs `write` under `pid`'s input lock while no key-in-app scope is open
/// on the app (waiting at most `bound`; refused after it) and the app is
/// not the person's (`front_is_target`, read again under the lock).
pub(super) fn gated_in<T>(
    registry: &super::activation::Registry,
    pid: i32,
    bound: std::time::Duration,
    front_is_target: impl Fn() -> bool,
    write: impl FnOnce() -> T,
) -> DResult<AxWrite<T>> {
    if front_is_target() {
        return Ok(AxWrite::PersonsApp);
    }
    registry
        .post_unprimed(pid, 0, bound, |_| {
            if front_is_target() { AxWrite::PersonsApp } else { AxWrite::Done(write()) }
        })
        .ok_or_else(|| DesktopError::Unsupported(super::activation::PRIMED_KEYS_REFUSAL.into()))
}

/// [`gated_in`] on the process-wide registry, for `t`'s app.
fn gated<T>(d: &MacDesktop, t: &Target, write: impl FnOnce() -> T) -> DResult<AxWrite<T>> {
    gated_in(
        super::activation::registry(),
        t.window.pid,
        super::activation::WAIT_BOUND,
        || d.is_persons_app(t),
        write,
    )
}

/// Focuses `el` (when it is not) and selects `range` of its text: whether
/// both writes were taken.
fn focus_and_select(el: &Ax, range: super::sys::CFRange) -> bool {
    let focused = el.bool("AXFocused") == Some(true)
        || Cf::boolean(true).is_some_and(|yes| el.set("AXFocused", &yes).is_ok());
    focused && el.set_selected_range(range).is_ok()
}

/// A plain click in text puts the caret at the character under the point
/// (`AXRangeForPosition`) and focuses the element, as the click would; the
/// caret is read back, and again after the settle. Posted clicks do not
/// reach a background AppKit text view (macOS 27.0.1: TextEdit and the
/// fixture's text view kept their selection). `None` only before anything
/// was written: once a write was tried, no click is posted after it.
fn caret_click(d: &MacDesktop, t: &Target, el: &Ax, at: Point) -> DResult<Option<ActionOutcome>> {
    if !ax_text(el) {
        return Ok(None);
    }
    let Some(under) = el.range_for_position(at.x, at.y) else { return Ok(None) };
    let caret = super::sys::CFRange { location: under.location, length: 0 };
    // The baseline, before the write (unread: no read-back, uncertain).
    let check = readback::Check::range(el, caret);
    let AxWrite::Done(taken) = gated(d, t, || focus_and_select(el, caret))? else {
        return Ok(None);
    };
    let mut out = if taken && el.selected_range() == Some(caret) {
        ActionOutcome::confirmed("ax_caret")
    } else {
        let mut out = ActionOutcome::delivered("ax_caret");
        if !taken {
            out.note =
                "the caret could not be set through accessibility; no click was posted after it"
                    .into();
        }
        out
    };
    out.expect = d.expect(check);
    Ok(Some(out.showing("selection").at(at)))
}

/// A left drag from `from` to `to` inside one text element selects the text
/// between the two points through accessibility (read back, and again after
/// the settle). Not in the person's app (it would move their selection) and
/// not in a row (editable cells). `None` only before anything was written.
fn select_drag(
    d: &MacDesktop,
    t: &Target,
    from: Point,
    to: Point,
) -> DResult<Option<ActionOutcome>> {
    let Ok((app, win)) = d.ax_window(t) else { return Ok(None) };
    let Some(el) = app.element_at(from.x, from.y) else { return Ok(None) };
    if !el.element("AXWindow").is_some_and(|w| w.same(&win))
        || !ax_text(&el)
        || !roles::caret_click_allowed(false, selectable(&el).is_some(), d.is_persons_app(t))
        || !app.element_at(to.x, to.y).is_some_and(|end| end.same(&el))
    {
        return Ok(None);
    }
    let (Some(a), Some(b)) =
        (el.range_for_position(from.x, from.y), el.range_for_position(to.x, to.y))
    else {
        return Ok(None);
    };
    let (a, b) = (a.location, b.location);
    let range = super::sys::CFRange { location: a.min(b), length: (a - b).abs() };
    if range.length == 0 {
        return Ok(None);
    }
    let check = readback::Check::range(&el, range);
    let AxWrite::Done(taken) = gated(d, t, || focus_and_select(&el, range))? else {
        return Ok(None);
    };
    let mut out = if taken && el.selected_range() == Some(range) {
        ActionOutcome::confirmed("ax_select_text")
    } else {
        let mut out = ActionOutcome::delivered("ax_select_text");
        if !taken {
            out.note =
                "the selection could not be set through accessibility; no drag was posted after it"
                    .into();
        }
        out
    };
    out.expect = d.expect(check);
    Ok(Some(out.showing("selection").at(to)))
}

/// The slider at `p`: the hit element, or the slider its knob belongs to.
fn slider_at(app: &Ax, win: &Ax, p: Point) -> Option<Ax> {
    let hit = app.element_at(p.x, p.y)?;
    if !hit.element("AXWindow").is_some_and(|w| w.same(win))
        || !roles::native_route(in_web_area(&hit))
    {
        return None;
    }
    if hit.string("AXRole").as_deref() == Some("AXSlider") {
        return Some(hit);
    }
    hit.element("AXParent").filter(|p| p.string("AXRole").as_deref() == Some("AXSlider"))
}

/// A slider's value at a point along it: its fraction of the track times
/// the range (left to right, or bottom to top for a vertical slider).
pub(super) fn slider_value_at(frame: &Rect, min: f64, max: f64, p: Point) -> f64 {
    let fraction = if frame.width >= frame.height {
        (p.x - frame.x) / frame.width
    } else {
        (frame.y + frame.height - p.y) / frame.height
    };
    min + fraction.clamp(0.0, 1.0) * (max - min)
}

/// A left drag from a slider (its track or knob) sets the value under the
/// end point through accessibility, as the drag would (an AppKit slider
/// jumps to a pressed track point and follows the pointer); read back.
/// Posted drags do not reach a background AppKit slider on macOS 27.0.1.
fn slider_drag(
    d: &MacDesktop,
    t: &Target,
    from: Point,
    to: Point,
) -> DResult<Option<ActionOutcome>> {
    let Ok((app, win)) = d.ax_window(t) else { return Ok(None) };
    let Some(slider) = slider_at(&app, &win, from) else { return Ok(None) };
    if !slider.settable("AXValue") {
        return Ok(None);
    }
    let (Some(min), Some(max), Some(frame)) =
        (slider.number("AXMinValue"), slider.number("AXMaxValue"), slider.frame())
    else {
        return Ok(None);
    };
    // A circular slider's value follows the angle, not a track: the events.
    if max <= min || frame.width < 2.0 || frame.height < 2.0 || roles::looks_circular(&frame) {
        return Ok(None);
    }
    let wanted = slider_value_at(&frame, min, max, to);
    let tolerance = roles::slider_tolerance(min, max);
    let check = readback::Check::value(
        &slider,
        readback::Wanted::from_request(format!("{wanted}")),
        tolerance,
    );
    let Some(cf) = Cf::number_f64(wanted) else { return Ok(None) };
    // Not in the person's app, not under another session's scope; from
    // here on a write was tried, so no drag is posted after it.
    let AxWrite::Done(taken) = gated(d, t, || slider.set("AXValue", &cf).is_ok())? else {
        return Ok(None);
    };
    let after = slider.number("AXValue");
    let mut out = if taken && after.is_some_and(|a| (a - wanted).abs() <= tolerance) {
        ActionOutcome::confirmed("ax_slider")
    } else {
        ActionOutcome::delivered("ax_slider")
    };
    out.expect = d.expect(check);
    Ok(Some(out.showing("value").at(to)))
}

/// Points per scroll line for a scroll done through the scroll bars.
const LINE_POINTS: f64 = 16.0;

/// A scroll over an AppKit scroll area (not web content, whose page may
/// handle wheel events itself) moves its scroll bars through accessibility:
/// posted wheel events do not reach a background AppKit view on macOS
/// 27.0.1. The bar's value is a fraction of the scrollable distance (the
/// document's height less the visible height); read back.
fn ax_scroll(
    d: &MacDesktop,
    t: &Target,
    at: Point,
    dx: f64,
    dy: f64,
) -> DResult<Option<ActionOutcome>> {
    Ok(ax_scroll_plan(d, t, at, dx, dy)
        .map(|plan| ax_scroll_run(d, t, at, plan))
        .transpose()?
        .flatten())
}

/// A scroll bar to move: the bar, its value before, the value wanted and
/// the way it moves (+1 toward the end).
type ScrollPlan = Vec<(Ax, readback::Known<f64>, f64, f64)>;

/// The bars an AX scroll would move; `None`: the events instead.
fn ax_scroll_plan(d: &MacDesktop, t: &Target, at: Point, dx: f64, dy: f64) -> Option<ScrollPlan> {
    let (app, win) = d.ax_window(t).ok()?;
    let mut el = app.element_at(at.x, at.y)?;
    if !el.element("AXWindow").is_some_and(|w| w.same(&win))
        || !roles::native_route(in_web_area(&el))
    {
        return None;
    }
    let mut area = None;
    for _ in 0..12 {
        if el.string("AXRole").as_deref() == Some("AXScrollArea") {
            area = Some(el);
            break;
        }
        el = el.element("AXParent")?;
    }
    let area = area?;
    let visible = area.frame()?;
    let content = area
        .elements("AXChildren")
        .into_iter()
        .find(|c| !matches!(c.string("AXRole").as_deref(), Some("AXScrollBar") | None))?;
    let doc = content.frame()?;
    // Everything is read before anything is written: a view this cannot
    // scroll gets the events instead.
    let mut plan = Vec::new();
    for (bar_attr, lines, doc_len, vis_len) in [
        ("AXVerticalScrollBar", dy, doc.height, visible.height),
        ("AXHorizontalScrollBar", dx, doc.width, visible.width),
    ] {
        if lines == 0.0 {
            continue;
        }
        let bar = area.element(bar_attr)?;
        let span = doc_len - vis_len;
        if span <= 0.0 || !bar.settable("AXValue") {
            return None;
        }
        let before = readback::Known::number(&bar, "AXValue")?;
        let wanted = (before.get() + lines * LINE_POINTS / span).clamp(0.0, 1.0);
        plan.push((bar, before, wanted, lines.signum()));
    }
    (!plan.is_empty()).then_some(plan)
}

/// Moves the planned bars, not in the person's app and not under another
/// session's scope (`None`: the events instead, nothing written).
fn ax_scroll_run(
    d: &MacDesktop,
    t: &Target,
    at: Point,
    plan: ScrollPlan,
) -> DResult<Option<ActionOutcome>> {
    // From here on a write was tried: a failure is reported, no events.
    let written = gated(d, t, || {
        let (mut moved, mut failed) = (false, false);
        for (bar, before, wanted, sign) in &plan {
            let before = *before.get();
            if (wanted - before).abs() < 1e-9 {
                continue;
            }
            if Cf::number_f64(*wanted).is_none_or(|cf| bar.set("AXValue", &cf).is_err()) {
                failed = true;
            }
            moved |=
                bar.number("AXValue").is_some_and(|a| readback::moved_toward(before, a, *sign));
        }
        (moved, failed)
    })?;
    let AxWrite::Done((moved, failed)) = written else { return Ok(None) };
    let mut out = if moved && !failed {
        ActionOutcome::confirmed("ax_scroll_bar")
    } else {
        let mut out = ActionOutcome::delivered("ax_scroll_bar");
        if failed {
            out.note = "a scroll bar did not take its new position through accessibility; no scroll events were posted after it".into();
        }
        out
    };
    // At the end it scrolls toward, wanted == before: the read-back states
    // no change.
    out.expect = d.expect(Some(readback::Check::scroll_planned(plan)));
    Ok(Some(out.showing("scroll").at(at)))
}

/// Makes a background app validate its menus against `t`'s window
/// ([`super::activation`]) and waits for `item` to be enabled; the scope
/// hands the window back when ended. Refused (nothing pressed) when the
/// item stays disabled: the command does not apply to that window.
fn enable_menu_item(
    d: &MacDesktop,
    t: &Target,
    item: &Ax,
    element_id: &str,
) -> DResult<(super::activation::KeyInApp<'static>, super::ax::TimeoutGuard)> {
    let title = item.string("AXTitle").unwrap_or_default();
    let key = key_in_app(d, t).ok_or_else(|| {
        DesktopError::Unsupported(format!(
            "menu item {title:?} ({element_id}) is disabled while its app is in the background, and the window could not be made the app's key window; nothing was pressed. Use delivery foreground if it is allowed"
        ))
    })?;
    // Short reads; the item keeps them while the scope is open (the caller
    // presses it), and gets the long timeout back on every exit.
    let short = item.timeout_until_drop(
        super::activation::AX_TIMEOUT_IN_SCOPE,
        super::ax::MESSAGE_TIMEOUT_SECONDS,
    );
    // Only an AXEnabled read as true counts (unreadable: not enabled).
    if key.wait_until(super::activation::VALIDATE_WAIT, &|| item.bool("AXEnabled") == Some(true)) {
        return Ok((key, short));
    }
    drop(short);
    Err(DesktopError::Unsupported(format!(
        "menu item {title:?} ({element_id}) stays disabled with window {} as the app's key window: the command does not apply to it now, so nothing was pressed",
        t.window.id
    )))
}

/// The longest the app gets to take its window as key before the input.
const KEY_SETTLE: std::time::Duration = std::time::Duration::from_millis(250);

/// `t`'s window as its app's key window (to the app only), or `None` unless
/// the app reports it as its focused window within KEY_SETTLE (then the
/// scope is handed back at once).
fn key_in_app(_d: &MacDesktop, t: &Target) -> Option<super::activation::KeyInApp<'static>> {
    let key = super::activation::KeyInApp::enter(t.window.id, t.window.pid)?;
    key.wait_until(KEY_SETTLE, &|| focused_on_target(t)).then_some(key)
}

/// The read-back of selecting `row` alone, its baseline read now (before
/// the selection); `None` when its list or selection cannot be read.
fn select_check(row: &Ax) -> Option<readback::Check> {
    let list = row.try_element("AXParent").ok()??;
    readback::Check::selected(row, &list)
}

/// `confirmed` when the row reads back as the only selected one (and again
/// after the settle, through `check`, built before the selection).
fn select_outcome(d: &MacDesktop, row: &Ax, check: Option<readback::Check>) -> ActionOutcome {
    let mut out = if row.bool("AXSelected") == Some(true) && only_selected(row) {
        ActionOutcome::confirmed("ax_select")
    } else {
        ActionOutcome::delivered("ax_select")
    }
    .showing("selection");
    out.expect = d.expect(check);
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
    reporting_hand_back(|| click_inner(d, target, spec))
}

fn click_inner(d: &MacDesktop, target: &PointerTarget, spec: &ClickSpec) -> DResult<ActionOutcome> {
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
    let semantic = (spec.delivery == Delivery::Background || in_menu_bar)
        && spec.modifiers.is_empty()
        && spec.count <= 1;
    // Read before any scope opens: a click that cannot press never primes.
    let available = if semantic { el.actions() } else { Vec::new() };
    let has_press = press_actions(spec.button).iter().any(|a| available.iter().any(|x| x == a));
    // The item's short AX timeout while a scope is open; the long one comes
    // back when this drops, on every exit.
    let mut item_timeout: Option<super::ax::TimeoutGuard> = None;
    // The item's title before the scope: inside it only the title is read
    // again (the deny list, the protected apps and its place were checked
    // above and by prime_block_of, outside the scope).
    let mut title_before: Option<String> = None;
    // A menu bar item's title and check mark before any scope: read back
    // after the settle (a toggle changes one of them).
    let item_toggle = if in_menu_bar { readback::Check::menu_item(&el) } else { None };
    let item_effect = if in_menu_bar {
        item_effect(d, &t, el.try_string("AXTitle").ok().flatten().as_deref())
    } else {
        None
    };
    // A disabled item of an app that cannot be made to validate (the
    // person's front app, or the scope off) is not pressed: the press would
    // do nothing.
    if spec.delivery == Delivery::Background
        && in_menu_bar
        && semantic
        && el.bool("AXEnabled") == Some(false)
        && d.is_persons_app(&t)
    {
        let title = el.string("AXTitle").unwrap_or_default();
        return Err(DesktopError::Unsupported(format!(
            "menu item {title:?} ({element_id}) is disabled, so nothing was pressed"
        )));
    }
    let mut menu_key = if spec.delivery == Delivery::Background
        && in_menu_bar
        && el.bool("AXEnabled") == Some(false)
        && !d.is_persons_app(&t)
    {
        // Never made available: launch-list items and items that open or
        // reveal documents or apps (they can run a denied app).
        if let Some(why) = prime_block_of(&el, None) {
            return Err(DesktopError::Unsupported(why.into()));
        }
        roles::primed_click(true, has_press)
            .map_err(|why| DesktopError::Unsupported(why.into()))?;
        // Readable here: prime_block_of blocks an unreadable title.
        title_before = el.attr("AXTitle").ok().flatten().and_then(|v| v.as_string());
        let (key, short) = enable_menu_item(d, &t, &el, element_id)?;
        item_timeout = Some(short);
        Some(key)
    } else {
        None
    };
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
    {
        let check = select_check(&row);
        if select_only(&row) {
            return Ok(select_outcome(d, &row, check));
        }
    }
    if semantic
        && let Some(action) =
            press_actions(spec.button).iter().find(|a| available.iter().any(|x| x == *a))
    {
        // In a scope: focus still on the target, the item's title as before
        // (short reads), then live (not stopped, not past its bound, the
        // person did not switch to the app) last, right before the press.
        if let Some(key) = menu_key.as_ref() {
            let title_now = el.attr("AXTitle").ok().flatten().and_then(|v| v.as_string());
            if let Err(why) = roles::primed_press(true, focused_on_target(&t), false)
                .and_then(|()| roles::same_item(title_before.as_deref(), title_now.as_deref()))
                .and_then(|()| roles::primed_press(key.live(), true, false))
            {
                return Err(scope_refusal(menu_key.take(), why));
            }
        }
        // No value read inside a scope (the item has none to compare).
        let primed_press = menu_key.is_some();
        let before = if menu_key.is_some() { None } else { readback::Known::value(&el) };
        // Read before the press: what it must show elsewhere.
        let effects = if menu_key.is_some() { None } else { press_effects(&el, action) };
        let mut out = match el.perform(action) {
            Ok(()) if menu_key.is_some() => ActionOutcome::delivered(&route_name(action)),
            Ok(()) => outcome_after(d, &route_name(action), action, before, &el, effects),
            Err(e) if roles::press_error_falls_back(e) => {
                let err = ax_error(e, &format!("element {element_id}"));
                return Err(with_hand_back(err, menu_key.take()));
            }
            // A timeout or cannot-complete may come back after the press ran
            // (a dialog it opened holds it): delivered, may have run.
            Err(_) => press_outcome(Err(super::sys::AX_CANNOT_COMPLETE), &route_name(action))?,
        };
        drop(item_timeout.take());
        // A menu bar item's frame while its menu is closed is off screen
        // (Safari's View items report y 900): no cursor there.
        if in_menu_bar {
            out.cursor_at = None;
        }
        // Not after a scope: validation itself can change an item's title or
        // mark, and an app primed a moment ago may write its document on
        // its own; a primed press stays uncertain.
        if in_menu_bar && out.evidence != "confirmed" && menu_key.is_none() && !primed_press {
            out.expect = d.expect(menu_checks(item_toggle, item_effect));
        }
        // AXPress runs the item's action before it returns: hand back now.
        if let Some(key) = menu_key.take()
            && key.end() == super::activation::Ended::HandBackFailed
        {
            super::activation::append_note(&mut out.note, super::activation::HAND_BACK_FAILED);
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
/// How long the app gets to report an element focused after the AX focus
/// write, before keys are posted to it.
const FOCUS_WAIT: std::time::Duration = std::time::Duration::from_millis(400);

/// Whether the app reports `el` as its focused element within
/// [`FOCUS_WAIT`] (read strictly; an unreadable focus is not focused).
fn wait_focused(d: &MacDesktop, t: &Target, el: &Ax) -> bool {
    let Ok((app, _)) = d.ax_window(t) else { return false };
    let is_target = || {
        app.try_element("AXFocusedUIElement")
            .ok()
            .flatten()
            .is_some_and(|f| roles::focus_is_target(f.same(el)))
    };
    is_target() || super::menus::wait_for(FOCUS_WAIT, is_target)
}

/// How long an accepted AX insert gets to show in the field's value before
/// the outcome is decided (never followed by keys).
const INSERT_WAIT: std::time::Duration = std::time::Duration::from_millis(600);

/// The bundle id of `t`'s app.
fn app_bundle(t: &Target) -> Option<String> {
    workspace::app_for_pid(t.window.pid).and_then(|a| a.bundle_id)
}

fn ax_insert(d: &MacDesktop, el: &Ax, text: &str) -> DResult<Option<ActionOutcome>> {
    let role = el.string("AXRole").unwrap_or_default();
    if !roles::is_text_input(&role) {
        return Ok(None);
    }
    let secure = roles::is_secure(&role, el.string("AXSubrole").as_deref());
    // The baseline, strictly: unreadable before anything is written, keys
    // are posted instead (nothing was inserted).
    let (Some(known), Some(caret_known)) = (readback::Known::value(el), readback::Known::range(el))
    else {
        return Ok(None);
    };
    let before = known.get().clone();
    let caret = *caret_known.get();
    // A secure field hides its value; its length reads back the typing.
    let typed = text.encode_utf16().count() as f64;
    let length_check =
        || readback::secure_count(el).and_then(|n| readback::Check::length(el, n + typed));
    let Some(cf) = Cf::string(text) else { return Ok(None) };
    if el.settable("AXSelectedText") {
        let check = if secure {
            length_check()
        } else {
            readback::Check::text_from(el, &known, text, &caret_known)
        };
        let written = el.set("AXSelectedText", &cf);
        // A write that timed out or could not complete may still apply:
        // nothing is posted after it (keys could type it twice).
        if let Err(code) = written
            && !roles::press_error_falls_back(code)
        {
            let mut out = ActionOutcome::delivered("ax_insert_text");
            out.note = "the app did not answer the accessibility write in time; it may have applied it, so no keys were posted after it".into();
            out.expect = d.expect(check);
            return Ok(Some(out.showing("text")));
        }
        if written.is_ok() {
            // Taken: no keys after it, ever (a slow app shows the text
            // later; posting keys would type it twice). Wait, bounded, for
            // the value to change before deciding.
            let shows = |after: &str| match caret {
                Some(at) => readback::typed_at(&before, after, text, at),
                None => readback::typed_shows(&before, after, text),
            };
            let mut after = el.try_value_text().ok().flatten();
            if !secure {
                super::menus::wait_for(INSERT_WAIT, || {
                    after = el.try_value_text().ok().flatten();
                    after.as_deref().is_some_and(|a| a != before)
                });
            }
            let applied = !secure && after.as_deref().is_some_and(&shows);
            let mut out = if applied {
                ActionOutcome::confirmed("ax_insert_text")
            } else {
                ActionOutcome::delivered("ax_insert_text")
            };
            if !secure && after.as_deref() == Some(before.as_str()) {
                let app = el
                    .pid()
                    .and_then(workspace::app_for_pid)
                    .map(|a| a.name)
                    .unwrap_or_else(|| "the app".into());
                out.note = format!(
                    "{app} accepted the accessibility write but did not apply it within {} ms; no keys were posted after it",
                    INSERT_WAIT.as_millis()
                );
            }
            out.expect = d.expect(check);
            return Ok(Some(out.showing("text")));
        }
    }
    if !el.settable("AXValue") {
        return Ok(None);
    }
    let wanted = format!("{before}{text}");
    let Some(value) = Cf::string(&wanted) else { return Ok(None) };
    let check = if secure {
        length_check()
    } else {
        Some(readback::Check::value_from(
            el,
            &known,
            readback::Wanted::from_request(wanted.clone()),
            0.0,
        ))
    };
    el.set("AXValue", &value).map_err(|e| ax_error(e, "setting the value"))?;
    let reads_back =
        !secure && el.try_value_text().ok().flatten().as_deref() == Some(wanted.as_str());
    let mut out = if reads_back {
        ActionOutcome::confirmed("ax_set_value")
    } else {
        ActionOutcome::delivered("ax_set_value")
    }
    .showing("text");
    out.expect = d.expect(check);
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
    // Plain text typed into a text element shows in its value; into
    // anything else (a canvas, a calculator's keypad) it may not show.
    let shows_text = !has_keys && target.as_ref().is_some_and(is_text_element);
    if let Some(el) = &target {
        // Web content (and a browser's fields) take an AX insert and ignore
        // it: posted keys go there directly, gated as always, read back at
        // the caret; nothing was written, so nothing can be typed twice.
        let route = roles::insert_route(
            !roles::native_route(in_web_area(el)),
            roles::is_browser(app_bundle(&t).as_deref()),
        );
        if delivery == Delivery::Background
            && !has_keys
            && route == roles::InsertRoute::Ax
            && let Some(mut out) = ax_insert(d, el, text)?
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
        if element_id.is_some() {
            // Not while another session's scope holds the app.
            let written = ax_unprimed(t.window.pid, || {
                Cf::boolean(true).is_some_and(|yes| el.set("AXFocused", &yes).is_ok())
            })?;
            // Keys go only once the app reports the target focused: a write
            // it ignored would send them to whatever field has focus.
            let focused = written && wait_focused(d, &t, el);
            if !focused {
                let mut out = ActionOutcome::delivered("ax_focus");
                out.note = format!(
                    "the element did not take keyboard focus through accessibility within {} ms, so no keys were posted",
                    FOCUS_WAIT.as_millis()
                );
                return Ok(out);
            }
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
    // Read back after the settle: the value before the keys.
    let check =
        target.as_ref().filter(|_| shows_text).and_then(|el| readback::Check::text(el, text));
    // Typed into a focused list: type-to-select picks a row by its name.
    // A row starting with the text already selected is done already (the
    // read-back states no change); an unreadable selection, no read-back.
    let check = check.or_else(|| {
        let list = target.as_ref().filter(|el| {
            matches!(el.string("AXRole").as_deref(), Some("AXTable" | "AXOutline" | "AXList"))
        })?;
        if has_keys || text.trim().is_empty() {
            return None;
        }
        readback::Check::type_select(list, text)
    });
    // Never into a primed app (another session's scope): each chunk is posted
    // under the lock entering a scope takes, so a scope can open between
    // chunks but no key lands inside one.
    if matches!(route, Route::Pid { .. }) {
        let chunks = roles::text_chunks(text, TYPE_CHUNK);
        let mut sent = 0usize;
        for chunk in &chunks {
            match super::activation::post_unprimed(route, |p| input::type_text(p, chunk)) {
                Some(res) => res?,
                None => {
                    return Err(DesktopError::Unsupported(roles::partial_typing_refusal(
                        sent,
                        text.chars().count(),
                        super::activation::PRIMED_KEYS_REFUSAL,
                    )));
                }
            }
            sent += chunk.chars().count();
        }
        return Ok(typed_outcome(route.name(), shows_text, d.expect(check)));
    }
    unprimed(route, |p| input::type_text(p, text))?;
    Ok(typed_outcome(route.name(), shows_text, d.expect(check)))
}

/// Whether `el` is a text element whose value shows what is typed into it.
fn is_text_element(el: &Ax) -> bool {
    roles::is_text_input(&el.string("AXRole").unwrap_or_default())
}

fn typed_outcome(route: &str, shows_text: bool, expect: Option<Expect>) -> ActionOutcome {
    let mut out = ActionOutcome::delivered(route);
    out.expect = expect;
    if shows_text { out.showing("text") } else { out }
}

pub(super) fn press_keys(
    d: &MacDesktop,
    window_id: &str,
    combo: &KeyCombo,
    delivery: Delivery,
) -> DResult<ActionOutcome> {
    reporting_hand_back(|| press_keys_inner(d, window_id, combo, delivery))
}

fn press_keys_inner(
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
    let mut notes = String::new();
    let menu_chord = combo
        .modifiers
        .iter()
        .any(|m| matches!(m, Modifier::Meta | Modifier::Control | Modifier::Alt))
        || matches!(combo.key, Key::F(_));
    let denies_any = d.denies_any();
    // Command-A in a text element: read back as all of it selected, after
    // the settle; whether it already was, before the press.
    // A list or table: all of its rows selected.
    let select_all = if roles::is_select_all(combo) {
        d.focused_in(&t).and_then(|el| {
            if is_text_element(&el) {
                readback::Check::select_all(&el)
            } else if matches!(
                el.string("AXRole").as_deref(),
                Some("AXTable" | "AXOutline" | "AXList")
            ) {
                readback::Check::all_rows(&el)
            } else {
                None
            }
        })
    } else {
        None
    };
    if menu_chord {
        // In the background the walk stops at the first enabled match (it is
        // pressed or refused); a foreground chord may be posted, which needs
        // every match.
        let background = delivery == Delivery::Background;
        // A background app has no key window, so its menu items that act on
        // one validate as disabled, and posted keys never reach its menu key
        // equivalents. When every match is disabled, the target window is
        // made the app's key window (to the app only) just until the matches
        // validate; then the background rule runs on what validated, and the
        // only thing done in the scope is pressing that item through
        // accessibility. Nothing is posted into the scope, a Services
        // shortcut is never primed, and a chord with no match keeps the
        // background rule.
        let mut primed: Option<super::activation::KeyInApp<'static>> = None;
        // The first walk, reused when nothing is primed.
        let mut first_walk: Option<(Vec<(Ax, roles::ShortcutMatch)>, bool)> = None;
        if background && !d.is_persons_app(&t) {
            let (first, first_complete) = shortcut_matches(d, t.window.pid, combo, true);
            let first_matches: Vec<roles::ShortcutMatch> =
                first.iter().map(|(_, m)| m.clone()).collect();
            if roles::needs_menu_validation(&first_matches) && !chord_is_service(code, flags) {
                // Never made available: launch-list items and items that
                // open or reveal documents or apps; a posted chord would not
                // reach them either, so the chord is refused.
                if let Some(why) = first.iter().find_map(|(el, _)| prime_block_of(el, None)) {
                    return Err(DesktopError::Unsupported(why.into()));
                }
                if let Some(key) = key_in_app(d, &t) {
                    // Every AX read inside the scope is short; restored on
                    // every exit.
                    let _short: Vec<_> = first
                        .iter()
                        .map(|(el, _)| {
                            el.timeout_until_drop(
                                super::activation::AX_TIMEOUT_IN_SCOPE,
                                super::ax::MESSAGE_TIMEOUT_SECONDS,
                            )
                        })
                        .collect();
                    // Only an AXEnabled read as true counts (unreadable: no).
                    if key.wait_until(super::activation::VALIDATE_WAIT, &|| {
                        first.iter().any(|(el, _)| el.bool("AXEnabled") == Some(true))
                    }) {
                        // Only the first pass's matches are read again, not
                        // the whole menu bar; the bound is checked between
                        // reads.
                        // Inside the scope only each match's own title and
                        // enabled state are read again (short timeout, the
                        // bound checked between reads); the deny list and
                        // the protected apps were checked in the first walk,
                        // outside it. A changed title fails closed.
                        let mut again = Vec::new();
                        for (el, m0) in first {
                            if !key.live() {
                                return Err(scope_refusal(
                                    Some(key),
                                    roles::primed_press(false, true, false).unwrap_err(),
                                ));
                            }
                            let mut m = m0.clone();
                            m.enabled = el.bool("AXEnabled") == Some(true);
                            let title =
                                el.attr("AXTitle").ok().flatten().and_then(|v| v.as_string());
                            if roles::same_item(Some(&m0.title), title.as_deref()).is_err() {
                                m.blocked = true;
                            }
                            again.push((el, m));
                        }
                        primed = Some(key);
                        first_walk = Some((again, first_complete));
                    } else if key.end() == super::activation::Ended::HandBackFailed {
                        super::activation::append_note(
                            &mut notes,
                            super::activation::HAND_BACK_FAILED,
                        );
                    }
                } else {
                    first_walk = Some((first, first_complete));
                }
            } else {
                first_walk = Some((first, first_complete));
            }
        }
        let (items, complete) = match first_walk.take() {
            Some(walk) => walk,
            None => shortcut_matches(d, t.window.pid, combo, background),
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
                let el = &items[i].0;
                let _short = primed.as_ref().map(|_| {
                    el.timeout_until_drop(
                        super::activation::AX_TIMEOUT_IN_SCOPE,
                        super::ax::MESSAGE_TIMEOUT_SECONDS,
                    )
                });
                // Focus still on the target, then live last, right before the
                // press (the item's place was checked before the scope).
                if let Some(key) = primed.as_ref()
                    && let Err(why) = roles::primed_press(true, focused_on_target(&t), false)
                        .and_then(|()| roles::primed_press(key.live(), true, false))
                {
                    return Err(scope_refusal(primed.take(), why));
                }
                // A toggle's title and mark before (not read inside a scope).
                let item_checks = if primed.is_none() {
                    let title = el.try_string("AXTitle").ok().flatten();
                    menu_checks(
                        readback::Check::menu_item(el),
                        item_effect(d, &t, title.as_deref()),
                    )
                } else {
                    None
                };
                let mut out = match press_outcome(el.perform("AXPress"), "ax_menu_shortcut") {
                    Ok(out) => out,
                    Err(e) => return Err(with_hand_back(e, primed.take())),
                };
                if let Some(key) = primed.take()
                    && key.end() == super::activation::Ended::HandBackFailed
                {
                    super::activation::append_note(&mut notes, super::activation::HAND_BACK_FAILED);
                }
                if !notes.is_empty() {
                    super::activation::append_note(&mut out.note, &notes);
                }
                // Command-A in a text element selects all of it: read back
                // after the settle.
                if let Some(check) = select_all {
                    out = out.showing("selection");
                    out.expect = d.expect(Some(check));
                } else if item_checks.is_some() {
                    out.expect = d.expect(item_checks);
                }
                return Ok(out);
            }
            roles::ChordAction::Refuse(why) => {
                if let Some(key) = primed.take()
                    && key.end() == super::activation::Ended::HandBackFailed
                {
                    super::activation::append_note(&mut notes, super::activation::HAND_BACK_FAILED);
                }
                // A block that only stands because names are still loading
                // says so, not "the deny list".
                let blocking = matches.iter().find(|m| m.blocked);
                if let Some(loading) =
                    roles::loading_instead(why, blocking.is_some_and(|m| m.unknown))
                {
                    return Err(DesktopError::Unsupported(with_notes(loading.into(), &notes)));
                }
                // Blocked because an item above it cannot be read: say so.
                if why == roles::REFUSE_BLOCKED && blocking.is_some_and(|m| m.unplaced) {
                    return Err(DesktopError::Unsupported(with_notes(
                        menus::UNREADABLE_ITEM_REFUSAL.into(),
                        &notes,
                    )));
                }
                // Name the menu item only when it is the reason.
                let item = (why == roles::REFUSE_BLOCKED)
                    .then(|| matches.iter().find(|m| m.blocked))
                    .flatten()
                    .filter(|m| !m.title.is_empty())
                    .map(|m| format!(" (menu item {:?})", m.title))
                    .unwrap_or_default();
                return Err(DesktopError::Unsupported(with_notes(format!("{why}{item}"), &notes)));
            }
            roles::ChordAction::Post => {
                // Never post into a primed app: the scope ends first.
                if let Some(key) = primed.take()
                    && key.end() == super::activation::Ended::HandBackFailed
                {
                    super::activation::append_note(&mut notes, super::activation::HAND_BACK_FAILED);
                }
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
    // Never into a primed app (its own or another session's scope): posted
    // under the lock entering a scope takes, waiting at most the bound.
    let carries = keymap::carries_text(&combo.key, flags);
    // A character key into a focused text element shows in its value.
    let focused = carries.and_then(|_| d.focused_in(&t)).filter(is_text_element);
    let shows_text = focused.is_some();
    let check =
        focused.as_ref().zip(carries).and_then(|(el, c)| readback::Check::text(el, &c.to_string()));
    // A digit into an app with no text element focused (a calculator):
    // the one text that changed ends with it.
    let check = check.or_else(|| {
        let ch = carries.filter(|c| c.is_ascii_digit())?;
        if focused.is_some() {
            return None;
        }
        let (_, win) = d.ax_window(&t).ok()?;
        readback::Check::digit(&win, ch)
    });
    unprimed(route, |p| input::key(p, code, flags, carries))?;
    let mut out = typed_outcome(route.name(), shows_text, d.expect(check));
    if let Some(title) = disabled_item {
        out.note = format!(
            "the chord is the key equivalent of menu item {title:?}, which stays disabled in this background app, so the key was posted to the window; posted keys never run a background app's menu commands"
        );
    }
    if !notes.is_empty() {
        super::activation::append_note(&mut out.note, &notes);
    }
    Ok(out)
}

/// Characters per chunk of background typing: the lock is held per chunk.
const TYPE_CHUNK: usize = 16;

/// Posts `post` on `route`: a process route only while the app is not
/// primed (under its lock; [`super::activation::post_unprimed`]), the
/// system-wide route at once.
fn unprimed(
    route: Route,
    post: impl FnOnce(&super::activation::Posting) -> DResult<()>,
) -> DResult<()> {
    super::activation::post_unprimed(route, post).unwrap_or_else(|| {
        Err(DesktopError::Unsupported(super::activation::PRIMED_KEYS_REFUSAL.into()))
    })
}

/// Runs an action that may open a key-in-app scope: the hand-back flag is
/// cleared first (no earlier call's failure leaks in) and a failure during
/// the action is added to its result or refusal, once.
pub(super) fn reporting_hand_back(
    action: impl FnOnce() -> DResult<ActionOutcome>,
) -> DResult<ActionOutcome> {
    super::activation::take_hand_back_failed();
    with_hand_back_flag(action())
}

/// Adds a failed hand-back to an action's result or refusal, however the
/// scope ended (an explicit end or a drop on an early return).
fn with_hand_back_flag(res: DResult<ActionOutcome>) -> DResult<ActionOutcome> {
    if !super::activation::take_hand_back_failed() {
        return res;
    }
    let note = super::activation::HAND_BACK_FAILED;
    match res {
        Ok(mut out) => {
            super::activation::append_note(&mut out.note, note);
            Ok(out)
        }
        Err(DesktopError::Unsupported(m)) if !m.contains(note) => {
            Err(DesktopError::Unsupported(with_notes(m, note)))
        }
        Err(DesktopError::Failed(m)) if !m.contains(note) => {
            Err(DesktopError::Failed(with_notes(m, note)))
        }
        // Their message is built around the target or element id: the note
        // goes after the whole message, not into the id.
        Err(e @ (DesktopError::TargetNotFound(_) | DesktopError::StaleElement(_))) => {
            Err(DesktopError::Failed(with_notes(e.to_string(), note)))
        }
        other => other,
    }
}

/// A refusal inside a key-in-app scope: the scope ends first (the app is
/// handed back), and a failed hand-back is said in the message.
fn scope_refusal(key: Option<super::activation::KeyInApp<'static>>, why: &str) -> DesktopError {
    with_hand_back(DesktopError::Unsupported(why.into()), key)
}

/// Ends the scope, if one is open, and adds a failed hand-back to `err`.
fn with_hand_back(
    err: DesktopError,
    key: Option<super::activation::KeyInApp<'static>>,
) -> DesktopError {
    let failed = key.is_some_and(|k| k.end() == super::activation::Ended::HandBackFailed);
    if !failed {
        return err;
    }
    let add = |m: String| with_notes(m, super::activation::HAND_BACK_FAILED);
    match err {
        DesktopError::Unsupported(m) => DesktopError::Unsupported(add(m)),
        DesktopError::Failed(m) => DesktopError::Failed(add(m)),
        e @ (DesktopError::TargetNotFound(_) | DesktopError::StaleElement(_)) => {
            DesktopError::Failed(add(e.to_string()))
        }
        other => other,
    }
}

/// `message` with `notes` after it, when there are any.
fn with_notes(message: String, notes: &str) -> String {
    if notes.is_empty() { message } else { format!("{message} ({notes})") }
}

/// Whether the chord is a Services shortcut (read from the pasteboard
/// server's list; unread counts as one): never primed.
fn chord_is_service(code: u16, flags: u64) -> bool {
    match workspace::service_shortcuts() {
        Some(list) => keymap::is_service_shortcut(code, flags, &list),
        None => true,
    }
}

/// Why a disabled menu item must not be made available through the
/// key-in-app scope, if it must not: it runs a Service or another launch
/// list item, or it opens or reveals documents or apps (File > Open runs
/// whatever app the document names, which the item's title does not show).
/// Read from the item's own place and key equivalent, with AppKit's
/// localized titles.
fn prime_block_of(
    item: &Ax,
    scope: Option<&super::activation::KeyInApp<'static>>,
) -> Option<&'static str> {
    // Short reads; the item keeps the timeout it had (short inside a scope).
    let restore = if scope.is_some() {
        super::activation::AX_TIMEOUT_IN_SCOPE
    } else {
        super::ax::MESSAGE_TIMEOUT_SECONDS
    };
    let _short = item.timeout_until_drop(super::activation::AX_TIMEOUT_IN_SCOPE, restore);
    let live = || scope.is_none_or(|k| k.live());
    // The item's place: its menu items' titles up to the menu bar, read one
    // parent at a time with the short timeout.
    let mut node = item.element("AXParent");
    let parents = std::iter::from_fn(|| {
        let n = node.take()?;
        n.set_timeout(super::activation::AX_TIMEOUT_IN_SCOPE);
        let role = n.attr("AXRole").ok().flatten().and_then(|v| v.as_string());
        let title = n.attr("AXTitle").map(|t| t.and_then(|t| t.as_string())).map_err(|_| ());
        node = n.element("AXParent");
        Some(roles::MenuNode { role, title })
    });
    let ancestors = roles::menu_place(parents, &live);
    // Unreadable title or key equivalent: None (blocked).
    let title =
        item.attr("AXTitle").ok().map(|t| t.and_then(|t| t.as_string()).unwrap_or_default());
    let number = |name: &str| -> Result<Option<i64>, ()> {
        item.attr(name).map(|v| v.and_then(|v| v.as_f64()).map(|v| v as i64)).map_err(|_| ())
    };
    let opens_by_key = (|| {
        let cmd_char = item.attr("AXMenuItemCmdChar").ok()?.and_then(|v| v.as_string());
        let key = keymap::menu_item_key(
            cmd_char.as_deref(),
            number("AXMenuItemCmdVirtualKey").ok()?,
            number("AXMenuItemCmdGlyph").ok()?,
        );
        let mods = number("AXMenuItemCmdModifiers").ok()?.unwrap_or(0);
        Some(roles::is_open_key_equivalent(&key, mods))
    })();
    roles::prime_block(
        title.as_deref(),
        ancestors.as_deref(),
        opens_by_key,
        workspace::launch_submenu_titles(),
        workspace::open_item_titles(),
    )
}

/// Whether the target's app reports the target window as its focused
/// window (the key-in-app scope landed there), with a short AX timeout.
fn focused_on_target(t: &Target) -> bool {
    let Some(app) = Ax::application(t.window.pid) else { return false };
    app.set_timeout(super::activation::AX_TIMEOUT_IN_SCOPE);
    app.element("AXFocusedWindow").and_then(|w| w.window_id()) == Some(t.window.id)
}

/// The outcome of an AXPress on a menu item: an error the item did not take
/// is an error; a timeout or cannot-complete may come back after the item
/// ran (a dialog or menu it opened), so it is delivered with a note.
fn press_outcome(res: Result<(), super::sys::AXError>, route: &str) -> DResult<ActionOutcome> {
    match res {
        Ok(()) => Ok(ActionOutcome::delivered(route)),
        Err(e) if roles::press_error_falls_back(e) => Err(ax_error(e, "press the menu item")),
        Err(_) => {
            let mut out = ActionOutcome::delivered(route);
            out.note = "the app did not answer the press in time; it may have run (a dialog or menu it opened would hold it)".into();
            Ok(out)
        }
    }
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
    // A window off screen keeps refusing (pointer_route).
    if roles::hit_usable(t.window.on_screen, true)
        && let Some(out) = ax_scroll(d, &t, at, dx, dy)?
    {
        return Ok(out);
    }
    let route = d.pointer_route(&t, Delivery::Background)?;
    // The scroll bars' positions before, read back after the settle.
    let check = readback::Check::scroll(t.window.pid, at.x, at.y, dx, dy);
    unprimed(route, |p| input::scroll(p, at, dx, dy))?;
    let mut out = ActionOutcome::delivered(route.name()).at(at).showing("scroll");
    out.expect = d.expect(check);
    Ok(out)
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
    if delivery == Delivery::Background
        && button == Button::Left
        && roles::hit_usable(t.window.on_screen, true)
    {
        if let Some(out) = select_drag(d, &t, from, to)? {
            return Ok(out);
        }
        if let Some(out) = slider_drag(d, &t, from, to)? {
            return Ok(out);
        }
    }
    let route = d.pointer_route(&t, delivery)?;
    let pid = t.window.pid;
    unprimed(route, |p| input::drag(p, from, to, button, super::aimed(pid)?))?;
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
        && let Some(out) = step_to(d, &el, value)?
    {
        return Ok(out);
    }
    if !el.settable("AXValue") {
        return Err(DesktopError::Unsupported(format!(
            "element {element_id}'s value cannot be set; use type_text or click"
        )));
    }
    let secure = roles::is_secure(&role, el.string("AXSubrole").as_deref());
    let new_count = value.encode_utf16().count() as f64;
    // The baseline, before the write: the value (or a secure field's
    // length) now; unreadable, no read-back. One that already reads the
    // wanted value states no change.
    let check = if secure {
        readback::Check::length(&el, new_count)
    } else {
        // What the write sets, the same way value_for maps it ("on" -> 1).
        let current_is_number = el.try_number("AXValue").ok().flatten().is_some();
        let wanted =
            roles::requested_value(current_is_number, value).unwrap_or_else(|| value.to_string());
        // The same float tolerance as same_value.
        readback::Check::value(&el, readback::Wanted::from_request(wanted), 1e-6)
    };
    el.set("AXValue", &value_for(&el, value)?)
        .map_err(|e| ax_error(e, &format!("element {element_id}")))?;
    let read = el.try_value_text().ok().flatten();
    let holds = if secure {
        readback::secure_count(&el) == Some(new_count)
    } else {
        let requested =
            roles::requested_value(el.try_number("AXValue").ok().flatten().is_some(), value)
                .unwrap_or_else(|| value.to_string());
        read.as_deref().is_some_and(|r| same_value(r, &requested))
    };
    let mut out = if holds {
        ActionOutcome::confirmed("ax_set_value")
    } else {
        ActionOutcome::delivered("ax_set_value")
    }
    .showing("value");
    out.expect = d.expect(check);
    let requested =
        roles::requested_value(el.try_number("AXValue").ok().flatten().is_some(), value)
            .unwrap_or_else(|| value.to_string());
    if !secure && read.as_deref().is_some_and(|r| !same_value(r, &requested)) {
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
    // Unreadable children: no pick here (the caller opens the menu).
    let Some(Some(menu)) = menu_of(el) else { return Ok(None) };
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
    // The baseline before the press (one already showing the item states
    // no change).
    let check = readback::Check::title(el, &title);
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
    out.expect = d.expect(check);
    out.menu = Some(menus::MenuReport::picked(&title, None));
    if let Some(frame) = el.frame() {
        out = out.at(roles::center(&frame));
    }
    Ok(Some(out))
}

fn write_attribute(
    d: &MacDesktop,
    el: &Ax,
    element_id: &str,
    attr: &str,
    value: bool,
) -> DResult<ActionOutcome> {
    if !el.settable(attr) {
        return Err(DesktopError::Unsupported(format!(
            "element {element_id} cannot change {}",
            roles::snake(attr)
        )));
    }
    let cf = Cf::boolean(value).ok_or_else(|| DesktopError::Failed("no boolean".into()))?;
    let check = readback::Check::flag(el, attr, value);
    el.set(attr, &cf).map_err(|e| ax_error(e, &format!("element {element_id}")))?;
    let route = format!("ax_set_{}", roles::snake(attr));
    let mut out = if el.bool(attr) == Some(value) {
        ActionOutcome::confirmed(&route)
    } else {
        ActionOutcome::delivered(&route)
    };
    out.expect = d.expect(check);
    Ok(out.showing("value"))
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
            if attr == "AXFocused" && !roles::native_route(in_web_area(&el)) {
                return Err(DesktopError::Unsupported(
                    "this element is web content, where an accessibility focus write may be ignored; click it instead".into(),
                ));
            }
            if attr == "AXFocused" && d.is_persons_app(&t) {
                return Err(DesktopError::Unsupported(
                    "this element is in the app the person is using; focusing it would move their caret. Use set_value or type_text with element_id, or a click with delivery foreground".into(),
                ));
            }
            return write_attribute(d, &el, element_id, attr, value);
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
    let before = readback::Known::value(&el);
    let effects = press_effects(&el, ax_action);
    el.perform(ax_action).map_err(|e| ax_error(e, &format!("element {element_id}")))?;
    let route = if ax_action.starts_with("Name:") {
        "ax_custom_action".into()
    } else {
        route_name(ax_action)
    };
    Ok(outcome_after(d, &route, ax_action, before, &el, effects))
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
                let (m, read_all) = shortcut_match_of(d, &node);
                complete &= read_all;
                let enabled = m.enabled;
                found.push((node.clone(), m));
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

/// One shortcut match read from its menu item: enabled, title, and its
/// check against the deny list and the protected apps. The bool is false
/// when a read failed (the walk is then incomplete).
fn shortcut_match_of(d: &MacDesktop, node: &Ax) -> (roles::ShortcutMatch, bool) {
    let mut read_all = true;
    let enabled = match node.attr("AXEnabled") {
        Ok(v) => v.and_then(|v| v.as_bool()) != Some(false),
        Err(_) => {
            // Unknown: it may run at key time.
            read_all = false;
            true
        }
    };
    let title = node.attr("AXTitle").map(|v| v.and_then(|v| v.as_string()));
    let (title, blocked, checked, unknown, unplaced) = match title {
        Ok(t) => {
            let t = t.unwrap_or_default();
            let check = d.menu_item_check_titled(node, &t);
            let unknown = check == roles::ItemCheck::Unknown;
            let unplaced = check == roles::ItemCheck::Unplaced;
            (t, check != roles::ItemCheck::Allowed, true, unknown, unplaced)
        }
        // A title that cannot be read cannot be checked: blocked while
        // something is denied, and never pressed; with nothing denied the key
        // is posted, as Codex does (a posted chord leaves no menu under the
        // person's keys).
        Err(_) => {
            read_all = false;
            (String::new(), d.denies_any(), false, false, false)
        }
    };
    (roles::ShortcutMatch { title, enabled, blocked, checked, unknown, unplaced }, read_all)
}

/// Whether `row` is its table's only selected row (true when the table does
/// not say).
pub(super) fn only_selected(row: &Ax) -> bool {
    let Some(table) = row.element("AXParent") else { return true };
    let selected = table.elements("AXSelectedRows");
    selected.is_empty() || (selected.len() == 1 && selected[0].same(row))
}

/// Selects `row` alone, as a plain click does: the table's AXSelectedRows set
/// to just this row when it can be set, else the row's AXSelected (which in a
/// multi-select table may add to the selection).
fn select_only(row: &Ax) -> bool {
    // Web content (or unknown): its rows may ignore AX selection writes;
    // the click's events select it instead.
    if !roles::native_route(in_web_area(row)) {
        return false;
    }
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
/// How far a stepped value must move to count as moved (also the
/// read-back's tolerance, so the two agree).
const STEP_EPSILON: f64 = 1e-9;

fn step_to(d: &MacDesktop, el: &Ax, value: &str) -> DResult<Option<ActionOutcome>> {
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
    let start_known = readback::Known::value(el);
    let mut step = 0.0_f64;
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
        // One step: the first move's size.
        if step == 0.0 {
            step = (next - current).abs();
        }
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
    // One tolerance for "moved" and for the read-back's change: a stepper
    // that never moved states no change and is never confirmed.
    let moved = (read - start).abs() > STEP_EPSILON;
    let mut out = if roles::step_confirmed(capped, read, target, min, max) && moved {
        ActionOutcome::confirmed("ax_step")
    } else {
        ActionOutcome::delivered("ax_step")
    };
    // Read again after the settle: the value it was stepped to.
    // The asked target, within one step (a stepper moves in fixed steps).
    if let Some(known) = start_known.as_ref() {
        let check = readback::Check::value_from(
            el,
            known,
            readback::Wanted::from_request(format!("{target}")),
            roles::step_tolerance(step),
        );
        out.expect = d.expect(Some(check));
    }
    out = out.showing("value");
    out.note = format!(
        "stepped from {start} to {read} (asked {target}); the element moves in fixed steps"
    );
    if let Some(frame) = el.frame() {
        out = out.at(roles::center(&frame));
    }
    Ok(Some(out))
}
