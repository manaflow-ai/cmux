//! The macOS desktop: the Accessibility API for trees and semantic actions,
//! CGEvents posted to the target process for pointer and key input, the
//! window server's list for windows, NSWorkspace for apps, and pixels from
//! the hosting worker (ScreenCaptureKit) with a CoreGraphics fallback.
//!
//! Background-first (see [`crate::desktop`]): no app is activated and the
//! person's pointer never moves unless the call asked for
//! [`Delivery::Foreground`].

mod actions;
mod activation;
mod ax;
mod capture;
mod cgwindows;
mod input;
mod key_focus;
mod keymap;
mod menus;
mod roles;
mod sys;
#[cfg(test)]
mod tests;
mod workspace;

use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex};

use crate::desktop::*;
use crate::keys::KeyCombo;
use ax::{Ax, ElementCache};
use cgwindows::CgWindow;

pub struct MacDesktop {
    host: Option<Arc<dyn HostServices>>,
    elements: ElementCache,
    menu_guard: std::sync::RwLock<Option<Arc<dyn MenuGuard>>>,
    /// The engine's menu policy for the current call ([`crate::menus`]).
    menu_policy: Mutex<crate::menus::MenuPolicy>,
    /// The menu a call opened and left open, and its window.
    opened: Mutex<Option<menus::Opened>>,
}

impl MacDesktop {
    pub fn new(host: Option<Arc<dyn HostServices>>) -> Self {
        Self {
            host,
            elements: ElementCache::default(),
            menu_guard: std::sync::RwLock::new(None),
            menu_policy: Mutex::new(crate::menus::MenuPolicy::default()),
            opened: Mutex::new(None),
        }
    }

    fn guard(&self) -> Option<Arc<dyn MenuGuard>> {
        self.menu_guard.read().unwrap_or_else(|e| e.into_inner()).clone()
    }

    /// Whether the deny list or the protected apps hide and refuse this menu
    /// item (Recent Items, Open With and Services entries that reach a
    /// denied or protected app), with its title already read (one read, so
    /// the name checked is the one the caller has), telling a real block
    /// from a name not resolved yet (for an honest refusal). Names come from
    /// LaunchServices-backed [`workspace::apps_named`] (the menu bar and
    /// shortcuts). A title that cannot be read is refused by the caller,
    /// whatever the deny list.
    fn menu_item_check_titled(&self, item: &Ax, title: &str) -> roles::ItemCheck {
        self.menu_item_check_with(item, title, &workspace::apps_named)
    }

    /// [`Self::menu_item_check_titled`] with the given names.
    fn menu_item_check_with(
        &self,
        item: &Ax,
        title: &str,
        resolve: &dyn Fn(&str) -> Option<Vec<String>>,
    ) -> roles::ItemCheck {
        let Some(guard) = self.guard() else { return roles::ItemCheck::Allowed };
        // Without its place in the menus (its own chain could not be read)
        // the item is still checked by name (protected apps count with
        // nothing denied); while something is denied it is blocked: an item
        // above it cannot be read.
        let Some((top_index, depth, siblings)) = ax::menu_context(item) else {
            if guard.denies_any() {
                return roles::ItemCheck::Unplaced;
            }
            let ctx = roles::MenuItemContext {
                title,
                top_index: None,
                depth: 0,
                siblings: &[],
                launch: None,
            };
            return roles::menu_item_check(&*guard, &ctx, resolve);
        };
        // Siblings whose titles could not be read are unknown: no launch-list
        // inference from them; the launch-list rule applies while something
        // is denied (fail closed).
        let launch = siblings.is_none().then(|| guard.denies_any());
        let siblings = siblings.unwrap_or_default();
        let ctx = roles::MenuItemContext { title, top_index, depth, siblings: &siblings, launch };
        roles::menu_item_check(&*guard, &ctx, resolve)
    }

    fn denies_any(&self) -> bool {
        self.guard().is_some_and(|g| g.denies_any())
    }

