use super::*;

#[test]
fn asks_and_answers_round_trip() {
    let asks = [
        Ask::Read { ask: 1, entry: 9, offset: 1 << 33, len: 4096 },
        Ask::Batch { ask: 2, entries: vec![3, 4, 5] },
        Ask::Ping { ask: 3 },
    ];
    let mut bytes = Vec::new();
    for ask in &asks {
        ask.write(&mut bytes).unwrap();
    }
    let mut input = bytes.as_slice();
    for ask in &asks {
        assert_eq!(Ask::read(&mut input).unwrap().as_ref(), Some(ask));
    }
    assert_eq!(Ask::read(&mut input).unwrap(), None);

    let parts = vec![Part::ok(b"abc".to_vec()), Part::status(CHANGED)];
    let mut bytes = Vec::new();
    write_answer(&mut bytes, 7, &parts).unwrap();
    let mut input = bytes.as_slice();
    assert_eq!(read_answer(&mut input).unwrap(), Some((7, parts)));
    assert_eq!(read_answer(&mut input).unwrap(), None);
}

#[test]
fn an_oversized_ask_is_refused() {
    let mut bytes = Vec::new();
    Ask::Read { ask: 1, entry: 0, offset: 0, len: MAX_READ + 1 }.write(&mut bytes).unwrap();
    assert!(Ask::read(&mut bytes.as_slice()).is_err());
}
