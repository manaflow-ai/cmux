//! Ported from `MacScreenHomeDevicesTests` (Your Devices says none only after the list was read).
use super::*;

#[test]
fn your_devices_says_none_only_after_the_list_was_read() {
    let none = empty_note(&Discovery::NoDevices).english();
    assert_eq!(empty_note(&Discovery::Finding), empty_note(&Discovery::List));
    assert_ne!(empty_note(&Discovery::Finding).english(), none);
    let failed =
        empty_note(&Discovery::Failed { reason: ListFailure::List, detail: "HTTP 503".into() })
            .english();
    assert!(failed.contains("HTTP 503") && failed != none);
    let hub =
        empty_note(&Discovery::Failed { reason: ListFailure::Replaced, detail: String::new() });
    assert_eq!(hub.key.as_deref(), Some("macScreen.home.listFailed.hub"));
}

#[test]
fn rows_list_and_read_in_order() {
    let d = |id: &str, platform, shared| HomeDevice {
        id: id.into(),
        platform,
        online: true,
        mac_screen_shared: shared,
        ..Default::default()
    };
    let devices = [
        d("mac", Some(Platform::Macos), false),
        d("phone", Some(Platform::Ios), false),
        d("ipad", Some(Platform::Ios), true),
    ];
    assert_eq!(listed(&devices), ["mac", "ipad"]);
    assert_eq!(row_state(&devices[0]), RowState::SharingOff);
    assert_eq!(row_state(&devices[2]), RowState::Usable);
    assert_eq!(row_state(&HomeDevice { online: false, ..devices[2].clone() }), RowState::Offline);
    assert_eq!(
        row_state(&HomeDevice { online: false, online_known: false, ..devices[2].clone() }),
        RowState::Usable
    );
    assert_eq!(row_state(&d("pc", Some(Platform::Windows), true)), RowState::NotViewable);
    assert_eq!(
        row_state(&HomeDevice { access: Some("none".into()), ..devices[2].clone() }),
        RowState::Blocked
    );
    assert!(matches!(setup_devices(false, true), SetupDevices::Note { .. }));
    assert!(matches!(setup_devices(true, false), SetupDevices::SignedOut { .. }));
    assert!(shows_first_use(false, false) && !shows_first_use(false, true));
}