    /// Why one element of an opened menu (a pop-up, a context menu) is
    /// hidden and refused, reading what it needs from AX (one element: a
    /// press or a click; a walk over many uses [`Self::opened_item_known`]);
    /// None when it is not. Names come from the same [`workspace::NameSource`]
    /// the listing uses, so the press refuses exactly what the listing hides.
    fn opened_item_reason(&self, item: &Ax) -> Option<crate::menus::BlockReason> {
        use crate::menus::BlockReason;
        let guard = self.guard()?;
        let title = match item.attr("AXTitle") {
            Ok(v) => v.and_then(|v| v.as_string()).unwrap_or_default(),
            // Unreadable: blocked, whatever the deny list.
            Err(_) => return Some(BlockReason::Unreadable),
        };
        let names = workspace::NameSource::now();
        let resolve = |n: &str| names.resolve(n);
        let check = self.menu_item_check_with(item, &title, &resolve);
        if check == roles::ItemCheck::Unplaced {
            return Some(BlockReason::Unreadable);
        }
        let path = menus::item_path_checked(item);
        press_reason(&*guard, check, &title, path.as_deref(), &|n| names.cold_answer(n), &resolve)
    }

    /// Whether a menu item a walk or a menu listing reached is hidden and
    /// refused, from what was already read: no AX reads of its own (a font
    /// pop-up holds thousands of items). Names come from `names`, fetched
    /// once for the walk (the index plus the blocked apps known before it).
    fn opened_item_known(&self, it: &ax::OpenedItem, names: &workspace::NameSource) -> bool {
        let Some(guard) = self.guard() else { return false };
        // Unreadable: blocked, whatever the deny list.
        if it.title_failed {
            return true;
        }
        let ctx = roles::MenuItemContext {
            title: it.title,
            top_index: None,
            depth: it.depth,
            siblings: &[],
            launch: Some(it.launch),
        };
        listing_blocked(&*guard, &ctx, it.path, &|n| names.resolve(n))
    }

    /// Whether items at this menu depth need their menu's titles: only a
    /// launch list (depth 2 and more) while anything is denied reads them.
    fn opened_needs_siblings(&self, depth: usize) -> bool {
        depth >= 2 && self.denies_any()
    }

    fn menu_policy(&self) -> crate::menus::MenuPolicy {
        self.menu_policy.lock().unwrap_or_else(|e| e.into_inner()).clone()
    }
}

/// The opened-menu rules past the menu bar's: an item under one that cannot
/// be read is blocked while anything is denied; under Services, Quick
/// Actions, Share, Open With or Recent Items (or a title above that cannot
/// be read), while anything is denied, only an item that names an allowed
/// installed app may run ("Services Settings…", "Make Sticky", "Customize…"
/// can open or hand data to any app); and any run of words in its title or
/// in the items above that names a denied or protected app blocks it.
fn opened_rules(
    guard: &dyn MenuGuard,
    title: &str,
    path: Option<&[String]>,
    resolve: &dyn Fn(&str) -> Option<Vec<String>>,
) -> bool {
    // An item above it cannot be read: while something is denied it is
    // hidden and refused (the listing and the press agree).
    if path.is_none() && guard.denies_any() {
        return true;
    }
    if guard.denies_any() && roles::in_opened_launch_list(path, workspace::launch_submenu_titles())
    {
        let name = roles::menu_app_name(title).0;
        let ids = resolve(name).unwrap_or_default();
        if ids.is_empty() || ids.iter().any(|id| guard.app_blocked(id, name)) {
            return true;
        }
    }
    std::iter::once(title)
        .chain(path.unwrap_or_default().iter().map(String::as_str))
        .any(|t| crate::menus::title_names_blocked_app(guard, t, resolve))
}

/// The rules of [`opened_rules`] that need no app names: a word run of the
/// title or the path above it that the guard blocks by name (a `name:`
/// entry, a protected app's name). A block here is real, loading or not.
pub(super) fn opened_rules_name_free(
    guard: &dyn MenuGuard,
    title: &str,
    path: Option<&[String]>,
) -> bool {
    let no_names = |_: &str| -> Option<Vec<String>> { Some(Vec::new()) };
    std::iter::once(title)
        .chain(path.unwrap_or_default().iter().map(String::as_str))
        .any(|t| crate::menus::title_names_blocked_app(guard, t, &no_names))
}

