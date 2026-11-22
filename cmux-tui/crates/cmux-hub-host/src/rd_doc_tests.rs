use super::*;
use crate::identity::Device;
use serde_json::json;

const KEY: &str = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff";

#[test]
fn documents_round_trip_like_the_mac() {
    let doc = RdDocument {
        key: KEY.into(),
        candidates: vec!["host 10.0.0.2:5000".into()],
        display: Some(1),
        max_width: Some(1920),
        max_fps: Some(60),
        encode_profile: Some("ultra".into()),
        displays: vec![(2560, 1440)],
        current_display: Some(0),
    };
    assert!(doc.text().contains("\r\na=cmux-rd-encode-profile:ultra\r\n"));
    let text = doc.text();
    assert!(text.starts_with("cmux.rd/1\r\na=fingerprint:cmux-rd-key 0011"));
    assert_eq!(RdDocument::parse(&text), Some(doc));
    assert_eq!(fingerprint_of(&text).as_deref(), Some(format!("cmux-rd-key {KEY}").as_str()));
}

#[test]
fn webrtc_offers_and_bad_keys_are_not_documents() {
    assert!(RdDocument::parse("v=0\r\na=fingerprint:sha-256 AB:CD\r\n").is_none());
    assert!(RdDocument::parse("cmux.rd/1\r\na=fingerprint:cmux-rd-key 1234\r\n").is_none());
    assert!(RdDocument::parse("cmux.rd/1\r\n").is_none());
}

#[test]
fn fp_sig_verifies_only_for_the_peer_role_and_key() {
    let viewer = Device::generate("viewer").unwrap().signer().unwrap();
    let other = Device::generate("other").unwrap().signer().unwrap();
    let sdp = RdDocument { key: KEY.into(), ..RdDocument::default() }.text();
    let fp = fingerprint_of(&sdp).unwrap();
    let sig = b64::encode(&viewer.sign(&fingerprint_message("sid", "viewer", &fp)).unwrap());
    assert!(verify_fp_sig(&sdp, &sig, "sid", "viewer", &viewer.public_key()));
    assert!(!verify_fp_sig(&sdp, &sig, "sid", "host", &viewer.public_key()));
    assert!(!verify_fp_sig(&sdp, &sig, "other-sid", "viewer", &viewer.public_key()));
    assert!(!verify_fp_sig(&sdp, &sig, "sid", "viewer", &other.public_key()));
    let tampered = RdDocument { key: KEY.replace("00", "ff"), ..RdDocument::default() }.text();
    assert!(!verify_fp_sig(&tampered, &sig, "sid", "viewer", &viewer.public_key()));
}

#[test]
fn ice_servers_become_stun_and_udp_turn() {
    let ice = json!([
        {"urls": ["stun:stun.example", "turn:turn.example:3478?transport=udp", "turn:turn.example:443?transport=tcp"],
         "username": "u", "credential": "p"},
        {"urls": "stun:stun.example:3478"}
    ]);
    let (stun, turn) = servers(&ice);
    assert_eq!(stun, vec!["stun.example:3478"]);
    assert_eq!(
        turn,
        vec![Turn {
            addr: "turn.example:3478".into(),
            username: "u".into(),
            password: "p".into()
        }]
    );
}
