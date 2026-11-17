use super::explains_exit;

#[test]
fn a_wrapper_exit_line_does_not_hide_the_real_error() {
    let tail = ["No conversation found with session ID: e140627e", "subrouter: exit status 1"];
    let last = tail.iter().rev().map(|l| l.trim()).find(|l| explains_exit(l));
    assert_eq!(last, Some("No conversation found with session ID: e140627e"));
}

/// acp-chief-issues.md #3: sr2 prints its route banner at every start; a
/// start that died after it must quote the real error, never the banner.
#[test]
fn the_sr2_route_banner_does_not_explain_the_exit() {
    let tail = [
        "claude2: read rotation: context deadline exceeded",
        "sr2 route: profile settings name http://127.0.0.1:1; managed settings override it with the sr2 gateway",
        "sr2 route: gateway http://sr2-gateway.tail137216.ts.net:4016",
    ];
    let last = tail.iter().rev().map(|l| l.trim()).find(|l| explains_exit(l));
    assert_eq!(last, Some("claude2: read rotation: context deadline exceeded"));
}

#[test]
fn ordinary_lines_still_explain_the_exit() {
    assert!(explains_exit("Error: exit status unknown to me"));
    assert!(explains_exit("panic: index out of range"));
    assert!(!explains_exit("at Object.<anonymous> (cli.js:1:1)"));
    assert!(!explains_exit("[SYSTEM_ERROR] boom"));
    assert!(!explains_exit(""));
}
