//! wlroots compositors (Sway, Hyprland, river, Wayfire, labwc, ...).
//!
//! - Windows: the compositor's IPC (Sway, Hyprland: positions, pids,
//!   stacking), else wlr-foreign-toplevel (titles and app ids, no
//!   positions: those windows take element actions and display shots only).
//! - Pixels: wlr-screencopy of the output; a window shot is its rectangle
//!   of the output, refused while another window covers it.
//! - Input: AT-SPI first. wlr-virtual-pointer and the virtual keyboard are
//!   global (they act at the pointer and on the focused window), so they
//!   run only with `Delivery::Foreground` (after focusing the window) or on
//!   a headless session (`HEADLESS-*` outputs, `CMUX_CU_HEADLESS=1`), where
//!   the window is focused first since no person's focus is taken.
//! - Element positions: AT-SPI window coordinates plus the window's origin
//!   (Wayland clients do not know where they are on screen).

use std::sync::{Arc, Mutex, MutexGuard};

use super::atspi::{Atspi, Coords};
use super::keysym;
use super::{AppResolver, WaylandCaps, contains, crop_rgba};
use crate::desktop::*;
use crate::keys::{KeyCombo, Modifier};

pub mod ipc;
pub mod wl;

use ipc::{Ipc, IpcWindow};

/// What the compositor offers, for [`super::open`].
pub fn probe() -> Result<WaylandCaps, String> {
    wl::Wl::connect().map(|w| w.caps)
}

pub struct WlrootsDesktop {
    wl: Mutex<wl::Wl>,
    ipc: Option<Ipc>,
    headless: bool,
    apps: AppResolver,
    atspi: Mutex<Option<Arc<Atspi>>>,
}

impl WlrootsDesktop {
    pub fn connect() -> Result<Self, String> {
        let wl = wl::Wl::connect()?;
        let ipc = Ipc::detect();
        let mut names: Vec<String> = wl.state.outputs.iter().map(|o| o.name.clone()).collect();
        if let Some(i) = &ipc {
            names.extend(i.outputs());
        }
        let headless = std::env::var("CMUX_CU_HEADLESS").is_ok_and(|v| v == "1")
            || (!names.is_empty() && names.iter().all(|n| n.starts_with("HEADLESS")));
        Ok(Self {
            wl: Mutex::new(wl),
            ipc,
            headless,
            apps: AppResolver::default(),
            atspi: Mutex::new(None),
        })
    }

