//! The acpmux permission bridge's rules (`AcpmuxPermissionFeedBridge`): what a pending prompt posts
//! to the Feed, what the app keeps about it, and which answer goes back to the agent when the item
//! closes on another device.

use crate::json::{obj_at, str_at};
use crate::prompt::{self, digest, input_summary, shown_command};
use crate::proof::{self, Context, Decision, Failure, Key, Outcome, Scope};
use crate::text::{count, cut, prefix, scrub, visible};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

/// The localized texts the bridge posts; English by default. A template's `{name}`, `{agent}` and
/// `{text}` are filled in.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(default)]
pub struct Strings {
    pub summary: String,
    pub title: String,
    pub poster: String,
    pub question_agent: String,
    pub question_untitled: String,
    pub question_title: String,
}

impl Default for Strings {
    fn default() -> Self {
        Self {
            summary: "An agent asks to run a tool".into(),
            title: "Allow {name}?".into(),
            poster: "Agent".into(),
            question_agent: "An agent".into(),
            question_untitled: "{agent} asks a question".into(),
            question_title: "{agent} asks: {text}".into(),
        }
    }
}

/// `template` with each `{key}` of `values` filled in one pass (a value is never read again).
pub fn fill(template: &str, values: &[(&str, &str)]) -> String {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    'scan: while let Some((before, tail)) = rest.split_once('{') {
        out.push_str(before);
        for (key, value) in values {
            let placeholder = format!("{key}}}");
            if let Some(after) = tail.strip_prefix(&placeholder) {
                out.push_str(value);
                rest = after;
                continue 'scan;
            }
        }
        out.push('{');
        rest = tail;
    }
    out.push_str(rest);
    out
}

fn context(host: &str, session: &str) -> Value {
    json!({"host": prefix(host, 128), "acp_session": prefix(session, 128)})
}

fn wrap(params: Value, key: &str) -> Value {
    json!({"op": "feed.post", "params": params, "idempotency_key": prefix(key, 200), "origin": "script"})
}

/// The `feed.post` op a pending prompt posts: an approve request, or a high-priority notice for a
/// question (a question is answered on the Mac, never from the Feed).
pub fn post_body(
    session: &str,
    permission: &str,
    request: &Value,
    host: &str,
    strings: &Strings,
) -> Value {
    if prompt::is_question(request) {
        return question_body(session, permission, request, host, strings);
    }
    let call = request.get("toolCall").cloned().unwrap_or(Value::Null);
    let raw_title = str_at(&call, "title").unwrap_or_default();
    let title = visible(&scrub(raw_title));
    let kind = visible(str_at(&call, "kind").unwrap_or_default());
    let input = obj_at(&call, "rawInput").cloned().unwrap_or_default();
    let raw_command = shown_command(input.get("command"));
    let command = raw_command.as_deref().map(|command| visible(&scrub(command)));
    let summary = input_summary(&input);
    let redacted = raw_command.as_deref().is_some_and(|command| scrub(command) != command)
        || scrub(raw_title) != raw_title;
    let truncated = command.as_deref().map_or(0, count) > 8000
        || count(&title) > 500
        || count(&kind) > 200
        || redacted
        || summary.as_ref().is_some_and(|summary| summary.truncated);
    let action_type = match kind.as_str() {
        "execute" => "command",
        "edit" | "delete" | "move" => "edit",
        _ => "tool",
    };
    let mut action = Map::new();
    action.insert("type".into(), action_type.into());
    action.insert(
        "summary".into(),
        cut(if title.is_empty() { &strings.summary } else { &title }, 500).into(),
    );
    if !kind.is_empty() {
        action.insert("tool".into(), cut(&kind, 200).into());
    }
    if let Some(command) = command.as_deref().filter(|command| !command.is_empty()) {
        action.insert("command".into(), cut(command, 8000).into());
    }
    if let Some(summary) = &summary {
        action.insert("input".into(), json!(summary.fields));
    }
    if truncated {
        action.insert("truncated".into(), true.into());
    }
    let key = format!("acpmux:{permission}");
    let name = cut(if title.is_empty() { &kind } else { &title }, 120);
    let mut params = json!({
        "type": "request",
        "kind": "approve",
        "title": cut(&fill(&strings.title, &[("name", &name)]), 200),
        "prompt": {"action": action, "scopes": ["once"]},
        "context": context(host, session),
        "dedupe_key": prefix(&key, 200),
        "thread": prefix(&format!("acpmux:{session}"), 200),
        "poster": {"label": strings.poster},
    });
    if let Some(command) = command.as_deref().filter(|command| !command.is_empty())
        && let Some(params) = params.as_object_mut()
    {
        params.insert("body".into(), cut(command, 4096).into());
    }
    wrap(params, &key)
}

