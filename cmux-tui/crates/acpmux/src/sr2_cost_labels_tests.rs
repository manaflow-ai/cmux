use super::*;
use std::collections::BTreeMap;

fn run(pairs: &[(&str, &str)]) -> Option<String> {
    let env: BTreeMap<String, String> =
        pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect();
    custom_headers(|k| env.get(k).cloned())
}

#[test]
fn sr2_route_gets_labels_and_keeps_other_lines() {
    let got = run(&[
        ("ANTHROPIC_BASE_URL", "http://sr2-gateway.tail137216.ts.net:4016"),
        ("ACPMUX_SESSION_NAME", "optchat-sub-2e448bc2-a444"),
        ("ACPMUX_SESSION_ID", "01a161cb-7203-77c0-87b4-ee37fce53896"),
        ("CMUX_WORKSPACE_ID", "F524F024-9AF5-4DD6-BE7E-1DF1DA620B87"),
        (HEADERS_ENV, "X-Subrouter-Session: optchat-a-turn\nx-cmux-agent-id: old"),
    ]);
    assert_eq!(
        got.as_deref(),
        Some(
            "X-Subrouter-Session: optchat-a-turn\nX-Cmux-Agent-Id: optchat-sub-2e448bc2-a444\nX-Cmux-Workspace-Id: F524F024-9AF5-4DD6-BE7E-1DF1DA620B87\nX-Cmux-Session: 01a161cb-7203-77c0-87b4-ee37fce53896"
        )
    );
}

#[test]
fn other_routes_and_off_switch_get_nothing() {
    let labels = [("ACPMUX_SESSION_NAME", "a1"), ("CMUX_WORKSPACE_ID", "ws")];
    assert_eq!(run(&labels), None, "no base URL: Claude talks to Anthropic directly");
    let mut direct = labels.to_vec();
    direct.push(("ANTHROPIC_BASE_URL", "https://api.anthropic.com"));
    assert_eq!(run(&direct), None);
    let mut off = labels.to_vec();
    off.push(("ANTHROPIC_BASE_URL", "http://100.64.0.1:4016"));
    off.push((OFF_ENV, "0"));
    assert_eq!(run(&off), None);
}

#[test]
fn a_value_never_adds_a_header_line() {
    let got = run(&[
        ("ANTHROPIC_BASE_URL", "http://sr2-gateway:4016/"),
        ("ACPMUX_SESSION_NAME", "a b\nX-Evil: 1"),
    ])
    .unwrap();
    assert_eq!(got, "X-Cmux-Agent-Id: a_b_X-Evil:_1");
}

#[test]
fn gateway_detection() {
    assert!(is_sr2_gateway("http://sr2-gateway.tail137216.ts.net:4016"));
    assert!(is_sr2_gateway("http://100.89.1.2:4016/v1"));
    assert!(!is_sr2_gateway("https://api.anthropic.com"));
    assert!(!is_sr2_gateway("http://127.0.0.1:1"));
    assert!(!is_sr2_gateway("http://cmux-lawrences-mac-mini:31415"));
}
