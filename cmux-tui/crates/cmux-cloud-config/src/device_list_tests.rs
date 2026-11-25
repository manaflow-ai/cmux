use super::*;

fn device(id: &str, name: &str) -> Device {
    Device { id: id.into(), name: name.into(), platform: Some("macos".into()), ..Device::default() }
}

fn this(id: &str) -> This {
    This { id: id.into(), ..This::default() }
}

#[test]
fn this_macs_other_builds_are_this_mac_not_remotes() {
    // One Mac: NIGHTLY's record (this build), DEV's and a renewed one, plus Laptop.
    let devices = [
        device("dev", "Desk Mac"),
        device("nightly", "Desk Mac"),
        Device { online: true, mac_screen_shared: true, ..device("air", "Laptop") },
        device("old", "desk-mac"),
    ];
    let listing = listing(&this("nightly"), &devices);
    assert_eq!(listing.this_device, ["nightly", "dev", "old"]);
    assert_eq!(listing.others, [Machine { id: "air".into(), ids: vec!["air".into()] }]);
}

#[test]
fn one_row_per_other_device_showing_the_record_to_reach() {
    let devices = [
        Device { last_seen_at: Some(10.0), ..device("a1", "Studio") },
        Device { last_seen_at: Some(30.0), ..device("a2", "studio") },
        Device { online: true, ..device("a3", "Studio") },
        device("me", "Laptop"),
        Device { online: true, mac_screen_shared: true, ..device("b1", "Mini") },
        Device { online: true, ..device("b2", "Mini") },
    ];
    let listing = listing(&this("me"), &devices);
    assert_eq!(
        listing.others,
        [
            Machine { id: "a3".into(), ids: vec!["a3".into(), "a1".into(), "a2".into()] },
            Machine { id: "b1".into(), ids: vec!["b1".into(), "b2".into()] },
        ]
    );
}

#[test]
fn offline_records_pick_the_newest_seen() {
    let devices = [
        Device { last_seen_at: Some(30.0), ..device("new", "Studio") },
        Device { last_seen_at: Some(10.0), ..device("old", "Studio") },
    ];
    assert_eq!(listing(&this("me"), &devices).others[0].id, "new");
}

#[test]
fn names_fold_punctuation_case_and_typographic_quotes() {
    assert_eq!(key("x", "Leo’s Mac", None), key("y", "leos-mac", Some("macos")));
    assert_ne!(key("x", "Leo's Mac", Some("macos")), key("y", "Leo's Mac", Some("ios")));
    // A name with no letters or digits never merges.
    assert_ne!(key("x", "--", None), key("y", "--", None));
}

#[test]
fn platforms_never_merge_and_phones_reinstalled_collapse() {
    let devices = [
        Device { platform: Some("ios".into()), ..device("p1", "Leo’s iPhone") },
        Device { platform: Some("ios".into()), online: true, ..device("p2", "Leo's iPhone") },
        Device { platform: Some("linux".into()), ..device("l1", "Leo's iPhone") },
    ];
    let listing = listing(&this("me"), &devices);
    assert_eq!(listing.others.iter().map(|m| m.id.as_str()).collect::<Vec<_>>(), ["p2", "l1"]);
}

#[test]
fn before_the_hub_lists_this_device_its_name_still_marks_it() {
    let devices = [device("dev", "Desk Mac"), device("air", "Laptop")];
    let mine = This {
        id: "nightly".into(),
        name: Some("Desk Mac".into()),
        platform: Some("macos".into()),
    };
    let listing = listing(&mine, &devices);
    assert_eq!(listing.this_device, ["nightly", "dev"]);
    assert_eq!(listing.others.len(), 1);
}

#[test]
fn a_renamed_or_blank_own_record_still_marks_this_macs_builds_by_its_registered_name() {
    let devices = [device("nightly", ""), device("dev", "Desk Mac"), device("air", "Laptop")];
    let mine = This {
        id: "nightly".into(),
        name: Some("Desk Mac".into()),
        platform: Some("macos".into()),
    };
    assert_eq!(listing(&mine, &devices).this_device, ["nightly", "dev"]);
}

fn ready(connection: &str) -> DiscoveryInput {
    DiscoveryInput {
        status: "ready".into(),
        connection: connection.into(),
        ..DiscoveryInput::default()
    }
}

#[test]
fn a_registered_hub_whose_list_was_never_read_is_finding_not_none() {
    // Leo, 2026-11-19 (ask-6a79af928f): `ready` comes at registration, before the list is read.
    for connection in ["connecting", "connected", "disconnected"] {
        assert_eq!(discovery(&ready(connection)), Discovery::Finding, "{connection}");
    }
    assert_eq!(
        discovery(&DiscoveryInput { status: "starting".into(), ..DiscoveryInput::default() }),
        Discovery::Finding
    );
}

#[test]
fn none_only_after_a_read_succeeded() {
    assert_eq!(discovery(&DiscoveryInput { listed: true, ..ready("connected") }), Discovery::None);
    assert_eq!(
        discovery(&DiscoveryInput { listed: true, shown: 2, ..ready("connected") }),
        Discovery::List
    );
}

#[test]
fn a_failed_read_says_why_even_after_an_earlier_read() {
    let input =
        DiscoveryInput { listed: true, list_error: Some("HTTP 500".into()), ..ready("connected") };
    assert_eq!(
        discovery(&input),
        Discovery::Failed { reason: FailReason::List, detail: Some("HTTP 500".into()) }
    );
}

#[test]
fn a_hub_or_socket_that_fails_is_a_reason_not_none() {
    let hub = DiscoveryInput {
        status: "failed".into(),
        status_detail: Some("offline".into()),
        ..DiscoveryInput::default()
    };
    assert_eq!(
        discovery(&hub),
        Discovery::Failed { reason: FailReason::Hub, detail: Some("offline".into()) }
    );
    let socket =
        DiscoveryInput { connection_detail: Some("timed out".into()), ..ready("reconnecting") };
    assert_eq!(
        discovery(&socket),
        Discovery::Failed { reason: FailReason::Connection, detail: Some("timed out".into()) }
    );
    for (connection, reason) in [
        ("replaced", FailReason::Replaced),
        ("removed", FailReason::Removed),
        ("signedOut", FailReason::SignedOut),
    ] {
        assert_eq!(discovery(&ready(connection)), Discovery::Failed { reason, detail: None });
    }
}
