//! A background app's menus ([`crate::menus`]): pop-up and menu buttons,
//! context menus. Menu bar menus are never opened in the background.
//!
//! - A closed pop-up that lists its items (AppKit exposes its `AXMenu` while
//!   closed for many pop-ups) is set by pressing the item's element: the menu
//!   never shows and nothing takes the person's keyboard.
//! - Otherwise, with `computerUse.menus` `open`, the element's own press
//!   (`AXPress`, `AXShowMenu`) opens the menu. The app runs its menu-tracking
//!   loop inside that press and answers it only when the menu closes, so the
//!   press runs on a helper thread with a short timeout while this thread
//!   waits for the menu window (layer 101) to show.
//! - `set_value` presses the item and waits for the menu to close in the same
//!   call. While a background app's menu is open the window server gives it
//!   key focus: the person's typing goes to the menu (measured in a guest: a
//!   key typed into the frontmost TextEdit while a System Settings pop-up was
//!   open never reached TextEdit), though the frontmost app and the pointer do
//!   not change. So the menu is open only for that moment (the result's
//!   `menu.open_ms`, about half a second). A click or press leaves the menu open with its
//!   items in the result, as Codex Computer Use does; the window's tree then
//!   shows the menu (only the tree of the window it was opened for).
//! - An item not found is cancelled (`AXCancel`, else Escape posted to the
//!   app while its menu still shows) and the items are listed.
//!
//! cua-driver (MIT, read as a reference) opens pop-ups the same way and
//! cancels with `AXCancel` then Escape.

use std::sync::mpsc;
use std::time::{Duration, Instant};

use super::ax::{Ax, ax_error};
use super::input::{self, Route};
use super::sys::{AX_CANNOT_COMPLETE, AXError};
use super::{MacDesktop, Target, cgwindows, key_focus, roles, workspace};
use crate::desktop::*;
use crate::menus::{self, MenuItemInfo, MenuReport};

/// `NSPopUpMenuWindowLevel`: pop-up and context menus show at this layer.
const MENU_LAYER: i64 = 101;
/// How long the press that opens a menu may block before it returns.
const PRESS_TIMEOUT_SECONDS: f32 = 0.5;
/// How long a menu may take to show, and to close after a pick.
const OPEN_WAIT: Duration = Duration::from_millis(1500);
const CLOSE_WAIT: Duration = Duration::from_millis(1000);
/// How long `AXCancel` gets before Escape.
const CANCEL_WAIT: Duration = Duration::from_millis(300);
const STEP: Duration = Duration::from_millis(10);
const ESCAPE: u16 = 53;
/// Why a press or right click showed no menu.
const MENU_DID_NOT_OPEN: &str = "the menu did not open (the app showed no menu)";

/// How long a call waits for the keyboard to go back to the person after
/// its menu shows.
const RELEASE_WAIT: Duration = Duration::from_millis(300);

/// The key-focus guard for one call that opens a menu of an app: armed when
/// the person's frontmost app is another app (a menu in their own app takes
/// their keyboard inside that app; nothing to give back). Disarmed when it
/// drops, on every path out of the call.
pub(super) struct KeyGuard(Option<(u64, u64)>);

impl KeyGuard {
    fn arm(t: &Target) -> Self {
        let armed = workspace::frontmost_pid()
            .is_some_and(|front| front != t.window.pid && key_focus::arm(front, t.window.pid));
        KeyGuard(armed.then(key_focus::counts))
    }

    fn armed(&self) -> bool {
        self.0.is_some()
    }

    /// `person` when the keyboard went back to the person's app since the
    /// guard armed, else `menu` (the menu holds it, as with Codex Computer
    /// Use when the guard could not arm).
    fn report(&self) -> String {
        let given_back =
            self.0.is_some_and(|before| key_focus::released_since(before, RELEASE_WAIT));
        if given_back { "person".into() } else { "menu".into() }
    }
}

