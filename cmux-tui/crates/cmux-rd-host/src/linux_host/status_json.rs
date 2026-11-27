//! `cmux-rd linux-host status --json`: the screen-share host's state as the one JSON shape
//! cmux reads from every share host (`cmux.screen-share.status/1`; the Mac helper prints it
//! from `cmux-rd helper status --json`). [`status_json`] is a pure function of the facts
//! [`gather`] reads from local files and the local display only: it never contacts the hub
//! or the network, and a missing piece is a state, never an error, so it is safe to poll.
//!
//! Not seen locally: a desktop the hub removed (`device_removed`) or whose key it refuses.
//! Only the hub knows that; `run` exits with `EXIT_NEEDS_SETUP` when it hears it.

use super::consent::LocalConsent;
use crate::capture::Readback;
use crate::capture_backend::{x_display, CaptureBackend};
use cmux_hub_host::identity::{self, Account, Device};
use serde_json::{json, Value};

pub const SCHEMA: &str = "cmux.screen-share.status/1";

/// The facts of this desktop now, `now_ms` being the current Unix time in ms.
pub fn gather(now_ms: u64) -> Facts {
    let dir = identity::config_dir().ok();
    let device = dir.as_deref().map(Device::load);
    // An unreadable device file is an identity to set up again, not "never enabled".
    let enabled = matches!(device, Some(Ok(Some(_)) | Err(_)));
    let backend = super::host_capture(identity::runtime_dir().ok().as_deref());
    let idle = Capture {
        backend,
        usable: false,
        size: None,
        portal_granted: false,
        portal_control: false,
        readback: None,
    };
    let Some(dir) = dir.filter(|_| enabled) else {
        return Facts { enabled, setup_ok: false, consent: None, capture: idle };
    };
    let setup_ok = matches!(device, Some(Ok(Some(_))))
        && match Account::load(&dir) {
            Ok(Some(a)) => a.anchored_until == 0 || a.anchored_until > now_ms,
            _ => false,
        };
    Facts {
        enabled,
        setup_ok,
        consent: LocalConsent::load(&dir).ok(),
        capture: probe_capture(backend),
    }
}

/// Whether `backend` can capture in this session, and the screen size when cheaply known.
fn probe_capture(backend: CaptureBackend) -> Capture {
    match backend {
        CaptureBackend::X11 => {
            let own = super::setup::virtual_display();
            // A DISPLAY naming that virtual display (the user environment's, so apps land on it)
            // is read as it, so its being stopped is no reason to say unsupported.
            let env = std::env::var("DISPLAY")
                .ok()
                .filter(|v| !v.is_empty())
                .filter(|v| own.is_none() || super::setup::display_number(v) != own);
            // Without a DISPLAY (a command over ssh), the virtual display this machine's host
            // shares, if it has one.
            let virtual_display = if env.is_none() { own } else { None };
            let env = env.or_else(|| virtual_display.map(|n| format!(":{n}")));
            let display = x_display(None, None, env.as_deref());
            // Only a local display is probed: a `host:N` display is a TCP connection.
            let local = display.starts_with(':') || display.starts_with("unix:");
            let probe = local.then(|| x11_probe(&display)).flatten();
            // A stopped virtual display is no reason to say unsupported: the host starts it
            // when a share needs it.
            let stopped_virtual = virtual_display
                .is_some_and(|n| !std::path::Path::new(&format!("/tmp/.X11-unix/X{n}")).exists());
            Capture {
                backend,
                usable: !local || probe.is_some() || stopped_virtual,
                size: probe.map(|(size, _)| size),
                portal_granted: false,
                portal_control: false,
                readback: probe.map(|(_, readback)| readback),
            }
        }
        CaptureBackend::Portal => Capture {
            backend,
            usable: backend.available().is_ok() && session_bus(),
            size: None,
            portal_granted: portal_token_saved(),
            readback: None,
            portal_control: crate::capture_backend::portal_control_granted(),
        },
    }
}

/// The root window size of the X display, when it accepts a connection, and how a capture
/// would read its pixels back (a one-page shared segment, freed when the connection closes).
fn x11_probe(display: &str) -> Option<((u32, u32), Readback)> {
    use x11rb::connection::Connection;
    let (conn, screen) = x11rb::connect(Some(display)).ok()?;
    let root = conn.setup().roots.get(screen)?;
    let size = (root.width_in_pixels.into(), root.height_in_pixels.into());
    // No warning here: `status` is polled; the capture itself warns once per session.
    let readback = match crate::capture::shm_works(&conn, 4096) {
        Ok(_) => Readback::Shm,
        Err(_) => Readback::Core,
    };
    Some((size, readback))
}

