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
use super::sys::{AX_CANNOT_COMPLETE, AXError, Cf};
use super::{MacDesktop, Target, cgwindows, key_focus, roles, workspace};
use crate::desktop::*;
use crate::menus::{self, ItemMatch, MenuItemInfo, MenuReport};

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
    fn arm(t: &Target, guard: Option<std::sync::Arc<dyn MenuGuard>>) -> Self {
        let armed = super::frontmost_pid().is_some_and(|front| {
            front != t.window.pid && key_focus::arm(front, t.window.pid, t.window.frame, guard)
        });
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
    /// Where an Escape goes if `AXCancel` does not close it: the menu
    /// window's owner (a helper draws some apps' menus).
    pub escape_to: Route,
    /// It has items the deny list hides: arrows could park the highlight
    /// on one, so they are refused too.
    pub has_hidden: bool,
    /// It holds the person's keyboard (the handoff did not arm, or it could
    /// not be closed).
    pub keyboard_held: bool,
    /// Some level of it (a submenu too) may hide an item (denied or
    /// protected), or could not be read. With `keyboard_held`, whatever the
    /// deny list, bare arrows and opening a submenu are refused: a hidden
    /// item could get the highlight and the person's Return would run it.
    pub nested_hidden: bool,
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
    // Last: AXCancel on the menu the owner says it shows (a submenu opened
    // by a path pick may be the one holding on).
    if showing(windows)
        && let Route::Pid { pid, .. } = escape_to
        && let Some(shown) = Ax::application(pid).and_then(|a| a.element("AXShownMenuUIElement"))
    {
        let _ = shown.perform("AXCancel");
        wait_for(CANCEL_WAIT, || !showing(windows));
    }
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

/// Where an Escape for a menu goes: its window's owner (a System Settings
/// pane draws its menus in a helper), else the target.
fn escape_route(t: &Target, windows: &[u32]) -> Route {
    cgwindows::on_screen()
        .into_iter()
        .find(|w| windows.contains(&w.id))
        .filter(|w| w.pid != t.window.pid)
        .map_or(Route::Pid { pid: t.window.pid, window: t.window.id }, |w| Route::Pid {
            pid: w.pid,
            window: w.id,
        })
}

/// Whether a menu window of `owner` may be the one a call on `target`
/// opened: the target's own, or a helper process's (not a regular app) that
/// the deny list does not cover (a denied menu-bar app's status menu the
/// person opens meanwhile is never taken as this call's).
pub(super) fn may_be_targets_menu(owner: i32, target: i32, guard: Option<&dyn MenuGuard>) -> bool {
    if owner == target {
        return true;
    }
    match workspace::app_for_pid(owner) {
        Some(app) => {
            !app.is_regular() && !guard.is_some_and(|g| g.app_blocked(&app.id(), &app.name))
        }
        // An owner that cannot be named: a helper only while nothing is denied.
        None => !guard.is_some_and(|g| g.denies_any()),
    }
}

/// The windows of a menu just found among `new` menu windows: the target's
/// own when it owns one, else only the window the menu sits in (a status
/// menu the person opens meanwhile is not taken as part of it).
fn menu_windows_of(menu: &Ax, new: &[cgwindows::CgWindow], target: i32) -> Vec<u32> {
    let own: Vec<u32> = new.iter().filter(|w| w.pid == target).map(|w| w.id).collect();
    if !own.is_empty() {
        return own;
    }
    let at = menu.frame().map(|f| roles::center(&f));
    let holding: Vec<u32> = new
        .iter()
        .filter(|w| at.is_some_and(|p| roles::contains(&w.frame, p)))
        .map(|w| w.id)
        .collect();
    if holding.is_empty() { new.iter().take(1).map(|w| w.id).collect() } else { holding }
}

/// Whether two rects share any area.
pub(super) fn overlaps(a: &Rect, b: &Rect) -> bool {
    a.x < b.x + b.width && b.x < a.x + a.width && a.y < b.y + b.height && b.y < a.y + a.height
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

/// The titled items of `menu` (separators left out), each held to the deny
/// list through the desktop's menu guard. One round trip per item (its role
/// and title), the menu's place once: a font pop-up's thousands of items
/// cost one pass. The rest of an item ([`Item::detail`]) is read only for
/// the items a result lists or a pick presses.
pub(super) fn items(d: &MacDesktop, menu: &Ax) -> Vec<Item> {
    let text = |v: &Result<Option<Cf>, AXError>| -> Result<Option<String>, AXError> {
        v.as_ref().map(|v| v.as_ref().and_then(Cf::as_string)).map_err(|e| *e)
    };
    // One round trip per item: its role, title and children (a submenu).
    let read: Vec<(Ax, Result<Option<String>, AXError>, bool)> = menu
        .elements("AXChildren")
        .into_iter()
        .filter_map(|el| {
            let (role, title, submenu) = match el.attrs(&["AXRole", "AXTitle", "AXChildren"]) {
                Ok(v) => {
                    // Children that cannot be read count as a submenu.
                    let submenu = v[2]
                        .as_ref()
                        .map_or(true, |c| c.as_ref().is_some_and(|c| !c.items().is_empty()));
                    (text(&v[0]), text(&v[1]), submenu)
                }
                Err(e) => (Err(e), Err(e), true),
            };
            match role {
                Ok(r) if r.as_deref() != Some("AXMenuItem") => None,
                // A role that cannot be read is checked like an item.
                _ => Some((el, title, submenu)),
            }
        })
        .collect();
    let (depth, path) = menu_place(menu);
    // Whether the menu is a launch list by its items: once per menu.
    let launch = d.opened_needs_siblings(depth) && {
        let titles: Vec<String> =
            read.iter().map(|(_, t, _)| t.clone().ok().flatten().unwrap_or_default()).collect();
        roles::siblings_name_apps(&titles, &workspace::apps_named_indexed)
    };
    read.into_iter()
        .filter_map(|(el, title, submenu)| {
            let (title, title_failed) = match title {
                Ok(t) => (t.unwrap_or_default(), false),
                Err(_) => (String::new(), true),
            };
            let it = super::ax::OpenedItem {
                title: &title,
                title_failed,
                depth,
                path: path.as_deref(),
                launch,
            };
            let row = listed_row(&title, title_failed, d.opened_item_known(&it));
            if row == Row::Separator {
                return None;
            }
            let denied = row == Row::Hidden;
            Some(Item {
                el,
                info: MenuItemInfo { title, submenu, ..MenuItemInfo::default() },
                denied,
            })
        })
        .collect()
}

/// How a menu listing takes one item.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Row {
    /// An untitled item: a separator, left out.
    Separator,
    /// Hidden and counted in `hidden` (denied, protected, or a title that
    /// could not be read: an unreadable title is never a separator).
    Hidden,
    Visible,
}

/// Pure, for tests.
pub(super) fn listed_row(title: &str, title_failed: bool, denied: bool) -> Row {
    if title_failed || denied {
        Row::Hidden
    } else if title.trim().is_empty() {
        Row::Separator
    } else {
        Row::Visible
    }
}

/// The note a menu left open carries while the app names load: its items
/// are hidden until they can be checked. Pure, for tests.
pub(super) fn loading_note(names_ready: bool) -> Option<&'static str> {
    (!names_ready).then_some(menus::APP_NAMES_LOADING)
}