impl Drop for KeyGuard {
    fn drop(&mut self) {
        if self.armed() {
            key_focus::disarm();
        }
    }
}

/// A menu just opened: its element, its windows, when it was asked for, and
/// the keyboard guard.
type OpenedMenu = (Ax, Vec<u32>, Instant, KeyGuard);

/// A menu this desktop opened and left open: the window it is for, its
/// element and its menu windows.
pub(super) struct Opened {
    pub window_id: String,
    /// Its app: keys posted to this process reach the menu while it shows,
    /// whichever of the app's windows they are aimed at.
    pub pid: i32,
    /// Its element: None for a menu that showed but could not be read (it
    /// is still recorded, so keys, typing and drags into it are refused and
    /// the next call closes it).
    pub menu: Option<Ax>,
    pub windows: Vec<u32>,
    /// Where an Escape goes if `AXCancel` does not close it.
    pub escape_to: Route,
}

/// The menu windows on screen now, any owner.
fn menu_windows() -> Vec<cgwindows::CgWindow> {
    cgwindows::on_screen().into_iter().filter(|w| w.layer == MENU_LAYER).collect()
}

fn menu_window_ids() -> Vec<u32> {
    menu_windows().into_iter().map(|w| w.id).collect()
}

/// `AXCancel` on the menu, then Escape posted to `escape_to` only while the
/// menu still shows (an Escape after it closed would reach the app's key
/// window).
fn cancel(menu: &Ax, windows: &[u32], escape_to: Route) {
    let _ = menu.perform("AXCancel");
    if wait_for(CANCEL_WAIT, || !showing(windows)) {
        return;
    }
    escape_while_showing(escape_to, windows);
}

/// Posts Escape to the menu's app only while one of `windows` shows, read
/// right before posting: an Escape after the menu closed would reach the
/// app's key window (in the person's own app, their sheet or field). A menu
/// in the person's app that AXCancel left open is closed this way too.
fn escape_while_showing(escape_to: Route, windows: &[u32]) {
    if !showing(windows) {
        return;
    }
    let _ = input::key(escape_to, ESCAPE, 0, None);
    wait_for(CANCEL_WAIT, || !showing(windows));
}

/// Whether a menu window of `owner` may be the one a call on `target`
/// opened: the target's own, or a helper process's (not a regular app).
fn may_be_targets_menu(owner: i32, target: i32) -> bool {
    owner == target || workspace::app_for_pid(owner).is_none_or(|a| !a.is_regular())
}

/// Whether any of `windows` still shows.
fn showing(windows: &[u32]) -> bool {
    menu_window_ids().iter().any(|w| windows.contains(w))
}

/// The menu shown in a menu window, by its owner's own hit test inside the
/// window (a context menu that its app lists nowhere else, as Finder's),
/// then up to the `AXMenu`.
fn menu_in_window(w: &cgwindows::CgWindow) -> Option<Ax> {
    let app = Ax::application(w.pid)?;
    let x = w.frame.x + w.frame.width / 2.0;
    // A few points down from the top: past the menu's rounded top edge.
    let y = w.frame.y + (w.frame.height / 2.0).min(12.0);
    let mut el = app.element_at(x, y);
    for _ in 0..4 {
        let current = el?;
        if is_menu(&current) {
            return Some(current);
        }
        el = current.element("AXParent");
    }
    None
}

/// Waits up to `limit` for `done`, looking every [`STEP`]: the menu lives in
/// another process, which posts no notification this thread could wait on
/// without a run loop of its own.
pub(super) fn wait_for(limit: Duration, mut done: impl FnMut() -> bool) -> bool {
    let start = Instant::now();
    loop {
        if done() {
            return true;
        }
        if start.elapsed() >= limit {
            return false;
        }
        std::thread::sleep(STEP);
    }
}

fn is_menu(el: &Ax) -> bool {
    el.string("AXRole").as_deref() == Some("AXMenu")
}