    fn wl(&self) -> MutexGuard<'_, wl::Wl> {
        self.wl.lock().unwrap_or_else(|e| e.into_inner())
    }

    fn atspi(&self) -> Option<Arc<Atspi>> {
        let mut g = self.atspi.lock().unwrap_or_else(|e| e.into_inner());
        if g.is_none() {
            *g = Atspi::connect().ok().map(Arc::new);
        }
        g.clone()
    }

    fn raw_windows(&self) -> DResult<Vec<IpcWindow>> {
        if let Some(i) = &self.ipc {
            let mut w = i.windows().map_err(DesktopError::Failed)?;
            w.sort_by_key(|w| std::cmp::Reverse((w.visible, w.layer, w.focused)));
            return Ok(w);
        }
        let mut wl = self.wl();
        wl.sync()?;
        Ok(wl
            .state
            .toplevels
            .iter()
            .filter(|t| !t.closed)
            .map(|t| IpcWindow {
                id: format!("tl:{}", t.serial),
                app_id: t.app_id.clone(),
                pid: 0,
                title: t.title.clone(),
                rect: Rect::default(),
                visible: !t.minimized,
                focused: t.activated,
                workspace: String::new(),
                layer: 0,
            })
            .collect())
    }

    fn find(&self, id: &str) -> DResult<(IpcWindow, Vec<IpcWindow>)> {
        let all = self.raw_windows()?;
        let w = all.iter().find(|w| w.id == id).cloned().ok_or_else(|| {
            DesktopError::TargetNotFound(format!("window {id} is gone; call list_windows"))
        })?;
        Ok((w, all))
    }

    fn coords(w: &IpcWindow) -> Coords {
        if w.rect.width > 0.0 {
            Coords::Window(Point { x: w.rect.x, y: w.rect.y })
        } else {
            Coords::None
        }
    }

    fn frame_obj(&self, w: &IpcWindow) -> DResult<(Arc<Atspi>, super::atspi::Frame)> {
        let a = self.atspi().ok_or_else(|| {
            DesktopError::Unsupported(
                "the accessibility bus (AT-SPI) is not running in this session".into(),
            )
        })?;
        let rect = (w.rect.width > 0.0).then_some(w.rect);
        let frames = a.frames(|_| Coords::None)?;
        let mine: Vec<_> = frames
            .into_iter()
            .filter(|f| {
                (w.pid != 0 && f.pid == w.pid)
                    || (w.pid == 0 && !w.title.is_empty() && f.name == w.title)
            })
            .collect();
        let f = super::atspi::pick_frame(mine, &w.title, rect).ok_or_else(|| {
            DesktopError::Unsupported("no accessibility tree for this window".into())
        })?;
        Ok((a, f))
    }

    /// Global input is allowed now for this window: focuses it first.
    fn global_input(&self, w: &IpcWindow, delivery: Delivery) -> DResult<&'static str> {
        if delivery == Delivery::Background && !self.headless {
            return Err(DesktopError::Unsupported(
                "on Wayland, virtual input goes to whatever has focus; use an element action (get_ui_tree), or delivery foreground".into(),
            ));
        }
        if !w.focused {
            match (&self.ipc, w.id.strip_prefix("tl:")) {
                (Some(i), _) => i.focus(&w.id).map_err(DesktopError::Failed)?,
                (None, Some(serial)) => self.wl().activate(serial.parse().unwrap_or(0))?,
                _ => return Err(DesktopError::Unsupported("cannot focus this window".into())),
            }
            self.settle_focus(w)?;
        }
        Ok(if self.headless && delivery == Delivery::Background {
            "wlr_virtual_input_headless"
        } else {
            "wlr_virtual_input"
        })
    }

    /// After a focus change: waits (bounded, on compositor round trips) until
    /// the compositor reports the window activated, then taps Shift. Clients
    /// such as foot drop the first keys that arrive in the same burst as
    /// their keyboard enter; a modifier tap absorbs that and types nothing.
    fn settle_focus(&self, w: &IpcWindow) -> DResult<()> {
        let deadline = std::time::Instant::now() + std::time::Duration::from_millis(500);
        let mut wl = self.wl();
        while std::time::Instant::now() < deadline {
            wl.sync()?;
            let active =
                wl.state.toplevels.iter().any(|t| !t.closed && t.activated && t.title == w.title);
            if active || !wl.toplevel_list {
                break;
            }
        }
        wl.keys(&[keysym::SHIFT_L], &[(0, true), (0, false)])
    }

    fn point_in(w: &IpcWindow, p: Point) -> DResult<()> {
        if w.rect.width <= 0.0 {
            return Err(DesktopError::Unsupported(
                "this compositor does not say where windows are; use element actions from get_ui_tree".into(),
            ));
        }
        if !contains(&w.rect, p.x, p.y) {
            return Err(DesktopError::TargetNotFound("the point is outside the window".into()));
        }
        Ok(())
    }

    fn element_center(
        &self,
        w: &IpcWindow,
        element_id: &str,
    ) -> DResult<(Arc<Atspi>, super::atspi::Obj, Option<Point>)> {
        let (a, _) = self.frame_obj(w)?;
        let obj = a.element(&w.id, element_id)?;
        let c = a.center(&obj, Self::coords(w));
        Ok((a, obj, c))
    }

    fn output_for(&self, p: Point) -> Option<usize> {
        self.wl().state.outputs.iter().position(|o| contains(&o.logical, p.x, p.y))
    }

    fn send_keys(
        &self,
        w: &IpcWindow,
        delivery: Delivery,
        syms: Vec<u32>,
        plan: Vec<(usize, bool)>,
    ) -> DResult<ActionOutcome> {
        if delivery == Delivery::Foreground || self.headless {
            self.wl().ensure_keymap(&syms)?;
        }
        let route = self.global_input(w, delivery)?;
        self.wl().sync()?;
        self.wl().keys(&syms, &plan)?;
        Ok(ActionOutcome::delivered(route))
    }
}

