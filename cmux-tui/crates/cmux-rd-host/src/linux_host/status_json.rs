//! `cmux-rd linux-host status --json`: the screen-share host's state as the one JSON shape
//! cmux reads from every share host (`cmux.screen-share.status/1`; the Mac helper prints it
//! from `cmux-rd helper status --json`). [`status_json`] is a pure function of the facts
//! [`gather`] reads from local files and the local display only: it never contacts the hub
//! or the network, and a missing piece is a state, never an error, so it is safe to poll.
//!
//! Not seen locally: a desktop the hub removed (`device_removed`) or whose key it refuses.
//! Only the hub knows that; `run` exits with `EXIT_NEEDS_SETUP` when it hears it.

use super::consent::LocalConsent;
use super::identity::{self, Account, Device};
use crate::capture_backend::{x_display, CaptureBackend};
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
            let display = x_display(None, None, std::env::var("DISPLAY").ok().as_deref());
            // Only a local display is probed: a `host:N` display is a TCP connection.
            let local = display.starts_with(':') || display.starts_with("unix:");
            let size = local.then(|| x11_root_size(&display)).flatten();
            Capture {
                backend,
                usable: !local || size.is_some(),
                size,
                portal_granted: false,
                portal_control: false,
            }
        }
        CaptureBackend::Portal => Capture {
            backend,
            usable: backend.available().is_ok() && session_bus(),
            size: None,
            portal_granted: portal_token_saved(),
            portal_control: crate::capture_backend::portal_control_granted(),
        },
    }
}

/// The root window size of the X display, when it accepts a connection.
fn x11_root_size(display: &str) -> Option<(u32, u32)> {
    use x11rb::connection::Connection;
    let (conn, screen) = x11rb::connect(Some(display)).ok()?;
    let root = conn.setup().roots.get(screen)?;
    Some((root.width_in_pixels.into(), root.height_in_pixels.into()))
}

/// Whether there is a session bus to reach the portal on (no call is made).
fn session_bus() -> bool {
    std::env::var_os("DBUS_SESSION_BUS_ADDRESS").is_some_and(|v| !v.is_empty())
        || std::env::var_os("XDG_RUNTIME_DIR")
            .filter(|v| !v.is_empty())
            .is_some_and(|dir| std::path::Path::new(&dir).join("bus").exists())
}