/// Whether there is a session bus to reach the portal on (no call is made).
fn session_bus() -> bool {
    std::env::var_os("DBUS_SESSION_BUS_ADDRESS").is_some_and(|v| !v.is_empty())
        || std::env::var_os("XDG_RUNTIME_DIR")
            .filter(|v| !v.is_empty())
            .is_some_and(|dir| std::path::Path::new(&dir).join("bus").exists())
}

/// Whether shares start with no dialog: a portal restore token (the grant `enable` makes,
/// refreshed by every share) is saved, or this is GNOME, which is cast through mutter directly
/// and needs no grant.
#[cfg(feature = "portal")]
fn portal_token_saved() -> bool {
    !crate::capture_backend::wayland_capture().needs_grant() || crate::portal::any_grant_saved()
}

#[cfg(not(feature = "portal"))]
fn portal_token_saved() -> bool {
    false
}

/// What `status` found on this desktop.
#[derive(Clone, Debug, PartialEq)]
pub struct Facts {
    /// A device identity exists (`enable` ran).
    pub enabled: bool,
    /// Signed in with an anchor that has not ended (no `enable`/`share on` to redo).
    pub setup_ok: bool,
    /// consent.json, when present and readable.
    pub consent: Option<LocalConsent>,
    pub capture: Capture,
}

/// The capture the host uses and whether it can capture here.
#[derive(Clone, Debug, PartialEq)]
pub struct Capture {
    pub backend: CaptureBackend,
    /// The backend can capture in this session: an X display answered, or this build has
    /// portal capture and a session bus to reach the portal on.
    pub usable: bool,
    /// Width and height of the captured screen, when known without a new dependency.
    pub size: Option<(u32, u32)>,
    /// A portal restore token is saved, so Start needs nobody at the screen.
    pub portal_granted: bool,
    /// X11: how a capture reads pixels back here, when the display answered.
    pub readback: Option<Readback>,
    /// The saved grant is RemoteDesktop's, so portal sessions apply a viewer's input.
    pub portal_control: bool,
}

/// The `cmux.screen-share.status/1` document for `facts`, `version` being this binary's.
pub fn status_json(facts: &Facts, version: &str) -> Value {
    let capture = &facts.capture;
    let applies_input = capture.backend.applies_input_with(capture.portal_control);
    let consent = facts.consent.filter(|_| facts.enabled);
    let shares = match consent {
        Some(c) if c.full && applies_input => "view_and_control",
        Some(c) if c.view || c.full => "view",
        _ => "none",
    };
    let (state, missing) = if !facts.enabled {
        ("not_installed", Vec::new())
    } else if !capture.usable {
        ("unsupported", Vec::new())
    } else {
        let mut missing = Vec::new();
        if !facts.setup_ok {
            missing.push("setup");
        }
        if consent.is_none() {
            missing.push("consent");
        }
        if capture.backend == CaptureBackend::Portal && !capture.portal_granted {
            missing.push("portal_grant");
        }
        (if missing.is_empty() { "granted" } else { "needs_grant" }, missing)
    };
    let display = match capture.size {
        Some((width, height)) if matches!(state, "granted" | "needs_grant") => json!({
            "capture": capture.backend.name(),
            "width": width,
            "height": height,
        }),
        _ => Value::Null,
    };
    // `getimage` is a slower capture than `xshm`: the status says so, not only a log.
    let capture_backend = match (capture.backend, capture.readback) {
        (CaptureBackend::Portal, _) => Some("portal"),
        (CaptureBackend::X11, readback) => readback.map(Readback::name),
    };
    json!({
        "schema": SCHEMA,
        "platform": "linux",
        "state": state,
        "capture_backend": capture_backend,
        "control": facts.enabled && applies_input && consent.is_some_and(|c| c.full),
        "display": display,
        "helperVersion": version,
        "missing": missing,
        "shares": shares,
    })
}

#[cfg(test)]
#[path = "status_json_tests.rs"]
mod tests;
