use super::http_store_allowed;

#[test]
fn http_is_taken_only_on_loopback_or_the_tailnet() {
    for ok in [
        "https://sessions.example.com",
        "http://127.0.0.1:8080",
        "http://100.89.225.106:18765",
        "http://100.89.225.106:18765/v1",
        "http://100.64.0.1",
        "http://100.127.255.254:1",
    ] {
        assert!(http_store_allowed(ok), "{ok}");
    }
    for no in [
        "http://8.8.8.8",
        "http://100.128.0.1",
        "http://100.63.255.255",
        "http://127.0.0.1.evil.com",
        "http://100.89.225.106.evil.com:80",
        "http://user@100.89.225.106",
        "http://example.com",
        "ftp://100.89.225.106",
    ] {
        assert!(!http_store_allowed(no), "{no}");
    }
}
