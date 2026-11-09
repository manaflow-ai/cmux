//! An in-memory desktop for engine tests and for the tool-level evals'
//! dry runs. It records every input it receives.

use std::sync::Mutex;

use super::*;
use crate::keys::KeyCombo;

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
    /// From capture number `.0` on, the pixels are `.1` (an app that
    /// redraws a little after an action).
    pub repaint_from: Mutex<Option<(u32, u8)>>,
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
            repaint_from: Mutex::new(None),
        }
    }

    pub fn events(&self) -> Vec<Event> {
        self.events.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone()
    }

    fn push(&self, e: Event) {
        self.events.lock().unwrap_or_else(std::sync::PoisonError::into_inner).push(e);
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
        Ok(self.windows.clone())
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
                }],
            },
        })
    }
    fn click(&self, target: &PointerTarget, spec: &ClickSpec) -> DResult<ActionOutcome> {
        self.known(target.window_id())?;
        let (point, element) = match target {
            PointerTarget::Point { point, .. } => (Some(*point), None),
            PointerTarget::Element { element_id, .. } => (None, Some(element_id.clone())),
        };
        self.push(Event::Click {
            window: target.window_id().into(),
            point,
            element,
            count: spec.count,
        });
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
        self.push(Event::SetValue {
            window: window_id.into(),
            element: element_id.into(),
            value: value.into(),
        });
        Ok(ActionOutcome::confirmed("fake"))
    }
    fn perform_action(
        &self,
        window_id: &str,
        element_id: &str,
        action: &str,
    ) -> DResult<ActionOutcome> {
        self.known(window_id)?;
        self.push(Event::Action {
            window: window_id.into(),
            element: element_id.into(),
            action: action.into(),
        });
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
}
