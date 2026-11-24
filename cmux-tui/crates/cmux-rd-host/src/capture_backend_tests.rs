use super::*;

#[test]
fn capture_option_names_x11_or_portal() {
    assert_eq!(CaptureBackend::parse("x11"), Ok(CaptureBackend::X11));
    assert_eq!(CaptureBackend::parse(" portal "), Ok(CaptureBackend::Portal));
    assert!(CaptureBackend::parse("vnc").is_err());
}

#[test]
#[cfg(feature = "link")]
fn wayland_session_picks_portal_and_x11_otherwise() {
    assert_eq!(CaptureBackend::choose(None, Some("wayland")), Ok(CaptureBackend::Portal));
    assert_eq!(CaptureBackend::choose(None, Some("Wayland")), Ok(CaptureBackend::Portal));
    assert_eq!(CaptureBackend::choose(None, Some("x11")), Ok(CaptureBackend::X11));
    assert_eq!(CaptureBackend::choose(None, Some("tty")), Ok(CaptureBackend::X11));
    assert_eq!(CaptureBackend::choose(None, None), Ok(CaptureBackend::X11));
}

#[test]
#[cfg(feature = "link")]
fn the_portal_applies_input_only_with_a_remote_desktop_grant() {
    // XTest injects input; the portal only through a granted RemoteDesktop session.
    assert!(CaptureBackend::X11.applies_input_with(false));
    assert!(!CaptureBackend::Portal.applies_input_with(false));
    assert!(CaptureBackend::Portal.applies_input_with(true));
    for backend in [CaptureBackend::X11, CaptureBackend::Portal] {
        assert_eq!(CaptureBackend::parse(backend.name()), Ok(backend));
    }
}

#[test]
#[cfg(feature = "link")]
fn explicit_override_wins() {
    assert_eq!(CaptureBackend::choose(Some("x11"), Some("wayland")), Ok(CaptureBackend::X11));
    assert_eq!(CaptureBackend::choose(Some("portal"), Some("x11")), Ok(CaptureBackend::Portal));
    assert_eq!(CaptureBackend::choose(Some(""), Some("wayland")), Ok(CaptureBackend::Portal));
    assert!(CaptureBackend::choose(Some("vnc"), None).is_err());
}

#[test]
#[cfg(not(all(feature = "portal", target_os = "linux")))]
fn portal_is_refused_with_a_clear_reason_until_built_in() {
    assert_eq!(CaptureBackend::X11.available(), Ok(()));
    let reason = CaptureBackend::Portal.available().unwrap_err();
    assert!(reason.starts_with("portal capture not built in"), "{reason}");
}

#[test]
#[cfg(all(feature = "portal", target_os = "linux", feature = "link"))]
fn portal_is_available_when_built_in() {
    assert_eq!(CaptureBackend::X11.available(), Ok(()));
    assert_eq!(CaptureBackend::Portal.available(), Ok(()));
}

#[test]
#[cfg(feature = "link")]
fn display_defaults_to_the_session_then_display_then_zero() {
    assert_eq!(x_display(Some(":5"), Some(":99"), Some(":1")), ":5");
    assert_eq!(x_display(Some("main"), Some(":99"), Some(":1")), ":99");
    assert_eq!(x_display(Some("0"), None, Some(":1")), ":1");
    assert_eq!(x_display(None, None, Some("localhost:10.0")), "localhost:10.0");
    assert_eq!(x_display(None, None, Some("")), ":0");
    assert_eq!(x_display(None, None, None), ":0");
}
