//! The real desktops. [`open`] picks the one for this machine at run time
//! (on Linux: X11, a Wayland compositor through the portals or the wlroots
//! protocols, or a headless X server), so one build runs on every
//! distribution and display server.

use std::sync::Arc;

use crate::desktop::Desktop;

#[cfg(target_os = "linux")]
pub mod linux;
#[cfg(target_os = "macos")]
pub mod macos;
#[cfg(windows)]
pub mod windows;

/// The desktop for this machine, or why there is none.
pub fn open() -> Result<Arc<dyn Desktop>, String> {
    #[cfg(target_os = "macos")]
    {
        Ok(Arc::new(macos::MacDesktop::new(None)))
    }
    #[cfg(windows)]
    {
        windows::WindowsDesktop::new().map(|d| Arc::new(d) as Arc<dyn Desktop>)
    }
    #[cfg(target_os = "linux")]
    {
        linux::open()
    }
    #[cfg(not(any(target_os = "macos", windows, target_os = "linux")))]
    {
        Err("cmux Computer Use supports macOS, Windows and Linux".into())
    }
}
