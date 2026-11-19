//! The Windows desktop: Win32, DWM, GDI and UI Automation.
//!
//! - Coordinates: the process is per-monitor DPI aware (v2, set once in
//!   [`WindowsDesktop::new`]), so every rectangle and point is a physical
//!   virtual-screen pixel, top-left origin, the same space UI Automation
//!   reports. Screenshots therefore have scale 1.0.
//! - Windows: visible, uncloaked top-level app windows in z-order (front
//!   first), framed by DWM's extended frame bounds (no invisible resize
//!   borders). Window ids are the HWND in decimal.
//! - Apps: the id is the owning process's executable name, lowercased
//!   (`notepad.exe`); a UWP window hosted by ApplicationFrameHost belongs to
//!   the app process inside it. The name is the file's version description.
//! - Background-first: semantic UI Automation patterns first, then window
//!   messages posted to the child window under the point or with the
//!   keyboard focus. Nothing is activated, and the person's pointer never
//!   moves. `Delivery::Foreground` raises the window and uses SendInput,
//!   which the person's activity tracker knows to ignore.
//! - Protected UI: a locked workstation, the secure desktop (UAC, sign-in)
//!   or a session-0 service has no reachable input desktop; [`permissions`]
//!   says so and every action refuses.

use std::sync::Once;

use windows::Win32::UI::HiDpi::{
    DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2, SetProcessDpiAwarenessContext,
};

use crate::desktop::*;
use crate::keys::KeyCombo;

mod activity;
mod capture;
mod input;
mod launch;
#[cfg(test)]
mod live_tests;
mod overlay;
pub mod pure;
mod session;
mod uia;
mod uia_act;
mod win;

pub use activity::person_activity;
pub use overlay::cursor_overlay;

/// Makes this process per-monitor DPI aware (v2) once. A manifest or an
/// earlier call may already have set it; either way the API then fails and
/// the existing awareness stays, which is what we want unless it is lower.
pub(crate) fn ensure_dpi_awareness() {
    static ONCE: Once = Once::new();
    ONCE.call_once(|| {
        // SAFETY: a process-wide setting with a constant argument.
        let _ =
            unsafe { SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2) };
    });
}

pub struct WindowsDesktop {
    uia: uia::Uia,
    names: win::NameCache,
}

impl WindowsDesktop {
    pub fn new() -> Result<Self, String> {
        ensure_dpi_awareness();
        if session::current().session_id == 0 {
            return Err("cmux Computer Use cannot run in session 0 (a service has no desktop); run the worker in the person's session".into());
        }
        Ok(Self { uia: uia::Uia::new(), names: win::NameCache::default() })
    }

    fn window(&self, id: &str) -> DResult<win::Hwnd> {
        win::Hwnd::parse(id)
    }
}

impl Desktop for WindowsDesktop {
    fn info(&self) -> PlatformInfo {
        let s = session::current();
        PlatformInfo {
            os: "windows".into(),
            display_server: "win32".into(),
            detail: format!(
                "{}; session {}; input desktop {}",
                session::os_version(),
                s.session_id,
                s.desktop.as_deref().unwrap_or("unreachable (locked or secure desktop)")
            ),
        }
    }

    fn permissions(&self) -> Permissions {
        // Windows has no per-app grants for UI Automation, capture or input
        // within the person's session. What can block us is the session
        // state: no input desktop while locked or on the secure desktop.
        let s = session::current();
        if s.interactive() {
            Permissions::default()
        } else {
            Permissions {
                accessibility: Grant::NotNeeded,
                screen_capture: Grant::Denied,
                input: Grant::Denied,
            }
        }
    }

    fn list_apps(&self) -> DResult<Vec<App>> {
        Ok(win::apps(&win::top_level_windows(&self.names)?))
    }

    fn list_windows(&self) -> DResult<Vec<Window>> {
        Ok(win::top_level_windows(&self.names)?.into_iter().map(|w| w.window).collect())
    }

    /// Not isolated: when PrintWindow returns nothing the capture falls back to a copy of the
    /// screen, which can hold a small denied window drawn over the target (the five-point
    /// "nothing covers it" check can miss one). So overlapping denied windows stay painted out.
    fn window_capture_isolated(&self) -> bool {
        false
    }

