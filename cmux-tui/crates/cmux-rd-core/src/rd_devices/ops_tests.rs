use super::*;

#[test]
fn a_setup_run_lives_by_device_until_dismissed() {
    let mut d = RdDevices::new();
    assert!(RdDevices::serves("rd_devices_setup_row") && !RdDevices::serves("tab_discard_plan"));
    let row =
        d.call("rd_devices_setup_row", json!({"id": "m", "is_mac": true, "online": true})).unwrap();
    assert_eq!(
        (row["shows_setup"].clone(), row["shows_start"].clone()),
        (json!(false), json!(false))
    );
    assert_eq!(
        d.call("rd_devices_setup_run", json!({"id": "m", "verb": "setup"})).unwrap()["started"],
        false
    );
    d.call("rd_devices_setup_set_runner", json!({"on": true})).unwrap();
    let row =
        d.call("rd_devices_setup_row", json!({"id": "m", "is_mac": true, "online": true})).unwrap();
    assert_eq!(row["shows_setup"], true);
    assert_eq!(
        d.call("rd_devices_setup_run", json!({"id": "m", "verb": "setup"})).unwrap()["started"],
        true
    );
    let taken = d
        .call(
            "rd_devices_setup_line",
            json!({"id": "m", "text": r#"{"step":"daemon","state":"ok"}"#}),
        )
        .unwrap();
    assert_eq!(taken["taken"], true);
    assert_eq!(
        d.call("rd_devices_setup_line", json!({"id": "m", "text": "noise"})).unwrap()["taken"],
        false
    );
    let ended = d.call("rd_devices_setup_end", json!({"id": "m"})).unwrap();
    assert_eq!(ended["ended"]["succeeded"], true);
    assert_eq!(d.call("rd_devices_setup_dismiss", json!({"id": "m"})).unwrap()["dismissed"], true);
    assert!(d.call("rd_devices_nope", Value::Null).is_err());
}

#[test]
fn the_stateless_rules_answer() {
    let mut d = RdDevices::new();
    assert_eq!(
        d.call("rd_devices_duration_text", json!({"seconds": 1347})).unwrap(),
        json!("22m 27s")
    );
    assert_eq!(
        d.call("rd_devices_redials", json!({"connection": "reconnecting"})).unwrap(),
        json!(true)
    );
    let status =
        d.call("rd_devices_status", json!({"hub": "ready", "connection": "connected"})).unwrap();
    assert_eq!(status["status"]["tone"], "success");
    let rows = d
        .call(
            "rd_devices_history",
            json!({"entries": [{"id": "e", "event": "ended", "viewerId": "v", "detail": "bye", "durationS": 8}], "names": {"v": "Laptop"}}),
        )
        .unwrap();
    assert_eq!(
        (rows[0]["device"]["text"].clone(), rows[0]["duration"].clone()),
        (json!("Laptop"), json!("8s"))
    );
    let bad = d
        .call(
            "rd_devices_relay_validate",
            json!({"draft": {"name": "", "urls": [], "mode": "static"}}),
        )
        .unwrap();
    assert_eq!(bad["error"]["key"], "devices.error.name");
    assert_eq!(
        d.call("rd_devices_check_result", json!({"outcome": "relayed"})).unwrap()["tone"],
        "success"
    );
    assert_eq!(
        d.call("rd_devices_error_message", json!({"kind": "hub", "code": "device_removed"}))
            .unwrap()["key"],
        "devices.error.gone"
    );
    assert_eq!(
        d.call("rd_devices_relay_mode", json!("static")).unwrap()["key"],
        "devices.relay.modeStatic"
    );
    assert_eq!(
        d.call("rd_devices_home_listed", json!({"devices": [{"id": "p", "platform": "ios"}]}))
            .unwrap(),
        json!([])
    );
    assert_eq!(
        d.call("rd_devices_home_empty_note", json!({"discovery": "finding"})).unwrap()["key"],
        "macScreen.home.devicesLoading"
    );
    assert_eq!(d.call("rd_devices_home_row_state", json!({"id": "x"})).unwrap(), json!("offline"));
    assert_eq!(
        d.call("rd_devices_reconcile", json!({"url": "https://h", "user": "u"})).unwrap()["action"],
        "restart"
    );
    assert_eq!(
        d.call("rd_devices_startup_error", json!({"error": "keychain", "status": -25300})).unwrap(),
        json!("device_identity_keychain_-25300")
    );
    assert_eq!(d.call("rd_devices_build_space", json!({})).unwrap()["allows_remote_hub"], true);
}
