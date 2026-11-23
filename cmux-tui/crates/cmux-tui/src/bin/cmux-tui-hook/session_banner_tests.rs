use super::*;

#[test]
fn the_sr2_supervisor_socket_means_managed_compaction() {
    let gateway = Some("http://sr2-gateway.tail137216.ts.net:4016");
    assert_eq!(compaction(Some("/tmp/sr2-claude2-1/hook.sock"), gateway), Compaction::Managed);
    assert_eq!(compaction(Some("/tmp/x/hook.sock"), None), Compaction::Managed);
    assert_eq!(compaction(Some("  "), gateway), Compaction::Unmanaged);
}

#[test]
fn plain_claude_on_the_sr2_gateway_is_unmanaged() {
    for url in [
        "http://sr2-gateway.tail137216.ts.net:4016",
        "HTTP://SR2-GATEWAY.tail137216.ts.net:4016/",
        "http://127.0.0.1:31416",
        "http://localhost:31416/v1",
    ] {
        assert_eq!(compaction(None, Some(url)), Compaction::Unmanaged, "{url}");
    }
}

#[test]
fn any_other_route_is_stock() {
    for url in [
        None,
        Some(""),
        Some("https://api.anthropic.com"),
        Some("http://100.89.225.106:31415"),
        Some("http://example.com/sr2-gateway"),
        Some("http://notsr2-gateway.example.com"),
    ] {
        assert_eq!(compaction(None, url), Compaction::Stock, "{url:?}");
    }
}

#[test]
fn the_line_shows_once_per_process_start_and_matches_the_capability() {
    assert_eq!(message(Compaction::Managed, "startup"), Some(MANAGED));
    assert_eq!(message(Compaction::Managed, "resume"), Some(MANAGED));
    assert_eq!(message(Compaction::Unmanaged, "startup"), Some(UNMANAGED));
    for source in ["clear", "compact", ""] {
        assert_eq!(message(Compaction::Managed, source), None, "{source}");
        assert_eq!(message(Compaction::Unmanaged, source), None, "{source}");
    }
    assert_eq!(message(Compaction::Stock, "startup"), None);
    // Each line promises only what its capability does.
    assert!(
        MANAGED.contains("/compact into this terminal between turns")
            && MANAGED.contains("fresh account")
    );
    assert!(
        UNMANAGED.contains("`sr2 claude`")
            && !UNMANAGED.contains("/compact into this terminal between turns")
    );
}
