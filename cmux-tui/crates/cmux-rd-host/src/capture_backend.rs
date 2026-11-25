//! Which capture backend a Linux session uses, and which X display it names.
//!
//! A Linux desktop is either an X11 session (XShm and XDamage, `capture.rs`) or a Wayland
//! session, where only the compositor can hand out the screen: the xdg-desktop-portal
//! ScreenCast interface and a PipeWire stream. The choice is a pure function of the
//! session's environment and an explicit `--capture x11|portal` override, so it is the
//! same in `cmux-rd serve` and in the Linux screen host that starts it.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

/// The capture backend of one session.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum CaptureBackend {
    /// The X server's root window (XShm readback driven by XDamage), with XTest input.
    #[default]
    X11,
    /// The compositor's screen through xdg-desktop-portal ScreenCast and PipeWire.
    Portal,
}

impl CaptureBackend {
    /// `--capture` (or the setup line's `capture`): `x11` or `portal`.
    pub fn parse(value: &str) -> Result<Self, String> {
        match value.trim() {
            "x11" => Ok(CaptureBackend::X11),
            "portal" => Ok(CaptureBackend::Portal),
            other => Err(format!("capture {other}: use x11 or portal")),
        }
    }

    /// The backend for a session: the explicit override when given, else `portal` in a
    /// Wayland session (`XDG_SESSION_TYPE=wayland`) and X11 otherwise. Device hub sessions
    /// (`serve`, `linux-host`) choose by session; `cmux-rd host` takes `--capture` alone.
    #[cfg(feature = "link")]
    pub fn choose(explicit: Option<&str>, session_type: Option<&str>) -> Result<Self, String> {
        if let Some(value) = explicit.filter(|v| !v.trim().is_empty()) {
            return Self::parse(value);
        }
        Ok(match session_type.map(str::trim) {
            Some(kind) if kind.eq_ignore_ascii_case("wayland") => CaptureBackend::Portal,
            _ => CaptureBackend::X11,
        })
    }

    /// [`CaptureBackend::choose`] with this process's `XDG_SESSION_TYPE`.
    #[cfg(feature = "link")]
    pub fn from_env(explicit: Option<&str>) -> Result<Self, String> {
        Self::choose(explicit, std::env::var("XDG_SESSION_TYPE").ok().as_deref())
    }

    /// Whether a viewer's input reaches this desktop with the backend: XTest on X11; the
    /// portal through its RemoteDesktop session, once that grant is saved (`portal.rs`) in a
    /// build with portal capture. Without it a portal session is view only.
    #[cfg(feature = "link")]
    pub fn applies_input(self) -> bool {
        self.applies_input_with(portal_control_granted())
    }

    /// [`CaptureBackend::applies_input`] with the RemoteDesktop grant given.
    #[cfg(feature = "link")]
    pub fn applies_input_with(self, remote_desktop_granted: bool) -> bool {
        match self {
            CaptureBackend::X11 => true,
            CaptureBackend::Portal => remote_desktop_granted,
        }
    }

    /// The `--capture` word for the backend.
    #[cfg(feature = "link")]
    pub fn name(self) -> &'static str {
        match self {
            CaptureBackend::X11 => "x11",
            CaptureBackend::Portal => "portal",
        }
    }

    /// Whether this build can capture with the backend. The portal backend is its own
    /// module (`portal.rs`, `pipewire_capture.rs`, feature `portal`); a build without it
    /// fails a portal session with [`PORTAL_NOT_BUILT_IN`] instead of streaming a black or
    /// wrong screen.
    #[cfg(any(feature = "link", not(all(feature = "portal", target_os = "linux"))))]
    pub fn available(self) -> Result<(), String> {
        match self {
            CaptureBackend::X11 => Ok(()),
            CaptureBackend::Portal if cfg!(all(feature = "portal", target_os = "linux")) => Ok(()),
            CaptureBackend::Portal => Err(PORTAL_NOT_BUILT_IN.to_owned()),
        }
    }
}

/// Whether this desktop's portal sessions can apply input: a build with portal capture and a
/// saved RemoteDesktop grant (`linux-host enable --allow-control` or `linux-host grant
/// --control` made it).
#[cfg(feature = "link")]
pub fn portal_control_granted() -> bool {
    #[cfg(all(feature = "portal", target_os = "linux"))]
    return crate::portal::remote_desktop_granted();
    #[cfg(not(all(feature = "portal", target_os = "linux")))]
    false
}

/// The reason a Wayland session cannot be shared by this build (shown to the viewer; the
/// app localizes it by this exact text).
#[cfg(any(feature = "link", not(all(feature = "portal", target_os = "linux"))))]
pub const PORTAL_NOT_BUILT_IN: &str =
    "portal capture not built in: this cmux cannot share a Wayland screen yet (run an X11 session, or pass --capture x11 with an X display)";

/// The X display a Linux session captures: the session's own (`--display`) when it names
/// an X display, else `$DISPLAY`, else `:0`. `main` and display indexes are the viewer's
/// display picker words (macOS); on Linux they mean the session's display.
#[cfg(feature = "link")]
pub fn x_display(
    requested: Option<&str>,
    option: Option<&str>,
    env_display: Option<&str>,
) -> String {
    let is_x_display = |v: &&str| v.contains(':');
    requested
        .map(str::trim)
        .filter(is_x_display)
        .or_else(|| option.map(str::trim).filter(is_x_display))
        .or_else(|| env_display.map(str::trim).filter(is_x_display))
        .unwrap_or(":0")
        .to_owned()
}

#[cfg(test)]
#[path = "capture_backend_tests.rs"]
mod tests;
