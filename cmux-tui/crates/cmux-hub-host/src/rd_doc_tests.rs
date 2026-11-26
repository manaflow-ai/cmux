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
        max_kbps: Some(5_000),
        cursor: Some(false),
        encode_profile: Some("ultra".into()),
        displays: vec![(2560, 1440)],
        current_display: Some(0),
        display_id: Some(17),
        display_ids: vec![1, 17],
    };
    assert!(doc.text().contains("\r\na=cmux-rd-encode-profile:ultra\r\n"));
    let text = doc.text();
    assert!(text.contains("a=cmux-rd-display-id:17\r\n"));
    assert!(text.contains("a=cmux-rd-display-ids:1,17\r\n"));
    assert!(text.contains("a=cmux-rd-max-kbps:5000\r\n"));
    assert!(text.contains("a=cmux-rd-cursor:0\r\n"));
    assert!(text.starts_with("cmux.rd/1\r\na=fingerprint:cmux-rd-key 0011"));
    assert_eq!(RdDocument::parse(&text), Some(doc));
    assert_eq!(fingerprint_of(&text).as_deref(), Some(format!("cmux-rd-key {KEY}").as_str()));
}

#[test]
fn customize_wishes_round_trip_and_unset_ones_stay_out() {
    let shown = RdDocument { key: KEY.into(), cursor: Some(true), ..RdDocument::default() };
    assert!(shown.text().contains("a=cmux-rd-cursor:1\r\n"));
    assert_eq!(RdDocument::parse(&shown.text()), Some(shown));
    // Today's offer: no bitrate cap and no cursor line, so an older host reads the same.
    let plain = RdDocument { key: KEY.into(), ..RdDocument::default() }.text();
    assert!(!plain.contains("max-kbps") && !plain.contains("cmux-rd-cursor"));
    // A value this side does not know is no wish, not a wrong one.
    let odd = format!("{plain}a=cmux-rd-cursor:yes\r\na=cmux-rd-max-kbps:-3\r\n");
    let parsed = RdDocument::parse(&odd).unwrap();
    assert_eq!((parsed.cursor, parsed.max_kbps), (None, None));
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
fn ice_servers_keep_udp_relays_first_then_tcp_and_tls() {
    let ice = json!([
        {"urls": ["turns:turn.example:443?transport=tcp", "stun:stun.example",
                  "turn:turn.example:443?transport=tcp", "turn:turn.example:3478?transport=udp",
                  "turns:tls.example"],
         "username": "u", "credential": "p"},
        {"urls": "stun:stun.example:3478"},
        {"urls": "turn:nocreds.example"}
    ]);
    let (stun, turn) = servers(&ice);
    assert_eq!(stun, vec!["stun.example:3478"]);
    let relay = |addr: &str, transport| Turn {
        addr: addr.into(),
        username: "u".into(),
        password: "p".into(),
        transport,
    };
    assert_eq!(
        turn,
        vec![
            relay("turn.example:3478", TurnTransport::Udp),
            relay("turn.example:443", TurnTransport::Tcp),
            relay("turn.example:443", TurnTransport::Tls),
            relay("tls.example:5349", TurnTransport::Tls),
        ]
    );
    assert_eq!(udp_only(&turn), vec![relay("turn.example:3478", TurnTransport::Udp)]);
    // A UDP relay serializes exactly as before; the others name their transport.
    assert_eq!(
        serde_json::to_value(&turn[0]).unwrap(),
        json!({"addr": "turn.example:3478", "username": "u", "password": "p"})
    );
    assert_eq!(serde_json::to_value(&turn[2]).unwrap()["transport"], "tls");
}
