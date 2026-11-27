use super::*;

#[test]
fn destinations_a_value_may_reach() {
    let at = |a: &str, intercept| reachable(&a.parse().unwrap(), intercept);
    for never in [
        "127.0.0.1:443",
        "169.254.169.254:80",
        "0.0.0.0:443",
        "[::1]:443",
        "[::ffff:127.0.0.1]:443",
        "224.0.0.1:443",
        "[fe80::1]:443",
    ] {
        assert!(!at(never, false) && !at(never, true), "{never}");
    }
    // Inside the machine's network: a blind tunnel may go there, a value never.
    for internal in [
        "10.0.0.5:443",
        "172.16.4.1:443",
        "192.168.1.1:443",
        "100.64.0.1:443",
        "100.127.255.254:443",
        "198.18.0.1:443",
        "192.0.0.8:443",
        "240.0.0.1:443",
        "[fc00::1]:443",
        "[fd12:3456::1]:443",
        "[::ffff:10.0.0.5]:443",
        "168.63.129.16:80",
        "[64:ff9b::a00:5]:443",
        "[2002:c0a8:101::1]:443",
    ] {
        assert!(at(internal, false) && !at(internal, true), "{internal}");
    }
    // NAT64 and 6to4 forms of loopback are never reached, tunnel or not.
    assert!(!at("[64:ff9b::7f00:1]:443", false) && !at("[2002:7f00:1::1]:443", false));
    for public in
        ["140.82.112.6:443", "100.128.0.1:443", "[2606:4700::1111]:443", "[64:ff9b::8c52:7006]:443"]
    {
        assert!(at(public, false) && at(public, true), "{public}");
    }
}

#[test]
fn authority_match_is_host_and_port() {
    assert!(same_authority("api.github.com", "api.github.com", 443));
    assert!(same_authority("API.GitHub.com:443", "api.github.com", 443));
    assert!(!same_authority("api.github.com:8443", "api.github.com", 443));
    assert!(!same_authority("evil.test", "api.github.com", 443));
    assert!(!same_authority("evil.test@api.github.com", "api.github.com", 443));
}