/// The menu `el` opened: its own `AXMenu` child (a pop-up), else the app's
/// shown menu (a context menu), else a menu among the app's children.
fn shown_menu(el: &Ax, app: &Ax) -> Option<Ax> {
    if let Some(m) = el.elements("AXChildren").into_iter().find(is_menu) {
        return Some(m);
    }
    if let Some(m) = app.element("AXShownMenuUIElement").filter(is_menu) {
        return Some(m);
    }
    app.elements("AXChildren").into_iter().find(is_menu)
}

/// One item of a menu, its element and how a result lists it.
pub(super) struct Item {
    pub el: Ax,
    pub info: MenuItemInfo,
    /// It leads to a denied or protected app (hidden and refused).
    pub denied: bool,
}

/// A text attribute as read: Err when it exists but could not be read.
type ReadText = Result<Option<String>, AXError>;

/// The titled items of `menu` (separators left out), each held to the deny
/// list through the desktop's menu guard. The menu's place (its depth and
/// the items above it) is read once, and each item's role and title once:
/// a font pop-up's thousands of items cost one pass.
pub(super) fn items(d: &MacDesktop, menu: &Ax) -> Vec<Item> {
    let text = |n: &Ax, a: &str| n.attr(a).map(|v| v.and_then(|v| v.as_string()));
    let read: Vec<(Ax, ReadText, ReadText)> = menu
        .elements("AXChildren")
        .into_iter()
        .map(|el| {
            let role = text(&el, "AXRole");
            let title = text(&el, "AXTitle");
            (el, role, title)
        })
        .filter(|(_, role, _)| match role {
            Ok(r) => r.as_deref() == Some("AXMenuItem"),
            // A role that cannot be read is checked like an item.
            Err(_) => true,
        })
        .collect();
    let (depth, path) = menu_place(menu);
    let siblings: Vec<String> = if d.opened_needs_siblings(depth) {
        read.iter().map(|(_, _, t)| t.clone().ok().flatten().unwrap_or_default()).collect()
    } else {
        Vec::new()
    };
    read.into_iter()
        .filter_map(|(el, _, title)| {
            let (title, title_failed) = match title {
                Ok(t) => (t.unwrap_or_default(), false),
                Err(_) => (String::new(), true),
            };
            let it = super::ax::OpenedItem {
                title: &title,
                title_failed,
                depth,
                path: path.as_deref(),
                siblings: &siblings,
            };
            let denied = d.opened_item_known(&it);
            // An untitled item is a separator, unless its title could not be
            // read: then it is listed only to be counted as hidden.
            if title.trim().is_empty() && !(title_failed && denied) {
                return None;
            }
            let info = MenuItemInfo {
                disabled: el.bool("AXEnabled") == Some(false),
                checked: el.string("AXMenuItemMarkChar").is_some_and(|m| !m.trim().is_empty()),
                submenu: el.elements("AXChildren").iter().any(is_menu),
                title,
            };
            Some(Item { el, info, denied })
        })
        .collect()
}

/// How many menus enclose `menu`'s items (it and the menus above it), and
/// the titles of the items above it (None when one cannot be read).
fn menu_place(menu: &Ax) -> (usize, Option<Vec<String>>) {
    let text = |n: &Ax, a: &str| n.attr(a).map(|v| v.and_then(|v| v.as_string()));
    let mut depth = 1;
    let mut path = Some(Vec::new());
    let mut current = menu.attr("AXParent").ok().flatten().and_then(Ax::from_cf);
    for _ in 0..16 {
        let Some(node) = current else { break };
        match text(&node, "AXRole") {
            Ok(r) => match r.as_deref() {
                Some("AXMenu") => depth += 1,
                Some("AXMenuItem") | Some("AXMenuBarItem") => match text(&node, "AXTitle") {
                    Ok(t) => {
                        if let Some(p) = path.as_mut() {
                            p.push(t.unwrap_or_default());
                        }
                    }
                    Err(_) => path = None,
                },
                _ => break,
            },
            Err(_) => {
                path = None;
                break;
            }
        }
        current = node.attr("AXParent").ok().flatten().and_then(Ax::from_cf);
    }
    if let Some(p) = path.as_mut() {
        p.reverse();
    }
    (depth, path)
}

