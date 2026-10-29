//! Agent questions inside permission requests (plans/cmux-next/agent-questions.md).
//!
//! Claude Code's AskUserQuestion and a Codex user-input request reach the
//! hub as `session/request_permission` with the questions in the tool input.
//! The hub adds one harness-neutral copy, `toolCall._meta.acpmux.question`
//! (`{harness, agent, items: [{id, header?, prompt, options: [{id, label,
//! detail?, preview?: {text, format}}], multiSelect, allowsOther, input?}]}`;
//! `input: "number"` marks a typed number, `claude_stdio/elicitation.rs`), so
//! every client renders the same model, and it checks a client's `answers`
//! against it before they reach the agent.
//!
//! A preview's `format` is `monospace` (Claude Code's default: Markdown in a
//! monospace box), or `html` when the session's Claude Code was launched with
//! `CLAUDE_CODE_QUESTION_PREVIEW_FORMAT=html` ([`PreviewFormat::of`]): it then
//! writes each preview as an HTML fragment with inline styles and no script
//! or style tag, and refuses one that is not before the card is shown.
//!
//! A question is never answered by policy: approve-all, approve rules and
//! the chat allowance do not apply to it (only deny-all and deny rules may
//! decline it), so an answer always comes from a person, or, for a
//! sub-session, from a session above it (`subsession_answer.rs`).

use crate::rpc::RpcError;
use cmux_json::JsonSet as _;
use serde_json::{Map, Value, json};

/// The normalized question of a request, when it carries one.
pub(super) fn question(request: &Value) -> Option<&Value> {
    request.pointer("/toolCall/_meta/acpmux/question").filter(|q| q["items"].is_array())
}

/// The folder a trust request asks about (`hub/trust_wait.rs`): a card the daemon raises on a
/// session that wants to start a sub-session in a folder nobody answered for. It renders as a
/// choice question (`question` with the `acp` harness: the answer is the picked option, no
/// `answers`), and only a person answers it, never a policy.
pub(super) fn trust_cwd(request: &Value) -> Option<&str> {
    request.pointer("/toolCall/_meta/acpmux/trust/cwd").and_then(Value::as_str)
}

/// True when policy and batches must not answer the request: a question.
/// Other interactive requests (plan approval) keep their policy behavior.
pub(super) fn needs_person(request: &Value) -> bool {
    question(request).is_some()
        || matches!(
            request.pointer("/toolCall/_meta/claude/tool").and_then(Value::as_str),
            Some("AskUserQuestion")
        )
}

/// Whether a session above the asking one may answer `request`
/// (`subsession_answer.rs`): a question by a signal the agent's tool input
/// cannot forge, with a one-time allow. `from_agent` is false for a request
/// acpmux builds itself from Grok's or Cursor's own ask kinds (`xai.rs`,
/// `cursor_ext.rs`); an agent's `session/request_permission` counts only as
/// Claude Code's AskUserQuestion (`_meta.claude.tool`, which the adapter
/// writes from the tool's name). Any other tool whose input holds
/// `questions` (an MCP tool, ExitPlanMode), a writer's own
/// `_meta.acpmux.question`, a Codex user-input request (its adapter's
/// shape is unverified) and the folder-trust card (`trust_cwd`) stay the person's.
pub(super) fn ancestor_answerable(request: &Value, from_agent: bool) -> bool {
    let asks = question(request).is_some()
        && trust_cwd(request).is_none()
        && (!from_agent
            || request.pointer("/toolCall/_meta/claude/tool").and_then(Value::as_str)
                == Some("AskUserQuestion"));
    let allow_once = request["options"]
        .as_array()
        .is_some_and(|options| options.iter().any(|o| o["kind"] == "allow_once"));
    asks && allow_once
}

/// Checks a reply to `request`: answers go only with an allow option, and a
/// question is allowed only with answers (an empty allow would hand the
/// agent a blank answer nobody gave). A reject or a cancel needs none.
pub(super) fn check_reply(
    request: &Value,
    option_id: Option<&str>,
    answers: Option<&Value>,
) -> Result<(), RpcError> {
    let kind = option_id.and_then(|id| {
        request["options"].as_array()?.iter().find(|o| o["optionId"] == id)?["kind"].as_str()
    });
    let allows = kind.is_some_and(|k| k.starts_with("allow"));
    match answers {
        Some(_) if !allows => Err(RpcError::invalid_params("answers go only with an allow option")),
        Some(answers) => check_answers(request, answers),
        None if allows && needs_person(request) && trust_cwd(request).is_none() => {
            Err(RpcError::invalid_params(
                "this is a question: answer it with `acpmux answer <session> --answer \"<question or id>=<choice>\"` (one --answer per question), in the agent tab or Home card, or decline it with `acpmux deny <session>`",
            ))
        }
        None => Ok(()),
    }
}

