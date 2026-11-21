use super::*;

#[test]
fn a_bearer_header_or_one_token_subprotocol_is_the_token() {
    let p = presented(&["Bearer abc"], &[]).unwrap();
    assert_eq!(p, Presented { token: Some("abc"), answer_protocol: false });
    let p = presented(&[], &["acpmux.v1, acpmux.token.abc"]).unwrap();
    assert_eq!(p, Presented { token: Some("abc"), answer_protocol: true });
    let p = presented(&[], &["acpmux.token.abc", "acpmux.v1"]).unwrap();
    assert_eq!(p.token, Some("abc"));
    assert_eq!(presented(&[], &[]).unwrap(), Presented::default());
}

#[test]
fn an_ambiguous_or_unanswerable_token_is_refused() {
    for (auth, protocols) in [
        (&["Bearer a"][..], &["acpmux.v1, acpmux.token.a"][..]),
        (&[][..], &["acpmux.v1, acpmux.token.a, acpmux.token.b"][..]),
        (&[][..], &["acpmux.token.a"][..]),
        (&["Bearer a", "Bearer a"][..], &[][..]),
    ] {
        assert!(presented(auth, protocols).is_err(), "{auth:?} {protocols:?}");
    }
}

#[test]
fn only_loopback_binds_without_the_opt_in() {
    let addr = |s: &str| s.parse::<SocketAddr>().unwrap();
    for ok in ["127.0.0.1:0", "[::1]:0", "[::ffff:127.0.0.1]:0"] {
        assert!(check_listen(ok, &[addr(ok)], false).is_ok(), "{ok}");
    }
    for net in ["0.0.0.0:0", "[::]:0", "10.0.0.5:1", "100.64.0.1:1", "[fd7a:115c:a1e0::1]:1"] {
        assert!(check_listen(net, &[addr(net)], false).is_err(), "{net}");
        assert!(check_listen(net, &[addr(net)], true).is_ok(), "{net}");
    }
    assert!(check_listen("x", &[], false).is_err());
    let mixed = [addr("127.0.0.1:0"), addr("10.0.0.5:0")];
    assert!(check_listen("both", &mixed, false).is_err());
}