/// The titles of the menu items and menu bar items above `el` (outermost
/// first), or None when a role or a title above it cannot be read (the
/// caller fails closed).
pub(super) fn item_path_checked(el: &Ax) -> Option<Vec<String>> {
    let text = |n: &Ax, a: &str| n.attr(a).map(|v| v.and_then(|v| v.as_string()));
    let mut path = Vec::new();
    let mut current = el.attr("AXParent").ok()?.and_then(Ax::from_cf);
    for _ in 0..16 {
        let Some(node) = current else { break };
        match text(&node, "AXRole").ok()?.as_deref() {
            Some("AXMenuItem") | Some("AXMenuBarItem") => {
                path.push(text(&node, "AXTitle").ok()?.unwrap_or_default());
            }
            Some("AXMenu") => {}
            _ => break,
        }
        current = node.attr("AXParent").ok()?.and_then(Ax::from_cf);
    }
    path.reverse();
    Some(path)
}

impl MacDesktop {
    /// Refuses leaving a menu open in the app the person is using (it would
    /// track their pointer and keyboard until the next call).
    pub(super) fn refuse_left_open_in_persons_app(&self, t: &Target) -> DResult<()> {
        if workspace::frontmost_pid() == Some(t.window.pid) {
            return Err(DesktopError::Unsupported(menus::PERSONS_APP_REFUSAL.into()));
        }
        Ok(())
    }

    /// Refuses pressing a menu item that leads to a denied app.
    pub(super) fn refuse_denied_item(&self, el: &Ax) -> DResult<()> {
        // A role that cannot be read is checked like an item.
        if el
            .attr("AXRole")
            .is_ok_and(|r| r.and_then(|r| r.as_string()).as_deref() != Some("AXMenuItem"))
        {
            return Ok(());
        }
        if self.opened_item_blocked(el) {
            return Err(DesktopError::Unsupported(menus::denied_item_refusal(None)));
        }
        Ok(())
    }

    /// The menu this desktop left open for `window_id`, while it shows.
    pub(super) fn opened_menu_for(&self, window_id: &str) -> Option<Ax> {
        let mut opened = self.opened.lock().unwrap_or_else(|e| e.into_inner());
        let o = opened.as_ref().filter(|o| o.window_id == window_id)?;
        if !showing(&o.windows) {
            *opened = None;
            return None;
        }
        o.menu.clone()
    }

    /// Whether a menu this desktop left open for an app of `pid` still shows.
    pub(super) fn menu_open_in(&self, pid: i32) -> bool {
        let mut opened = self.opened.lock().unwrap_or_else(|e| e.into_inner());
        let Some(o) = opened.as_ref().filter(|o| o.pid == pid) else { return false };
        if !showing(&o.windows) {
            *opened = None;
            return false;
        }
        true
    }