/// Whether a pick may choose an item now: not while the app names its
/// items are checked against load. Pure, for tests.
pub(super) fn pick_gate(names_ready: bool) -> Result<(), &'static str> {
    if names_ready { Ok(()) } else { Err(menus::APP_NAMES_LOADING) }
}

/// A pick of `wanted` among a menu's items, behind [`pick_gate`]: no item,
/// not even a visible exact match, is chosen while the names load (an item
/// counted visible then was not checked). Pure, for tests.
pub(super) fn gated_pick(
    names_ready: bool,
    titles: &[String],
    hidden: &[bool],
    wanted: &str,
) -> Result<menus::Pick, &'static str> {
    pick_gate(names_ready)?;
    Ok(menus::pick(titles, hidden, wanted))
}

impl Item {
    /// Reads whether it is enabled and checked (one round trip), for an
    /// item a result lists or a pick presses (whether it opens a submenu
    /// came with its title; unreadable children count as one).
    pub(super) fn detail(&mut self) {
        if let Ok(v) = self.el.attrs(&["AXEnabled", "AXMenuItemMarkChar"]) {
            let get = |i: usize| v[i].as_ref().ok().and_then(|x| x.as_ref());
            self.info.disabled = get(0).and_then(Cf::as_bool) == Some(false);
            self.info.checked =
                get(1).and_then(Cf::as_string).is_some_and(|m| !m.trim().is_empty());
        }
    }
}

