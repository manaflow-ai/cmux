//! The lists against what the page sends (webviews/src/agent-session/acpmux),
//! as AcpmuxPaneMethods.swift says they were made: every
//! `this.request("...")` in direct.ts, `HANDOFF_OPS` (handoff/protocol.ts),
//! `PERMISSION_GROUP_OPS` (permissions/protocol.ts), `FORK_OP`
//! (operations.ts), `PREWARM_METHOD` (direct.ts), and the raw
//! `session/cancel` notification. `file.search` (and the git reads, sent by a
//! variable) go to the socket only in mock mode and stay off the list. Folder
//! trust levels (folderTrust.ts `LEVELS`) give the gesture rule's
//! non-trusting levels.

use cmux_agent_pane_policy::policy;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

/// The page sources next to this crate in the repository. A checkout without
/// them fails these tests (they are what the lists are checked against).
fn pane() -> PathBuf {
    let dir =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../webviews/src/agent-session/acpmux");
    assert!(dir.is_dir(), "webviews/src/agent-session/acpmux is missing at {}", dir.display());
    dir
}

fn read(dir: &Path, file: &str) -> String {
    std::fs::read_to_string(dir.join(file)).unwrap_or_else(|e| panic!("{file}: {e}"))
}

/// Every `"..."` string that follows `prefix` (whitespace allowed between).
fn quoted_after(text: &str, prefix: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut rest = text;
    while let Some(at) = rest.find(prefix) {
        rest = &rest[at + prefix.len()..];
        let trimmed = rest.trim_start();
        if let Some(body) = trimmed.strip_prefix('"')
            && let Some(end) = body.find('"')
        {
            out.push(body[..end].to_owned());
        }
    }
    out
}

/// The string values of `export const NAME = { key: "value", ... }`.
fn object_values(text: &str, name: &str) -> Vec<String> {
    let start = text
        .find(&format!("export const {name} = {{"))
        .unwrap_or_else(|| panic!("{name} not found"));
    let body = &text[start..];
    let body = &body[..body.find('}').unwrap()];
    quoted_after(body, ":")
}

fn constant(text: &str, name: &str) -> String {
    quoted_after(text, &format!("export const {name} ="))
        .into_iter()
        .next()
        .unwrap_or_else(|| panic!("{name} not found"))
}

#[test]
fn the_allowlist_is_what_the_page_sends() {
    let dir = pane();
    let direct = read(&dir, "direct.ts");
    let mut sent: BTreeSet<String> = quoted_after(&direct, "this.request(").into_iter().collect();
    sent.extend(object_values(&read(&dir, "handoff/protocol.ts"), "HANDOFF_OPS"));
    sent.extend(object_values(&read(&dir, "permissions/protocol.ts"), "PERMISSION_GROUP_OPS"));
    sent.insert(constant(&read(&dir, "operations.ts"), "FORK_OP"));
    sent.insert(constant(&direct, "PREWARM_METHOD"));
    let p = policy();
    assert!(sent.remove(&p.initialize), "the page sends initialize");
    assert!(sent.remove("file.search"), "file.search is a mock-mode literal");
    assert_eq!(sent, p.requests, "requests the page sends vs policy.json requests");
    // A frame the page writes itself: `jsonrpc: "2.0",` then its `method:`.
    let notifications: BTreeSet<String> = direct
        .split(r#"jsonrpc: "2.0","#)
        .skip(1)
        .filter_map(|after| {
            quoted_after(after.split("})").next().unwrap_or_default(), "method:").into_iter().next()
        })
        .collect();
    assert_eq!(notifications, p.notifications, "raw notifications the page sends");
}

#[test]
fn non_trusting_levels_are_the_page_levels_but_trusted() {
    let dir = pane();
    let trust = read(&dir, "folderTrust.ts");
    let line =
        trust.lines().find(|l| l.contains("const LEVELS")).expect("LEVELS in folderTrust.ts");
    let mut levels: BTreeSet<String> =
        quoted_after(line, "[").into_iter().chain(quoted_after(line, ",")).collect();
    assert!(levels.remove("trusted"), "{levels:?}");
    assert_eq!(levels, policy().non_trusting_levels);
}

fn trust_cases() -> serde_json::Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/cases/trust_gate.json");
    serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap()
}

/// AGENT-TRUST-GATE: the refusal reasons the page reads (direct.ts
/// `isTrustRefusal`) are the ones acpmux's gate writes (trust_gate.rs
/// `folder_answered`), and trust_gate.json's `page_reasons` lists them, so a
/// host that passes the reply through (`unfiltered`) keeps what the page needs.
#[test]
fn trust_refusal_reasons_are_the_daemons() {
    let dir = pane();
    let direct = read(&dir, "direct.ts");
    let start =
        direct.find("export function isTrustRefusal(").expect("isTrustRefusal in direct.ts");
    let body = &direct[start..];
    let body = &body[..body.find("\n}").unwrap()];
    let page: BTreeSet<String> = quoted_after(body, "reason ===").into_iter().collect();
    let want: BTreeSet<String> = trust_cases()["page_reasons"]
        .as_array()
        .unwrap()
        .iter()
        .map(|r| r.as_str().unwrap().to_owned())
        .collect();
    assert_eq!(page, want, "direct.ts isTrustRefusal vs trust_gate.json page_reasons");
    let gate = std::fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../acpmux/src/server/trust_gate.rs"),
    )
    .expect("acpmux trust_gate.rs next to this crate");
    for reason in &want {
        assert!(gate.contains(&format!("(\"{reason}\",")), "acpmux trust_gate.rs writes {reason}");
    }
}

/// AGENT-TRUST-GATE: the page sends `sessionId` on `acp.trust.get` and
/// `acp.trust.set` when a chat is selected (direct.ts `trustGet`,
/// `trustSet`; acpmux routes a remote session's answer to its peer), and the
/// hosts allow it (`knownParams`) when the session is the pane's
/// (`optionallySessionScoped`, sessions.json).
#[test]
fn trust_session_id_is_sent_and_scoped() {
    let dir = pane();
    let direct = read(&dir, "direct.ts");
    for (function, method) in [("trustGet(", "acp.trust.get"), ("trustSet(", "acp.trust.set")] {
        let start = direct.find(function).unwrap_or_else(|| panic!("{function} in direct.ts"));
        let body = &direct[start..];
        let body = &body[..body.find("\n  }").unwrap()];
        assert!(
            body.contains("sessionId: this.selectedSessionId"),
            "{method}: the page sends sessionId"
        );
        assert!(
            policy().known_params[method].params.contains("sessionId"),
            "{method}: the hosts allow sessionId"
        );
        assert!(
            policy().optionally_session_scoped.contains(method),
            "{method}: a named session must be the pane's"
        );
    }
}
