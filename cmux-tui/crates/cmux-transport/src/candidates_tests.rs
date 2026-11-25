use super::*;

#[test]
fn a_list_round_trips_and_is_bounded() {
    let list: Vec<SocketAddr> = vec![
        "192.168.1.20:4101".parse().unwrap(),
        "[fd7a:115c:a1e0::1]:4101".parse().unwrap(),
        "169.254.3.4:4101".parse().unwrap(),
    ];
    assert_eq!(decode_candidates(&encode_candidates(&list)), Ok(list.clone()));
    let many: Vec<SocketAddr> = (0..20).map(|n| SocketAddr::new([10, 0, 0, n].into(), 1)).collect();
    assert_eq!(decode_candidates(&encode_candidates(&many)).unwrap().len(), MAX_CANDIDATES);
}

#[test]
fn malformed_lists_are_refused() {
    let list = encode_candidates(&["10.0.0.1:1".parse().unwrap()]);
    assert_eq!(decode_candidates(&list[..4]), Err(CandidateError::Length(4)));
    assert_eq!(decode_candidates(&list[..list.len() - 1]), Err(CandidateError::Length(11)));
    let mut magic = list.clone();
    magic[0] = b'x';
    assert_eq!(decode_candidates(&magic), Err(CandidateError::Magic));
    let mut family = list.clone();
    family[5] = 9;
    assert_eq!(decode_candidates(&family), Err(CandidateError::Family(9)));
    let mut count = list.clone();
    count[4] = 200;
    assert_eq!(decode_candidates(&count), Err(CandidateError::Count(200)));
    let mut trailing = list;
    trailing.push(0);
    assert_eq!(decode_candidates(&trailing), Err(CandidateError::Length(13)));
}