/// Why an opened-menu item past the menu-bar rule is hidden and refused,
/// and how to say it, in this order: an item above it that cannot be read
/// while something is denied is Unreadable; a name-free block, or a word
/// run that names a blocked app known before the index (`cold`), is
/// Denied; a name the menu-bar rule could not resolve yet (`menu_unknown`)
/// is Loading; the full rules on the index (`indexed`) block as Loading
/// when it left a name unanswered during this check, else as Denied.
/// Whether it blocks at all is exactly what [`opened_rules`] says with the
/// same index, which the listing uses. Pure, for tests.
pub(super) fn opened_reason(
    guard: &dyn MenuGuard,
    title: &str,
    path: Option<&[String]>,
    menu_unknown: bool,
    cold: &dyn Fn(&str) -> Option<Vec<String>>,
    indexed: &dyn Fn(&str) -> Option<Vec<String>>,
) -> Option<crate::menus::BlockReason> {
    use crate::menus::BlockReason;
    if path.is_none() && guard.denies_any() {
        return Some(BlockReason::Unreadable);
    }
    if opened_rules_name_free(guard, title, path) {
        return Some(BlockReason::Denied);
    }
    let cold_hit = std::iter::once(title)
        .chain(path.unwrap_or_default().iter().map(String::as_str))
        .any(|t| crate::menus::title_names_blocked_app(guard, t, cold));
    if cold_hit {
        return Some(BlockReason::Denied);
    }
    if menu_unknown {
        return Some(BlockReason::Loading);
    }
    let unanswered = std::cell::Cell::new(false);
    let tracked = |name: &str| {
        let ids = indexed(name);
        if ids.is_none() {
            unanswered.set(true);
        }
        ids
    };
    opened_rules(guard, title, path, &tracked)
        .then(|| if unanswered.get() { BlockReason::Loading } else { BlockReason::Denied })
}

/// Whether the listing hides an opened-menu item whose title was read: the
/// menu-bar rule or the opened-menu rules, on `resolve`. Pure, for tests.
pub(super) fn listing_blocked(
    guard: &dyn MenuGuard,
    ctx: &roles::MenuItemContext,
    path: Option<&[String]>,
    resolve: &dyn Fn(&str) -> Option<Vec<String>>,
) -> bool {
    roles::menu_item_blocked(guard, ctx, resolve) || opened_rules(guard, ctx.title, path, resolve)
}

/// Why the press refuses an opened-menu item whose title was read, given
/// the menu-bar rule's check on the same `resolve`: a block is Denied; else
/// [`opened_reason`]. It refuses exactly what [`listing_blocked`] hides for
/// the same context and names. Pure, for tests.
pub(super) fn press_reason(
    guard: &dyn MenuGuard,
    check: roles::ItemCheck,
    title: &str,
    path: Option<&[String]>,
    cold: &dyn Fn(&str) -> Option<Vec<String>>,
    resolve: &dyn Fn(&str) -> Option<Vec<String>>,
) -> Option<crate::menus::BlockReason> {
    use crate::menus::BlockReason;
    match check {
        roles::ItemCheck::Blocked => Some(BlockReason::Denied),
        roles::ItemCheck::Unplaced => Some(BlockReason::Unreadable),
        roles::ItemCheck::Unknown | roles::ItemCheck::Allowed => {
            opened_reason(guard, title, path, check == roles::ItemCheck::Unknown, cold, resolve)
        }
    }
}

/// A resolved window: the window server's entry and its app's identity.
struct Target {
    window: CgWindow,
}

impl Target {
    fn id(&self) -> String {
        self.window.id.to_string()
    }
}

fn grant(granted: bool) -> Grant {
    if granted { Grant::Granted } else { Grant::Denied }
}

/// The frontmost app's pid: the system-wide focused application as the
/// window server reports it (NSWorkspace's reading can lag in a process
/// whose main run loop is busy), else NSWorkspace's.
pub(super) fn frontmost_pid() -> Option<i32> {
    Ax::system_wide()
        .and_then(|s| s.element("AXFocusedApplication"))
        .and_then(|a| a.pid())
        .or_else(workspace::frontmost_pid)
}