    /// Waits for a menu window that was not on screen in `before` and for
    /// its menu element: `find`, else the menu inside that window, up to
    /// [`OPEN_WAIT`].
    fn await_menu(
        &self,
        t: &Target,
        before: &[u32],
        mut press_failed: impl FnMut() -> Option<DesktopError>,
        mut find: impl FnMut() -> Option<Ax>,
    ) -> DResult<(Ax, Vec<u32>)> {
        let mut failed = None;
        let mut found = None;
        let mut unread: Vec<u32> = Vec::new();
        wait_for(OPEN_WAIT, || {
            if let Some(e) = press_failed() {
                failed = Some(e);
                return true;
            }
            // Only the target's menus, or a helper process's (a System
            // Settings pane draws its menus in an extension): a menu the
            // person opens in their own app meanwhile is never taken as
            // this call's.
            let new: Vec<cgwindows::CgWindow> = menu_windows()
                .into_iter()
                .filter(|w| !before.contains(&w.id) && may_be_targets_menu(w.pid, t.window.pid))
                .collect();
            if !new.is_empty() {
                unread = new.iter().map(|w| w.id).collect();
                let menu = find().or_else(|| new.iter().find_map(menu_in_window));
                found = menu.map(|m| (m, new.iter().map(|w| w.id).collect()));
            }
            found.is_some()
        });
        if let Some(e) = failed {
            return Err(e);
        }
        if let Some(found) = found {
            return Ok(found);
        }
        // A menu window of the app showed, but no menu element in time: it
        // is closed, never left open unrecorded (it could hold the keyboard).
        if !unread.is_empty() {
            let escape_to = Route::Pid { pid: t.window.pid, window: t.window.id };
            escape_while_showing(escape_to, &unread);
            // Some menus ignore a posted Escape (Finder's context menu): one
            // still on screen is recorded, so keys, typing and drags into
            // it stay refused and the next call closes it.
            if showing(&unread) {
                *self.opened.lock().unwrap_or_else(|e| e.into_inner()) = Some(Opened {
                    window_id: t.id(),
                    pid: t.window.pid,
                    menu: None,
                    windows: unread,
                    escape_to,
                });
                return Err(DesktopError::Failed(menus::MENU_UNREAD_OPEN.into()));
            }
            return Err(DesktopError::Failed(menus::MENU_UNREAD.into()));
        }
        Err(DesktopError::Failed(MENU_DID_NOT_OPEN.into()))
    }

    /// Opens `el`'s menu with `action` and waits until it shows.
    fn open_menu(&self, t: &Target, el: &Ax, action: &str) -> DResult<OpenedMenu> {
        let app = Ax::application(t.window.pid).ok_or_else(|| {
            DesktopError::TargetNotFound(format!("the app of window {}", t.window.id))
        })?;
        self.close_opened();
        let guard = KeyGuard::arm(t);
        let before = menu_window_ids();
        let start = Instant::now();
        let (tx, rx) = mpsc::channel();
        let presser = el.clone();
        let action = action.to_string();
        presser.set_timeout(PRESS_TIMEOUT_SECONDS);
        std::thread::spawn(move || {
            let _ = tx.send(presser.perform(&action));
        });
        let opened = self.await_menu(
            t,
            &before,
            || match rx.try_recv() {
                Ok(Err(e)) if e != AX_CANNOT_COMPLETE => Some(ax_error(e, "opening the menu")),
                _ => None,
            },
            || shown_menu(el, &app),
        );
        el.set_timeout(super::ax::MESSAGE_TIMEOUT_SECONDS);
        let (menu, windows) = opened?;
        Ok((menu, windows, start, guard))
    }

    /// Closes an open menu without choosing: `AXCancel`, then Escape posted
    /// to the app only while its menu still shows (an Escape after it closed
    /// would reach the app's key window).
    pub(super) fn cancel_menu(&self, t: &Target, menu: &Ax, windows: &[u32]) {
        cancel(menu, windows, Route::Pid { pid: t.window.pid, window: t.window.id });
    }

    /// Closes the menu a call left open, in any window, while it shows: a
    /// new menu never opens over it, and Escape for its window closes it
    /// (an Escape posted to the app does not reach every menu: Finder's
    /// context menu stays open). True when one was open and is closed now;
    /// one that is still on screen stays recorded (keys, typing and drags
    /// into it stay refused).
    pub(super) fn close_opened(&self) -> bool {
        let opened = self.opened.lock().unwrap_or_else(|e| e.into_inner()).take();
        match opened {
            Some(o) if showing(&o.windows) => {
                match &o.menu {
                    Some(menu) => cancel(menu, &o.windows, o.escape_to),
                    None => escape_while_showing(o.escape_to, &o.windows),
                }
                if showing(&o.windows) {
                    let mut slot = self.opened.lock().unwrap_or_else(|e| e.into_inner());
                    if slot.is_none() {
                        *slot = Some(o);
                    }
                    return false;
                }
                true
            }
            _ => false,
        }
    }

