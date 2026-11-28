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
fn oversize_length_is_refused() {
    let mut buf = (u32::MAX).to_be_bytes().to_vec();
    buf.extend_from_slice(b"{}");
    let err = read_frame::<_, GuestResponse>(&mut buf.as_slice()).unwrap_err();
    assert_eq!(err.kind(), io::ErrorKind::InvalidData);
}
