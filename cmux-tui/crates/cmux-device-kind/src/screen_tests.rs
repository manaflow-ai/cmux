use super::*;
use crate::DeviceKind;

/// Leo, 2026-11-15: "and why dont' i see the other linked up vms and such? and [a Linux desktop]?" Every
/// kind of linked machine has an answer on the Screen Sharing page: Macs and Cloud machines a
/// View, every other kind its reason, so no machine is left off and no row has a dead button.
#[test]
fn every_kind_says_what_the_screen_sharing_page_offers() {
    let view = |route| Screen::View { route };
    let none = |reason| Screen::None { reason };
    for kind in [
        DeviceKind::MacBook,
        DeviceKind::MacMini,
        DeviceKind::IMac,
        DeviceKind::MacStudio,
        DeviceKind::MacPro,
    ] {
        assert_eq!(offer(kind, None, true), view(ScreenRoute::Hub), "{kind}");
        assert_eq!(offer(kind, None, false), none(NoScreen::Offline), "{kind}");
    }
    // A Cloud machine's desktop opens (and resumes a paused machine) from any state.
    assert_eq!(offer(DeviceKind::Cloud, None, false), view(ScreenRoute::Cloud));
    // A headless Linux server or VM has no desktop. A Linux desktop is viewed through the device
    // hub like a Mac (`cmux-rd linux-host`), and is offline the same way.
    assert_eq!(offer(DeviceKind::LinuxServer, Some("linux"), true), none(NoScreen::NoDesktop));
    assert_eq!(offer(DeviceKind::LinuxDesktop, Some("linux"), true), view(ScreenRoute::Hub));
    assert_eq!(offer(DeviceKind::LinuxDesktop, Some("linux"), false), none(NoScreen::Offline));
    assert_eq!(offer(DeviceKind::IPhone, None, true), none(NoScreen::Phone));
    assert_eq!(offer(DeviceKind::IPad, None, true), none(NoScreen::Phone));
    // An older peer that reports no kind: its OS still tells a Mac. A Linux one may be a desktop
    // or a server, so it is listed as unknown rather than given a button that may be dead.
    assert_eq!(offer(DeviceKind::Generic, Some("macOS"), true), view(ScreenRoute::Hub));
    assert_eq!(offer(DeviceKind::Generic, Some("macOS"), false), none(NoScreen::Offline));
    // A Windows PC (`cmux-rd windows-host`, platform "windows" on the device hub) is viewed the same way.
    assert_eq!(offer(DeviceKind::Generic, Some("windows"), true), view(ScreenRoute::Hub));
    assert_eq!(offer(DeviceKind::Generic, Some("Windows"), false), none(NoScreen::Offline));
    assert_eq!(offer(DeviceKind::Generic, Some("linux"), true), none(NoScreen::Unknown));
    assert_eq!(offer(DeviceKind::Generic, Some("android"), true), none(NoScreen::Phone));
    assert_eq!(offer(DeviceKind::Generic, None, true), none(NoScreen::Unknown));
    // Every kind has an answer.
    for kind in DeviceKind::ALL {
        let _ = offer(kind, None, true);
    }
}

/// The app reads the offer as `{"action": "view", "route": ...}` or `{"action": "none", "reason": ...}`.
#[test]
fn the_offer_goes_out_as_action_with_route_or_reason() {
    let wire = |s: Screen| serde_json::to_value(s).unwrap();
    assert_eq!(
        wire(Screen::View { route: ScreenRoute::Hub }),
        serde_json::json!({"action": "view", "route": "hub"})
    );
    assert_eq!(
        wire(Screen::View { route: ScreenRoute::Cloud }),
        serde_json::json!({"action": "view", "route": "cloud"})
    );
    for (reason, word) in [
        (NoScreen::Offline, "offline"),
        (NoScreen::NoDesktop, "no-desktop"),
        (NoScreen::Phone, "phone"),
        (NoScreen::NoScreenHost, "no-screen-host"),
        (NoScreen::SharingOff, "sharing-off"),
        (NoScreen::Unknown, "unknown"),
    ] {
        assert_eq!(
            wire(Screen::None { reason }),
            serde_json::json!({"action": "none", "reason": word})
        );
    }
}