/// How long a submenu gets to open and fill after its parent is pressed.
const SUBMENU_WAIT: Duration = Duration::from_millis(1000);

/// The titles of a menu's items, as a cheap snapshot (one read each).
fn item_titles(menu: &Ax) -> Vec<String> {
    menu.elements("AXChildren").iter().map(|c| c.string("AXTitle").unwrap_or_default()).collect()
}

/// Whether a submenu has opened and filled since its parent was pressed:
/// a new menu-layer window showed, or its items changed from what they were
/// while closed (a placeholder, a stale list, nothing). Pure, for tests.
pub(super) fn submenu_opened(
    windows_before: &[u32],
    windows_now: &[u32],
    titles_before: &[String],
    titles_now: &[String],
) -> bool {
    let titled = titles_now.iter().any(|t| !t.trim().is_empty());
    let new_window = windows_now.iter().any(|w| !windows_before.contains(w));
    titled && (new_window || titles_now != titles_before)
}

/// Opens the submenu of the menu item `parent` (pressing it, else selecting
/// it), waits up to SUBMENU_WAIT for it to open and fill, and returns its
/// menu. None when it has no submenu.
fn open_submenu(parent: &Ax) -> Option<Ax> {
    let sub_now = || parent.elements("AXChildren").into_iter().find(is_menu);
    let closed = sub_now()?;
    let titles_before = item_titles(&closed);
    let windows_before = menu_window_ids();
    if parent.perform("AXPress").is_err()
        && let Some(yes) = Cf::boolean(true)
    {
        let _ = parent.set("AXSelected", &yes);
    }
    let mut opened = None;
    wait_for(SUBMENU_WAIT, || {
        let Some(sub) = sub_now() else { return false };
        let titles = item_titles(&sub);
        let done = submenu_opened(&windows_before, &menu_window_ids(), &titles_before, &titles);
        if done {
            opened = Some(sub);
        }
        done
    });
    // A submenu that read the same (not filled on open) is used as it is.
    opened.or_else(sub_now)
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

/// What becomes of a menu that just opened.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum HeldMenu {
    /// Left open with its items for the next call.
    LeaveOpen,
    /// Closed again and its titles listed (`menu.state` `listed`), for a
    /// one-call pick with a path.
    List,
    /// Closed again: the app names its items are checked against are still
    /// loading (APP_NAMES_LOADING).
    Loading,
}

/// The rule for a menu that holds the person's keyboard (the handoff did
/// not arm, or did not give the keyboard back): their own arrows, Return
/// and typing reach every level of it, and AX gives no sign of a submenu an
/// app fills when it opens. So it is left open only when it hides nothing
/// (no item the deny list or the protected apps cover) and has no submenu
/// at all; else it is listed and closed, whether or not anything is denied
/// (a protected app's item could sit under a submenu). While the app names
/// its items are checked against are still loading it is closed and the
/// call says so (the protected apps always apply). A handoff that did not
/// give the keyboard back (`kept`) leaves the person's window looking
/// active, so that menu is never left open. A menu that does not hold the
/// keyboard is left open. Pure, for tests.
pub(super) fn held_menu_decision(
    held: bool,
    kept: bool,
    any_hidden: bool,
    any_submenu: bool,
    names_ready: bool,
) -> HeldMenu {
    if !held {
        return HeldMenu::LeaveOpen;
    }
    if !names_ready {
        return HeldMenu::Loading;
    }
    if kept || any_hidden || any_submenu { HeldMenu::List } else { HeldMenu::LeaveOpen }
}

