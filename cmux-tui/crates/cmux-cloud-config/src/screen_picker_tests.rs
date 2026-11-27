use super::*;

fn machine(id: &str, name: &str, platform: &str) -> Machine {
    Machine {
        id: id.into(),
        name: name.into(),
        platform: Some(platform.into()),
        online: true,
        online_known: true,
        mac_screen_shared: true,
        allows_requests: true,
    }
}

fn states(rows: &[Row]) -> Vec<(&str, State)> {
    rows.iter().map(|row| (row.id.as_str(), row.state)).collect()
}

#[test]
fn a_viewable_mac_and_linux_desktop_open_in_one_click() {
    let rows =
        rows(&[machine("mac", "cosmic-gray", "macos"), machine("box", "linux-box", "linux")]);
    assert_eq!(states(&rows), [("mac", State::View), ("box", State::View)]);
    assert!(rows.iter().all(|row| row.opens && row.fix.is_none()));
    assert_eq!(rows[0].symbol, "desktopcomputer");
    assert_eq!(rows[1].symbol, "pc");
}

#[test]
fn a_machine_that_cannot_be_viewed_says_why_and_who_fixes_it() {
    // Leo, 2026-11-18: "idk why that was greyed".
    let rows = rows(&[
        Machine { mac_screen_shared: false, ..machine("off", "cosmic-gray", "macos") },
        Machine { allows_requests: false, ..machine("no", "studio", "macos") },
        Machine { online: false, ..machine("gone", "mini", "macos") },
        machine("ok", "air-blue", "macos"),
    ]);
    assert_eq!(
        states(&rows),
        [
            ("ok", State::View),
            ("off", State::SharingOff),
            ("no", State::NotAllowed),
            ("gone", State::Offline)
        ]
    );
    assert_eq!(rows[1].fix, Some(Fix::ShareThisMac));
    assert_eq!(rows[2].fix, Some(Fix::DeviceAccess));
    assert_eq!(rows[3].fix, None);
    assert!(!rows[1].opens && !rows[2].opens && !rows[3].opens);
}

#[test]
fn offline_is_not_believed_while_the_hub_link_is_down() {
    let rows =
        rows(&[Machine { online: false, online_known: false, ..machine("m", "Studio", "macos") }]);
    assert_eq!(states(&rows), [("m", State::View)]);
}

#[test]
fn phones_list_only_while_they_share_and_unknown_platforms_never() {
    let rows = rows(&[
        Machine { mac_screen_shared: false, ..machine("p1", "iPhone", "ios") },
        machine("p2", "Pad", "ios"),
        machine("w", "pc", "windows"),
        machine("blank", "  ", "macos"),
        Machine { platform: None, ..machine("old", "Old Mac", "macos") },
    ]);
    assert_eq!(states(&rows), [("p2", State::View), ("old", State::View)]);
    assert_eq!(rows[0].symbol, "iphone");
}

#[test]
fn reads_the_apps_request_with_defaults() {
    let machine: Machine = serde_json::from_str(r#"{"id":"a","name":"A"}"#).unwrap();
    assert!(machine.online_known && machine.allows_requests && !machine.online);
}