fn post_event_granted() -> bool {
    // SAFETY: no arguments.
    unsafe { sys::CGPreflightPostEventAccess() }
}

impl MacDesktop {
    /// The window server's entry for `window_id`, a normal app window.
    fn target(&self, window_id: &str) -> DResult<Target> {
        let id: u32 = window_id
            .trim()
            .parse()
            .map_err(|_| DesktopError::TargetNotFound(format!("window {window_id}")))?;
        let window = cgwindows::by_id(id)
            .filter(|w| w.layer == 0)
            .ok_or_else(|| DesktopError::TargetNotFound(format!("window {window_id}")))?;
        Ok(Target { window })
    }

    /// The window's app and window accessibility elements.
    fn ax_window(&self, t: &Target) -> DResult<(Ax, Ax)> {
        ax::find_window(t.window.pid, t.window.id, &t.window.frame, &t.window.title)
    }

    fn element(&self, t: &Target, element_id: &str) -> DResult<Ax> {
        self.elements.lookup(&t.id(), element_id)
    }

    fn require_input(&self) -> DResult<()> {
        if post_event_granted() || ax::trusted() {
            Ok(())
        } else {
            Err(DesktopError::PermissionMissing("accessibility".into()))
        }
    }

    /// The apps that own the given windows, looked up fresh by pid
    /// (NSRunningApplication), so the answer never waits on a run loop.
    /// Computer Use works on windows, so the window server's window owners
    /// are the apps it can see: no process list is read.
    fn apps_of(&self, windows: &[CgWindow]) -> HashMap<i32, workspace::RunningApp> {
        let pids: HashSet<i32> =
            windows.iter().filter(|w| w.is_app_window()).map(|w| w.pid).collect();
        pids.into_iter().filter_map(|pid| workspace::app_for_pid(pid).map(|a| (pid, a))).collect()
    }

    fn request_direct(&self, which: &str) -> DResult<()> {
        match which {
            "accessibility" => {
                let key = sys::Cf::retained(
                    // SAFETY: an immortal CFString constant.
                    unsafe { sys::kAXTrustedCheckOptionPrompt },
                );
                let value = sys::Cf::boolean(true);
                let options = key.zip(value).and_then(|(k, v)| sys::Cf::dictionary(&k, &v));
                let ptr = options.as_ref().map_or(std::ptr::null(), sys::Cf::ptr);
                // SAFETY: ptr is null or a live dictionary.
                unsafe { sys::AXIsProcessTrustedWithOptions(ptr) };
                Ok(())
            }
            "screen_capture" => {
                // SAFETY: no arguments; shows the OS prompt once.
                unsafe { sys::CGRequestScreenCaptureAccess() };
                Ok(())
            }
            "input" => {
                // SAFETY: no arguments.
                unsafe { sys::CGRequestPostEventAccess() };
                Ok(())
            }
            other => Err(DesktopError::Unsupported(format!("no permission named {other}"))),
        }
    }

    /// Off-screen windows count only when Accessibility knows them as real
    /// windows (minimized or hidden); the window server also lists many
    /// invisible helper windows at layer 0.
    fn windows_from(
        &self,
        cg: Vec<CgWindow>,
        apps: &HashMap<i32, workspace::RunningApp>,
    ) -> Vec<Window> {
        let frontmost = apps.values().find(|a| a.active).map(|a| a.pid);
        let mut ax_states: HashMap<i32, HashMap<u32, (String, bool)>> = HashMap::new();
        let mut focused_done = false;
        let mut out = Vec::new();
        for w in cg.into_iter().filter(CgWindow::is_app_window) {
            // A window without a known app has no identity the policy can
            // match (deny list, approvals): leave it out rather than guess.
            let Some(app) = apps.get(&w.pid) else { continue };
            let needs_ax = !w.on_screen || w.title.is_empty();
            let state = if needs_ax {
                ax_states
                    .entry(w.pid)
                    .or_insert_with(|| ax::window_states(w.pid))
                    .get(&w.id)
                    .cloned()
            } else {
                None
            };
            if !w.on_screen && state.is_none() {
                continue;
            }
            let focused = !focused_done && w.on_screen && Some(w.pid) == frontmost;
            focused_done |= focused;
            let app_id = app.id();
            let (ax_title, minimized) = state.unwrap_or_default();
            out.push(Window {
                id: w.id.to_string(),
                app_id,
                pid: w.pid as u32,
                title: if w.title.is_empty() { ax_title } else { w.title },
                frame: w.frame,
                on_screen: w.on_screen,
                focused,
                minimized,
            });
        }
        out
    }
}

