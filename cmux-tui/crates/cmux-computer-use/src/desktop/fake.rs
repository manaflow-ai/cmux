//! An in-memory desktop for engine tests and for the tool-level evals'
//! dry runs. It records every input it receives.

use std::sync::Mutex;

use super::*;
use crate::keys::KeyCombo;
use crate::menus::{self, ItemMatch, MenuItemInfo, MenuPolicy, MenuReport};

/// A pop-up button of a fake window: what its menu holds and shows.
#[derive(Clone, Debug, PartialEq)]
pub struct FakePopup {
    pub window: String,
    pub element: String,
    pub items: Vec<String>,
    pub value: String,
    /// Its menu is open (a click left it open).
    pub open: bool,
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

#[derive(Clone, Debug, PartialEq)]
pub enum Event {
    Click { window: String, point: Option<Point>, element: Option<String>, count: u8 },
    Type { window: String, text: String },
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
    /// Focus readings so far.
    pub focus_reads: Mutex<u32>,
    /// `restore_focus` calls so far.
    pub restores: Mutex<Vec<FocusSnapshot>>,
    /// Whether `restore_focus` works.
    pub restore_works: bool,
    /// Pop-up buttons (their menus open and pick like the macOS desktop's).
    pub popups: Mutex<Vec<FakePopup>>,
    /// The menu policy the engine handed over last.
    pub menu_policy: Mutex<Option<MenuPolicy>>,
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
            focus: Mutex::new(None),
            steal_on_input: Mutex::new(None),
            steal_on_read: Mutex::new(None),
            focus_reads: Mutex::new(0),
            restores: Mutex::new(vec![]),
            restore_works: true,
            popups: Mutex::new(vec![]),
            menu_policy: Mutex::new(None),
        }
    }

    pub fn events(&self) -> Vec<Event> {
        self.events.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

    fn push(&self, e: Event) {
        self.events.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(e);
        let steal =
            self.steal_on_input.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
        if let Some(stolen) = steal {
            *self.focus.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(stolen);
        }
    }

    pub fn restores(&self) -> Vec<FocusSnapshot> {
        self.restores.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

    /// The window's pop-ups as tree elements, an open one with its menu.
    fn popup_elements(&self, window_id: &str) -> Vec<Element> {
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
        };
        lock(&self.popups)
            .iter()
            .filter(|p| p.window == window_id)
            .map(|p| {
                let items = p
                    .items
                    .iter()
                    .enumerate()
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
            p.items.iter().filter(|t| policy.denied_item(t, &[]).is_none()).cloned().collect();
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
        if let ItemMatch::Found(i) = menus::match_item(&p.items, wanted)
            && let Some(app) = policy.denied_item(&p.items[i], &[])
        {
            return Some(Err(DesktopError::Unsupported(menus::denied_item_refusal(
                &p.items[i],
                app,
            ))));
        }
        let found = menus::match_item(&visible, wanted);
        p.open = false;
        let ItemMatch::Found(i) = found else {
            return Some(Err(DesktopError::Unsupported(menus::not_found(
                wanted, &found, &visible,
            ))));
        };
        p.value = visible[i].clone();
        drop(popups);
        self.push(event);
        Some(Ok(ActionOutcome {
            menu: Some(MenuReport::picked(&visible[i], Some(1))),
            ..ActionOutcome::confirmed("fake_menu_pick")
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
        Ok(self.windows.clone())
    }
    fn window(&self, id: &str) -> DResult<Option<Window>> {
        Ok(self.windows.iter().find(|w| w.id == id).cloned())
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
    fn ui_tree(&self, window_id: &str, _options: TreeOptions) -> DResult<UiTree> {
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
                }]
                .into_iter()
                .chain(self.popup_elements(window_id))
                .collect(),
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
        Ok(ActionOutcome::delivered("fake"))
    }
    fn type_text(
        &self,
        window_id: &str,
        _e: Option<&str>,
        text: &str,
        _d: Delivery,
    ) -> DResult<ActionOutcome> {
        self.known(window_id)?;
        self.push(Event::Type { window: window_id.into(), text: text.into() });
        Ok(ActionOutcome::delivered("fake"))
    }
    fn press_keys(
        &self,
        window_id: &str,
        combo: &KeyCombo,
        _d: Delivery,
    ) -> DResult<ActionOutcome> {
        self.known(window_id)?;
        self.push(Event::Keys { window: window_id.into(), combo: combo.clone() });
        Ok(ActionOutcome::delivered("fake"))
    }
    fn scroll(&self, target: &PointerTarget, dx: f64, dy: f64) -> DResult<ActionOutcome> {
        self.known(target.window_id())?;
        self.push(Event::Scroll { window: target.window_id().into(), dx, dy });
        Ok(ActionOutcome::delivered("fake"))
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
        Ok(ActionOutcome::delivered("fake"))
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
        Ok(ActionOutcome::confirmed("fake"))
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
        Ok(ActionOutcome::confirmed("fake"))
    }
    /// Like Windows: a bare name launches `<name>.exe`, matched lowercased.
    fn launch_identities(&self, app_id: &str) -> DResult<Vec<String>> {
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
