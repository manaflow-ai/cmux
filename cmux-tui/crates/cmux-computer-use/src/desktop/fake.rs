//! An in-memory desktop for engine tests and for the tool-level evals'
//! dry runs. It records every input it receives.

use std::sync::Mutex;

use super::*;
use crate::keys::KeyCombo;
use crate::menus::{self, MenuItemInfo, MenuPolicy, MenuReport};

/// A pop-up button of a fake window: what its menu holds and shows.
#[derive(Clone, Debug, Default, PartialEq)]
pub struct FakePopup {
    pub window: String,
    pub element: String,
    pub items: Vec<String>,
    pub value: String,
    /// Its menu is open (a click left it open).
    pub open: bool,
    /// Submenus by their parent item's title, filled only when they open
    /// (as AppKit fills Open With): a path pick ("Open With > TextEdit")
    /// reads them from there.
    pub submenus: Vec<(String, Vec<String>)>,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    Click { window: String, point: Option<Point>, element: Option<String>, count: u8 },
    Type { window: String, element: Option<String>, text: String },
    Keys { window: String, combo: KeyCombo },
    Scroll { window: String, dx: f64, dy: f64 },
    Drag { window: String, from: Point, to: Point },
    SetValue { window: String, element: String, value: String },
    Action { window: String, element: String, action: String },
    Launch(String),
}

