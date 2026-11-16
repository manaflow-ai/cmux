//! `cmux-rd linux-host status --json`: the screen-share host's state as the one JSON shape
//! cmux reads from every share host (`cmux.screen-share.status/1`; the Mac helper prints it
//! from `cmux-rd helper status --json`). [`status_json`] is a pure function of the facts
//! `status` gathers from local files and the local display only: it never contacts the hub
//! or the network, and a missing piece is a state, never an error, so it is safe to poll.

use super::consent::LocalConsent;
use crate::capture_backend::CaptureBackend;
use serde_json::{json, Value};

pub const SCHEMA: &str = "cmux.screen-share.status/1";

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
}

/// The `cmux.screen-share.status/1` document for `facts`, `version` being this binary's.
pub fn status_json(facts: &Facts, version: &str) -> Value {
    let _ = (facts, version, json!(null), SCHEMA);
    Value::Null
}

#[cfg(test)]
mod tests {
    use super::*;

    const FULL: LocalConsent = LocalConsent { view: true, full: true };
    const VIEW: LocalConsent = LocalConsent { view: true, full: false };

    fn x11(size: Option<(u32, u32)>) -> Capture {
        Capture { backend: CaptureBackend::X11, usable: true, size, portal_granted: false }
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
        };
        let v = status_json(&ready(FULL, portal.clone()), "v");
        assert_eq!(v["state"], "needs_grant");
        assert_eq!(missing(&v), ["portal_grant"]);
        // The portal applies no input: control allowed is still view only.
        assert_eq!(v["control"], false);
        assert_eq!(v["shares"], "view");
        let v = status_json(&ready(FULL, Capture { portal_granted: true, ..portal }), "v");
        assert_eq!(v["state"], "granted");
        assert!(missing(&v).is_empty());
        assert_eq!(v["shares"], "view");
        assert_eq!(v["control"], false);
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
                                let capture =
                                    Capture { backend, usable, size: None, portal_granted };
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
