//! The lists against what the page sends (webviews/src/agent-session/acpmux),
//! as AcpmuxPaneMethods.swift says they were made: every
//! `this.request("...")` in direct.ts and sessionPages.ts, the literal method
//! of each `typedRequest(send, "...", ...)` and `this.typed("...", ...)` in
//! direct.ts (the typed protocol client, #20576, #20894), `SIDE_SESSION_METHOD`
//! (needsYou/asks.ts), `HANDOFF_OPS` (handoff/protocol.ts),
//! `PERMISSION_GROUP_OPS` (permissions/protocol.ts), `FORK_OP`
//! (operations.ts), `PREWARM_METHOD` and `MCP_RECONNECT_METHOD` (direct.ts), `this.send("...")` in
//! multiplayer/presenceClient.ts, `RETRY_METHOD` (subagents/retryState.ts), and the raw
//! `session/cancel` notification. `file.search` (and the git reads, sent by a
//! variable) go to the socket only in mock mode and stay off the list. Folder
//! trust levels (folderTrust.ts `LEVELS`) give the gesture rule's
//! non-trusting levels. The `_meta.acpmux` keys direct.ts writes on
//! `session/prompt` and `session/new` are checked against `known_params`.

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

/// The literal method of each `typedRequest(send, "method", params)` call:
/// the first `"..."` after a `, ` on the call's line. A call that names its
/// method by a constant (`PERMISSION_GROUP_OPS.respond`) has none and is read
/// from that constant's object instead.
fn typed_request_methods(text: &str) -> Vec<String> {
    text.split("typedRequest(")
        .skip(1)
        .filter_map(|after| {
            let line = after.lines().next().unwrap_or_default();
            quoted_after(line, ", ").into_iter().next()
        })
        .collect()
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
    sent.extend(typed_request_methods(&direct));
    // The typed protocol client's method on the connection (`this.typed("...", params)`).
    sent.extend(quoted_after(&direct, "this.typed("));
    // `/btw` and Needs you's Ask about this send `SIDE_SESSION_METHOD` (needsYou/asks.ts).
    sent.insert(constant(&read(&dir, "needsYou/asks.ts"), "SIDE_SESSION_METHOD"));
    sent.extend(quoted_after(&read(&dir, "sessionPages.ts"), "this.request("));
    sent.extend(object_values(&read(&dir, "handoff/protocol.ts"), "HANDOFF_OPS"));
    sent.extend(object_values(&read(&dir, "permissions/protocol.ts"), "PERMISSION_GROUP_OPS"));
    sent.insert(constant(&read(&dir, "operations.ts"), "FORK_OP"));
    sent.insert(constant(&direct, "PREWARM_METHOD"));
    sent.insert(constant(&direct, "MCP_RECONNECT_METHOD"));
    // A chat's typing (multiplayer/presenceClient.ts) and a failed subagent's, sub-session's or
    // turn's Retry (subagents/retryState.ts `RETRY_METHOD`, sent through direct.ts `retry`).
    sent.extend(quoted_after(&read(&dir, "multiplayer/presenceClient.ts"), "this.send("));
    sent.insert(constant(&read(&dir, "subagents/retryState.ts"), "RETRY_METHOD"));
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

/// The body of the `{ ... }` that opens at byte `open` of `text`.
fn braced(text: &str, open: usize) -> &str {
    let mut depth = 0;
    for (i, c) in text[open..].char_indices() {
        match c {
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if depth == 0 {
                    return &text[open + 1..open + i];
                }
            }
            _ => {}
        }
    }
    panic!("unclosed brace in {}", &text[open..text.len().min(open + 80)]);
}