impl Desktop for WlrootsDesktop {
    fn info(&self) -> PlatformInfo {
        let compositor = self
            .ipc
            .as_ref()
            .map(|i| i.name().to_string())
            .or_else(|| std::env::var("XDG_CURRENT_DESKTOP").ok())
            .unwrap_or_else(|| "wlroots".into());
        let mut detail = compositor;
        if self.headless {
            detail.push_str("; headless outputs");
        }
        if self.ipc.is_none() {
            detail.push_str("; windows from wlr-foreign-toplevel (no positions)");
        }
        PlatformInfo { os: "linux".into(), display_server: "wayland-wlroots".into(), detail }
    }

    fn permissions(&self) -> Permissions {
        let caps = self.wl().caps;
        let g = |b: bool| if b { Grant::NotNeeded } else { Grant::Denied };
        Permissions {
            accessibility: if self.atspi().is_some() { Grant::Granted } else { Grant::Unknown },
            screen_capture: g(caps.screencopy),
            input: g(caps.virtual_pointer && caps.virtual_keyboard),
        }
    }

    fn list_apps(&self) -> DResult<Vec<App>> {
        let mut apps: Vec<App> = Vec::new();
        for w in self.raw_windows()? {
            let (id, name) = self.apps.resolve(w.pid, &w.app_id, "");
            if let Some(a) = apps.iter_mut().find(|a| a.id == id && a.pid == w.pid) {
                a.frontmost |= w.focused;
                a.hidden &= !w.visible;
                continue;
            }
            apps.push(App { id, name, pid: w.pid, frontmost: w.focused, hidden: !w.visible });
        }
        Ok(apps)
    }

    fn list_windows(&self) -> DResult<Vec<Window>> {
        Ok(self
            .raw_windows()?
            .into_iter()
            .map(|w| Window {
                app_id: self.apps.resolve(w.pid, &w.app_id, "").0,
                pid: w.pid,
                title: w.title.clone(),
                frame: w.rect,
                on_screen: w.visible,
                focused: w.focused,
                minimized: !w.visible,
                id: w.id,
            })
            .collect())
    }

    fn capture(&self, target: &CaptureTarget) -> DResult<RawFrame> {
        match target {
            CaptureTarget::Display(name) => {
                let idx = {
                    let wl = self.wl();
                    let outs = &wl.state.outputs;
                    match name {
                        Some(n) => outs.iter().position(|o| &o.name == n).ok_or_else(|| {
                            let names: Vec<&str> = outs.iter().map(|o| o.name.as_str()).collect();
                            DesktopError::TargetNotFound(format!(
                                "display {n:?}; displays: {names:?}"
                            ))
                        })?,
                        None => outs
                            .iter()
                            .position(|o| o.logical.x == 0.0 && o.logical.y == 0.0)
                            .unwrap_or(0),
                    }
                };
                self.wl().capture_output(idx)
            }
            CaptureTarget::Window(id) => {
                let (w, all) = self.find(id)?;
                if w.rect.width <= 0.0 || !w.visible {
                    return Err(DesktopError::Unsupported(
                        "the window is not on screen; take a display screenshot".into(),
                    ));
                }
                if ipc::covered(&w, &all) {
                    return Err(DesktopError::Unsupported(
                        "another window covers this one and wlr-screencopy only copies the screen; take a display screenshot".into(),
                    ));
                }
                let center =
                    Point { x: w.rect.x + w.rect.width / 2.0, y: w.rect.y + w.rect.height / 2.0 };
                let idx = self
                    .output_for(center)
                    .ok_or_else(|| DesktopError::Unsupported("the window is off screen".into()))?;
                let full = self.wl().capture_output(idx)?;
                let s = full.scale;
                let (x, y) = ((w.rect.x - full.origin.x) * s, (w.rect.y - full.origin.y) * s);
                let (rgba, cw, ch, x0, y0) = crop_rgba(
                    &full.rgba,
                    full.width,
                    full.height,
                    x as i64,
                    y as i64,
                    (w.rect.width * s) as i64,
                    (w.rect.height * s) as i64,
                )
                .ok_or_else(|| DesktopError::Unsupported("the window is off screen".into()))?;
                let origin =
                    Point { x: full.origin.x + x0 as f64 / s, y: full.origin.y + y0 as f64 / s };
                Ok(RawFrame { width: cw, height: ch, rgba, scale: s, origin })
            }
        }
    }