    /// Before a foreground pointer action on `t`: a menu left open in
    /// another app (or another window) is closed, so the click or drag
    /// cannot land on one of its items, a hidden one too. A menu of `t`'s
    /// own app stays (its visible items may be clicked; hidden ones are
    /// refused by the caller's hit test).
    pub(super) fn close_other_menus(&self, t: &Target) {
        if !self.menu_open_in(t.window.pid) {
            self.close_opened();
        }
    }

    /// Records the menu left open for `t`'s window and reports its items.
    fn leave_open(&self, t: &Target, menu: Ax, windows: Vec<u32>, route: &str) -> ActionOutcome {
        let all = items(self, &menu);
        *self.opened.lock().unwrap_or_else(|e| e.into_inner()) = Some(Opened {
            window_id: t.id(),
            pid: t.window.pid,
            menu: Some(menu),
            windows,
            escape_to: Route::Pid { pid: t.window.pid, window: t.window.id },
        });
        let hidden = all.iter().filter(|i| i.denied).count();
        let shown = all.into_iter().filter(|i| !i.denied).map(|i| i.info).collect();
        let mut out = ActionOutcome::delivered(route);
        out.menu = Some(MenuReport::open(shown, hidden));
        out
    }

    /// Opens `el`'s menu and leaves it open, with its items in the result.
    pub(super) fn open_and_list(
        &self,
        t: &Target,
        el: &Ax,
        action: &str,
    ) -> DResult<ActionOutcome> {
        let (menu, windows, _, guard) = self.open_menu(t, el, action)?;
        let keyboard = guard.report();
        // Armed and nothing given back: the person's window would look
        // active while their typing went to the menu. It is closed.
        if guard.armed() && keyboard == "menu" {
            self.cancel_menu(t, &menu, &windows);
            return Err(DesktopError::Unsupported(menus::KEYBOARD_KEPT_REFUSAL.into()));
        }
        let route = format!("ax_{}_menu", roles::snake(action));
        let mut out = self.leave_open(t, menu, windows, &route);
        if let Some(report) = out.menu.as_mut() {
            report.keyboard = keyboard;
        }
        if let Some(frame) = el.frame() {
            out = out.at(roles::center(&frame));
        }
        Ok(out)
    }