/// The normalized items of Claude-shaped `questions` (`{question, header?,
/// options: [{label, description?, preview?}], multiSelect?}`), answered by
/// question text: the shape Grok's `x.ai/ask_user_question` also uses.
pub(super) fn items_by_text(questions: &[Value]) -> Vec<Value> {
    questions
        .iter()
        .enumerate()
        .filter_map(|(index, q)| item(q, index, false, PreviewFormat::Monospace))
        .collect()
}

/// The normalized items of Codex-shaped `questions` (`{id, question,
/// options: [{label, description?}], multiSelect?, isOther?}`), answered by
/// item id with `{answers: [labels]}`: the shape Cursor's
/// `cursor/ask_question` maps onto.
pub(super) fn items_by_id(questions: &[Value]) -> Vec<Value> {
    questions
        .iter()
        .enumerate()
        .filter_map(|(index, q)| item(q, index, true, PreviewFormat::Monospace))
        .collect()
}

/// How the asking agent writes its option previews.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum PreviewFormat {
    /// Markdown or plain text for a monospace box (every agent but the one below).
    #[default]
    Monospace,
    /// An HTML fragment: a Claude Code told so by its launch environment.
    Html,
}

/// The variable Claude Code reads its preview format from (the Agent SDK's
/// `toolConfig.askUserQuestion.previewFormat` sets the same one).
pub(crate) const PREVIEW_FORMAT_ENV: &str = "CLAUDE_CODE_QUESTION_PREVIEW_FORMAT";

impl PreviewFormat {
    /// The format a Claude Code launched with `env` writes. Only the literal
    /// `html` counts: anything else (unset, `markdown`, a reference not
    /// resolved here) keeps the monospace box, which shows any text as it is.
    pub fn of(claude: bool, env: &std::collections::BTreeMap<String, String>) -> Self {
        match env.get(PREVIEW_FORMAT_ENV).map(|v| v.trim()) {
            Some("html") if claude => Self::Html,
            _ => Self::Monospace,
        }
    }

    pub(super) fn from_flag(html: bool) -> Self {
        if html { Self::Html } else { Self::Monospace }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Monospace => "monospace",
            Self::Html => "html",
        }
    }

    /// The value of [`PREVIEW_FORMAT_ENV`] that makes Claude Code write this format.
    pub(crate) fn claude_value(self) -> &'static str {
        match self {
            Self::Monospace => "markdown",
            Self::Html => "html",
        }
    }
}

/// Adds `toolCall._meta.acpmux.question` when the tool input holds
/// questions and no writer added one yet. `previews` is how the asking
/// agent writes previews; a Codex-shaped ask has none, so it never matters there.
pub(super) fn normalize(request: &mut Value, previews: PreviewFormat) {
    if question(request).is_some() {
        return;
    }
    let tool = &request["toolCall"];
    let questions =
        tool.pointer("/rawInput/questions").and_then(Value::as_array).cloned().unwrap_or_default();
    if questions.is_empty() {
        return;
    }
    let codex =
        tool.pointer("/_meta/codex").is_some() || questions.iter().any(|q| q["id"].is_string());
    let items: Vec<Value> = questions
        .iter()
        .enumerate()
        .filter_map(|(index, q)| item(q, index, codex, previews))
        .collect();
    if items.is_empty() {
        return;
    }
    let (harness, agent) = if codex { ("codex", "Codex") } else { ("claude", "Claude Code") };
    let normalized = json!({"harness": harness, "agent": agent, "items": items});
    let Some(tool) = request.get_mut("toolCall").and_then(Value::as_object_mut) else { return };
    let meta = tool.entry("_meta").or_insert_with(|| json!({}));
    if !meta.is_object() {
        *meta = json!({});
    }
    if let Some(acpmux) =
        meta.as_object_mut().map(|m| m.entry("acpmux").or_insert_with(|| json!({})))
    {
        if !acpmux.is_object() {
            *acpmux = json!({});
        }
        if let Some(acpmux) = acpmux.as_object_mut() {
            acpmux.insert("question".into(), normalized);
        }
    }
}

