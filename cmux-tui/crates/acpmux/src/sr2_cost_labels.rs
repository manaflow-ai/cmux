//! sr2 cost labels: when a Claude Code agent's final `ANTHROPIC_BASE_URL` is
//! the sr2 gateway, its requests carry which cmux agent, workspace and
//! acpmux session they belong to, so `sr2 costs --by agent|workspace` can
//! split dollars (subrouter `docs/sr2-costs.md`). The gateway reads and
//! deletes these headers before anything goes upstream; they are labels,
//! not credentials. A base URL that is not the sr2 gateway gets nothing, so
//! the ids never go to a provider directly. `sr2 claude` (the `claude-sr2`
//! harness) adds the same lines itself.

use crate::subrouter_session::HEADERS_ENV;

const AGENT: &str = "X-Cmux-Agent-Id";
const WORKSPACE: &str = "X-Cmux-Workspace-Id";
const SESSION: &str = "X-Cmux-Session";
/// `0` turns the labels off.
pub const OFF_ENV: &str = "SUBROUTER2_COST_LABELS";
const MAX_LABEL: usize = 128;

/// Whether `url` names the sr2 gateway (its tailnet host or port 4016).
pub fn is_sr2_gateway(url: &str) -> bool {
    let rest = url.trim().split_once("://").map_or(url.trim(), |(_, r)| r);
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
    let (name, port) = host.rsplit_once(':').unwrap_or((host, ""));
    name.split('.').next() == Some("sr2-gateway") || port == "4016"
}

/// A value mapped into the gateway's label charset: anything else becomes
/// `_`, so a value can never start a new header line.
fn label(value: &str) -> String {
    value
        .trim()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || "._:@/+=-".contains(c) { c } else { '_' })
        .take(MAX_LABEL)
        .collect()
}

/// The `ANTHROPIC_CUSTOM_HEADERS` value for a process whose final env is
/// `get`: the existing lines minus any older `X-Cmux-*` line, plus this
/// session's labels; `None` to leave it unchanged.
pub fn custom_headers(get: impl Fn(&str) -> Option<String>) -> Option<String> {
    if get(OFF_ENV).as_deref().map(str::trim) == Some("0") {
        return None;
    }
    if !get("ANTHROPIC_BASE_URL").is_some_and(|u| is_sr2_gateway(&u)) {
        return None;
    }
    let labels = [
        (AGENT, get("ACPMUX_SESSION_NAME")),
        (WORKSPACE, get("CMUX_WORKSPACE_ID")),
        (SESSION, get("ACPMUX_SESSION_ID")),
    ];
    let added: Vec<String> = labels
        .iter()
        .filter_map(|(name, v)| {
            v.as_deref().map(label).filter(|v| !v.is_empty()).map(|v| format!("{name}: {v}"))
        })
        .collect();
    if added.is_empty() {
        return None;
    }
    let mut lines: Vec<String> = get(HEADERS_ENV)
        .unwrap_or_default()
        .lines()
        .filter(|l| {
            let name = l.split(':').next().unwrap_or("").trim().to_ascii_lowercase();
            !l.trim().is_empty() && !name.starts_with("x-cmux-")
        })
        .map(str::to_owned)
        .collect();
    lines.extend(added);
    Some(lines.join("\n"))
}

#[cfg(test)]
mod tests {
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
}