impl MacDesktop {
    /// Refuses leaving a menu open in the app the person is using (it would
    /// track their pointer and keyboard until the next call).
    pub(super) fn refuse_left_open_in_persons_app(&self, t: &Target) -> DResult<()> {
        if super::frontmost_pid() == Some(t.window.pid) {
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
        armed: bool,
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
            let guard = self.guard();
            let mut new: Vec<cgwindows::CgWindow> = menu_windows()
                .into_iter()
                .filter(|w| {
                    !before.contains(&w.id)
                        && may_be_targets_menu(w.pid, t.window.pid, guard.as_deref())
                        // A helper's menu counts only over the target's
                        // window (a System Settings pane's pop-up): another
                        // app's status menu elsewhere is never adopted.
                        && (w.pid == t.window.pid || overlaps(&w.frame, &t.window.frame))
                })
                .collect();
            // The target's own menu windows first.
            new.sort_by_key(|w| w.pid != t.window.pid);
            if !new.is_empty() {
                unread = new.iter().map(|w| w.id).collect();
                let menu = find().or_else(|| new.iter().find_map(menu_in_window));
                found = menu.map(|m| {
                    let windows = menu_windows_of(&m, &new, t.window.pid);
                    (m, windows)
                });
            }
            found.is_some()
        });
        if let Some(e) = failed {
            return Err(e);
        }
        if let Some(found) = found {
            // The menu is up: when this call armed the handoff, its target
            // theft still waiting goes back now.
            if armed {
                key_focus::menu_opened();
            }
            return Ok(found);
        }
        // A menu window of the app showed, but no menu element in time: it
        // is closed, never left open unrecorded (it could hold the keyboard).
        if !unread.is_empty() {
            let escape_to = escape_route(t, &unread);
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
                    // Unread: its items cannot be told apart.
                    has_hidden: true,
                    keyboard_held: true,
                    nested_hidden: true,
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
        self.close_before_opening()?;
        let guard = KeyGuard::arm(t, self.guard());
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
            guard.armed(),
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
        cancel(menu, windows, escape_route(t, windows));
    }

    /// [`Self::cancel_menu`], and a menu that is still on screen after it
    /// is recorded (keys, typing and drags into the app stay refused, the
    /// next call closes it). True when it closed.
    fn cancel_or_record(&self, t: &Target, menu: &Ax, windows: &[u32]) -> bool {
        self.cancel_menu(t, menu, windows);
        if !showing(windows) {
            return true;
        }
        *self.opened.lock().unwrap_or_else(|e| e.into_inner()) = Some(Opened {
            window_id: t.id(),
            pid: t.window.pid,
            menu: Some(menu.clone()),
            windows: windows.to_vec(),
            escape_to: escape_route(t, windows),
            // Kept only because it would not close: arrows stay refused.
            has_hidden: true,
            keyboard_held: true,
            nested_hidden: true,
        });
        false
    }

    /// Closes `menu` and fails with `err`, or with MENU_DID_NOT_CLOSE when
    /// it stays on screen (then recorded).
    fn close_and_fail(
        &self,
        t: &Target,
        menu: &Ax,
        windows: &[u32],
        err: DesktopError,
    ) -> DesktopError {
        if self.cancel_or_record(t, menu, windows) {
            err
        } else {
            DesktopError::Failed(format!("{} ({err})", menus::MENU_DID_NOT_CLOSE))
        }
    }

    /// Closes the menu a call left open before another opens: one that
    /// stays on screen refuses the new one (the single record must not be
    /// overwritten while a menu it tracks still shows).
    fn close_before_opening(&self) -> DResult<()> {
        self.close_opened();
        let still = self.opened.lock().unwrap_or_else(|e| e.into_inner()).is_some();
        if still && self.any_recorded_menu_showing() {
            return Err(DesktopError::Failed(menus::MENU_DID_NOT_CLOSE.into()));
        }
        Ok(())
    }

