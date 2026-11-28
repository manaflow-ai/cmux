use super::*;

#[test]
fn one_way_send_round_trips_without_base64_on_the_wire() {
    let packet =
        encode_local_line(br#"{"id":17,"cmd":"send","surface":23,"bytes":"AP+A","no_reply":true}"#)
            .unwrap()
            .unwrap();
    assert_eq!(packet.len(), HEADER_BYTES + 3);
    assert!(!packet.windows(4).any(|window| window == b"AP+A"));

    let input = decode_packet(&packet).unwrap().unwrap();
    assert_eq!(input.request, 17);
    assert_eq!(input.surface, 23);
    assert_eq!(input.bytes, b"\0\xff\x80".as_slice());
    assert_eq!(
        serde_json::from_slice::<Value>(&input.into_local_line().unwrap()).unwrap(),
        json!({"id": 17, "cmd": "send", "surface": 23, "bytes": "AP+A"})
    );
}
