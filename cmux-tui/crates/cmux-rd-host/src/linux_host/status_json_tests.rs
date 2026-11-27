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
        readback: Some(Readback::Shm),
    }
}

#[test]
fn a_core_getimage_capture_says_so_in_the_status() {
    let v = status_json(&ready(FULL, x11(Some((1920, 1080)))), "v");
    assert_eq!(v["capture_backend"], "xshm");
    let slow = Capture { readback: Some(Readback::Core), ..x11(Some((1920, 1080))) };
    assert_eq!(status_json(&ready(FULL, slow), "v")["capture_backend"], "getimage");
    let unknown = Capture { readback: None, usable: false, ..x11(None) };
    assert_eq!(status_json(&ready(FULL, unknown), "v")["capture_backend"], Value::Null);
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
            "capture_backend": "xshm",
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
    assert_eq!((v["state"].as_str(), v["shares"].as_str()), (Some("not_installed"), Some("none")));
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
        readback: None,
        portal_control: false,
    };
    let v = status_json(&ready(FULL, portal.clone()), "v");
    assert_eq!(v["capture_backend"], "portal");
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
            readback: None,
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
                                readback: None,
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
