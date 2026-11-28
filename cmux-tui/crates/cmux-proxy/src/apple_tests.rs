use super::*;

/// A PAC script runs in CFNetwork, as the system's PAC file would: its
/// answer for the TURN server, in order, with repeats and kinds the link
/// cannot use dropped.
#[test]
fn cfnetwork_runs_a_pac_script_into_hops() {
    let script = r#"function FindProxyForURL(url, host) {
            if (dnsDomainIs(host, ".internal.example")) { return "DIRECT"; }
            if (host == "turn.cloudflare.com") {
                return "PROXY proxy.corp.example:3128; SOCKS socks.corp.example:1080; DIRECT";
            }
            return "PROXY other.corp.example:8080";
        }"#;
    let pac = SystemEntry::PacScript(script.to_owned());
    let run = |url: &str| {
        let target = cf_url(url).expect("a URL");
        hops_from_entries(vec![pac.clone()], |entry| run_pac(entry, &target))
    };
    assert_eq!(
        run("https://turn.cloudflare.com:443/"),
        vec![
            Hop::Http(ProxyServer::new("proxy.corp.example", 3128)),
            Hop::Socks5(ProxyServer::new("socks.corp.example", 1080)),
            Hop::Direct,
        ]
    );
    assert_eq!(run("https://wiki.internal.example:443/"), vec![Hop::Direct]);
    assert_eq!(
        run("https://mobile-api.cmux.dev:443/"),
        vec![Hop::Http(ProxyServer::new("other.corp.example", 8080))]
    );
    // A script that does not run is direct, as CFNetwork and browsers go.
    let broken = SystemEntry::PacScript("this is not JavaScript (".to_owned());
    let target = cf_url("https://turn.cloudflare.com:443/").expect("a URL");
    assert_eq!(hops_from_entries(vec![broken], |entry| run_pac(entry, &target)), vec![Hop::Direct]);
}

/// The system's own settings answer for any destination without a panic,
/// leaks or a hang (the runner's settings: usually direct).
#[test]
fn the_system_settings_answer() {
    let hops = hops_for_url("https://turn.cloudflare.com:443/");
    assert!(!hops.is_empty());
    eprintln!("this Mac's proxy for TURN over TLS: {hops:?}");
}