pub struct FakeDesktop {
    /// Whether a window capture holds only the window's own pixels.
    pub isolated_window_capture: bool,
    /// Whether a display capture can leave processes out; the last list asked for.
    pub excludes_apps: bool,
    pub last_excluded: Mutex<Vec<u32>>,
    /// Apps only the capture system sees (a floating panel's app, a helper).
    pub capture_only_apps: Vec<App>,
    /// The capture refuses its exclusion list (a requested app it cannot find).
    pub refuse_exclusion: bool,
    pub apps: Vec<App>,
    pub windows: Vec<Window>,
    /// A window the next input opens (a sheet, a dialog), listed after it.
    pub opens_on_input: Mutex<Option<Window>>,
    opened: Mutex<Vec<Window>>,
    pub scale: f64,
    pub events: Mutex<Vec<Event>>,
    /// Bumped to change the pixels the next capture returns.
    pub paint: Mutex<u8>,
    /// Captures taken so far.
    pub captures: Mutex<u32>,
    /// Full window lists read so far.
    pub window_lists: Mutex<u32>,
    /// Where the person's pointer is.
    pub pointer: Mutex<Option<Point>>,
    /// From capture number `.0` on, the pixels are `.1` (an app that
    /// redraws a little after an action).
    pub repaint_from: Mutex<Option<(u32, u8)>>,
    /// The person's focus, when the fake reports one (`None`: it cannot tell).
    pub focus: Mutex<Option<FocusSnapshot>>,
    /// Focus after the next input this desktop receives (an app that
    /// activates itself on a click or a launch).
    pub steal_on_input: Mutex<Option<FocusSnapshot>>,
    /// Focus from focus reading number `.0` on (counting every reading).
    pub steal_on_read: Mutex<Option<(u32, FocusSnapshot)>>,
    /// Set: launch_identities answers these and the desktop launches by
    /// identity (as macOS does with bundle ids).
    pub launch_names: Mutex<Option<Vec<String>>>,
    /// Focus readings so far.
    pub focus_reads: Mutex<u32>,
    /// `restore_focus` calls so far.
    pub restores: Mutex<Vec<FocusSnapshot>>,
    /// Whether `restore_focus` works.
    pub restore_works: bool,
    /// The menu guard the engine set ([`Desktop::set_menu_guard`]).
    pub menu_guard: Mutex<Option<std::sync::Arc<dyn MenuGuard>>>,
    /// Pop-up buttons (their menus open and pick like the macOS desktop's).
    pub popups: Mutex<Vec<FakePopup>>,
    /// The menu policy the engine handed over last.
    pub menu_policy: Mutex<Option<MenuPolicy>>,
    /// Installed apps by display name (for menu items that name an app):
    /// (name, bundle id). Running apps count too.
    pub installed: Mutex<Vec<(String, String)>>,
    /// Set: every window's tree is this one (tests of ids, diffs and guards
    /// change it between calls). Its menus part is left out when the walk
    /// asks for no menus (a child with role `menu_bar`).
    pub tree: Mutex<Option<Element>>,
    /// Served by the next walk only, before `tree` (an app that builds its
    /// accessibility when a client first asks: WebKit's page content).
    pub first_walk: Mutex<Option<Element>>,
    /// Trees walked so far.
    pub walks: Mutex<u32>,
    /// (walk number, tree): from that walk on (counting every walk from 1),
    /// `tree` is that tree (an app whose sheet opens, or whose element is
    /// replaced, a few reads after an action).
    pub trees_from_walk: Mutex<Vec<(u32, Element)>>,
    /// The element limit the latest walk was asked for.
    pub last_max_nodes: Mutex<usize>,
    /// Where the effect of the next inputs must show ([`ActionOutcome::shows`]).
    pub shows: Mutex<Option<String>>,
    /// Set: a watch listens and reports these signals ([`Desktop::watch`]).
    pub signals: std::sync::Arc<Mutex<Option<Signals>>>,
    /// The pasteboard's change count ([`Desktop::world`]).
    pub pasteboard: Mutex<i64>,
    /// The next input writes to the pasteboard.
    pub copies_on_input: Mutex<bool>,
    /// Set: delivered results ask for a read-back, which answers this.
    pub reads_back: Mutex<Option<bool>>,
    /// The read-back's state already matched before the action.
    pub already: Mutex<bool>,
    /// Whether the app answers ([`Desktop::responsive`]).
    pub responsive: Mutex<Option<bool>>,
    /// What a confirmed result reads back after the settle.
    pub confirms_on_reread: Mutex<Option<bool>>,
    /// The read-backs state no change (their wanted state held before).
    pub unchanged: Mutex<bool>,
    /// Delivered results carry a read-back even when `reads_back` is None
    /// (it then answers "unreadable").
    pub reads_back_expect: Mutex<bool>,
    /// What a batch step's read-back answers right after its step (`None`:
    /// as after the batch).
    pub holds_after_step: Mutex<Option<bool>>,
    /// Set: the type_text call with this index (from 0) fails (a gate
    /// refusing partway through paced typing).
    pub type_fails_at: Mutex<Option<usize>>,
    /// type_text calls so far.
    pub type_calls: Mutex<usize>,
    /// Windows moved or resized since the fake was made: id -> frame now.
    pub reframed: Mutex<Vec<(String, Rect)>>,
}

/// A fake watch: the signals the desktop's `signals` holds when read.
struct FakeWatch(std::sync::Arc<Mutex<Option<Signals>>>);

impl Watch for FakeWatch {
    fn signals(&self) -> Signals {
        lock(&self.0).clone().unwrap_or_default()
    }
    fn listening(&self) -> bool {
        lock(&self.0).is_some()
    }
}