impl Desktop for MacDesktop {
    fn info(&self) -> PlatformInfo {
        let version = sys::sysctl_string(c"kern.osproductversion").unwrap_or_default();
        let build = sys::sysctl_string(c"kern.osversion").unwrap_or_default();
        let detail = match (version.is_empty(), build.is_empty()) {
            (false, false) => format!("macOS {version} ({build})"),
            (false, true) => format!("macOS {version}"),
            _ => "macOS".into(),
        };
        PlatformInfo { os: "macos".into(), display_server: "quartz".into(), detail }
    }

    fn permissions(&self) -> Permissions {
        Permissions {
            accessibility: grant(ax::trusted()),
            screen_capture: grant(capture::screen_capture_granted()),
            input: grant(post_event_granted()),
        }
    }

    fn list_apps(&self) -> DResult<Vec<App>> {
        let on_screen: HashSet<i32> = cgwindows::on_screen()
            .into_iter()
            .filter(CgWindow::is_app_window)
            .map(|w| w.pid)
            .collect();
        // Every window (hidden apps keep theirs off screen); an accessory
        // app (menu bar extra, agent) counts only with a window on screen.
        let mut apps: Vec<App> = self
            .apps_of(&cgwindows::all())
            .into_values()
            .filter(|a| a.is_regular() || (a.is_accessory() && on_screen.contains(&a.pid)))
            .map(|a| App {
                id: a.id(),
                name: a.name,
                pid: a.pid as u32,
                frontmost: a.active,
                hidden: a.hidden,
            })
            .collect();
        apps.sort_by(|a, b| b.frontmost.cmp(&a.frontmost).then_with(|| a.name.cmp(&b.name)));
        Ok(apps)
    }

    fn list_windows(&self) -> DResult<Vec<Window>> {
        let windows = cgwindows::all();
        let apps = self.apps_of(&windows);
        Ok(self.windows_from(windows, &apps))
    }

    /// One window from the window server and its app alone; the full list
    /// asks every app with a window (tens of ms).
    fn app_window_ids(&self, pid: u32) -> DResult<Vec<String>> {
        // One window server query; every layer (sheets, panels, popovers).
        let mut ids: Vec<String> = cgwindows::on_screen()
            .into_iter()
            .filter(|w| w.pid as u32 == pid && w.frame.width >= 2.0 && w.alpha > 0.0)
            .map(|w| w.id.to_string())
            .collect();
        ids.sort();
        Ok(ids)
    }

    fn window(&self, id: &str) -> DResult<Option<Window>> {
        let Ok(number) = id.parse::<u32>() else { return Ok(None) };
        let Some(cg) = cgwindows::by_id(number) else { return Ok(None) };
        let Some(app) = workspace::app_for_pid(cg.pid) else { return Ok(None) };
        let (pid, active) = (cg.pid, app.active);
        let apps = HashMap::from([(pid, app)]);
        let Some(mut window) = self.windows_from(vec![cg], &apps).pop() else { return Ok(None) };
        // Focused: the front window of the frontmost app, as in the full list.
        if window.focused && active {
            window.focused = cgwindows::on_screen()
                .into_iter()
                .find(|w| w.pid == pid && w.is_app_window())
                .is_some_and(|w| w.id == number);
        }
        Ok(Some(window))
    }

    fn is_frontmost_app(&self, window: &Window) -> bool {
        workspace::app_for_pid(window.pid as i32).is_none_or(|a| a.active)
    }

    fn pointer(&self) -> Option<Point> {
        // SAFETY: a null source makes a plain event at the pointer; released by Cf.
        let event = sys::Cf::created(unsafe { sys::CGEventCreate(std::ptr::null()) })?;
        // SAFETY: event is a live CGEvent.
        let at = unsafe { sys::CGEventGetLocation(event.ptr()) };
        Some(Point { x: at.x, y: at.y })
    }