    /// Whether the recorded menu (any app) still shows.
    fn any_recorded_menu_showing(&self) -> bool {
        let opened = self.opened.lock().unwrap_or_else(|e| e.into_inner());
        opened.as_ref().is_some_and(|o| showing(&o.windows))
    }

    /// Before keys or typing in the foreground to `t`: a menu left open in
    /// another app is closed (on the fallback path it holds the keyboard,
    /// and the keys would type-select or run one of its items); one that
    /// stays refuses the keys.
    pub(super) fn refuse_other_menus(&self, t: &Target) -> DResult<()> {
        self.close_other_menus(t);
        let other = {
            let opened = self.opened.lock().unwrap_or_else(|e| e.into_inner());
            opened.as_ref().is_some_and(|o| o.pid != t.window.pid && showing(&o.windows))
        };
        if other {
            return Err(DesktopError::Unsupported(menus::OTHER_MENU_KEYS_REFUSAL.into()));
        }
        Ok(())
    }

    /// Whether the menu left open in `pid`'s app has items the deny list
    /// hides (bare arrows into it are refused too).
    pub(super) fn open_menu_hides_items(&self, pid: i32) -> bool {
        let opened = self.opened.lock().unwrap_or_else(|e| e.into_inner());
        opened.as_ref().is_some_and(|o| o.pid == pid && o.has_hidden && showing(&o.windows))
    }

    /// Whether a menu left open (any app) holds the person's keyboard and
    /// may hide an item at some level (one recorded because it would not
    /// close): arrows and opening submenus are refused then, whether or not
    /// anything is denied (a protected app's item counts). A menu left open
    /// by list_opened has no hidden item and no submenu, so it is fully
    /// reachable, as Codex's.
    pub(super) fn held_menu_guards_keys(&self) -> bool {
        let held = {
            let opened = self.opened.lock().unwrap_or_else(|e| e.into_inner());
            opened
                .as_ref()
                .is_some_and(|o| o.keyboard_held && o.nested_hidden && showing(&o.windows))
        };
        // Whether or not anything is denied: a protected app's item counts.
        held
    }

    /// Refuses pressing or clicking a menu item that opens a submenu while a
    /// menu holding the person's keyboard is open and may hide an item
    /// (denied or protected): the submenu's hidden items could get the
    /// highlight, and the person's Return would run one. Items are pressed by element; `click` with
    /// `menu_item` picks in one call.
    pub(super) fn refuse_submenu_open(&self, el: &Ax) -> DResult<()> {
        if !self.held_menu_guards_keys() {
            return Ok(());
        }
        let role = el.attr("AXRole").map(|r| r.and_then(|r| r.as_string()));
        let item = match role {
            Ok(r) => r.as_deref() == Some("AXMenuItem"),
            Err(_) => true,
        };
        if item && el.attr("AXChildren").map_or(true, |c| c.is_some_and(|c| !c.items().is_empty()))
        {
            return Err(DesktopError::Unsupported(menus::SUBMENU_HELD_REFUSAL.into()));
        }
        Ok(())
    }