/// The notice a question posts.
pub fn question_body(
    session: &str,
    permission: &str,
    request: &Value,
    host: &str,
    strings: &Strings,
) -> Value {
    let call = request.get("toolCall").cloned().unwrap_or(Value::Null);
    let normalized = prompt::question(request);
    let first_item = normalized.and_then(|question| question.get("items")?.as_array()?.first());
    let asked = call.get("rawInput").and_then(|input| input.get("questions")?.as_array()?.first());
    let raw = first_item
        .and_then(|item| str_at(item, "prompt"))
        .or_else(|| asked.and_then(|asked| str_at(asked, "question")))
        .or_else(|| str_at(&call, "title"))
        .unwrap_or_default();
    let text = cut(&visible(&scrub(raw)), 160);
    let agent = normalized
        .and_then(|question| str_at(question, "agent"))
        .map(|agent| cut(&visible(agent), 60))
        .filter(|agent| !agent.is_empty())
        .unwrap_or_else(|| strings.question_agent.clone());
    let key = format!("acpmux:{permission}");
    let heading = if text.is_empty() {
        fill(&strings.question_untitled, &[("agent", &agent)])
    } else {
        fill(&strings.question_title, &[("agent", &agent), ("text", &text)])
    };
    let params = json!({
        "type": "notice",
        "kind": "notice",
        "title": cut(&heading, 200),
        "priority": "high",
        "expires_in_ms": 86_400_000,
        "context": context(host, session),
        "dedupe_key": prefix(&key, 200),
        "thread": prefix(&format!("acpmux:{session}"), 200),
        "poster": {"label": strings.poster},
    });
    wrap(params, &key)
}

/// What the bridge keeps about a posted item.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Posted {
    pub session: String,
    pub permission: String,
    /// The prompt's [`digest`] when posted.
    pub digest: String,
    /// The shown text's SHA-256 the proof signs.
    pub shown: String,
    pub truncated: bool,
    #[serde(default)]
    pub notice: bool,
}

/// The record of a post of `request` with `body` (as [`post_body`] built it).
pub fn posted(session: &str, permission: &str, request: &Value, body: &Value) -> Posted {
    let params = body.get("params").cloned().unwrap_or(Value::Null);
    let action = params
        .get("prompt")
        .and_then(|prompt| prompt.get("action"))
        .cloned()
        .unwrap_or_else(crate::json::empty);
    Posted {
        session: session.to_owned(),
        permission: permission.to_owned(),
        digest: digest(request),
        shown: proof::shown_sha256(&action),
        truncated: action.get("truncated").and_then(Value::as_bool).unwrap_or(false),
        notice: str_at(&params, "type") == Some("notice"),
    }
}

/// The `feed.cancel` op that withdraws an item whose prompt was answered elsewhere.
pub fn withdraw_body(item: &str) -> Value {
    json!({"op": "feed.cancel", "params": {"item": item, "reason": "answered_elsewhere"},
           "idempotency_key": format!("cancel:{item}"), "origin": "script"})
}

/// Why an answer from the Feed does not reach the agent.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Refusal {
    SessionAnswer,
    OwnInstall,
    ByNotPlain,
    NotPending,
    Changed,
    NotOffered,
    Scope,
    /// An allow of a prompt the phone saw shortened.
    Truncated,
    /// This Mac's install changed since the presence keys were read.
    InstallChanged,
    /// The phone's proof did not hold.
    Proof(Failure),
}

/// The option a decision answers with: an allow only for `once`.
pub fn option_for(decision: &Decision, offered: &[Value]) -> Result<String, Refusal> {
    if decision.outcome == Outcome::Allow
        && decision.scope.is_some_and(|scope| scope != Scope::Once)
    {
        return Err(Refusal::Scope);
    }
    prompt::option(decision.outcome == Outcome::Allow, offered).ok_or(Refusal::NotOffered)
}