    fn ui_tree(&self, window_id: &str, options: TreeOptions) -> DResult<UiTree> {
        let (w, _) = self.find(window_id)?;
        let (a, f) = self.frame_obj(&w)?;
        a.tree(window_id, &f.obj, Self::coords(&w), options)
    }

    fn click(&self, target: &PointerTarget, spec: &ClickSpec) -> DResult<ActionOutcome> {
        let (w, _) = self.find(target.window_id())?;
        let simple = spec.button == Button::Left && spec.count == 1 && spec.modifiers.is_empty();
        let bg = spec.delivery == Delivery::Background;
        let p = match target {
            PointerTarget::Element { element_id, .. } => {
                let (a, obj, c) = self.element_center(&w, element_id)?;
                if simple && bg {
                    match a.press(&obj) {
                        Ok(_) => return Ok(at_opt(ActionOutcome::delivered("atspi_action"), c)),
                        Err(DesktopError::Unsupported(_)) => {}
                        Err(e) => return Err(e),
                    }
                }
                c.ok_or_else(|| {
                    DesktopError::Unsupported("the element has no action and no position".into())
                })?
            }
            PointerTarget::Point { point, .. } => *point,
        };
        Self::point_in(&w, p)?;
        if simple
            && bg
            && matches!(target, PointerTarget::Point { .. })
            && let Ok((a, f)) = self.frame_obj(&w)
            && let Some(hit) = a.at_point(&f.obj, p, Self::coords(&w))
            && let Some(obj) = a.actionable_ancestor(&hit, &f.obj)
            && a.extents(&obj, Self::coords(&w)).is_some_and(|r| contains(&r, p.x, p.y))
            && a.press(&obj).is_ok()
        {
            return Ok(ActionOutcome::delivered("atspi_action").at(p));
        }
        let code = button_code(spec.button);
        let mods: Vec<Modifier> =
            spec.modifiers.iter().copied().filter(|m| *m != Modifier::Fn).collect();
        let syms: Vec<u32> = mods.iter().filter_map(|m| keysym::of_modifier(*m)).collect();
        if !syms.is_empty() && (spec.delivery == Delivery::Foreground || self.headless) {
            self.wl().ensure_keymap(&syms)?;
        }
        let route = self.global_input(&w, spec.delivery)?;
        let mut wl = self.wl();
        if !syms.is_empty() {
            let plan: Vec<(usize, bool)> = (0..syms.len()).map(|i| (i, true)).collect();
            wl.keys(&syms, &plan)?;
        }
        wl.motion(p)?;
        for _ in 0..spec.count {
            wl.button(code, true)?;
            wl.button(code, false)?;
        }
        if !syms.is_empty() {
            let plan: Vec<(usize, bool)> = (0..syms.len()).rev().map(|i| (i, false)).collect();
            wl.keys(&syms, &plan)?;
        }
        wl.sync()?;
        Ok(ActionOutcome::delivered(route).at(p))
    }

    fn type_text(
        &self,
        window_id: &str,
        element_id: Option<&str>,
        text: &str,
        delivery: Delivery,
    ) -> DResult<ActionOutcome> {
        let (w, _) = self.find(window_id)?;
        if delivery == Delivery::Background
            && let Ok((a, f)) = self.frame_obj(&w)
        {
            let obj = match element_id {
                Some(id) => Some(a.element(window_id, id)?),
                None => a.typing_target(&f.obj)?,
            };
            if let Some(obj) = obj {
                match a.insert_text(&obj, text) {
                    Ok(true) => return Ok(ActionOutcome::confirmed("atspi_insert_text")),
                    Ok(false) => return Ok(ActionOutcome::delivered("atspi_insert_text")),
                    Err(DesktopError::Unsupported(_)) => {
                        let _ = a.perform(&obj, "focus");
                    }
                    Err(e) => return Err(e),
                }
            }
        }
        let mut syms: Vec<u32> = Vec::new();
        let mut plan = Vec::new();
        for c in text.chars() {
            let s = keysym::of_char(c);
            let i = syms.iter().position(|x| *x == s).unwrap_or_else(|| {
                syms.push(s);
                syms.len() - 1
            });
            plan.push((i, true));
            plan.push((i, false));
        }
        self.send_keys(&w, delivery, syms, plan)
    }

