use super::*;

#[test]
fn a_failed_link_says_when_billing_could_not_be_read() {
    let note = Some("could not read your plan");
    assert_eq!(
        with_relay_note("the link failed: the secure handshake timed out".into(), note),
        "the link failed: the secure handshake timed out; no relay: could not read your plan"
    );
    assert_eq!(with_relay_note("the link failed: x".into(), None), "the link failed: x");
    assert_eq!(with_relay_note("the window was closed".into(), note), "the window was closed");
}

fn devices() -> Value {
    json!({"devices": [
        {"id": "aaaa1111-0000", "name": "Me", "platform": "linux", "macScreenShared": true, "online": true},
        {"id": "bbbb2222-0000", "name": "Studio", "platform": "macos", "macScreenShared": 1, "online": 1},
        {"id": "cccc3333-0000", "name": "Laptop", "platform": "macos", "macScreenShared": true, "online": false},
        {"id": "dddd4444-0000", "name": "Phone", "platform": "ios", "macScreenShared": false, "online": true},
    ]})
}

#[test]
fn only_other_shared_devices_are_offered_online_first() {
    let list = shared_devices(&devices(), "aaaa1111-0000");
    let ids: Vec<&str> = list.iter().map(|d| d.id.as_str()).collect();
    assert_eq!(ids, ["bbbb2222-0000", "cccc3333-0000"]);
    assert!(list[0].online && !list[1].online);
}

#[test]
fn a_device_is_picked_by_id_prefix_or_name_or_as_the_only_one_online() {
    let list = shared_devices(&devices(), "aaaa1111-0000");
    assert_eq!(pick(&list, None).unwrap().name, "Studio");
    assert_eq!(pick(&list, Some("cccc")).unwrap().name, "Laptop");
    assert_eq!(pick(&list, Some("studio")).unwrap().id, "bbbb2222-0000");
    assert!(pick(&list, Some("nope")).is_err());
    let two_online: Vec<HostDevice> = list
        .iter()
        .cloned()
        .map(|mut d| {
            d.online = true;
            d
        })
        .collect();
    assert!(pick(&two_online, None).unwrap_err().to_string().contains("several"));
}

#[test]
fn a_whole_device_id_this_account_does_not_list_is_asked_of_the_hub() {
    let list = shared_devices(&devices(), "aaaa1111-0000");
    // Another account's machine: the hub answers (and refuses), not this list.
    let other = "0f1e2d3c-4b5a-4697-8877-665544332211";
    let host = pick(&list, Some(other)).unwrap();
    assert_eq!((host.id.as_str(), host.online), (other, false));
    // A name or a prefix that matches nothing is still this list's error.
    assert!(pick(&list, Some("0f1e2d3c")).is_err());
    assert!(pick(&list, Some("0f1e2d3c-4b5a-4697-8877-66554433221")).is_err());
    assert!(pick(&list, Some("zf1e2d3c-4b5a-4697-8877-665544332211")).is_err());
    assert!(device_id_shaped(other));
    assert!(!device_id_shaped("bbbb2222-0000"));
    // The hub's refusal names its code.
    let refused: Box<dyn std::error::Error + Send + Sync> = Box::new(HubError {
        status: 404,
        code: "not_found".into(),
        message: "device not found".into(),
    });
    let said = explain_request(refused, other).to_string();
    assert!(said.contains("is no device of this account (device hub 404 not_found)"), "{said}");
}

#[test]
fn the_offer_is_signed_for_the_viewer_role() {
    let hub = Hub::new("https://hub.example", Device::generate("t").unwrap(), None).unwrap();
    let doc = RdDocument { key: "ab".repeat(32), max_width: Some(1920), ..RdDocument::default() };
    let frame: Value =
        serde_json::from_str(&signed_frame("offer", &doc.text(), "sid-1", &hub).unwrap()).unwrap();
    let key = hub.device.signer().unwrap().public_key();
    let sdp = frame["sdp"].as_str().unwrap();
    let sig = frame["fpSig"].as_str().unwrap();
    assert!(rd_doc::verify_fp_sig(sdp, sig, "sid-1", "viewer", &key));
    assert!(!rd_doc::verify_fp_sig(sdp, sig, "sid-1", "host", &key));
    assert_eq!(RdDocument::parse(sdp).unwrap().max_width, Some(1920));
}

#[test]
fn session_keys_round_trip_as_hex() {
    let key = [7u8; 32];
    assert_eq!(unhex32(&hex(&key)), Some(key));
    assert_eq!(unhex32("zz"), None);
}