impl FakeDesktop {
    /// Safari (window 1, 800x600 at (100, 100)) and 1Password (window 2,
    /// 300x200 at (200, 200), on top of Safari).
    pub fn standard() -> Self {
        let app = |id: &str, name: &str, pid| App {
            id: id.into(),
            name: name.into(),
            pid,
            frontmost: false,
            hidden: false,
        };
        let window = |id: &str, app: &str, pid, frame| Window {
            id: id.into(),
            app_id: app.into(),
            pid,
            title: format!("{app} window"),
            frame,
            on_screen: true,
            focused: false,
            minimized: false,
        };
        Self {
            isolated_window_capture: false,
            excludes_apps: false,
            last_excluded: Mutex::new(vec![]),
            capture_only_apps: vec![],
            refuse_exclusion: false,
            apps: vec![
                app("com.apple.Safari", "Safari", 10),
                app("com.1password.1password", "1Password", 20),
            ],
            windows: vec![
                window(
                    "2",
                    "com.1password.1password",
                    20,
                    Rect { x: 200.0, y: 200.0, width: 300.0, height: 200.0 },
                ),
                window(
                    "1",
                    "com.apple.Safari",
                    10,
                    Rect { x: 100.0, y: 100.0, width: 800.0, height: 600.0 },
                ),
            ],
            scale: 2.0,
            events: Mutex::new(vec![]),
            paint: Mutex::new(200),
            captures: Mutex::new(0),
            window_lists: Mutex::new(0),
            pointer: Mutex::new(None),
            repaint_from: Mutex::new(None),
            opens_on_input: Mutex::new(None),
            opened: Mutex::new(Vec::new()),
            focus: Mutex::new(None),
            steal_on_input: Mutex::new(None),
            steal_on_read: Mutex::new(None),
            launch_names: Mutex::new(None),
            focus_reads: Mutex::new(0),
            restores: Mutex::new(vec![]),
            restore_works: true,
            menu_guard: Mutex::new(None),
            popups: Mutex::new(vec![]),
            menu_policy: Mutex::new(None),
            installed: Mutex::new(vec![("Terminal".into(), "com.apple.Terminal".into())]),
            tree: Mutex::new(None),
            first_walk: Mutex::new(None),
            walks: Mutex::new(0),
            trees_from_walk: Mutex::new(Vec::new()),
            last_max_nodes: Mutex::new(0),
            reframed: Mutex::new(Vec::new()),
            shows: Mutex::new(None),
            signals: std::sync::Arc::new(Mutex::new(None)),
            pasteboard: Mutex::new(0),
            copies_on_input: Mutex::new(false),
            reads_back: Mutex::new(None),
            already: Mutex::new(false),
            responsive: Mutex::new(Some(true)),
            confirms_on_reread: Mutex::new(Some(true)),
            unchanged: Mutex::new(false),
            reads_back_expect: Mutex::new(false),
            holds_after_step: Mutex::new(None),
            type_fails_at: Mutex::new(None),
            type_calls: Mutex::new(0),
        }
    }

    /// A window as it is now ([`Self::reframed`]).
    fn reframe(&self, mut w: Window) -> Window {
        if let Some((_, f)) = lock(&self.reframed).iter().find(|(id, _)| *id == w.id) {
            w.frame = *f;
        }
        w
    }

