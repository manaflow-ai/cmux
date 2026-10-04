use super::*;

const PORT: u16 = 47811;

fn policy() -> ListenerPolicy {
    ListenerPolicy::loopback(PORT)
}

#[test]
fn loopback_hosts_are_accepted_with_or_without_port() {
    for host in [
        "127.0.0.1",
        "127.0.0.1:47811",
        "localhost",
        "LOCALHOST:47811",
        "localhost.:47811",
        "[::1]",
        "[::1]:47811",
        "127.0.0.1:1",
    ] {
        assert_eq!(policy().check(&[host], &[]), Ok(()), "{host}");
    }
}

#[test]
fn rebinding_and_malformed_hosts_are_refused() {
    for host in [
        "evil.example",
        "evil.example:47811",
        "localhost.evil.example",
        "127.0.0.1.nip.io",
        "127.0.0.2",
        "0.0.0.0",
        "user@127.0.0.1",
        "127.0.0.1/x",
        "::1",
        "[::1]x",
        "127.0.0.1:notaport",
        "",
    ] {
        assert_eq!(policy().check(&[host], &[]), Err(Refusal::ForeignHost), "{host}");
    }
}

#[test]
fn a_missing_or_repeated_host_is_refused() {
    assert_eq!(policy().check(&[], &[]), Err(Refusal::MissingHost));
    assert_eq!(policy().check(&["localhost", "localhost"], &[]), Err(Refusal::MissingHost));
}

#[test]
fn no_origin_is_a_non_browser_client() {
    assert_eq!(policy().check(&["127.0.0.1:47811"], &[]), Ok(()));
}

#[test]
fn own_origins_are_accepted() {
    for origin in [
        "http://127.0.0.1:47811",
        "http://localhost:47811",
        "http://LOCALHOST:47811/",
        "http://[::1]:47811",
    ] {
        assert_eq!(policy().check(&["localhost:47811"], &[origin]), Ok(()), "{origin}");
    }
}

#[test]
fn foreign_origins_are_refused() {
    for origin in [
        "https://evil.example",
        "http://evil.example:47811",
        "http://127.0.0.1:47812",
        "http://localhost",
        "https://127.0.0.1:47811",
        "http://localhost.evil.example:47811",
        "file://",
        "chrome-extension://abcdef",
        "http://user@127.0.0.1:47811",
    ] {
        assert_eq!(
            policy().check(&["127.0.0.1:47811"], &[origin]),
            Err(Refusal::ForeignOrigin),
            "{origin}"
        );
    }
}

#[test]
fn null_origin_is_always_refused_even_when_added() {
    let policy = policy().with_origin("null");
    assert_eq!(policy.check(&["localhost"], &["null"]), Err(Refusal::NullOrigin));
    assert_eq!(policy.check(&["localhost"], &[" NULL "]), Err(Refusal::NullOrigin));
}

#[test]
fn repeated_origin_is_refused() {
    assert_eq!(
        policy().check(&["localhost"], &["http://localhost:47811", "http://localhost:47811"]),
        Err(Refusal::AmbiguousOrigin)
    );
}

#[test]
fn added_origins_and_hosts_are_exact() {
    let policy = policy().with_origin("file://").with_host("mini.tail1234.ts.net");
    assert_eq!(policy.check(&["localhost"], &["file://"]), Ok(()));
    assert_eq!(policy.check(&["mini.tail1234.ts.net:47811"], &[]), Ok(()));
    assert_eq!(
        policy.check(&["mini.tail1234.ts.net"], &["http://mini.tail1234.ts.net:47811"]),
        Ok(())
    );
    assert_eq!(policy.check(&["other.tail1234.ts.net"], &[]), Err(Refusal::ForeignHost));
    assert_eq!(policy.check(&["localhost"], &["file://evil"]), Err(Refusal::ForeignOrigin));
}

