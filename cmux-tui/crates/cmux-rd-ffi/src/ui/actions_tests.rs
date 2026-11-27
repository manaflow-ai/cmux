//! Parity with `MacScreenActionRoutingTests` (device resolution, no-screen refusals) and the
//! `record`/stop-sharing branches of `MacScreenActions`.

use serde_json::json;

use super::*;

const DEVICE: &str = "0f6c2d6a-1b2c-4d3e-8f40-5a6b7c8d9e0f";
const OTHER: &str = "5d1e0f2a-6b7c-4d8e-9f01-23456789abcd";
const THIRD: &str = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d";

fn dev(id: &str, name: &str) -> Device {
    Device { id: id.into(), name: name.into(), online: false, mac_screen_shared: false }
}

fn live(id: &str, name: &str, online: bool, shared: bool) -> Device {
    Device { id: id.into(), name: name.into(), online, mac_screen_shared: shared }
}

fn ids(f: &Failure) -> Vec<&str> {
    f.listed.iter().map(|l| l.id.as_str()).collect()
}

#[test]
fn names_resolve_folded() {
    let devices = [dev(DEVICE, "Mac Mini"), dev(OTHER, "Studio")];
    for text in ["Mac Mini", "mac mini", "  MAC MINI ", "mac-mini"] {
        assert_eq!(device_id(text, &devices), Ok(DEVICE.into()), "{text}");
    }
}

#[test]
fn slug_resolves_curly_apostrophe() {
    let devices = [dev(DEVICE, "Leo’s Mac Studio")];
    assert_eq!(device_id("leo-s-mac-studio", &devices), Ok(DEVICE.into()));
}

#[test]
fn diacritics_and_width_fold() {
    let devices = [dev(DEVICE, "Café Mac")];
    assert_eq!(device_id("cafe mac", &devices), Ok(DEVICE.into()));
    assert_eq!(device_id("ＣＡＦＥ mac", &devices), Ok(DEVICE.into()));
    assert_eq!(device_id("Cafe\u{301} Mac", &devices), Ok(DEVICE.into()));
}

#[test]
fn uuid_passes_through_lowercased() {
    assert_eq!(device_id(&DEVICE.to_uppercase(), &[]), Ok(DEVICE.into()));
    assert_eq!(
        normalized_device_id(&format!("  {}\t", DEVICE.to_uppercase())),
        Some(DEVICE.into())
    );
    assert_eq!(normalized_device_id("not-a-uuid"), None);
    assert_eq!(normalized_device_id("0f6c2d6a1b2c4d3e8f405a6b7c8d9e0f"), None);
}

#[test]
fn peer_prefix_names_the_machine() {
    let devices = [dev(DEVICE, "desk-1")];
    assert_eq!(device_id("peer:desk-1", &devices), Ok(DEVICE.into()));
}

#[test]
fn ambiguous_lists_only_matches() {
    let devices = [dev(DEVICE, "Studio"), dev(OTHER, "studio"), dev(THIRD, "Mini")];
    let f = device_id("STUDIO", &devices).unwrap_err();
    assert_eq!(f.key, "macScreen.actions.ambiguousDevice");
    assert_eq!(f.name.as_deref(), Some("STUDIO"));
    assert_eq!(ids(&f), [DEVICE, OTHER]);
}

#[test]
fn folded_pass_wins_before_slug() {
    let devices = [dev(DEVICE, "mac-mini"), dev(OTHER, "Mac Mini")];
    assert_eq!(device_id("Mac-Mini", &devices), Ok(DEVICE.into()));
}

#[test]
fn slug_ambiguity_lists() {
    let devices = [dev(DEVICE, "mac-mini"), dev(OTHER, "Mac Mini")];
    let f = device_id("mac mini!", &devices).unwrap_err();
    assert_eq!(f.key, "macScreen.actions.ambiguousDevice");
    assert!(ids(&f).contains(&OTHER));
}

#[test]
fn one_live_registration_wins() {
    let devices = [
        live(DEVICE, "Studio", false, true),
        live(OTHER, "Studio", true, true),
        live(THIRD, "Studio", true, false),
    ];
    assert_eq!(device_id("Studio", &devices), Ok(OTHER.into()));
    let two = [live(DEVICE, "Studio", true, true), live(OTHER, "Studio", true, true)];
    assert!(device_id("Studio", &two).is_err());
    let none = [live(DEVICE, "Studio", false, true), live(OTHER, "Studio", true, false)];
    assert!(device_id("Studio", &none).is_err());
}

#[test]
fn unknown_and_missing() {
    let devices = [dev(DEVICE, "Studio"), dev(OTHER, "Mini")];
    let f = device_id("office-imac", &devices).unwrap_err();
    assert_eq!(f.key, "macScreen.actions.unknownDevice");
    assert_eq!(ids(&f), [DEVICE, OTHER]);
    assert_eq!(
        device_id("office-imac", &[]).unwrap_err().key,
        "macScreen.actions.unknownDeviceNoneListed"
    );
    for text in ["", "   "] {
        let f = device_id(text, &devices).unwrap_err();
        assert_eq!(f.key, "macScreen.actions.missingDevice");
        assert_eq!(ids(&f), [DEVICE, OTHER]);
    }
    assert_eq!(missing_device(&[]).key, "macScreen.actions.missingDeviceNoneListed");
}