fn text(value: &Value) -> Option<String> {
    value.as_str().map(str::trim).filter(|s| !s.is_empty()).map(str::to_owned)
}

fn item(q: &Value, index: usize, codex: bool, previews: PreviewFormat) -> Option<Value> {
    // The prompt keeps its exact text: Claude Code matches answers by it.
    text(&q["question"])?;
    let prompt = q["question"].as_str()?.to_owned();
    let mut seen: Map<String, Value> = Map::new();
    let options: Vec<Value> = q["options"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|o| {
            let label = text(&o["label"])?;
            let count = seen.get(&label).and_then(Value::as_u64).unwrap_or(0) + 1;
            seen.insert(label.clone(), json!(count));
            let id = if count > 1 { format!("{label}#{count}") } else { label.clone() };
            let mut option = json!({"id": id, "label": label});
            if let Some(detail) = text(&o["description"]) {
                option.set("detail", json!(detail));
            }
            if let Some(preview) = text(&o["preview"]) {
                option.set("preview", json!({"text": preview, "format": previews.name()}));
            }
            Some(option)
        })
        .collect();
    let id = if codex {
        text(&q["id"]).unwrap_or_else(|| format!("q{index}"))
    } else {
        format!("q{index}")
    };
    let allows_other =
        if codex { q["isOther"].as_bool().unwrap_or(false) || options.is_empty() } else { true };
    let mut item = json!({
        "id": id, "prompt": prompt, "options": options,
        "multiSelect": q["multiSelect"].as_bool().unwrap_or(false), "allowsOther": allows_other,
    });
    if let Some(header) = text(&q["header"]) {
        item.set("header", json!(header));
    }
    Some(item)
}

/// The most items one answer may hold.
pub(super) const MAX_ANSWER_ITEMS: usize = 64;
/// The most strings one item's list may hold.
pub(super) const MAX_ANSWER_LIST_STRINGS: usize = 64;
/// The most UTF-8 bytes of one item key, and of each string of an item's value.
pub(super) const MAX_ANSWER_BYTES: usize = 4096;

/// Checks a client's `answers` for `request`. Answers are accepted only for
/// a question, in the asking harness's shape: Claude Code (and the Chief) by
/// question text with one non-empty string each; Codex by item id with
/// `{answers: [string, ...]}`. Every item must be answered, nothing else.
/// The daemon bounds them itself (it does not trust a client's relay): at
/// most [`MAX_ANSWER_ITEMS`] items, [`MAX_ANSWER_LIST_STRINGS`] strings per
/// list and [`MAX_ANSWER_BYTES`] bytes per key or string, the limits of the
/// Swift pane relay (`AcpmuxPaneMethods+Answers`).
pub(super) fn check_answers(request: &Value, answers: &Value) -> Result<(), RpcError> {
    let invalid = |why: &str| Err(RpcError::invalid_params(format!("answers {why}")));
    let Some(question) = question(request) else {
        return invalid("are accepted only for a question");
    };
    let Some(answers) = answers.as_object() else { return invalid("must be an object") };
    if answers.len() > MAX_ANSWER_ITEMS {
        return invalid(&format!("may hold at most {MAX_ANSWER_ITEMS} items"));
    }
    let too_long = |text: &str| text.len() > MAX_ANSWER_BYTES;
    if answers.iter().any(|(key, value)| {
        too_long(key)
            || match value {
                Value::String(text) => too_long(text),
                Value::Object(codex) => {
                    codex.get("answers").and_then(Value::as_array).is_some_and(|list| {
                        list.len() > MAX_ANSWER_LIST_STRINGS
                            || list.iter().any(|s| s.as_str().is_some_and(too_long))
                    })
                }
                _ => false,
            }
    }) {
        return invalid(&format!(
            "may hold at most {MAX_ANSWER_LIST_STRINGS} strings per item and {MAX_ANSWER_BYTES} bytes per key or string"
        ));
    }
    let items = question["items"].as_array().cloned().unwrap_or_default();
    let codex = question["harness"] == "codex";
    let keys: Vec<String> = items
        .iter()
        .filter_map(|item| {
            if codex { text(&item["id"]) } else { item["prompt"].as_str().map(str::to_owned) }
        })
        .collect();
    if answers.len() != keys.len() || keys.iter().any(|k| !answers.contains_key(k)) {
        return invalid("must answer every question and nothing else");
    }
    for key in &keys {
        let value = &answers[key];
        let ok = if codex {
            // `{answers: [...]}` with that one key: nothing else rides along
            // into the agent's tool input unchecked.
            value.as_object().is_some_and(|o| o.len() == 1)
                && value["answers"]
                    .as_array()
                    .is_some_and(|list| !list.is_empty() && list.iter().all(|s| text(s).is_some()))
        } else {
            text(value).is_some()
        };
        if !ok {
            return invalid("must not be empty");
        }
    }
    // An item that takes no answer of the person's own (an MCP form's choice,
    // `claude_stdio/elicitation.rs`) takes only its labels: one, or for a
    // multi-select several, each once, joined by ", ".
    for item in items.iter().filter(|i| !codex && i["allowsOther"] == false) {
        let Some(answer) = item["prompt"].as_str().and_then(|k| answers.get(k)?.as_str()) else {
            continue;
        };
        let labels: Vec<&str> = item["options"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|o| o["label"].as_str())
            .collect();
        let picked: Vec<&str> = if item["multiSelect"] == true {
            answer.split(", ").map(str::trim).collect()
        } else {
            vec![answer.trim()]
        };
        let mut seen = std::collections::HashSet::new();
        if !picked.iter().all(|p| labels.contains(p) && seen.insert(*p)) {
            return invalid("must be the item's own options where it takes no other answer");
        }
    }
    Ok(())
}