#[test]
fn port_80_origin_may_omit_the_port() {
    let policy = ListenerPolicy::loopback(80);
    assert_eq!(policy.check(&["localhost"], &["http://localhost"]), Ok(()));
}

#[test]
fn tokens_compare_exactly_and_empty_never_matches() {
    assert!(tokens_match("abc", "abc"));
    assert!(!tokens_match("abd", "abc"));
    assert!(!tokens_match("ab", "abc"));
    assert!(!tokens_match("", ""));
    assert_eq!(check_token(Some("abc"), "abc"), Ok(()));
    assert_eq!(check_token(None, "abc"), Err(Refusal::MissingToken));
    assert_eq!(check_token(Some(""), "abc"), Err(Refusal::MissingToken));
    assert_eq!(check_token(Some("abd"), "abc"), Err(Refusal::WrongToken));
    assert_eq!(check_token(Some(""), ""), Err(Refusal::MissingToken));
}

#[test]
fn bearer_and_query_tokens_parse() {
    assert_eq!(bearer_token("Bearer abc"), Some("abc"));
    assert_eq!(bearer_token("bearer  abc "), Some("abc"));
    assert_eq!(bearer_token("Basic abc"), None);
    assert_eq!(bearer_token("Bearer "), None);
    assert_eq!(query_token("a=1&token=abc&b=2"), Some("abc"));
    assert_eq!(query_token("token="), None);
    assert_eq!(query_token("xtoken=abc"), None);
}

#[test]
fn refusals_map_to_status_codes() {
    assert_eq!(Refusal::ForeignOrigin.status(), 403);
    assert_eq!(Refusal::ForeignHost.status(), 403);
    assert_eq!(Refusal::MissingToken.status(), 401);
    assert_eq!(Refusal::WrongToken.reason(), "wrong_token");
}

#[test]
fn non_loopback_binds_skip_only_the_host_rule() {
    let policy = ListenerPolicy::for_bind("0.0.0.0:47811".parse().unwrap());
    assert_eq!(policy.check(&["sandbox-a:47811"], &[]), Ok(()));
    assert_eq!(policy.check(&[], &[]), Err(Refusal::MissingHost));
    assert_eq!(
        policy.check(&["sandbox-a:47811"], &["https://evil.example"]),
        Err(Refusal::ForeignOrigin)
    );
    assert_eq!(policy.check(&["sandbox-a:47811"], &["null"]), Err(Refusal::NullOrigin));
    let loopback = ListenerPolicy::for_bind("127.0.0.1:47811".parse().unwrap());
    assert_eq!(loopback.check(&["evil.example"], &[]), Err(Refusal::ForeignHost));
}

#[test]
fn origins_parse_to_one_normal_form() {
    assert_eq!(parse_origin("HTTPS://Mini.TS.net:443/"), Some("https://mini.ts.net".into()));
    assert_eq!(parse_origin("http://localhost:80"), Some("http://localhost".into()));
    assert_eq!(parse_origin("http://localhost:5173"), Some("http://localhost:5173".into()));
    assert_eq!(parse_origin("cmux-agent://pane"), Some("cmux-agent://pane".into()));
    assert_eq!(parse_origin("http://[::1]:8080"), Some("http://[::1]:8080".into()));
    assert_eq!(parse_origin("file://"), Some("file://".into()));
    for bad in [
        "null",
        "localhost:5173",
        "https://x.ts.net/path",
        "http://user@localhost",
        "http://localhost:99999",
        "://x",
        "",
    ] {
        assert_eq!(parse_origin(bad), None, "{bad}");
    }
}

#[test]
fn an_added_origin_with_a_default_port_matches_what_browsers_send() {
    let policy = policy().with_origin("https://mini.ts.net:443");
    assert_eq!(policy.check(&["localhost"], &["https://mini.ts.net"]), Ok(()));
    let ignored = policy.clone().with_origin("not an origin");
    assert_eq!(ignored, policy);
}
