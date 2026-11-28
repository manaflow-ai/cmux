use super::*;

#[test]
fn frame_round_trip() {
    let req = GuestRequest::Exec {
        program: "echo".into(),
        args: vec!["hi".into()],
        env: vec![("A".into(), "b".into())],
        cwd: None,
        stdin: String::new(),
        timeout_ms: 0,
    };
    let mut buf = Vec::new();
    write_frame(&mut buf, &req).unwrap();
    let back: GuestRequest = read_frame(&mut buf.as_slice()).unwrap();
    assert_eq!(back, req);
}

#[test]
fn set_clock_round_trips_with_its_wire_names() {
    let req = GuestRequest::SetClock { unix_ns: 1_795_000_000_123_456_789 };
    let text = serde_json::to_string(&req).unwrap();
    assert_eq!(text, r#"{"op":"set_clock","unix_ns":1795000000123456789}"#);
    let mut buf = Vec::new();
    write_frame(&mut buf, &req).unwrap();
    assert_eq!(read_frame::<_, GuestRequest>(&mut buf.as_slice()).unwrap(), req);
    let reply = GuestResponse::Clock { stepped_ns: -5 };
    let text = serde_json::to_string(&reply).unwrap();
    assert_eq!(text, r#"{"result":"clock","stepped_ns":-5}"#);
    assert_eq!(serde_json::from_str::<GuestResponse>(&text).unwrap(), reply);
}

#[test]
fn clock_step_is_host_minus_guest_and_clamps() {
    // A guest restored from a snapshot taken an hour ago is an hour behind.
    let hour = 3_600_000_000_000u64;
    assert_eq!(clock_step_ns(10 * hour, 11 * hour), 3_600_000_000_000);
    assert_eq!(clock_step_ns(11 * hour, 10 * hour), -3_600_000_000_000);
    assert_eq!(clock_step_ns(0, u64::MAX), i64::MAX);
    assert_eq!(clock_step_ns(u64::MAX, 0), i64::MIN);
}

#[test]
fn oversize_length_is_refused() {
    let mut buf = (u32::MAX).to_be_bytes().to_vec();
    buf.extend_from_slice(b"{}");
    let err = read_frame::<_, GuestResponse>(&mut buf.as_slice()).unwrap_err();
    assert_eq!(err.kind(), io::ErrorKind::InvalidData);
}