    fn press_keys(
        &self,
        window_id: &str,
        combo: &KeyCombo,
        delivery: Delivery,
    ) -> DResult<ActionOutcome> {
        let (w, _) = self.find(window_id)?;
        let mut syms: Vec<u32> =
            combo.modifiers.iter().filter_map(|m| keysym::of_modifier(*m)).collect();
        syms.push(keysym::of_key(&combo.key));
        let n = syms.len();
        let mut plan: Vec<(usize, bool)> = (0..n).map(|i| (i, true)).collect();
        plan.extend((0..n).rev().map(|i| (i, false)));
        self.send_keys(&w, delivery, syms, plan)
    }

    fn scroll(&self, target: &PointerTarget, dx: f64, dy: f64) -> DResult<ActionOutcome> {
        let (w, _) = self.find(target.window_id())?;
        let p = match target {
            PointerTarget::Point { point, .. } => *point,
            PointerTarget::Element { element_id, .. } => self
                .element_center(&w, element_id)?
                .2
                .ok_or_else(|| DesktopError::Unsupported("the element has no position".into()))?,
        };
        Self::point_in(&w, p)?;
        let route = self.global_input(&w, Delivery::Background)?;
        let mut wl = self.wl();
        wl.motion(p)?;
        if dy != 0.0 {
            wl.axis(true, dy.round().clamp(-50.0, 50.0) as i32)?;
        }
        if dx != 0.0 {
            wl.axis(false, dx.round().clamp(-50.0, 50.0) as i32)?;
        }
        wl.sync()?;
        Ok(ActionOutcome::delivered(route).at(p))
    }

    fn drag(
        &self,
        window_id: &str,
        from: Point,
        to: Point,
        button: Button,
        delivery: Delivery,
    ) -> DResult<ActionOutcome> {
        let (w, _) = self.find(window_id)?;
        Self::point_in(&w, from)?;
        Self::point_in(&w, to)?;
        let route = self.global_input(&w, delivery)?;
        let code = button_code(button);
        let mut wl = self.wl();
        wl.motion(from)?;
        wl.button(code, true)?;
        for i in 1..=12 {
            let t = f64::from(i) / 12.0;
            wl.motion(Point { x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t })?;
        }
        wl.button(code, false)?;
        wl.sync()?;
        Ok(ActionOutcome::delivered(route).at(to))
    }

    fn set_value(&self, window_id: &str, element_id: &str, value: &str) -> DResult<ActionOutcome> {
        let (w, _) = self.find(window_id)?;
        let (a, obj, c) = self.element_center(&w, element_id)?;
        let out = if a.set_value(&obj, value)? {
            ActionOutcome::confirmed("atspi_set_value")
        } else {
            ActionOutcome::delivered("atspi_set_value")
        };
        Ok(at_opt(out, c))
    }

    fn perform_action(
        &self,
        window_id: &str,
        element_id: &str,
        action: &str,
    ) -> DResult<ActionOutcome> {
        let (w, _) = self.find(window_id)?;
        let (a, obj, c) = self.element_center(&w, element_id)?;
        a.perform(&obj, action)?;
        Ok(at_opt(ActionOutcome::delivered("atspi_action"), c))
    }

    fn launch_app(&self, app_id: &str) -> DResult<App> {
        super::launch(&self.apps, app_id)
    }
}

fn button_code(b: Button) -> u32 {
    match b {
        Button::Left => keysym::BTN_LEFT,
        Button::Right => keysym::BTN_RIGHT,
        Button::Middle => keysym::BTN_MIDDLE,
    }
}

pub(crate) fn at_opt(out: ActionOutcome, p: Option<Point>) -> ActionOutcome {
    match p {
        Some(p) => out.at(p),
        None => out,
    }
}