#[test]
fn unlisted_names() {
    let devices = [dev(DEVICE, "Studio")];
    assert_eq!(unlisted_name(Some(&json!("office-imac")), &devices), Some("office-imac".into()));
    assert_eq!(unlisted_name(Some(&json!(" studio ")), &devices), None);
    assert_eq!(unlisted_name(Some(&json!(DEVICE)), &devices), None);
    assert_eq!(unlisted_name(Some(&json!("  ")), &devices), None);
    assert_eq!(unlisted_name(Some(&json!(3)), &devices), None);
    assert_eq!(unlisted_name(None, &devices), None);
}

#[test]
fn no_screen_reasons() {
    let listed = [
        listed_device("my-vm", Some("none"), None).unwrap(),
        listed_device("Studio", Some("none"), Some("offline")).unwrap(),
        listed_device("new-mac", Some("screen"), None).unwrap(),
    ];
    assert_eq!(listed_device("login", None, Some("offline")), None);
    assert_eq!(
        no_screen("my-vm", &listed),
        Some(NoScreen {
            name: "my-vm".into(),
            reason_key: "macScreen.actions.refusal.noScreen.unknown"
        })
    );
    assert_eq!(
        no_screen("studio", &listed),
        Some(NoScreen {
            name: "Studio".into(),
            reason_key: "macScreen.actions.refusal.noScreen.offline"
        })
    );
    assert_eq!(
        no_screen("new-mac", &listed).unwrap().reason_key,
        "macScreen.actions.refusal.noScreen.notRegistered"
    );
    assert_eq!(no_screen("office-imac", &listed), None);
    assert_eq!(
        no_screen_reason_key(Some("no-desktop")),
        "macScreen.actions.refusal.noScreen.noDesktop"
    );
    assert_eq!(no_screen_reason_key(Some("phone")), "macScreen.actions.refusal.noScreen.phone");
}

#[test]
fn open_plans() {
    let base = || OpenPlanArgs { has_device: true, ..Default::default() };
    assert_eq!(
        open_plan(&OpenPlanArgs::default()),
        OpenPlan { requesting: None, started_by: false }
    );
    assert_eq!(open_plan(&OpenPlanArgs { is_person: true, ..base() }).requesting, Some("view"));
    assert_eq!(open_plan(&base()), OpenPlan { requesting: None, started_by: false });
    let own = OpenPlanArgs { own_device: true, scope: Some(json!("FULL")), ..base() };
    assert_eq!(open_plan(&own), OpenPlan { requesting: Some("full"), started_by: true });
    let auto =
        OpenPlanArgs { autoconnect: Some(json!("True")), scope: Some(json!("full")), ..base() };
    assert_eq!(open_plan(&auto), OpenPlan { requesting: Some("view"), started_by: true });
    let gated =
        OpenPlanArgs { autoconnect: Some(json!(true)), only_person_starts_viewing: true, ..base() };
    assert_eq!(open_plan(&gated).requesting, None);
}

#[test]
fn scope_and_autoconnect_values() {
    assert_eq!(scope(Some(&json!("Full"))), "full");
    assert_eq!(scope(Some(&json!("view"))), "view");
    assert_eq!(scope(Some(&json!(1))), "view");
    assert_eq!(scope(None), "view");
    assert!(autoconnects(Some(&json!(true))));
    assert!(autoconnects(Some(&json!("TRUE"))));
    assert!(!autoconnects(Some(&json!("yes"))));
    assert!(!autoconnects(None));
}

#[test]
fn stop_sharing_and_refusals() {
    let s = |w, h| stop_sharing(&StopArgs { worker_running: w, hub_has_session: h });
    assert_eq!(s(false, true), StopSharing { unavailable: false, run: "hub" });
    assert_eq!(s(true, true).run, "hub");
    assert_eq!(s(true, false), StopSharing { unavailable: false, run: "worker" });
    assert_eq!(s(false, false), StopSharing { unavailable: true, run: "refuse" });
    let r = |n, u| refusal(&RefusalArgs { not_found: n, unlisted: u });
    assert_eq!(r(true, true), "notFound");
    assert_eq!(r(false, true), "waitListed");
    assert_eq!(r(false, false), "refused");
}

#[test]
fn targets() {
    assert!(open_target(None) && open_target(Some("pane")) && open_target(Some("tab")));
    assert!(!open_target(Some("workspace")));
    let t = |k: Option<&str>, id: Option<&str>, sel: Option<&str>| {
        screen_tab_id(&ScreenTabArgs {
            target_kind: k.map(Into::into),
            target_id: id.map(Into::into),
            selected: sel.map(Into::into),
        })
    };
    assert_eq!(t(Some("tab"), Some("t1"), Some("t2")), Some("t1".into()));
    assert_eq!(t(Some("pane"), Some("p1"), Some("t2")), None);
    assert_eq!(t(None, None, Some("t2")), Some("t2".into()));
}

#[test]
fn ops_through_handle() {
    let a = handle(
        "deviceId",
        &json!({"text": "mac mini", "devices": [{"id": DEVICE, "name": "Mac Mini"}]}),
    );
    assert_eq!(a, Some(Ok(json!({"id": DEVICE}))));
    let a = handle("deviceId", &json!({"text": "x", "devices": []})).unwrap().unwrap();
    assert_eq!(a["failure"]["key"], "macScreen.actions.unknownDeviceNoneListed");
    assert_eq!(handle("isViewer", &json!({"streaming": true})), Some(Ok(json!(true))));
    assert_eq!(
        handle("mayAutoconnect", &json!({"autoconnect": "true", "onlyPersonStartsViewing": true})),
        Some(Ok(json!(false)))
    );
    assert!(handle("nope", &json!({})).is_none());
}