    pub fn events(&self) -> Vec<Event> {
        self.events.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

    fn push(&self, e: Event) {
        self.events.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(e);
        if let Some(w) =
            self.opens_on_input.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take()
        {
            self.opened.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(w);
        }
        if std::mem::take(&mut *lock(&self.copies_on_input)) {
            *lock(&self.pasteboard) += 1;
        }
        let steal =
            self.steal_on_input.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
        if let Some(stolen) = steal {
            *self.focus.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(stolen);
        }
    }

    pub fn restores(&self) -> Vec<FocusSnapshot> {
        self.restores.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

    /// A confirmed result whose read-back after the settle answers
    /// [`Self::confirms_on_reread`].
    fn confirmed(&self, route: &str) -> ActionOutcome {
        let unchanged = *lock(&self.unchanged);
        let expect = Some(Expect {
            token: 0,
            what: "value".into(),
            already: false,
            before: "a".into(),
            wanted: if unchanged { "a".into() } else { "b".into() },
        });
        ActionOutcome { expect, ..ActionOutcome::confirmed(route) }
    }

    /// A delivered result, showing where [`Self::shows`] says.
    fn delivered(&self) -> ActionOutcome {
        let already = *lock(&self.already);
        let carries = lock(&self.reads_back).is_some() || *lock(&self.reads_back_expect);
        let expect = carries.then(|| Expect {
            token: 1,
            what: "text".into(),
            already,
            before: "a".into(),
            wanted: if *lock(&self.unchanged) { "a".into() } else { "b".into() },
        });
        ActionOutcome {
            shows: lock(&self.shows).clone(),
            expect,
            ..ActionOutcome::delivered("fake")
        }
    }

    /// The bundle ids of the installed or running apps named `name`.
    fn apps_named(&self, name: &str) -> Option<Vec<String>> {
        let installed = lock(&self.installed);
        Some(
            installed
                .iter()
                .filter(|(n, _)| n.eq_ignore_ascii_case(name))
                .map(|(_, id)| id.clone())
                .chain(
                    self.apps
                        .iter()
                        .filter(|a| a.name.eq_ignore_ascii_case(name))
                        .map(|a| a.id.clone()),
                )
                .collect(),
        )
    }

    /// Whether the menu guard the engine set hides and refuses a menu item
    /// with this title (as the macOS desktop decides it for an opened menu).
    fn item_blocked(&self, title: &str) -> bool {
        let guard = lock(&self.menu_guard).clone();
        guard.is_some_and(|g| {
            menus::title_names_blocked_app(&*g, title, &|n: &str| self.apps_named(n))
        })
    }

    /// The window's pop-ups as tree elements, an open one with its menu.
    fn popup_elements(&self, window_id: &str) -> Vec<Element> {
        // As on macOS, every element has its identity, the same across walks.
        let node = |id: &str, role: &str, name: &str, children: Vec<Element>| Element {
            id: id.into(),
            role: role.into(),
            name: name.into(),
            value: String::new(),
            frame: None,
            actions: vec![],
            focused: false,
            disabled: false,
            children,
            identity: Some(crate::observe::hash_identity(id)),
            ..Element::default()
        };
        lock(&self.popups)
            .iter()
            .filter(|p| p.window == window_id)
            .map(|p| {
                let items = p
                    .items
                    .iter()
                    .enumerate()
                    .filter(|(_, t)| !self.item_blocked(t))
                    .map(|(i, t)| node(&format!("{}.{i}", p.element), "menu_item", t, vec![]))
                    .collect();
                let menu = p.open.then(|| node(&format!("{}.m", p.element), "menu", "", items));
                let mut e = node(&p.element, "popup_button", "", menu.into_iter().collect());
                e.value = p.value.clone();
                e.actions = vec!["press".into()];
                e
            })
            .collect()
    }

    pub fn popups(&self) -> Vec<FakePopup> {
        lock(&self.popups).clone()
    }

    /// A call on a pop-up, decided as the macOS desktop decides it: refused
    /// under `refuse`; with `pick`, the item is chosen and the menu closed in
    /// one call (or cancelled with the items listed); without, the menu opens
    /// and stays open with its items in the result. `None`: not a pop-up.
    fn popup_call(
        &self,
        window_id: &str,
        element_id: &str,
        pick: Option<&str>,
        event: Event,
    ) -> Option<DResult<ActionOutcome>> {
        let policy = lock(&self.menu_policy).clone().unwrap_or_default();
        let mut popups = lock(&self.popups);
        let p = popups.iter_mut().find(|p| p.window == window_id && p.element == element_id)?;
        if !policy.opens() {
            return Some(Err(DesktopError::Unsupported(menus::refused_by_setting(
                "this popup_button",
            ))));
        }
        let visible: Vec<String> =
            p.items.iter().filter(|t| !self.item_blocked(t)).cloned().collect();
        let hidden = p.items.len() - visible.len();
        let Some(wanted) = pick else {
            p.open = true;
            drop(popups);
            self.push(event);
            let items =
                visible.into_iter().map(|title| MenuItemInfo { title, ..Default::default() });
            return Some(Ok(ActionOutcome {
                menu: Some(MenuReport::open(items.collect(), hidden)),
                ..ActionOutcome::delivered("fake_menu_open")
            }));
        };
        p.open = false;
        // A path walks the submenus, each level opened (filled) and held to
        // the same checks as the item pressed.
        let path = menus::menu_path(wanted);
        let mut level: Vec<String> = p.items.clone();
        let mut picked_title = String::new();
        for (n, part) in path.iter().enumerate() {
            let hidden: Vec<bool> = level.iter().map(|t| self.item_blocked(t)).collect();
            let i = match menus::pick(&level, &hidden, part) {
                menus::Pick::Item(i) => i,
                menus::Pick::Hidden => {
                    return Some(Err(DesktopError::Unsupported(menus::denied_item_refusal(Some(
                        part,
                    )))));
                }
                menus::Pick::Missing(found) => {
                    let shown: Vec<String> =
                        level.iter().filter(|t| !self.item_blocked(t)).cloned().collect();
                    return Some(Err(DesktopError::Unsupported(menus::not_found(
                        part, &found, &shown,
                    ))));
                }
            };
            let Some(title) = level.get(i).cloned() else {
                return Some(Err(DesktopError::Unsupported(menus::not_found(
                    part,
                    &menus::ItemMatch::NotFound,
                    &level,
                ))));
            };
            let sub =
                p.submenus.iter().find(|(parent, _)| *parent == title).map(|(_, l)| l.clone());
            match (n + 1 == path.len(), sub) {
                (true, None) => picked_title = title,
                (true, Some(_)) => {
                    return Some(Err(DesktopError::Unsupported(format!(
                        "the item {title:?} opens a submenu; give the path to an item in it"
                    ))));
                }
                (false, Some(items)) => level = items,
                (false, None) => {
                    return Some(Err(DesktopError::Unsupported(format!(
                        "the item {title:?} opens no submenu"
                    ))));
                }
            }
        }
        let top = path.len() == 1;
        if top {
            p.value = picked_title.clone();
        }
        drop(popups);
        self.push(event);
        Some(Ok(ActionOutcome {
            menu: Some(MenuReport::picked(&picked_title, Some(1))),
            ..self.confirmed("fake_menu_pick")
        }))
    }

    fn known(&self, window: &str) -> DResult<()> {
        if self.windows.iter().any(|w| w.id == window) {
            Ok(())
        } else {
            Err(DesktopError::TargetNotFound(format!("window {window}")))
        }
    }
}

impl Desktop for FakeDesktop {
    fn set_menu_guard(&self, guard: std::sync::Arc<dyn MenuGuard>) {
        *lock(&self.menu_guard) = Some(guard);
    }

    fn info(&self) -> PlatformInfo {
        PlatformInfo { os: "fake".into(), display_server: "fake".into(), detail: String::new() }
    }
    fn permissions(&self) -> Permissions {
        Permissions {
            accessibility: Grant::Granted,
            screen_capture: Grant::Granted,
            input: Grant::Granted,
        }
    }
    fn list_apps(&self) -> DResult<Vec<App>> {
        Ok(self.apps.clone())
    }
    fn list_windows(&self) -> DResult<Vec<Window>> {
        *self.window_lists.lock().unwrap_or_else(std::sync::PoisonError::into_inner) += 1;
        let mut all: Vec<Window> = self.windows.iter().map(|w| self.reframe(w.clone())).collect();
        all.extend(self.opened.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone());
        Ok(all)
    }
    fn window(&self, id: &str) -> DResult<Option<Window>> {
        Ok(self.windows.iter().find(|w| w.id == id).cloned().map(|w| self.reframe(w)))
    }
    fn watch(&self, _window_id: &str) -> Option<Box<dyn Watch>> {
        Some(Box::new(FakeWatch(self.signals.clone())))
    }
    fn read_back(&self, expect: &Expect) -> Option<bool> {
        if expect.token == 0 {
            return *lock(&self.confirms_on_reread);
        }
        *lock(&self.reads_back)
    }
    fn peek_back(&self, expect: &Expect) -> Option<bool> {
        if let Some(step) = *lock(&self.holds_after_step) {
            return Some(step);
        }
        self.read_back(expect)
    }
    fn responsive(&self, _window_id: &str) -> Option<bool> {
        *lock(&self.responsive)
    }
    fn world(&self) -> Option<World> {
        let opened = lock(&self.opened);
        let mut windows: Vec<String> = self
            .windows
            .iter()
            .chain(opened.iter())
            .filter(|w| w.on_screen && !w.minimized)
            .map(|w| w.id.clone())
            .collect();
        windows.sort();
        Some(World { windows, pasteboard: Some(*lock(&self.pasteboard)), front_pid: None })
    }
    fn window_ids_over(&self, frame: &Rect) -> DResult<Vec<String>> {
        let opened = self.opened.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut ids: Vec<String> = self
            .windows
            .iter()
            .chain(opened.iter())
            .filter(|w| w.on_screen && !w.minimized && w.frame.intersects(frame))
            .map(|w| w.id.clone())
            .collect();
        ids.sort();
        Ok(ids)
    }
    fn pointer(&self) -> Option<Point> {
        *self.pointer.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }
    fn window_capture_isolated(&self) -> bool {
        self.isolated_window_capture
    }

    fn excludes_apps_from_display_capture(&self) -> bool {
        self.excludes_apps
    }

    fn capture_apps(&self) -> DResult<Vec<App>> {
        let mut apps = self.apps.clone();
        apps.extend(self.capture_only_apps.iter().cloned());
        Ok(apps)
    }

    fn capture_display_excluding(
        &self,
        display: Option<&str>,
        exclude_pids: &[u32],
    ) -> DResult<RawFrame> {
        if self.refuse_exclusion {
            return Err(DesktopError::Failed("exclusion_incomplete".into()));
        }
        *self.last_excluded.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
            exclude_pids.to_vec();
        self.capture(&CaptureTarget::Display(display.map(str::to_string)))
    }

    fn capture(&self, target: &CaptureTarget) -> DResult<RawFrame> {
        let (frame, origin) = match target {
            CaptureTarget::Window(id) => {
                let w = self
                    .windows
                    .iter()
                    .find(|w| w.id == *id)
                    .ok_or_else(|| DesktopError::TargetNotFound(id.clone()))?;
                (w.frame, Point { x: w.frame.x, y: w.frame.y })
            }
            CaptureTarget::Display(_) => {
                (Rect { x: 0.0, y: 0.0, width: 1000.0, height: 800.0 }, Point::default())
            }
        };
        let (w, h) = ((frame.width * self.scale) as u32, (frame.height * self.scale) as u32);
        let n = {
            let mut c = self.captures.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            *c += 1;
            *c
        };
        if let Some((from, p)) =
            *self.repaint_from.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
            && n >= from
        {
            *self.paint.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = p;
        }
        let paint = *self.paint.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        Ok(RawFrame {
            width: w,
            height: h,
            rgba: vec![paint; (w * h * 4) as usize],
            scale: self.scale,
            origin,
        })
    }
    fn draws_title_bars(&self) -> bool {
        true
    }
    fn ui_tree(&self, window_id: &str, options: TreeOptions) -> DResult<UiTree> {
        let walk = {
            let mut walks = lock(&self.walks);
            *walks += 1;
            *walks
        };
        {
            let mut pending = lock(&self.trees_from_walk);
            let due: Vec<Element> = pending
                .iter()
                .filter(|(from, _)| *from <= walk)
                .map(|(_, tree)| tree.clone())
                .collect();
            pending.retain(|(from, _)| *from > walk);
            if let Some(tree) = due.into_iter().last() {
                *lock(&self.tree) = Some(tree);
            }
        }
        *lock(&self.last_max_nodes) = options.max_nodes;
        let once = lock(&self.first_walk).take();
        if let Some(mut root) = once.or_else(|| lock(&self.tree).clone()) {
            self.known(window_id)?;
            if !options.menus {
                root.children.retain(|c| c.role != "menu_bar");
            }
            fn count(e: &Element) -> usize {
                1 + e.children.iter().map(count).sum::<usize>()
            }
            // Reported cut short past max_nodes (the walk keeps every node).
            let truncated = count(&root) > options.max_nodes;
            return Ok(UiTree { window_id: window_id.into(), root, truncated });
        }
        let w = self
            .windows
            .iter()
            .find(|w| w.id == window_id)
            .ok_or_else(|| DesktopError::TargetNotFound(format!("window {window_id}")))?;
        Ok(UiTree {
            window_id: window_id.into(),
            truncated: false,
            root: Element {
                id: "e0".into(),
                role: "window".into(),
                name: w.title.clone(),
                value: String::new(),
                frame: Some(w.frame),
                actions: vec![],
                focused: false,
                disabled: false,
                children: vec![Element {
                    id: "e1".into(),
                    role: "button".into(),
                    name: "OK".into(),
                    value: String::new(),
                    frame: Some(Rect {
                        x: w.frame.x + 10.0,
                        y: w.frame.y + 20.0,
                        width: 40.0,
                        height: 20.0,
                    }),
                    actions: vec!["press".into()],
                    focused: false,
                    disabled: false,
                    children: vec![],
                    ..Element::default()
                }]
                .into_iter()
                .chain(self.popup_elements(window_id))
                .collect(),
                ..Element::default()
            },
        })
    }
    fn click(&self, target: &PointerTarget, spec: &ClickSpec) -> DResult<ActionOutcome> {
        self.known(target.window_id())?;
        let (point, element) = match target {
            PointerTarget::Point { point, .. } => (Some(*point), None),
            PointerTarget::Element { element_id, .. } => (None, Some(element_id.clone())),
        };
        let event = Event::Click {
            window: target.window_id().into(),
            point,
            element: element.clone(),
            count: spec.count,
        };
        // menu_item: open, pick and close in one call, either delivery.
        if let Some(wanted) = spec.menu_item.as_deref() {
            return match &element {
                Some(id) => {
                    self.popup_call(target.window_id(), id, Some(wanted), event).unwrap_or_else(
                        || Err(DesktopError::Unsupported(format!("element {id} opens no menu"))),
                    )
                }
                None => Err(DesktopError::Unsupported("no menu at that point".into())),
            };
        }
        if spec.delivery == Delivery::Background {
            if let Some(id) = &element
                && let Some(done) = self.popup_call(target.window_id(), id, None, event.clone())
            {
                return done;
            }
            let refuse = lock(&self.menu_policy).as_ref().is_some_and(|p| !p.opens());
            if refuse && spec.button == Button::Right {
                return Err(DesktopError::Unsupported(menus::refused_by_setting("a right click")));
            }
        }
        self.push(event);
        Ok(self.delivered())
    }
    fn type_text(
        &self,
        window_id: &str,
        element: Option<&str>,
        text: &str,
        _d: Delivery,
    ) -> DResult<ActionOutcome> {
        self.known(window_id)?;
        let call = std::mem::replace(&mut *lock(&self.type_calls), 0);
        *lock(&self.type_calls) = call + 1;
        if *lock(&self.type_fails_at) == Some(call) {
            return Err(DesktopError::Unsupported("the caret gate refused".into()));
        }
        self.push(Event::Type {
            window: window_id.into(),
            element: element.map(str::to_string),
            text: text.into(),
        });
        Ok(self.delivered())
    }
    fn press_keys(
        &self,
        window_id: &str,
        combo: &KeyCombo,
        _d: Delivery,
    ) -> DResult<ActionOutcome> {
        self.known(window_id)?;
        self.push(Event::Keys { window: window_id.into(), combo: combo.clone() });
        Ok(self.delivered())
    }
    fn scroll(&self, target: &PointerTarget, dx: f64, dy: f64) -> DResult<ActionOutcome> {
        self.known(target.window_id())?;
        self.push(Event::Scroll { window: target.window_id().into(), dx, dy });
        Ok(self.delivered())
    }
    fn drag(
        &self,
        window_id: &str,
        from: Point,
        to: Point,
        _b: Button,
        _d: Delivery,
    ) -> DResult<ActionOutcome> {
        self.known(window_id)?;
        self.push(Event::Drag { window: window_id.into(), from, to });
        Ok(self.delivered())
    }
    fn set_value(&self, window_id: &str, element_id: &str, value: &str) -> DResult<ActionOutcome> {
        self.known(window_id)?;
        let event = Event::SetValue {
            window: window_id.into(),
            element: element_id.into(),
            value: value.into(),
        };
        if let Some(done) = self.popup_call(window_id, element_id, Some(value), event.clone()) {
            return done;
        }
        self.push(event);
        // With a read-back: as a route does, already matching is delivered.
        let mut out = if *lock(&self.already) {
            self.delivered()
        } else if lock(&self.reads_back).is_some() {
            ActionOutcome { expect: self.delivered().expect, ..ActionOutcome::confirmed("fake") }
        } else {
            self.confirmed("fake")
        };
        out.shows = None;
        Ok(out)
    }
    fn perform_action(
        &self,
        window_id: &str,
        element_id: &str,
        action: &str,
    ) -> DResult<ActionOutcome> {
        self.known(window_id)?;
        let event = Event::Action {
            window: window_id.into(),
            element: element_id.into(),
            action: action.into(),
        };
        if action == "press"
            && let Some(done) = self.popup_call(window_id, element_id, None, event.clone())
        {
            return done;
        }
        self.push(event);
        Ok(self.confirmed("fake"))
    }
    /// Like Windows: a bare name launches `<name>.exe`, matched lowercased.
    fn launches_by_identity(&self) -> bool {
        self.launch_names.lock().unwrap_or_else(std::sync::PoisonError::into_inner).is_some()
    }

    fn launch_identities(&self, app_id: &str) -> DResult<Vec<String>> {
        if let Some(names) =
            self.launch_names.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
        {
            return Ok(names);
        }
        let file = app_id.rsplit(['\\', '/']).next().unwrap_or(app_id).to_ascii_lowercase();
        Ok(vec![if file.contains('.') { file } else { format!("{file}.exe") }])
    }

    fn launch_app(&self, app_id: &str) -> DResult<App> {
        self.push(Event::Launch(app_id.into()));
        Ok(App { id: app_id.into(), name: app_id.into(), pid: 99, frontmost: false, hidden: false })
    }

    fn focus_snapshot(&self) -> Option<FocusSnapshot> {
        let n = {
            let mut reads =
                self.focus_reads.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
            *reads += 1;
            *reads
        };
        let mut pending =
            self.steal_on_read.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        if pending.as_ref().is_some_and(|(at, _)| n >= *at)
            && let Some((_, stolen)) = pending.take()
        {
            *self.focus.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(stolen);
        }
        self.focus.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

    fn picks_menu_items(&self) -> bool {
        true
    }

    fn set_menu_policy(&self, policy: MenuPolicy) {
        *lock(&self.menu_policy) = Some(policy);
    }

    fn restore_focus(&self, prior: &FocusSnapshot) -> DResult<bool> {
        self.restores.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(prior.clone());
        if self.restore_works {
            *self.focus.lock().unwrap_or_else(std::sync::PoisonError::into_inner) =
                Some(prior.clone());
        }
        Ok(self.restore_works)
    }
}
