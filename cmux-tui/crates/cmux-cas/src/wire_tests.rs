use super::*;

fn all() -> Vec<Message> {
    vec![
        Message::Have {
            version: VERSION,
            root: Some(Id([1; 32])),
            ids: vec![Id([2; 32]), Id([3; 32])],
        },
        Message::Have { version: VERSION, root: None, ids: vec![] },
        Message::Want { version: VERSION, ids: vec![Id([4; 32])], priority: 2 },
        Message::Data { version: VERSION, id: Id([5; 32]), bytes: b"chunk".to_vec() },
        Message::Nope {
            version: VERSION,
            ids: vec![Id([6; 32])],
            kind: None,
            reason: String::new(),
        },
        Message::Nope { version: VERSION, ids: vec![], kind: Some(9), reason: "unknown".into() },
    ]
}

#[test]
fn messages_round_trip_through_bytes_and_streams() {
    let mut stream = Vec::new();
    for m in all() {
        assert_eq!(Message::decode(&m.encode().unwrap()).unwrap(), m);
        m.to_frame().write_to(&mut stream).unwrap();
    }
    let mut input = stream.as_slice();
    for m in all() {
        let frame = Frame::read_from(&mut input).unwrap().unwrap();
        assert_eq!(Message::from_frame(&frame).unwrap(), m);
    }
    assert!(Frame::read_from(&mut input).unwrap().is_none());
}

#[test]
fn malformed_frames_are_refused() {
    assert!(Frame::decode_body(&[1]).is_err());
    assert!(Frame::decode_body(&[0, 0, KIND_HAVE]).is_err(), "version 0");
    assert!(Frame::decode_body(&[1, 0, KIND_DATA, tag::ID, 40, 0, 0, 0, 1]).is_err());
    assert!(Frame::decode_body(&[1, 0, KIND_DATA, tag::ID, 1]).is_err());
    // A known kind missing what it needs.
    assert!(Message::decode(&[1, 0, KIND_DATA]).is_err());
    assert!(Message::decode(&[1, 0, KIND_WANT]).is_err());
    // An id list that is not whole ids.
    assert!(Message::decode(&[1, 0, KIND_WANT, tag::IDS, 3, 0, 0, 0, 1, 2, 3]).is_err());
    // A frame over the limit is refused before it is read.
    let mut big = ((MAX_BODY + 1) as u32).to_le_bytes().to_vec();
    big.extend_from_slice(&[1, 0, KIND_HAVE]);
    assert!(Frame::read_from(&mut big.as_slice()).is_err());
}
