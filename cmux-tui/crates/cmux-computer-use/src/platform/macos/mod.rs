//! The macOS desktop: the Accessibility API for trees and semantic actions,
//! CGEvents posted to the target process for pointer and key input, the
//! window server's list for windows, NSWorkspace for apps, and pixels from
//! the hosting worker (ScreenCaptureKit) with a CoreGraphics fallback.
//!
//! Background-first (see [`crate::desktop`]): no app is activated and the
//! person's pointer never moves unless the call asked for
//! [`Delivery::Foreground`].

mod actions;
mod ax;
mod capture;
mod cgwindows;
mod input;
mod keymap;
mod roles;
mod sys;
#[cfg(test)]
mod tests;
mod workspace;

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use crate::desktop::*;
use crate::keys::KeyCombo;
use ax::{Ax, ElementCache};
use cgwindows::CgWindow;

pub struct MacDesktop {
    host: Option<Arc<dyn HostServices>>,
    elements: ElementCache,
}

impl MacDesktop {
    pub fn new(host: Option<Arc<dyn HostServices>>) -> Self {
        Self { host, elements: ElementCache::default() }
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
fn frontmost_pid() -> Option<i32> {
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
        self.elements.tree(&t.id(), window, options)
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

    fn launch_app(&self, app_id: &str) -> DResult<App> {
        let a = workspace::launch(app_id)?;
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
            Some(id) => app.elements("AXWindows").into_iter().find(|w| w.window_id() == Some(id)),
            None => app.element("AXFocusedWindow"),
        };
        if let Some(window) = window {
            let _ = window.set("AXMain", &yes);
            let _ = window.set("AXFocused", &yes);
            accepted &= window.perform("AXRaise").is_ok();
        }
        Ok(accepted)
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