/// The keys an object literal's body names: `name: value`, a shorthand
/// `name`, the keys of a conditional spread `...(c ? { name: v } : {})`, and
/// for each spread call `...f()` the keys of `f`'s return type (in direct.ts
/// or the file direct.ts imports it from). A value's own nested keys are not
/// the literal's. Full-line `//` comments are skipped.
fn literal_keys(dir: &Path, direct: &str, body: &str) -> BTreeSet<String> {
    enum Open {
        Paren { spread: bool },
        Brace { keys: bool },
        Other,
    }
    let body: String = body
        .lines()
        .filter(|line| !line.trim_start().starts_with("//"))
        .collect::<Vec<_>>()
        .join("\n");
    let ident = |c: char| c.is_ascii_alphanumeric() || c == '_' || c == '$';
    let chars: Vec<char> = body.chars().collect();
    let spread_at = |i: usize| i >= 3 && chars[i - 3..i] == ['.', '.', '.'];
    let mut stack: Vec<Open> = Vec::new();
    let mut keys = BTreeSet::new();
    let mut i = 0;
    while i < chars.len() {
        let c = chars[i];
        if ident(c) && (i == 0 || !ident(chars[i - 1])) {
            let end = (i..chars.len()).find(|&j| !ident(chars[j])).unwrap_or(chars.len());
            let name: String = chars[i..end].iter().collect();
            let before = chars[..i].iter().rev().find(|c| !c.is_whitespace()).copied();
            let after = chars[end..].iter().find(|c| !c.is_whitespace()).copied();
            let at_keys = match stack.last() {
                None => true,
                Some(Open::Brace { keys }) => *keys,
                _ => false,
            };
            if spread_at(i) && after == Some('(') && stack.is_empty() {
                keys.extend(returned_keys(dir, direct, &name));
            } else if at_keys
                && matches!(before, None | Some('{') | Some(','))
                && matches!(after, None | Some(':') | Some(',') | Some('}'))
            {
                keys.insert(name);
            }
            i = end;
            continue;
        }
        match c {
            '(' => stack.push(Open::Paren { spread: spread_at(i) && stack.is_empty() }),
            '{' => {
                let keys = matches!(stack.last(), Some(Open::Paren { spread: true }));
                stack.push(Open::Brace { keys });
            }
            '[' => stack.push(Open::Other),
            ')' | '}' | ']' => {
                stack.pop();
            }
            _ => {}
        }
        i += 1;
    }
    keys
}

/// The keys of the object type `function name(): { ... }` returns, found in
/// direct.ts or in the file direct.ts imports `name` from.
fn returned_keys(dir: &Path, direct: &str, name: &str) -> BTreeSet<String> {
    let signature = format!("function {name}(");
    let source = if direct.contains(&signature) {
        direct.to_owned()
    } else {
        let import = direct
            .lines()
            .find(|line| {
                line.starts_with("import {")
                    && line.split(['{', '}', ',']).any(|part| part.trim() == name)
            })
            .unwrap_or_else(|| panic!("direct.ts spreads {name}() but has no import of it"));
        let from = quoted_after(import, "from").into_iter().next().expect("import path");
        read(dir, &format!("{}.ts", from.trim_start_matches("./")))
    };
    let start = source.find(&signature).unwrap_or_else(|| panic!("{signature} not found"));
    let returns = start + source[start..].find("): {").expect("an object return type") + 3;
    literal_keys(dir, direct, braced(&source, returns))
}

/// The `_meta.acpmux` keys of every `this.request("method", ...)` in direct.ts
/// whose params write an `acpmux: { ... }` before the next request.
fn sent_acpmux_keys(dir: &Path, direct: &str, method: &str) -> BTreeSet<String> {
    let call = format!("this.request(\"{method}\"");
    let mut keys = BTreeSet::new();
    let mut found = 0;
    for (at, _) in direct.match_indices(&call) {
        let rest = &direct[at + call.len()..];
        let next = rest.find("this.request(").unwrap_or(rest.len());
        let Some(open) = rest[..next].find("acpmux: {") else { continue };
        found += 1;
        let open = at + call.len() + open + "acpmux: ".len();
        keys.extend(literal_keys(dir, direct, braced(direct, open)));
    }
    assert!(found > 0, "no {method} request in direct.ts writes _meta.acpmux");
    keys
}

/// The `_meta.acpmux` keys the page sends with `session/prompt` and
/// `session/new` are ones the hosts let through (`known_params`): the hosts
/// refuse a frame with any other as `transport.intent_invalid`. #22742's Retry
/// sent `resend`, which only the host may set (#22881), and every Retry
/// failed with "The pane sent a request the app does not accept".
#[test]
fn the_page_sends_only_allowed_acpmux_meta() {
    let dir = pane();
    let direct = read(&dir, "direct.ts");
    let prompt = sent_acpmux_keys(&dir, &direct, "session/prompt");
    assert!(prompt.contains("promptId"), "{prompt:?}");
    let allowed = &policy().known_params["session/prompt"].acpmux;
    let extra: Vec<_> = prompt.difference(allowed).collect();
    assert!(extra.is_empty(), "session/prompt _meta.acpmux keys the hosts refuse: {extra:?}");
    let start =
        direct.find("export function newSessionParams(").expect("newSessionParams in direct.ts");
    let body = &direct[start..];
    let body = &body[..body.find("\n}").unwrap()];
    let mut new = BTreeSet::new();
    for (at, _) in body.match_indices("acpmux: {") {
        new.extend(literal_keys(&dir, &direct, braced(body, at + "acpmux: ".len())));
    }
    assert_eq!(new, policy().known_params["session/new"].acpmux, "session/new _meta.acpmux keys");
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