    fn capture(&self, target: &CaptureTarget) -> DResult<RawFrame> {
        session::require_interactive()?;
        match target {
            CaptureTarget::Window(id) => capture::window(self.window(id)?),
            CaptureTarget::Display(id) => capture::display(id.as_deref()),
        }
    }

    fn ui_tree(&self, window_id: &str, options: TreeOptions) -> DResult<UiTree> {
        let hwnd = self.window(window_id)?;
        self.uia.tree(hwnd, window_id, options)
    }

    fn click(&self, target: &PointerTarget, spec: &ClickSpec) -> DResult<ActionOutcome> {
        session::require_interactive()?;
        let hwnd = self.window(target.window_id())?;
        match target {
            PointerTarget::Element { element_id, .. } => {
                let simple = spec.button == Button::Left
                    && spec.count <= 1
                    && spec.modifiers.is_empty()
                    && spec.delivery == Delivery::Background;
                if simple {
                    return self.uia.press(hwnd, element_id);
                }
                // A right, double or modified click has no pattern: click
                // the element's center with window messages (or SendInput).
                let at = self.uia.center(hwnd, element_id)?;
                input::click(hwnd, at, spec)
            }
            PointerTarget::Point { point, .. } => input::click(hwnd, *point, spec),
        }
    }

    fn type_text(
        &self,
        window_id: &str,
        element_id: Option<&str>,
        text: &str,
        delivery: Delivery,
    ) -> DResult<ActionOutcome> {
        session::require_interactive()?;
        let hwnd = self.window(window_id)?;
        if delivery == Delivery::Foreground {
            if let Some(element) = element_id {
                self.uia.focus(hwnd, element)?;
            }
            return input::type_foreground(hwnd, text);
        }
        let target = match element_id {
            None => input::focus_of(hwnd)?,
            Some(element) => match self.uia.text_target(hwnd, element)? {
                uia::TextTarget::Window(child) => child,
                uia::TextTarget::AppendValue => return self.uia.append_value(hwnd, element, text),
            },
        };
        input::type_background(target, text)
    }

    fn press_keys(
        &self,
        window_id: &str,
        combo: &KeyCombo,
        delivery: Delivery,
    ) -> DResult<ActionOutcome> {
        session::require_interactive()?;
        let hwnd = self.window(window_id)?;
        input::press_keys(hwnd, combo, delivery)
    }

    fn scroll(&self, target: &PointerTarget, dx: f64, dy: f64) -> DResult<ActionOutcome> {
        session::require_interactive()?;
        let hwnd = self.window(target.window_id())?;
        let at = match target {
            PointerTarget::Element { element_id, .. } => self.uia.center(hwnd, element_id)?,
            PointerTarget::Point { point, .. } => *point,
        };
        input::scroll(hwnd, at, dx, dy)
    }

    fn drag(
        &self,
        window_id: &str,
        from: Point,
        to: Point,
        button: Button,
        delivery: Delivery,
    ) -> DResult<ActionOutcome> {
        session::require_interactive()?;
        input::drag(self.window(window_id)?, from, to, button, delivery)
    }

    fn set_value(&self, window_id: &str, element_id: &str, value: &str) -> DResult<ActionOutcome> {
        session::require_interactive()?;
        self.uia.set_value(self.window(window_id)?, element_id, value)
    }

    fn perform_action(
        &self,
        window_id: &str,
        element_id: &str,
        action: &str,
    ) -> DResult<ActionOutcome> {
        session::require_interactive()?;
        self.uia.perform(self.window(window_id)?, element_id, action)
    }

    fn launch_app(&self, app_id: &str) -> DResult<App> {
        session::require_interactive()?;
        launch::launch(app_id, &self.names)
    }

    fn launch_identities(&self, app_id: &str) -> DResult<Vec<String>> {
        pure::launch_identities(app_id).map_err(DesktopError::Unsupported)
    }
}

/// Keeps the person's last-input clock honest about our own SendInput.
pub(crate) fn note_injected_input() {
    activity::note_injected();
}