/// The most UTF-8 bytes of one answer's notes (Claude Code's own limit is 8192 characters).
pub(super) const MAX_NOTES_BYTES: usize = 8192;

/// Checks a client's `annotations` and returns what goes into the tool input beside `answers`.
/// They are Claude Code's AskUserQuestion answer field (question text -> `{preview?, notes?}`):
/// the agent reads `"Q"="A" selected preview: <mockup> notes: <text>`, so it learns which mockup
/// the person picked. Only Claude Code's own AskUserQuestion (`_meta.claude.tool`, with its
/// `questions` in the tool input) gets them; for any other question they are dropped (`None`),
/// never refused, so a card that sends them for a Claude-shaped ask from another agent still
/// answers it. Keyed by a question's exact text; `preview` must be one of that question's option
/// previews as the card shows it (trimmed, `normalize`), and the agent's own text goes back,
/// since Claude Code refuses a preview it did not write; `notes` is free text of at most
/// [`MAX_NOTES_BYTES`] bytes. Nothing else rides along.
pub(super) fn check_annotations(
    request: &Value,
    annotations: &Value,
) -> Result<Option<Value>, RpcError> {
    let invalid = |why: &str| Err(RpcError::invalid_params(format!("annotations {why}")));
    let asks = request.pointer("/toolCall/_meta/claude/tool").and_then(Value::as_str)
        == Some("AskUserQuestion")
        && question(request).is_some_and(|q| q["harness"] == "claude");
    let questions = request.pointer("/toolCall/rawInput/questions").and_then(Value::as_array);
    let (true, Some(questions)) = (asks, questions) else {
        return Ok(None);
    };
    let Some(annotations) = annotations.as_object().filter(|a| !a.is_empty()) else {
        return invalid("must be a non-empty object");
    };
    if annotations.len() > MAX_ANSWER_ITEMS {
        return invalid(&format!("may hold at most {MAX_ANSWER_ITEMS} items"));
    }
    let mut out = Map::new();
    for (key, value) in annotations {
        let Some(asked) = questions.iter().find(|q| q["question"].as_str() == Some(key.as_str()))
        else {
            return invalid("must name a question by its text");
        };
        let Some(value) = value
            .as_object()
            .filter(|v| !v.is_empty() && v.keys().all(|k| k == "preview" || k == "notes"))
        else {
            return invalid("must be {preview?, notes?} per question");
        };
        let mut note = Map::new();
        if let Some(preview) = value.get("preview") {
            let shown = preview.as_str().map(str::trim);
            let raw = asked["options"].as_array().into_iter().flatten().find_map(|o| {
                (shown.is_some() && text(&o["preview"]).as_deref() == shown)
                    .then(|| o["preview"].clone())
            });
            let Some(raw) = raw else {
                return invalid("preview must be one of the question's option previews");
            };
            note.insert("preview".into(), raw);
        }
        if let Some(notes) = value.get("notes") {
            match notes.as_str() {
                Some(n) if !n.trim().is_empty() && n.len() <= MAX_NOTES_BYTES => {
                    note.insert("notes".into(), json!(n));
                }
                _ => {
                    return invalid(&format!("notes must be text of 1 to {MAX_NOTES_BYTES} bytes"));
                }
            }
        }
        out.insert(key.clone(), Value::Object(note));
    }
    Ok(Some(Value::Object(out)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ask(preview: &str) -> Value {
        json!({
            "toolCall": {
                "toolCallId": "toolu_1",
                "rawInput": {"questions": [{
                    "question": "Which card?", "header": "Card",
                    "options": [
                        {"label": "Glass", "description": "Frosted", "preview": preview},
                        {"label": "Plain", "description": "Flat"},
                    ],
                }]},
                "_meta": {"claude": {"tool": "AskUserQuestion", "interactive": true}},
            },
            "options": [{"optionId": "allow_once", "name": "Answer", "kind": "allow_once"}],
        })
    }

    fn preview_of(request: &Value) -> &Value {
        &question(request).unwrap()["items"][0]["options"][0]["preview"]
    }

    #[test]
    fn previews_are_monospace_unless_the_launch_says_html() {
        let mut plain = ask("┌──┐\n│ab│\n└──┘");
        normalize(&mut plain, PreviewFormat::Monospace);
        assert_eq!(preview_of(&plain), &json!({"text": "┌──┐\n│ab│\n└──┘", "format": "monospace"}));

        let fragment = r#"<div style="padding:8px">Glass</div>"#;
        let mut html = ask(fragment);
        normalize(&mut html, PreviewFormat::Html);
        assert_eq!(preview_of(&html), &json!({"text": fragment, "format": "html"}));
        // An option without a preview stays without one.
        assert!(question(&html).unwrap()["items"][0]["options"][1].get("preview").is_none());
    }

    #[test]
    fn only_a_claude_launch_with_the_literal_html_writes_html() {
        let env = |value: &str| {
            std::collections::BTreeMap::from([(PREVIEW_FORMAT_ENV.to_owned(), value.to_owned())])
        };
        assert_eq!(PreviewFormat::of(true, &env("html")), PreviewFormat::Html);
        assert_eq!(PreviewFormat::of(true, &env(" html ")), PreviewFormat::Html);
        assert_eq!(PreviewFormat::of(true, &env("markdown")), PreviewFormat::Monospace);
        assert_eq!(PreviewFormat::of(true, &env("${FORMAT}")), PreviewFormat::Monospace);
        assert_eq!(PreviewFormat::of(true, &Default::default()), PreviewFormat::Monospace);
        // Another harness reading the variable is not Claude Code's preview format.
        assert_eq!(PreviewFormat::of(false, &env("html")), PreviewFormat::Monospace);
    }

    #[test]
    fn a_question_normalized_earlier_keeps_its_format() {
        let mut request = ask("<b>x</b>");
        normalize(&mut request, PreviewFormat::Html);
        normalize(&mut request, PreviewFormat::Monospace);
        assert_eq!(preview_of(&request)["format"], "html");
    }

    /// An item that takes no answer of the person's own (an MCP form's choice)
    /// takes only its labels, each once.
    #[test]
    fn an_item_without_other_answers_takes_only_its_labels() {
        let request = json!({"toolCall": {"_meta": {"acpmux": {"question": {"harness": "claude", "items": [
            {"id": "q0", "prompt": "Region", "multiSelect": false, "allowsOther": false,
             "options": [{"id": "EU", "label": "EU"}, {"id": "US", "label": "US"}]},
            {"id": "q1", "prompt": "Tags", "multiSelect": true, "allowsOther": false,
             "options": [{"id": "a", "label": "a"}, {"id": "b", "label": "b"}]},
            {"id": "q2", "prompt": "Note", "multiSelect": false, "allowsOther": true, "options": []},
        ]}}}}});
        let check = |region: &str, tags: &str| {
            check_answers(&request, &json!({"Region": region, "Tags": tags, "Note": "free text"}))
        };
        assert!(check("EU", "a, b").is_ok());
        assert!(check("Mars", "a").is_err());
        assert!(check("EU", "a, c").is_err());
        assert!(check("EU", "a, a").is_err());
        assert!(check("EU, US", "a").is_err());
    }
}