    fn app_name(&self, window: &Window) -> Option<String> {
        workspace::app_for_pid(window.pid as i32).map(|a| a.name)
    }

    /// One window's own pixels (ScreenCaptureKit's window filter / PrintWindow), never a
    /// window drawn over it.
    fn window_capture_isolated(&self) -> bool {
        true
    }

    /// Through the worker's ScreenCaptureKit capture; the CoreGraphics fallback cannot.
    fn excludes_apps_from_display_capture(&self) -> bool {
        self.host.is_some()
    }

    fn capture_apps(&self) -> DResult<Vec<App>> {
        match &self.host {
            Some(host) => host.capture_apps(),
            None => Err(DesktopError::Unsupported("no capture host".into())),
        }
    }

    fn capture_display_excluding(
        &self,
        display: Option<&str>,
        exclude_pids: &[u32],
    ) -> DResult<RawFrame> {
        match &self.host {
            Some(host) => host.capture_display_excluding(display, exclude_pids),
            None => Err(DesktopError::Unsupported("no capture host".into())),
        }
    }

    fn capture(&self, target: &CaptureTarget) -> DResult<RawFrame> {
        if let Some(host) = &self.host {
            return host.capture(target);
        }
        match target {
            CaptureTarget::Window(id) => {
                let t = self.target(id)?;
                capture::window(t.window.id, &t.window.frame)
            }
            CaptureTarget::Display(id) => capture::display(id.as_deref()),
        }
    }

    fn ui_tree(&self, window_id: &str, options: TreeOptions) -> DResult<UiTree> {
        let t = self.target(window_id)?;
        let (_, window) = self.ax_window(&t)?;
        let guard = self.guard();
        let blocked = |ctx: &roles::MenuItemContext| {
            guard
                .as_ref()
                .is_some_and(|g| roles::menu_item_blocked(&**g, ctx, &workspace::apps_named))
        };
        let extra = self.opened_menu_for(&t.id()).into_iter().collect();
        let names = workspace::NameSource::now();
        let denies = self.denies_any();
        let filter = ax::MenuFilter {
            blocked: &|_: &Ax, it: &ax::OpenedItem| self.opened_item_known(it, &names),
            needs_siblings: &|depth| self.opened_needs_siblings(depth),
            launch_list: &|titles| roles::launch_by_items(titles, denies, &|n| names.resolve(n)),
        };
        self.elements.tree(&t.id(), window, extra, options, &blocked, &filter)
    }

    fn set_menu_guard(&self, guard: Arc<dyn MenuGuard>) {
        let ids = guard.clone();
        workspace::set_blocked_ids_source(Box::new(move || ids.blocked_ids()));
        *self.menu_guard.write().unwrap_or_else(|e| e.into_inner()) = Some(guard);
        workspace::warm_app_names();
        workspace::warm_service_shortcuts();
    }

    fn click(&self, target: &PointerTarget, spec: &ClickSpec) -> DResult<ActionOutcome> {
        actions::click(self, target, spec)
    }

    fn type_text(
        &self,
        window_id: &str,
        element_id: Option<&str>,
        text: &str,
        delivery: Delivery,
    ) -> DResult<ActionOutcome> {
        actions::type_text(self, window_id, element_id, text, delivery)
    }

    fn press_keys(
        &self,
        window_id: &str,
        combo: &KeyCombo,
        delivery: Delivery,
    ) -> DResult<ActionOutcome> {
        actions::press_keys(self, window_id, combo, delivery)
    }

    fn scroll(&self, target: &PointerTarget, dx: f64, dy: f64) -> DResult<ActionOutcome> {
        actions::scroll(self, target, dx, dy)
    }

    fn drag(
        &self,
        window_id: &str,
        from: Point,
        to: Point,
        button: Button,
        delivery: Delivery,
    ) -> DResult<ActionOutcome> {
        actions::drag(self, window_id, from, to, button, delivery)
    }

    fn set_value(&self, window_id: &str, element_id: &str, value: &str) -> DResult<ActionOutcome> {
        actions::set_value(self, window_id, element_id, value)
    }

