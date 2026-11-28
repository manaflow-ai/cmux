use super::*;

#[test]
fn a_session_lives_by_id_until_closed() {
    let mut m = MacScreen::new();
    assert!(
        MacScreen::serves("mac_screen_session_event") && !MacScreen::serves("tab_discard_plan")
    );
    let open = m.call("mac_screen_session_open", json!({"id": "a"})).unwrap();
    assert_eq!(open["phase"], "ended");
    let reply = m
        .call(
            "mac_screen_session_event",
            json!({"id": "a", "event": {"event": "connect", "signaling": true, "process_started": true}}),
        )
        .unwrap();
    assert_eq!(reply["state"]["phase"], "connecting");
    assert_eq!(reply["effects"][1], json!({"effect": "schedule_deadline", "ms": 15000}));
    let reply = m
        .call(
            "mac_screen_session_event",
            json!({"id": "a", "event": {"event": "process_line", "line": {"path": {"kind": "direct_lan", "rtt_ms": 2.0}}}}),
        )
        .unwrap();
    assert_eq!(reply["path_label"]["key"], "macScreen.rd.pathLan");
    assert_eq!(
        m.call("mac_screen_session_state", json!({"id": "a"})).unwrap()["state"]["phase"],
        "connecting"
    );
    assert_eq!(m.call("mac_screen_session_close", json!({"id": "a"})).unwrap()["closed"], true);
    assert!(m.call("mac_screen_session_state", json!({"id": "a"})).is_err());
    assert!(m.call("mac_screen_nope", Value::Null).is_err());
}

#[test]
fn the_stateless_rules_answer() {
    let mut m = MacScreen::new();
    let w = m.call("mac_screen_wish", json!({"quality": "smooth", "refresh": 120})).unwrap();
    assert_eq!(w, json!({"max_width": 1920, "max_fps": 120}));
    let key = "ab".repeat(32);
    let offer = m.call("mac_screen_offer", json!({"key": key, "linked_display": 5})).unwrap();
    let text = offer["text"].as_str().unwrap().to_owned();
    assert!(text.contains("a=cmux-rd-display-id:5\r\n"));
    assert_eq!(m.call("mac_screen_doc_parse", json!({"text": text})).unwrap()["key"], key);
    assert_eq!(m.call("mac_screen_doc_parse", json!({"text": "v=0"})).unwrap(), Value::Null);
    let hidden = m
        .call("mac_screen_customize", json!({"text": text, "customize": {"show_cursor": false}}))
        .unwrap();
    assert!(hidden["text"].as_str().unwrap().contains("a=cmux-rd-cursor:0\r\n"));
    assert_eq!(
        m.call("mac_screen_lacks_display", json!({"text": text, "id": 5})).unwrap()["lacks"],
        false
    );
    assert_eq!(
        m.call("mac_screen_failure_cause", json!({"text": "link failed: x"})).unwrap(),
        json!({"link": "x"})
    );
    assert_eq!(
        m.call("mac_screen_host_end", json!({"text": "failed: y"})).unwrap(),
        json!({"host_failed": "y"})
    );
    assert_eq!(
        m.call("mac_screen_host_end", json!({"text": "stopped"})).unwrap(),
        json!("host_stopped_sharing")
    );
    let path = m.call("mac_screen_path", json!({"kind": "turn_relay"})).unwrap();
    assert_eq!(
        (path["relayed"].clone(), path["label"]["text"].clone()),
        (json!(true), json!("Relayed"))
    );
    let stages = m.call("mac_screen_stages", Value::Null).unwrap();
    assert_eq!(stages["stages"][0]["timeout_key"], "macScreen.card.noAnswer");
    assert_eq!(stages["connect_timeout_ms"], 15000);
}

#[test]
fn a_host_lives_by_id_until_closed() {
    let mut m = MacScreen::new();
    let session = json!({"id": "s", "viewer_id": "v", "view_only": false, "stun": [], "turn": []});
    m.call("mac_screen_host_open", json!({"id": "h", "session": session})).unwrap();
    let offer = RdDocument { key: "ab".repeat(32), ..RdDocument::default() }.text();
    let r = m
        .call(
            "mac_screen_host_input",
            json!({"id": "h", "input": {"input": "offer", "text": offer}}),
        )
        .unwrap();
    assert_eq!(r["effects"], json!([{"effect": "start_serve"}]));
    let r = m
        .call("mac_screen_host_input", json!({"id": "h", "input": {"input": "serve_started"}}))
        .unwrap();
    assert_eq!(r["effects"][1]["line"]["scope"], "control");
    let s = m.call("mac_screen_host_setup", json!({"session": session, "offer": offer})).unwrap();
    assert_eq!(s["display"], "main");
    assert_eq!(m.call("mac_screen_line_kinds", json!({"key": "k"})).unwrap()["kinds"], "key");
    assert_eq!(
        m.call("mac_screen_exclude_windows", json!({"ids": [9, 3, 9]})).unwrap(),
        json!({"exclude_windows": [3, 9]})
    );
    assert_eq!(m.call("mac_screen_host_close", json!({"id": "h"})).unwrap()["closed"], true);
    assert!(
        m.call("mac_screen_host_input", json!({"id": "h", "input": {"input": "bye"}})).is_err()
    );
}
