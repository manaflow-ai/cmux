use super::*;

#[test]
fn display_tabs_map_to_capture_displays() {
    assert_eq!(display_of("d~0").as_deref(), Some("main"));
    assert_eq!(display_of("d~69734272").as_deref(), Some("id:69734272"));
    for bad in ["d~", "d~01", "d~-1", "s3", "d~99999999999"] {
        assert_eq!(display_of(bad), None, "{bad}");
    }
}

#[test]
fn eval_input_needs_the_token() {
    let token = "0123456789abcdef";
    assert_eq!(eval_input(b"0123456789abcdef key", token, (100, 50)).map(|v| v.len()), Some(2));
    assert!(eval_input(b"0123456789abcdeX key", token, (100, 50)).is_none());
    let click = eval_input(b"0123456789abcdef click 0.5 1", token, (101, 51)).unwrap();
    assert!(matches!(click[0], InputEvent::Pointer { x: 50, y: 50 }));
    assert!(eval_input(b"0123456789abcdef click nan 1", token, (101, 51)).is_none());
}

#[test]
fn deframer_reads_json_frames() {
    let mut d = Deframer::default();
    let bytes = json_frame(&json!({"t": "encode", "idr": true, "kbps": 9000}));
    d.extend(&bytes[..3]);
    assert_eq!(d.next_json().unwrap(), None);
    d.extend(&bytes[3..]);
    assert_eq!(d.next_json().unwrap().unwrap()["kbps"], 9000);
    let mut bad = Deframer::default();
    bad.extend(&access_unit(true, 1, &[0, 0, 0, 1]));
    assert!(bad.next_json().is_err());
}