/// Whether a portal restore token (the grant `enable` makes, refreshed by every share) is
/// saved, so Start shows no dialog.
#[cfg(feature = "portal")]
fn portal_token_saved() -> bool {
    crate::portal::any_grant_saved()
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
    json!({
        "schema": SCHEMA,
        "platform": "linux",
        "state": state,
        "control": facts.enabled && applies_input && consent.is_some_and(|c| c.full),
        "display": display,
        "helperVersion": version,
        "missing": missing,
        "shares": shares,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const FULL: LocalConsent = LocalConsent { view: true, full: true };
    const VIEW: LocalConsent = LocalConsent { view: true, full: false };

    fn x11(size: Option<(u32, u32)>) -> Capture {
        Capture {
            backend: CaptureBackend::X11,
            usable: true,
            size,
            portal_granted: false,
            portal_control: false,
        }
    }

    fn ready(consent: LocalConsent, capture: Capture) -> Facts {
        Facts { enabled: true, setup_ok: true, consent: Some(consent), capture }
    }

    fn missing(v: &Value) -> Vec<&str> {
        v["missing"].as_array().unwrap().iter().map(|m| m.as_str().unwrap()).collect()
    }

    #[test]
    fn granted_x11_with_control_has_every_field() {
        let v = status_json(&ready(FULL, x11(Some((1920, 1080)))), "1.2.3");
        assert_eq!(
            v,
            json!({
                "schema": "cmux.screen-share.status/1",
                "platform": "linux",
                "state": "granted",
                "control": true,
                "display": {"capture": "x11", "width": 1920, "height": 1080},
                "helperVersion": "1.2.3",
                "missing": [],
                "shares": "view_and_control",
            })
        );
    }

    #[test]
    fn view_consent_shares_view_without_control() {
        let v = status_json(&ready(VIEW, x11(Some((800, 600)))), "v");
        assert_eq!(v["state"], "granted");
        assert_eq!(v["control"], false);
        assert_eq!(v["shares"], "view");
    }

    #[test]
    fn unknown_size_reports_no_display() {
        let v = status_json(&ready(VIEW, x11(None)), "v");
        assert_eq!(v["state"], "granted");
        assert_eq!(v["display"], Value::Null);
    }

    #[test]
    fn no_device_is_not_installed() {
        let facts = Facts { enabled: false, setup_ok: false, consent: None, capture: x11(None) };
        let v = status_json(&facts, "v");
        assert_eq!(v["state"], "not_installed");
        assert_eq!(v["display"], Value::Null);
        assert_eq!(v["control"], false);
        assert_eq!(v["shares"], "none");
        assert!(missing(&v).is_empty());
        // A stale consent file without a device shares nothing.
        let stale = Facts { consent: Some(FULL), capture: x11(Some((1, 1))), ..facts };
        let v = status_json(&stale, "v");
        assert_eq!(
            (v["state"].as_str(), v["shares"].as_str()),
            (Some("not_installed"), Some("none"))
        );
        assert_eq!(v["control"], false);
        assert_eq!(v["display"], Value::Null);
    }

    #[test]
    fn no_display_and_no_portal_is_unsupported() {
        let capture = Capture { usable: false, ..x11(None) };
        let v = status_json(&ready(VIEW, capture), "v");
        assert_eq!(v["state"], "unsupported");
        assert_eq!(v["display"], Value::Null);
        assert!(missing(&v).is_empty());
        // Even with a size known, an unusable capture shows no display.
        let capture = Capture { usable: false, ..x11(Some((10, 10))) };
        assert_eq!(status_json(&ready(VIEW, capture), "v")["display"], Value::Null);
    }

    #[test]
    fn missing_consent_needs_consent_and_shares_nothing() {
        let facts = Facts { consent: None, ..ready(FULL, x11(Some((640, 480)))) };
        let v = status_json(&facts, "v");
        assert_eq!(v["state"], "needs_grant");
        assert_eq!(missing(&v), ["consent"]);
        assert_eq!(v["shares"], "none");
        assert_eq!(v["control"], false);
        assert_eq!(v["display"], json!({"capture": "x11", "width": 640, "height": 480}));
    }

    #[test]
    fn consent_allowing_nothing_shares_none() {
        let none = LocalConsent { view: false, full: false };
        assert_eq!(status_json(&ready(none, x11(None)), "v")["shares"], "none");
    }

    #[test]
    fn portal_without_a_restore_token_needs_a_portal_grant() {
        let portal = Capture {
            backend: CaptureBackend::Portal,
            usable: true,
            size: None,
            portal_granted: false,
            portal_control: false,
        };
        let v = status_json(&ready(FULL, portal.clone()), "v");
        assert_eq!(v["state"], "needs_grant");
        assert_eq!(missing(&v), ["portal_grant"]);
        // Without a RemoteDesktop grant the portal applies no input: control allowed is still
        // view only.
        assert_eq!(v["control"], false);
        assert_eq!(v["shares"], "view");
        let screen_cast = Capture { portal_granted: true, ..portal.clone() };
        let v = status_json(&ready(FULL, screen_cast), "v");
        assert_eq!(v["state"], "granted");
        assert!(missing(&v).is_empty());
        assert_eq!(v["shares"], "view");
        assert_eq!(v["control"], false);
        // The RemoteDesktop grant: the portal controls too.
        let remote = Capture { portal_granted: true, portal_control: true, ..portal };
        let v = status_json(&ready(FULL, remote), "v");
        assert_eq!(v["shares"], "view_and_control");
        assert_eq!(v["control"], true);
    }

    #[test]
    fn signed_out_or_expired_needs_setup() {
        let facts = Facts { setup_ok: false, ..ready(FULL, x11(Some((2, 2)))) };
        let v = status_json(&facts, "v");
        assert_eq!(v["state"], "needs_grant");
        assert_eq!(missing(&v), ["setup"]);
    }

    #[test]
    fn every_missing_piece_is_listed() {
        let facts = Facts {
            enabled: true,
            setup_ok: false,
            consent: None,
            capture: Capture {
                backend: CaptureBackend::Portal,
                usable: true,
                size: None,
                portal_granted: false,
                portal_control: false,
            },
        };
        let v = status_json(&facts, "v");
        assert_eq!(v["state"], "needs_grant");
        assert_eq!(missing(&v), ["setup", "consent", "portal_grant"]);
    }

    #[test]
    fn missing_is_empty_exactly_when_granted() {
        for enabled in [false, true] {
            for setup_ok in [false, true] {
                for consent in [None, Some(VIEW), Some(FULL)] {
                    for backend in [CaptureBackend::X11, CaptureBackend::Portal] {
                        for usable in [false, true] {
                            for portal_granted in [false, true] {
                                let capture = Capture {
                                    backend,
                                    usable,
                                    size: None,
                                    portal_granted,
                                    portal_control: false,
                                };
                                let facts = Facts { enabled, setup_ok, consent, capture };
                                let v = status_json(&facts, "v");
                                let granted = v["state"] == "granted";
                                let actionable =
                                    matches!(v["state"].as_str(), Some("granted" | "needs_grant"));
                                if actionable {
                                    assert_eq!(missing(&v).is_empty(), granted, "{facts:?}");
                                }
                                assert_eq!(v["schema"], SCHEMA);
                                assert_eq!(v["platform"], "linux");
                            }
                        }
                    }
                }
            }
        }
    }
}