/// Whether the answering install `by` may answer: never a session's answer or this Mac's own, and
/// only a plain install id.
pub fn admits(by: &str, own_install: Option<&str>) -> Result<(), Refusal> {
    if by.starts_with("session:") {
        return Err(Refusal::SessionAnswer);
    }
    if own_install == Some(by) {
        return Err(Refusal::OwnInstall);
    }
    let plain = (1..=128).contains(&count(by))
        && by.chars().all(|scalar| scalar.is_ascii_alphanumeric() || "_.:-".contains(scalar));
    if plain { Ok(()) } else { Err(Refusal::ByNotPlain) }
}

/// The presence keys and context read for an allow.
#[derive(Debug, Clone, PartialEq)]
pub struct Presence {
    pub context: Context,
    pub keys: BTreeMap<String, Key>,
}

/// The facts of a closed item's answer.
#[derive(Debug, Clone, PartialEq)]
pub struct AnswerFacts<'a> {
    pub item: &'a str,
    pub entry: &'a Posted,
    pub decision: &'a Decision,
    pub by: &'a str,
    pub own_install: Option<&'a str>,
    /// The prompt's request while it is still pending; `None` once it ended.
    pub pending: Option<&'a Value>,
    /// Read only for an allow; `None` until read.
    pub presence: Option<&'a Presence>,
    pub now_ms: f64,
}

/// What the bridge does with an answer.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "step", rename_all = "snake_case")]
pub enum AnswerStep {
    Refused {
        reason: Refusal,
    },
    /// An allow needs the presence keys: read them and ask again.
    NeedsPresence,
    /// Send `_acpmux/permission_respond` with these params.
    Respond {
        params: Value,
    },
}

/// The answer's step, in the bridge's order: the answering install, the prompt still pending and
/// unchanged, the option, a shortened prompt's allow, this Mac's install and the phone's proof.
pub fn answer(facts: &AnswerFacts<'_>) -> AnswerStep {
    let refused = |reason| AnswerStep::Refused { reason };
    if let Err(reason) = admits(facts.by, facts.own_install) {
        return refused(reason);
    }
    let Some(request) = facts.pending else { return refused(Refusal::NotPending) };
    if digest(request) != facts.entry.digest {
        return refused(Refusal::Changed);
    }
    let option = match option_for(facts.decision, &prompt::offered(request)) {
        Ok(option) => option,
        Err(reason) => return refused(reason),
    };
    if facts.decision.outcome == Outcome::Allow {
        if facts.entry.truncated {
            return refused(Refusal::Truncated);
        }
        let Some(presence) = facts.presence else { return AnswerStep::NeedsPresence };
        if facts.own_install.is_some_and(|own| presence.context.mac_install != own) {
            return refused(Refusal::InstallChanged);
        }
        if let Err(failure) = proof::check(
            facts.decision,
            facts.by,
            facts.item,
            &facts.entry.shown,
            &presence.context,
            &presence.keys,
            facts.now_ms,
        ) {
            return refused(Refusal::Proof(failure));
        }
    }
    AnswerStep::Respond {
        params: json!({
            "sessionId": facts.entry.session,
            "permissionId": facts.entry.permission,
            "optionId": option,
            "_meta": {"acpmux": {"answeredBy": {"device": facts.by, "feedItem": facts.item}}},
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fill_reads_each_value_once() {
        assert_eq!(
            fill("{agent} asks: {text}", &[("agent", "{text}"), ("text", "hi")]),
            "{text} asks: hi"
        );
        assert_eq!(fill("Allow {name}? {x}", &[("name", "ls")]), "Allow ls? {x}");
        assert_eq!(fill("é{{名}} {unknown} {", &[("名", "界")]), "é{界} {unknown} {");
    }

    #[test]
    fn admits_plain_installs_only() {
        assert_eq!(admits("session:abc", None), Err(Refusal::SessionAnswer));
        assert_eq!(admits("mac1", Some("mac1")), Err(Refusal::OwnInstall));
        assert_eq!(admits("has space", None), Err(Refusal::ByNotPlain));
        assert_eq!(admits("", None), Err(Refusal::ByNotPlain));
        assert_eq!(admits(&"a".repeat(129), None), Err(Refusal::ByNotPlain));
        assert_eq!(admits("inst_01:phone-2.a", Some("mac1")), Ok(()));
    }
}
