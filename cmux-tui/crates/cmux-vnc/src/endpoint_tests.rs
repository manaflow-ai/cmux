use super::*;

fn parse(text: &str) -> (String, u16) {
    let endpoint = Endpoint::parse(text).unwrap();
    (endpoint.host, endpoint.port)
}

#[test]
fn addresses_parse_like_other_viewers() {
    assert_eq!(parse("mac-mini.local"), ("mac-mini.local".into(), 5900));
    assert_eq!(parse("host:1"), ("host".into(), 5901));
    assert_eq!(parse("host:5901"), ("host".into(), 5901));
    assert_eq!(parse("host::99"), ("host".into(), 99));
    assert_eq!(parse("127.0.0.1:61234"), ("127.0.0.1".into(), 61234));
    assert_eq!(parse("[::1]:5901"), ("::1".into(), 5901));
    assert_eq!(parse("[::1]:2"), ("::1".into(), 5902));
    assert_eq!(parse("[fe80::1]"), ("fe80::1".into(), 5900));
    assert_eq!(parse("fe80::1:2"), ("fe80::1:2".into(), 5900));
    assert_eq!(parse("vnc://box:5"), ("box".into(), 5));
    assert_eq!(parse("vnc://box/"), ("box".into(), 5900));
    assert!(Endpoint::parse("").is_err());
    assert!(Endpoint::parse("host:abc").is_err());
    assert!(Endpoint::parse("host:70000").is_err());
    assert_eq!(Endpoint::parse("[::1]:5901").unwrap().to_string(), "[::1]:5901");
}