    /// Opens a pop-up's menu, presses the item titled `value` and waits for
    /// the menu to close, all in this call.
    pub(super) fn pick_by_opening(
        &self,
        t: &Target,
        el: &Ax,
        element_id: &str,
        value: &str,
    ) -> DResult<ActionOutcome> {
        let before = el.value_text();
        let (menu, windows, opened, guard) = self.open_menu(t, el, "AXPress")?;
        let all = items(self, &menu);
        let titles: Vec<String> = all.iter().map(|i| i.info.title.clone()).collect();
        let hidden: Vec<bool> = all.iter().map(|i| i.denied).collect();
        let refuse = |msg: String| -> DResult<ActionOutcome> {
            self.cancel_menu(t, &menu, &windows);
            Err(DesktopError::Unsupported(format!("{msg} (keyboard: {})", guard.report())))
        };
        let item = match menus::pick(&titles, &hidden, value) {
            menus::Pick::Item(i) => &all[i],
            menus::Pick::Hidden => return refuse(menus::denied_item_refusal(Some(value))),
            menus::Pick::Missing(found) => {
                if self.denies_any() && !workspace::app_names_ready() {
                    return refuse(menus::APP_NAMES_LOADING.into());
                }
                let shown: Vec<String> =
                    all.iter().filter(|i| !i.denied).map(|i| i.info.title.clone()).collect();
                return refuse(menus::not_found(value, &found, &shown));
            }
        };
        if item.info.disabled {
            return refuse(format!("the item {:?} is disabled", item.info.title));
        }
        if let Err(e) = item.el.perform("AXPress") {
            self.cancel_menu(t, &menu, &windows);
            return Err(ax_error(e, &format!("the item {:?}", item.info.title)));
        }
        let title = item.info.title.clone();
        // The menu closes and the pop-up shows the item a little after the
        // press (about 0.2 s in a System Settings pane); a menu button shows
        // no value, so its menu closing is the end.
        let shows_value = before.as_deref().is_some_and(|v| !v.trim().is_empty());
        let mut after = el.value_text();
        let closed = wait_for(CLOSE_WAIT, || {
            after = el.value_text();
            !showing(&windows) && (!shows_value || after != before)
        });
        if showing(&windows) {
            self.cancel_menu(t, &menu, &windows);
        }
        let open_ms = opened.elapsed().as_millis() as u64;
        let mut out = if after.as_deref().is_some_and(|a| roles::same_title(a, &title)) {
            ActionOutcome::confirmed("ax_menu_open_pick")
        } else {
            ActionOutcome::delivered("ax_menu_open_pick")
        };
        if !closed && after == before {
            out.note = format!(
                "pressed {title:?} in element {element_id}'s menu; the pop-up reads back its old value"
            );
        }
        let mut report = MenuReport::picked(&title, Some(open_ms));
        report.keyboard = guard.report();
        out.menu = Some(report);
        if let Some(frame) = el.frame() {
            out = out.at(roles::center(&frame));
        }
        Ok(out)
    }

    /// A context menu at a point of the window: the element there (or an
    /// ancestor) that offers `AXShowMenu`, else a right click posted to the
    /// app, then its menu, left open with its items.
    pub(super) fn context_menu_at(&self, t: &Target, at: Point) -> DResult<ActionOutcome> {
        let pid = t.window.pid;
        let app = Ax::application(pid)
            .ok_or_else(|| DesktopError::TargetNotFound(format!("the app of window {}", t.id())))?;
        let mut el = app.element_at(at.x, at.y);
        for _ in 0..8 {
            let Some(current) = el.take() else { break };
            if current.actions().iter().any(|a| a == "AXShowMenu") {
                return self.open_and_list(t, &current, "AXShowMenu");
            }
            el = current.element("AXParent");
        }
        self.close_opened();
        let guard = KeyGuard::arm(t);
        let before = menu_window_ids();
        let route = Route::Pid { pid, window: t.window.id };
        input::click(route, at, Button::Right, 1, 0, Duration::ZERO)?;
        let find = || {
            app.element("AXShownMenuUIElement")
                .filter(is_menu)
                .or_else(|| app.elements("AXChildren").into_iter().find(is_menu))
        };
        match self.await_menu(t, &before, || None, find) {
            Ok((menu, windows)) => {
                let keyboard = guard.report();
                if guard.armed() && keyboard == "menu" {
                    self.cancel_menu(t, &menu, &windows);
                    return Err(DesktopError::Unsupported(menus::KEYBOARD_KEPT_REFUSAL.into()));
                }
                let mut out = self.leave_open(t, menu, windows, route.name()).at(at);
                if let Some(report) = out.menu.as_mut() {
                    report.keyboard = keyboard;
                }
                Ok(out)
            }
            // The click was delivered and showed no menu (nothing there has one).
            Err(DesktopError::Failed(m)) if m == MENU_DID_NOT_OPEN => {
                Ok(ActionOutcome::delivered(route.name()).at(at))
            }
            Err(e) => Err(e),
        }
    }
}