    /// The pid and windows of the recorded menu, while it shows.
    pub(super) fn recorded_menu(&self) -> Option<(i32, Vec<u32>)> {
        let opened = self.opened.lock().unwrap_or_else(|e| e.into_inner());
        opened.as_ref().filter(|o| showing(&o.windows)).map(|o| (o.pid, o.windows.clone()))
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
    fn leave_open(
        &self,
        t: &Target,
        menu: Ax,
        windows: Vec<u32>,
        all: Vec<Item>,
        (keyboard_held, nested_hidden): (bool, bool),
        route: &str,
    ) -> ActionOutcome {
        let hidden = all.iter().filter(|i| i.denied).count();
        *self.opened.lock().unwrap_or_else(|e| e.into_inner()) = Some(Opened {
            window_id: t.id(),
            pid: t.window.pid,
            menu: Some(menu),
            escape_to: escape_route(t, &windows),
            windows,
            has_hidden: hidden > 0,
            keyboard_held,
            nested_hidden: nested_hidden || hidden > 0,
        });
        let visible: Vec<Item> = all.into_iter().filter(|i| !i.denied).collect();
        let more = visible.len().saturating_sub(menus::LISTED_ITEMS_MAX);
        let shown = visible
            .into_iter()
            .take(menus::LISTED_ITEMS_MAX)
            .map(|mut i| {
                i.detail();
                i.info
            })
            .collect();
        let mut out = ActionOutcome::delivered(route);
        if let Some(note) = loading_note(workspace::app_names_ready()) {
            out.note = note.into();
        }
        let mut report = MenuReport::open(shown, hidden);
        report.more = more;
        out.menu = Some(report);
        out
    }

    /// A menu just opened, left open with its items for the next call, or
    /// closed again when leaving it open is unsafe:
    /// - the guard armed and the keyboard was not given back (the person's
    ///   window would look active while their typing went to the menu);
    /// - the guard could not arm (the menu holds the person's keyboard, as
    ///   with Codex Computer Use) and the menu hides an item (denied or
    ///   protected), has a submenu, or the app names are still loading
    ///   ([`held_menu_decision`]): their typing could type-select a hidden
    ///   item and their Return run it. A one-call pick (`click` with
    ///   `menu_item`, `set_value`) never leaves the menu open.
    fn list_opened(&self, t: &Target, opened: OpenedMenu, route: &str) -> DResult<ActionOutcome> {
        let (menu, windows, _, guard) = opened;
        let keyboard = guard.report();
        // The guard armed but the keyboard was not given back: the menu holds
        // it (the person's window would even look active), so it is never
        // left open; it is listed and closed, as on the fallback.
        let kept = guard.armed() && keyboard == "menu";
        let all = items(self, &menu);
        let held = !guard.armed() || kept;
        let decision = held_menu_decision(
            held,
            kept,
            all.iter().any(|i| i.denied),
            all.iter().any(|i| i.info.submenu),
            workspace::app_names_ready(),
        );
        let nested_hidden = decision != HeldMenu::LeaveOpen;
        if nested_hidden {
            if decision == HeldMenu::Loading {
                let refused = DesktopError::Unsupported(menus::APP_NAMES_LOADING.into());
                return Err(self.close_and_fail(t, &menu, &windows, refused));
            }
            let hidden = all.iter().filter(|i| i.denied).count();
            let visible: Vec<Item> = all.into_iter().filter(|i| !i.denied).collect();
            let more = visible.len().saturating_sub(menus::LISTED_ITEMS_MAX);
            // A menu that kept the keyboard closes first: no detail reads.
            let shown: Vec<MenuItemInfo> = visible
                .into_iter()
                .take(menus::LISTED_ITEMS_MAX)
                .map(|mut i| {
                    if !kept {
                        i.detail();
                    }
                    i.info
                })
                .collect();
            if !self.cancel_or_record(t, &menu, &windows) {
                return Err(DesktopError::Failed(menus::MENU_DID_NOT_CLOSE.into()));
            }
            let mut out = ActionOutcome::delivered(route);
            if kept {
                out.note = format!("keyboard handoff: {}", key_focus::note());
            }
            let mut report = MenuReport::listed(shown, hidden);
            report.more = more;
            report.keyboard = keyboard;
            out.menu = Some(report);
            return Ok(out);
        }
        let mut out = self.leave_open(t, menu, windows, all, (held, nested_hidden), route);
        if let Some(report) = out.menu.as_mut() {
            report.keyboard = keyboard;
        }
        Ok(out)
    }

    /// Opens `el`'s menu and leaves it open, with its items in the result.
    pub(super) fn open_and_list(
        &self,
        t: &Target,
        el: &Ax,
        action: &str,
    ) -> DResult<ActionOutcome> {
        let opened = self.open_menu(t, el, action)?;
        let route = format!("ax_{}_menu", roles::snake(action));
        let mut out = self.list_opened(t, opened, &route)?;
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
        let opened = self.open_menu(t, el, "AXPress")?;
        self.pick_in(t, opened, value, Some((el, element_id, before)))
    }

    /// Presses the item titled `value` of a menu just opened and waits for
    /// it to close, in this call: visible items first, a hidden match
    /// refused, the one item pressed held to the full deny-list check. With
    /// `popup` (its element, id and value before), the pop-up's new value
    /// confirms the pick; else the menu closing does.
    fn pick_in(
        &self,
        t: &Target,
        opened: OpenedMenu,
        value: &str,
        popup: Option<(&Ax, &str, Option<String>)>,
    ) -> DResult<ActionOutcome> {
        let (menu, windows, opened, guard) = opened;
        let refuse = |msg: String| -> DResult<ActionOutcome> {
            let refused =
                DesktopError::Unsupported(format!("{msg} (keyboard: {})", guard.report()));
            Err(self.close_and_fail(t, &menu, &windows, refused))
        };
        // A path ("Sort By > Name") walks submenus, each level held to the
        // same checks as the item pressed.
        let path = menus::menu_path(value);
        let mut level = menu.clone();
        let mut chosen: Option<Item> = None;
        for (n, part) in path.iter().enumerate() {
            let last = n + 1 == path.len();
            let mut all = items(self, &level);
            let titles: Vec<String> = all.iter().map(|i| i.info.title.clone()).collect();
            let hidden: Vec<bool> = all.iter().map(|i| i.denied).collect();
            // Items are checked against the app names: none is chosen while
            // they load (the protected apps always apply).
            let picked = match gated_pick(workspace::app_names_ready(), &titles, &hidden, part) {
                Ok(p) => p,
                Err(why) => return refuse(why.into()),
            };
            let mut item = match picked {
                menus::Pick::Item(i) => all.swap_remove(i),
                menus::Pick::Hidden => return refuse(menus::denied_item_refusal(Some(part))),
                menus::Pick::Missing(found) => {
                    let shown: Vec<String> =
                        all.iter().filter(|i| !i.denied).map(|i| i.info.title.clone()).collect();
                    return refuse(menus::not_found(part, &found, &shown));
                }
            };
            item.detail();
            if item.info.disabled {
                return refuse(format!("the item {:?} is disabled", item.info.title));
            }
            // The full check (LaunchServices names too) on each item chosen.
            if self.refuse_denied_item(&item.el).is_err() {
                return refuse(menus::denied_item_refusal(Some(part)));
            }
            if last {
                if item.info.submenu {
                    return refuse(format!(
                        "the item {:?} opens a submenu; give the path to an item in it (\"{} > …\")",
                        item.info.title, item.info.title
                    ));
                }
                chosen = Some(item);
                break;
            }
            // Open the submenu (apps fill Open With, Services and the like
            // only when it opens) and read it from there.
            let Some(sub) = open_submenu(&item.el) else {
                return refuse(format!("the item {:?} opens no submenu", item.info.title));
            };
            level = sub;
        }
        let Some(item) = chosen else {
            return refuse(menus::not_found(value, &ItemMatch::NotFound, &[]));
        };
        if let Err(e) = item.el.perform("AXPress") {
            let failed = ax_error(e, &format!("the item {:?}", item.info.title));
            return Err(self.close_and_fail(t, &menu, &windows, failed));
        }
        let title = item.info.title;
        // A pop-up shows the item a little after the press (about 0.2 s in a
        // System Settings pane); a menu button shows no value, so its menu
        // closing is the end, as for a context menu.
        let before = popup.as_ref().and_then(|p| p.2.clone());
        let read = || popup.as_ref().and_then(|p| p.0.value_text());
        let shows_value = before.as_deref().is_some_and(|v| !v.trim().is_empty());
        let mut after = read();
        let closed = wait_for(CLOSE_WAIT, || {
            after = read();
            !showing(&windows) && (!shows_value || after != before)
        });
        let stays = showing(&windows) && !self.cancel_or_record(t, &menu, &windows);
        let open_ms = opened.elapsed().as_millis() as u64;
        let confirmed = match &popup {
            Some(_) => after.as_deref().is_some_and(|a| roles::same_title(a, &title)),
            None => closed,
        };
        let route = if popup.is_some() { "ax_menu_open_pick" } else { "ax_context_menu_pick" };
        let mut out = if confirmed {
            ActionOutcome::confirmed(route)
        } else {
            ActionOutcome::delivered(route)
        };
        if let Some((_, element_id, _)) = &popup
            && !closed
            && after == before
        {
            out.note = format!(
                "pressed {title:?} in element {element_id}'s menu; the pop-up reads back its old value"
            );
        }
        if stays {
            out.note = format!("{} {}", out.note, menus::MENU_DID_NOT_CLOSE).trim().to_string();
        }
        let mut report = MenuReport::picked(&title, Some(open_ms));
        report.keyboard = guard.report();
        out.menu = Some(report);
        if let Some(frame) = popup.as_ref().and_then(|p| p.0.frame()) {
            out = out.at(roles::center(&frame));
        }
        Ok(out)
    }

    /// Opens the context menu at a point of the window: the element there
    /// (or an ancestor) that offers `AXShowMenu`, else a right click posted
    /// to the app. None when the click showed no menu.
    fn open_context(&self, t: &Target, at: Point) -> DResult<Option<OpenedMenu>> {
        let pid = t.window.pid;
        let app = Ax::application(pid)
            .ok_or_else(|| DesktopError::TargetNotFound(format!("the app of window {}", t.id())))?;
        let mut el = app.element_at(at.x, at.y);
        for _ in 0..8 {
            let Some(current) = el.take() else { break };
            if current.actions().iter().any(|a| a == "AXShowMenu") {
                return self.open_menu(t, &current, "AXShowMenu").map(Some);
            }
            el = current.element("AXParent");
        }
        self.close_before_opening()?;
        let guard = KeyGuard::arm(t, self.guard());
        let before = menu_window_ids();
        let start = Instant::now();
        let route = Route::Pid { pid, window: t.window.id };
        input::click(route, at, Button::Right, 1, 0, Duration::ZERO)?;
        let find = || {
            app.element("AXShownMenuUIElement")
                .filter(is_menu)
                .or_else(|| app.elements("AXChildren").into_iter().find(is_menu))
        };
        match self.await_menu(t, &before, guard.armed(), || None, find) {
            Ok((menu, windows)) => Ok(Some((menu, windows, start, guard))),
            // The click was delivered and showed no menu (nothing there has one).
            Err(DesktopError::Failed(m)) if m == MENU_DID_NOT_OPEN => Ok(None),
            Err(e) => Err(e),
        }
    }

    /// A context menu at a point of the window, left open with its items
    /// (as [`Self::list_opened`] allows).
    pub(super) fn context_menu_at(&self, t: &Target, at: Point) -> DResult<ActionOutcome> {
        match self.open_context(t, at)? {
            Some(opened) => Ok(self.list_opened(t, opened, "context_menu")?.at(at)),
            None => Ok(ActionOutcome::delivered("pid_event").at(at)),
        }
    }

    /// The context menu at a point, its item titled `value` pressed and the
    /// menu closed, in this one call (the menu is never left open).
    pub(super) fn context_pick_at(
        &self,
        t: &Target,
        at: Point,
        value: &str,
    ) -> DResult<ActionOutcome> {
        let Some(opened) = self.open_context(t, at)? else {
            return Err(DesktopError::Failed(MENU_DID_NOT_OPEN.into()));
        };
        Ok(self.pick_in(t, opened, value, None)?.at(at))
    }

    /// An element's own menu (`AXShowMenu`), its item titled `value` pressed
    /// and the menu closed, in this one call.
    pub(super) fn element_menu_pick(
        &self,
        t: &Target,
        el: &Ax,
        value: &str,
    ) -> DResult<ActionOutcome> {
        let opened = self.open_menu(t, el, "AXShowMenu")?;
        let mut out = self.pick_in(t, opened, value, None)?;
        if let Some(frame) = el.frame() {
            out = out.at(roles::center(&frame));
        }
        Ok(out)
    }
}
