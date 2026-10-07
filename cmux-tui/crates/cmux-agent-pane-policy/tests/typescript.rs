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

fn pane() -> Option<PathBuf> {
    let dir =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../webviews/src/agent-session/acpmux");
    dir.is_dir().then_some(dir)
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
    let Some(dir) = pane() else {
        eprintln!(
            "skipped: webviews/src/agent-session/acpmux is not next to this crate (a sparse checkout)"
        );
        return;
    };
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
    let Some(dir) = pane() else {
        eprintln!(
            "skipped: webviews/src/agent-session/acpmux is not next to this crate (a sparse checkout)"
        );
        return;
    };
    let trust = read(&dir, "folderTrust.ts");
    let line =
        trust.lines().find(|l| l.contains("const LEVELS")).expect("LEVELS in folderTrust.ts");
    let mut levels: BTreeSet<String> =
        quoted_after(line, "[").into_iter().chain(quoted_after(line, ",")).collect();
    assert!(levels.remove("trusted"), "{levels:?}");
    assert_eq!(levels, policy().non_trusting_levels);
}
