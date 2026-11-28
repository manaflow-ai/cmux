use super::*;

#[test]
fn bind_and_bind_ok_round_trip() {
    assert_eq!(decode_bind(&encode_bind(b"tk")), Some(&b"tk"[..]));
    for a in ["198.18.0.4:40000", "[2001:db8::1]:9"] {
        let a: SocketAddr = a.parse().unwrap();
        assert_eq!(decode_bind_ok(&encode_bind_ok(a, 600)), Some((a, 600)));
    }
    assert_eq!(decode_error(&encode_error(E_BAD_TICKET)), Some(E_BAD_TICKET));
    assert_eq!(decode_bind(&[MAGIC, T_BIND, 0, 9, 1]), None);
}

#[test]
fn plain_wireguard_is_classed_by_shape() {
    let mut init = vec![1, 0, 0, 0];
    init.resize(148, 0);
    assert_eq!(plain_class(&init), CLASS_CONTROL);
    let mut keepalive = vec![4, 0, 0, 0];
    keepalive.resize(32, 0);
    assert_eq!(plain_class(&keepalive), CLASS_CONTROL);
    let mut key = vec![4, 0, 0, 0];
    key.resize(96, 0);
    assert_eq!(plain_class(&key), CLASS_INPUT);
    key.resize(1200, 0);
    assert_eq!(plain_class(&key), CLASS_BULK);
}
