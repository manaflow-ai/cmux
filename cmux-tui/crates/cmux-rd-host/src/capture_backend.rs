//! Which capture backend a Linux session uses, and which X display it names.
//!
//! A Linux desktop is either an X11 session (XShm and XDamage, `capture.rs`) or a Wayland
//! session, where only the compositor can hand out the screen: the xdg-desktop-portal
//! ScreenCast interface and a PipeWire stream. The choice is a pure function of the
//! session's environment and an explicit `--capture x11|portal` override, so it is the
//! same in `cmux-rd serve` and in the Linux screen host that starts it.
//!
//! Within a Wayland session ([`WaylandCapture`]), GNOME is cast through mutter's own
//! ScreenCast and RemoteDesktop interfaces (`mutter.rs`) when mutter is on the session bus:
//! they need no grant and show no dialog. Every other compositor uses the portal.
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

/// How a Wayland session (`CaptureBackend::Portal`) reaches the screen.
#[cfg_attr(not(all(feature = "link", feature = "portal")), allow(dead_code))]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum WaylandCapture {
    /// mutter's own ScreenCast and RemoteDesktop (GNOME): no grant, no dialog.
    Mutter,
    /// xdg-desktop-portal: a grant saved once, at enable.
    Portal,
}

#[cfg_attr(not(all(feature = "link", feature = "portal")), allow(dead_code))]
impl WaylandCapture {
    /// mutter directly when `org.gnome.Mutter.ScreenCast` has an owner on the session bus,
    /// else the portal.
    pub fn choose(mutter_screen_cast: bool) -> Self {
        if mutter_screen_cast {
            WaylandCapture::Mutter
        } else {
            WaylandCapture::Portal
        }
    }

    /// Whether this capture needs the portal's grant before shares start without a dialog.
    pub fn needs_grant(self) -> bool {
        self == WaylandCapture::Portal
    }
}

/// Starts a Wayland capture: through mutter when `mutter` is given, falling back to the portal
/// when mutter fails (remote access inhibited, a refused call, no PipeWire node), so a share
/// that mutter will not start still starts the way it did before mutter was tried.
#[cfg_attr(not(all(feature = "portal", target_os = "linux")), allow(dead_code))]
pub fn mutter_else_portal<T, E: std::fmt::Display>(
    mutter: Option<impl FnOnce() -> Result<T, E>>,
    portal: impl FnOnce() -> Result<T, E>,
) -> Result<T, E> {
    if let Some(mutter) = mutter {
        match mutter() {
            Ok(t) => return Ok(t),
            Err(e) => {
                eprintln!("cmux-rd: mutter's screen cast did not start ({e}); asking the portal")
            }
        }
    }
    portal()
}

/// Which of mutter's interfaces this session bus has: (ScreenCast, RemoteDesktop). Both
/// false in a build without the D-Bus half or with no session bus.
#[cfg_attr(not(all(feature = "link", feature = "portal")), allow(dead_code))]
pub fn mutter_on_bus() -> (bool, bool) {
    #[cfg(all(feature = "portal-dbus", target_os = "linux"))]
    return {
        let p = crate::mutter::MutterPresence::detect();
        (p.screen_cast, p.remote_desktop)
    };
    #[cfg(not(all(feature = "portal-dbus", target_os = "linux")))]
    (false, false)
}

/// This Wayland session's [`WaylandCapture`] (asks the session bus).
#[cfg_attr(not(all(feature = "link", feature = "portal")), allow(dead_code))]
pub fn wayland_capture() -> WaylandCapture {
    WaylandCapture::choose(mutter_on_bus().0)
}

/// Whether a Wayland capture applies input: through mutter, when it has RemoteDesktop; through
/// the portal, with a saved RemoteDesktop grant.
#[cfg_attr(not(all(feature = "link", feature = "portal")), allow(dead_code))]
pub fn wayland_control_with(
    capture: WaylandCapture,
    mutter_remote_desktop: bool,
    portal_granted: bool,
) -> bool {
    match capture {
        WaylandCapture::Mutter => mutter_remote_desktop,
        WaylandCapture::Portal => portal_granted,
    }
}

/// Whether this desktop's Wayland sessions can apply input: a build with portal capture, and
/// either mutter's RemoteDesktop on the session bus (no grant) or a saved portal RemoteDesktop
/// grant (`linux-host enable --allow-control` or `linux-host grant --control` made it).
#[cfg(feature = "link")]
pub fn portal_control_granted() -> bool {
    #[cfg(all(feature = "portal", target_os = "linux"))]
    return {
        let (screen_cast, remote_desktop) = mutter_on_bus();
        let capture = WaylandCapture::choose(screen_cast);
        let portal_granted =
            capture == WaylandCapture::Portal && crate::portal::remote_desktop_granted();
        wayland_control_with(capture, remote_desktop, portal_granted)
    };
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
