use super::*;

fn http(host: &str, port: u16) -> Hop {
    Hop::Http(ProxyServer::new(host, port))
}

/// A destination name with a line break or a space never reaches the
/// proxy: it would end the CONNECT line and smuggle headers in.
#[tokio::test]
async fn a_connect_target_that_would_inject_headers_is_refused() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let server = ProxyServer::new("127.0.0.1", address.port());
    for host in ["evil\r\nX-Injected: 1", "a b", "", "tab\there"] {
        let stream = TcpStream::connect(address).await.unwrap();
        let error = http_connect(stream, &server, host, 443).await.expect_err(host);
        assert!(
            matches!(error, EgressError::Io(ref message) if message.contains("not a host name")),
            "{error}"
        );
    }
}

#[test]
fn proxy_urls_parse_with_credentials_and_defaults() {
    assert_eq!(parse_proxy_url("proxy.corp:8080"), Some(http("proxy.corp", 8080)));
    assert_eq!(
        parse_proxy_url("http://ann%40corp:p%3Ass@proxy.corp:3128"),
        Some(Hop::Http(ProxyServer::new("proxy.corp", 3128).with_credentials("ann@corp", "p:ss")))
    );
    assert_eq!(
        parse_proxy_url("socks5h://10.0.0.1"),
        Some(Hop::Socks5(ProxyServer::new("10.0.0.1", 1080)))
    );
    assert_eq!(parse_proxy_url("http://[2001:db8::1]:8080"), Some(http("2001:db8::1", 8080)));
    // The scheme's own port, written out, is kept; none is 1080.
    assert_eq!(parse_proxy_url("http://proxy.corp:80"), Some(http("proxy.corp", 80)));
    assert_eq!(parse_proxy_url("http://proxy.corp"), Some(http("proxy.corp", 1080)));
    assert_eq!(parse_proxy_url("http://[::1]"), Some(http("::1", 1080)));
    // TLS to the proxy itself is not something the link speaks.
    assert_eq!(parse_proxy_url("https://proxy.corp:443"), None);
    assert_eq!(parse_proxy_url(""), None);
    // The URL form keeps the credentials, encoded.
    let server = ProxyServer::new("p", 1).with_credentials("a b", "c@d");
    assert_eq!(server.http_url(), "http://a%20b:c%40d@p:1");
    // Debug never shows the password.
    assert!(!format!("{server:?}").contains("c@d"));
}

#[test]
fn no_proxy_lists_match_names_suffixes_and_networks() {
    let list = "localhost, .corp.example, intranet, 10.0.0.0/8, ::1";
    assert!(no_proxy_matches(list, "wiki.corp.example"));
    assert!(no_proxy_matches(list, "corp.example"));
    assert!(no_proxy_matches(list, "INTRANET"));
    assert!(no_proxy_matches(list, "10.20.30.40"));
    assert!(no_proxy_matches(list, "[::1]"));
    assert!(!no_proxy_matches(list, "turn.cloudflare.com"));
    assert!(!no_proxy_matches(list, "11.0.0.1"));
    assert!(!no_proxy_matches(list, "notcorp.example"));
    assert!(no_proxy_matches("*", "anything"));
}

#[test]
fn the_environment_picks_by_scheme_then_all_proxy() {
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |name: &str| {
            pairs.iter().find(|(key, _)| *key == name).map(|(_, value)| (*value).to_owned())
        }
    };
    let vars = env(&[("https_proxy", "http://secure:8443"), ("http_proxy", "plain:8080")]);
    assert_eq!(env_hops("turn.cloudflare.com", true, vars), vec![http("secure", 8443)]);
    assert_eq!(env_hops("turn.cloudflare.com", false, vars), vec![http("plain", 8080)]);
    let vars = env(&[("ALL_PROXY", "socks5://s:1080"), ("NO_PROXY", ".internal")]);
    assert_eq!(env_hops("a.internal", true, vars), vec![Hop::Direct]);
    assert_eq!(env_hops("x.example", true, vars), vec![Hop::Socks5(ProxyServer::new("s", 1080))]);
    assert_eq!(env_hops("x.example", true, env(&[])), vec![Hop::Direct]);
}

/// A PAC entry is replaced by its answer, in order; an unusable kind is
/// skipped; a PAC file that cannot run is direct; repeats collapse.
#[test]
fn system_entries_become_hops_with_pac_run_in_place() {
    let pac = SystemEntry::PacUrl("http://wpad/wpad.dat".into());
    let entries = vec![
        SystemEntry::Other("FTP".into()),
        pac.clone(),
        SystemEntry::Http(ProxyServer::new("b", 8080)),
        SystemEntry::Direct,
    ];
    let hops = hops_from_entries(entries, |entry| {
        assert_eq!(entry, &pac);
        Some(vec![
            SystemEntry::Http(ProxyServer::new("a", 3128)),
            SystemEntry::PacUrl("nested".into()),
            SystemEntry::Http(ProxyServer::new("b", 8080)),
        ])
    });
    assert_eq!(hops, vec![http("a", 3128), http("b", 8080), Hop::Direct]);
    assert_eq!(
        hops_from_entries(vec![SystemEntry::PacScript("bad".into())], |_| None),
        vec![Hop::Direct]
    );
    assert_eq!(hops_from_entries(Vec::new(), |_| None), vec![Hop::Direct]);
}

#[test]
fn loopback_link_local_and_tailnet_hosts_are_never_proxied() {
    for host in [
        "localhost",
        "a.localhost",
        "127.0.0.1",
        "[::1]",
        "::1",
        "169.254.1.2",
        "fe80::1",
        "100.64.0.1",
        "100.127.255.254",
        "fd7a:115c:a1e0::10",
        "[fd7a:115c:a1e0:ab12::1]",
        "::ffff:127.0.0.1",
    ] {
        assert!(never_proxied(host), "{host}");
    }
    for host in ["cmux.dev", "100.128.0.1", "10.0.0.1", "8.8.8.8", "2001:db8::1", "fd7a:115d::1"] {
        assert!(!never_proxied(host), "{host}");
    }
}

#[test]
fn a_connect_target_is_a_plain_host() {
    for host in
        ["cmux.dev", "relay.cmux.dev", "10.0.0.1", "[2001:db8::1]", "2001:db8::1", "fe80::1%en0"]
    {
        assert!(is_plain_host(host), "{host}");
    }
    for host in ["", "a b", "evil\r\nX-Injected: 1", "a\nb", "user@host", "host/path", "[]"] {
        assert!(!is_plain_host(host), "{host:?}");
    }
}

#[test]
fn forget_clears_cached_answers() {
    remember(("forget.example".into(), 443, true), &[http("p", 1)]);
    assert_eq!(cached_hops("FORGET.example", 443, true), Some(vec![http("p", 1)]));
    forget();
    assert_eq!(cached_hops("forget.example", 443, true), None);
}

#[test]
fn a_407_names_its_schemes() {
    let head = "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Negotiate\r\nproxy-authenticate: NTLM\r\nProxy-Authenticate: Basic realm=\"corp\", Digest realm=\"corp\", nonce=\"x\"\r\n\r\n";
    assert_eq!(auth_schemes(head), vec!["Negotiate", "NTLM", "Basic", "Digest"]);
}
