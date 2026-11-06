//! Windows desktop (placeholder; replaced by the macOS backend).
use std::sync::Arc;

use crate::desktop::*;
use crate::keys::KeyCombo;

pub struct WindowsDesktop {
    host: Option<Arc<dyn HostServices>>,
}

impl WindowsDesktop {
    pub fn new() -> Result<Self, String> {
        Ok(Self { host: None })
    }
}

fn todo<T>() -> DResult<T> {
    Err(DesktopError::Unsupported("not implemented yet".into()))
}

impl Desktop for WindowsDesktop {
    fn info(&self) -> PlatformInfo {
        PlatformInfo { os: "windows".into(), display_server: "win32".into(), detail: String::new() }
    }
    fn permissions(&self) -> Permissions {
        Permissions::default()
    }
    fn list_apps(&self) -> DResult<Vec<App>> {
        todo()
    }
    fn list_windows(&self) -> DResult<Vec<Window>> {
        todo()
    }
    fn capture(&self, target: &CaptureTarget) -> DResult<RawFrame> {
        match &self.host {
            Some(h) => h.capture(target),
            None => todo(),
        }
    }
    fn ui_tree(&self, _w: &str, _o: TreeOptions) -> DResult<UiTree> {
        todo()
    }
    fn click(&self, _t: &PointerTarget, _s: &ClickSpec) -> DResult<ActionOutcome> {
        todo()
    }
    fn type_text(
        &self,
        _w: &str,
        _e: Option<&str>,
        _t: &str,
        _d: Delivery,
    ) -> DResult<ActionOutcome> {
        todo()
    }
    fn press_keys(&self, _w: &str, _c: &KeyCombo, _d: Delivery) -> DResult<ActionOutcome> {
        todo()
    }
    fn scroll(&self, _t: &PointerTarget, _dx: f64, _dy: f64) -> DResult<ActionOutcome> {
        todo()
    }
    fn drag(
        &self,
        _w: &str,
        _f: Point,
        _t: Point,
        _b: Button,
        _d: Delivery,
    ) -> DResult<ActionOutcome> {
        todo()
    }
    fn set_value(&self, _w: &str, _e: &str, _v: &str) -> DResult<ActionOutcome> {
        todo()
    }
    fn perform_action(&self, _w: &str, _e: &str, _a: &str) -> DResult<ActionOutcome> {
        todo()
    }
    fn launch_app(&self, _a: &str) -> DResult<App> {
        todo()
    }
}

pub fn person_activity() -> Arc<dyn crate::engine::PersonActivity> {
    Arc::new(crate::engine::NoTakeover)
}

pub fn cursor_overlay() -> Arc<dyn crate::cursor::CursorSink> {
    Arc::new(crate::cursor::NoCursor)
}
