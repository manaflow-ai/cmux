//! Parity with `MacScreenSharingSectionTests`: the status line, dot, rows and Grant Access.

use super::*;

fn sharing(screen: bool, ax: bool, session: Option<(bool, &str)>) -> Sharing {
    Sharing {
        session: session.map(|(connected, scope)| Session { connected, scope: scope.into() }),
        screen_recording_granted: screen,
        accessibility_granted: ax,
        is_sharing: true,
        busy: false,
    }
}

#[test]
fn status_lines() {
    assert_eq!(status(&sharing(true, true, None)).status_text, key("macScreen.home.hubReady"));
    assert_eq!(
        status(&sharing(false, true, None)).status_text,
        key("macScreen.home.hubNeedsScreenRecording")
    );
    assert_eq!(status(&sharing(true, false, None)).status_text, key("macScreen.home.hubViewOnly"));
    assert_eq!(
        status(&sharing(false, false, Some((false, "view")))).status_text,
        keyed("macScreen.home.hubConnecting", &["$viewerName"])
    );
    assert_eq!(
        status(&sharing(true, true, Some((true, "view")))).status_text,
        keyed("macScreen.indicator.viewing", &["$viewerName"])
    );
    assert_eq!(
        status(&sharing(true, true, Some((true, "full")))).status_text,
        keyed("macScreen.indicator.controlling", &["$viewerName"])
    );
}

#[test]
fn status_inks() {
    assert_eq!(status(&sharing(false, false, Some((true, "view")))).status_ink, "litGlyph");
    assert_eq!(status(&sharing(false, true, None)).status_ink, "attention");
    assert_eq!(status(&sharing(false, true, Some((false, "view")))).status_ink, "success");
    assert_eq!(status(&sharing(true, false, None)).status_ink, "success");
}

#[test]
fn simple_rows() {
    let mut off = sharing(false, false, Some((true, "full")));
    off.is_sharing = false;
    let s = status(&off);
    assert_eq!(s.simple_detail, key("macScreen.home.shareThisMacOff"));
    assert_eq!(s.connected, None);
    assert_eq!(s.grant, None);
    assert_eq!(s.status_title, key("macScreen.home.allowToggleShort"));
    let s = status(&sharing(true, true, Some((true, "full"))));
    assert_eq!(s.simple_detail, key("macScreen.home.shareThisMacOn"));
    assert_eq!(
        s.connected,
        Some(Connected {
            text: keyed("macScreen.home.connectedControlling", &["$viewerName"]),
            ink: "litGlyph"
        })
    );
    let s = status(&sharing(true, true, Some((false, "view"))));
    assert_eq!(s.connected.unwrap().ink, "attention");
    assert_eq!(
        status(&sharing(true, false, None)).simple_detail,
        key("macScreen.home.hubViewOnly")
    );
}

#[test]
fn grant_access() {
    assert_eq!(status(&sharing(true, true, None)).grant, None);
    assert_eq!(status(&sharing(true, true, None)).open_settings, None);
    let g = status(&sharing(false, false, None)).grant.unwrap();
    assert_eq!(
        (g.title, g.detail, g.request),
        (key("macScreen.home.grantBoth"), key("macScreen.home.grantDetail"), "screenRecording")
    );
    let g = status(&sharing(false, true, None)).grant.unwrap();
    assert_eq!(g.title, key("macScreen.home.screenRecording"));
    let g = status(&sharing(true, false, None)).grant.unwrap();
    assert_eq!(
        (g.title, g.detail, g.request),
        (
            key("macScreen.home.accessibility"),
            key("macScreen.home.grantAccessibilityDetail"),
            "accessibility"
        )
    );
    assert_eq!(status(&sharing(true, false, None)).open_settings, Some("accessibility"));
}

#[test]
fn switch_follows_busy() {
    let mut s = sharing(true, true, None);
    assert!(status(&s).switch_enabled);
    s.busy = true;
    assert!(!status(&s).switch_enabled);
}
