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

/// The lane VM's model front: a loopback relay whose every route is the sr2
/// gateway, so a request sent to it reaches the gateway with its headers.
const MODEL_FRONT_PORT: &str = "4026";

/// Whether `url` names the sr2 gateway (its tailnet host or port 4016), or
/// the loopback model front that relays only to it. Lane VMs point Claude at
/// `http://127.0.0.1:4026`; before the front counted here, none of their
/// requests carried labels, and most of the gateway's spend read as agent
/// `unknown`, which no per-lane limit can see.
pub fn is_sr2_gateway(url: &str) -> bool {
    let rest = url.trim().split_once("://").map_or(url.trim(), |(_, r)| r);
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let host = authority.rsplit_once('@').map_or(authority, |(_, h)| h);
    let (name, port) = host.rsplit_once(':').unwrap_or((host, ""));
    let loopback = matches!(name, "127.0.0.1" | "localhost" | "[::1]");
    name.split('.').next() == Some("sr2-gateway")
        || port == "4016"
        || (loopback && port == MODEL_FRONT_PORT)
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
#[path = "sr2_cost_labels_tests.rs"]
mod tests;