    fn perform_action(
        &self,
        window_id: &str,
        element_id: &str,
        action: &str,
    ) -> DResult<ActionOutcome> {
        actions::perform_action(self, window_id, element_id, action)
    }

    fn launches_by_identity(&self) -> bool {
        true
    }

    fn launch_identities(&self, app_id: &str) -> DResult<Vec<String>> {
        let ids = workspace::launch_targets(app_id);
        if ids.is_empty() {
            return Err(DesktopError::TargetNotFound(format!(
                "no installed app has the bundle id or name {app_id:?}; list_apps shows the running ones"
            )));
        }
        Ok(ids)
    }

    /// Starts the app `app_id` names. The engine resolves a name first
    /// (launch_identities) and checks policy on the bundle id it got, then
    /// passes that one bundle id here, so it launches what policy saw; a
    /// name passed here is resolved the same way, and must name one app.
    fn launch_app(&self, app_id: &str) -> DResult<App> {
        let bundle_id = if workspace::bundle_installed(app_id) {
            app_id.to_string()
        } else {
            let ids = self.launch_identities(app_id)?;
            let [only] = ids.as_slice() else {
                return Err(DesktopError::Unsupported(format!(
                    "{app_id:?} names several apps ({}); launch one by its bundle id",
                    ids.join(", ")
                )));
            };
            only.clone()
        };
        let bundle_id = bundle_id.as_str();
        let a = workspace::launch(bundle_id)?;
        Ok(App {
            id: a.id(),
            name: a.name,
            pid: a.pid as u32,
            frontmost: a.active,
            hidden: a.hidden,
        })
    }

    fn focus_snapshot(&self) -> Option<FocusSnapshot> {
        let pid = frontmost_pid()?;
        let app_id =
            workspace::app_for_pid(pid).map(|a| a.id()).unwrap_or_else(|| format!("pid:{pid}"));
        let window_id = Ax::application(pid)
            .and_then(|a| a.element("AXFocusedWindow"))
            .and_then(|w| w.window_id())
            .map(|id| id.to_string());
        let top_pid =
            cgwindows::on_screen().into_iter().find(CgWindow::is_app_window).map(|w| w.pid as u32);
        Some(FocusSnapshot { pid: pid as u32, app_id, window_id, top_pid, pointer: self.pointer() })
    }

    /// The person's app frontmost again (its own AXFrontmost, which AppKit
    /// performs as an activation inside that app, else an activation
    /// request), then its key window main, key and above anything raised
    /// over it (AXRaise on the active app's own window activates nothing
    /// else). True when the requests were accepted; activation completes
    /// asynchronously, and the engine checks again after the settle wait.
    fn restore_focus(&self, prior: &FocusSnapshot) -> DResult<bool> {
        let pid = prior.pid as i32;
        let app = Ax::application(pid)
            .ok_or_else(|| DesktopError::TargetNotFound(format!("app {}", prior.app_id)))?;
        let yes =
            sys::Cf::boolean(true).ok_or_else(|| DesktopError::Failed("no boolean".into()))?;
        let mut accepted = true;
        if frontmost_pid() != Some(pid) {
            accepted = app.set("AXFrontmost", &yes).is_ok() || workspace::activate(pid);
        }
        let window = match prior.window_id.as_deref().and_then(|w| w.parse::<u32>().ok()) {
            Some(id) => app.windows().into_iter().find(|w| w.window_id() == Some(id)),
            None => app.element("AXFocusedWindow"),
        };
        if let Some(window) = window {
            let _ = window.set("AXMain", &yes);
            let _ = window.set("AXFocused", &yes);
            accepted &= window.perform("AXRaise").is_ok();
        }
        Ok(accepted)
    }

    fn picks_menu_items(&self) -> bool {
        true
    }

    fn set_menu_policy(&self, policy: crate::menus::MenuPolicy) {
        *self.menu_policy.lock().unwrap_or_else(|e| e.into_inner()) = policy;
    }

    fn request_permission(&self, which: &str) -> DResult<()> {
        if let Some(host) = &self.host {
            match host.request_permission(which) {
                Err(DesktopError::Unsupported(_)) => {}
                other => return other,
            }
        }
        self.request_direct(which)
    }
}
