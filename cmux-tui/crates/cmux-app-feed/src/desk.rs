//! The agent dialogs the control socket lists and answers (`AgentDialogDesk`): each pending prompt
//! as a list item, the deny a script may send, and the answer a question's selections make.
//!
//! The question itself (`AgentQuestion`, from the request) is still parsed by the app's
//! CmuxAgentQuestion package and handed here normalized:
//! `{harness, items: [{id, header?, prompt, multi_select, allows_other, options: [{id, label}]}]}`.

use crate::json::{obj_at, str_at};
use crate::prompt::{self, shown_command};
use crate::text::{cut, same_ignoring_case, scrub, trim_inline, visible};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};
use std::collections::BTreeMap;

/// How many answered dialogs the list keeps.
pub const ANSWERED_LIMIT: usize = 50;

/// A pending prompt as the desk reads it.
#[derive(Debug, Clone, PartialEq, Deserialize)]
pub struct Pending {
    pub permission: String,
    pub session: String,
    #[serde(default)]
    pub session_name: Option<String>,
    #[serde(default)]
    pub request: Value,
}

/// A normalized question.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Question {
    #[serde(default)]
    pub harness: String,
    #[serde(default)]
    pub items: Vec<QuestionItem>,
    /// The option a decline answers with, when the question has one.
    #[serde(default, skip_serializing)]
    pub decline_option: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionItem {
    pub id: String,
    #[serde(default)]
    pub header: Option<String>,
    #[serde(default)]
    pub prompt: String,
    #[serde(default)]
    pub multi_select: bool,
    #[serde(default)]
    pub allows_other: bool,
    #[serde(default)]
    pub options: Vec<QuestionOption>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionOption {
    pub id: String,
    pub label: String,
}

fn or_null(text: Option<&str>) -> Value {
    text.map_or(Value::Null, Value::from)
}

/// The list item of a pending (or answered, by `status`) prompt.
pub fn item(
    prompt: &Pending,
    question: Option<&Question>,
    tab: Option<&str>,
    status: &str,
) -> Value {
    let call = prompt.request.get("toolCall").cloned().unwrap_or(Value::Null);
    let title = cut(&visible(&scrub(str_at(&call, "title").unwrap_or_default())), 500);
    let mut item = Map::new();
    item.insert("id".into(), prompt.permission.clone().into());
    item.insert("request_id".into(), prompt.permission.clone().into());
    item.insert("status".into(), status.into());
    item.insert("source".into(), "acpmux".into());
    item.insert("session_id".into(), prompt.session.clone().into());
    item.insert("agent_session".into(), prompt.session.clone().into());
    item.insert("title".into(), title.into());
    item.insert("session_name".into(), or_null(prompt.session_name.as_deref()));
    item.insert("tab_id".into(), or_null(tab));
    if let Some(question) = question {
        item.insert("kind".into(), "question".into());
        item.insert("harness".into(), question.harness.clone().into());
        let questions: Vec<Value> = question
            .items
            .iter()
            .map(|entry| {
                json!({
                    "id": entry.id, "header": or_null(entry.header.as_deref()), "prompt": entry.prompt,
                    "multi_select": entry.multi_select, "allows_other": entry.allows_other,
                    "options": entry.options.iter().map(|option| json!({"id": option.id, "label": option.label})).collect::<Vec<_>>(),
                })
            })
            .collect();
        item.insert("questions".into(), questions.into());
    } else {
        item.insert("kind".into(), "permissionRequest".into());
        if let Some(kind) = str_at(&call, "kind") {
            item.insert("tool".into(), cut(&visible(kind), 200).into());
        }
        let input = obj_at(&call, "rawInput").cloned().unwrap_or_default();
        if let Some(command) = shown_command(input.get("command")) {
            item.insert("command".into(), cut(&visible(&scrub(&command)), 8000).into());
        }
        let options: Vec<Value> = prompt::offered(&prompt.request)
            .iter()
            .map(|option| {
                json!({"id": or_null(str_at(option, "optionId")), "kind": or_null(str_at(option, "kind")),
                       "name": or_null(str_at(option, "name"))})
            })
            .collect();
        item.insert("options".into(), options.into());
    }
    Value::Object(item)
}

/// A control error: its code, message and the request it names.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct DeskError {
    pub code: String,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub request_id: Option<String>,
}

impl DeskError {
    fn invalid(message: impl Into<String>) -> Self {
        Self { code: "invalid_params".into(), message: message.into(), request_id: None }
    }
}

/// The `_acpmux/permission_respond` params of a script's `mode` for a pending prompt: only a deny
/// is sent from a script; a person approves in cmux.
pub fn deny_reply(
    mode: &str,
    prompt: &Pending,
    question: Option<&Question>,
) -> Result<Value, DeskError> {
    if mode != "deny" {
        return Err(DeskError {
            code: "person_required".into(),
            message: "Only a deny can be sent here; a person approves permissions in cmux".into(),
            request_id: Some(prompt.permission.clone()),
        });
    }
    let mut reply = Map::from_iter([
        ("sessionId".into(), prompt.session.clone().into()),
        ("permissionId".into(), prompt.permission.clone().into()),
    ]);
    let option = match question {
        Some(question) => question.decline_option.clone(),
        None => prompt::option(false, &prompt::offered(&prompt.request)),
    };
    if let Some(option) = option {
        reply.insert("optionId".into(), option.into());
    }
    Ok(Value::Object(reply))
}

/// One question item's answer: the chosen options and any other text.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Selection {
    pub option_ids: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub other: Option<String>,
}

/// The answer `selections` make to `question` (each `ITEM=CHOICE`, or a bare choice when the
/// question has one item), by item id.
pub fn answer(
    selections: &[String],
    question: &Question,
) -> Result<BTreeMap<String, Selection>, DeskError> {
    let mut chosen: BTreeMap<String, Selection> = BTreeMap::new();
    for selection in selections {
        let (item, value) = target(selection, question)?;
        let current = chosen.entry(item.id.clone()).or_default();
        let found =
            item.options.iter().find(|option| option.id == value || option.label == value).or_else(
                || {
                    item.options.iter().find(|option| {
                        same_ignoring_case(&option.id, &value)
                            || same_ignoring_case(&option.label, &value)
                    })
                },
            );
        if let Some(found) = found {
            if !current.option_ids.contains(&found.id) {
                current.option_ids.push(found.id.clone());
            }
        } else if item.allows_other {
            current.other = Some(match current.other.take() {
                Some(other) => format!("{other}, {value}"),
                None => value,
            });
        } else {
            let labels: Vec<&str> =
                item.options.iter().map(|option| option.label.as_str()).collect();
            return Err(DeskError::invalid(format!(
                "{value} is not an option of {}; choose from: {}",
                item.header.as_deref().unwrap_or(&item.prompt),
                labels.join(", ")
            )));
        }
    }
    Ok(chosen)
}

fn target<'a>(
    selection: &str,
    question: &'a Question,
) -> Result<(&'a QuestionItem, String), DeskError> {
    let names = |item: &'a QuestionItem| {
        [item.id.as_str(), item.prompt.as_str(), item.header.as_deref().unwrap_or("")]
    };
    for (split, _) in selection.match_indices('=') {
        let Some((key, value)) = selection.split_at_checked(split) else { continue };
        let Some(value) = value.strip_prefix('=') else { continue };
        let key = trim_inline(key);
        let item = question.items.iter().find(|item| names(item).contains(&key)).or_else(|| {
            question.items.iter().find(|item| {
                names(item)
                    .iter()
                    .any(|name| !name.is_empty() && same_ignoring_case(trim_inline(name), key))
            })
        });
        if let Some(item) = item {
            return Ok((item, trim_inline(value).to_owned()));
        }
    }
    match question.items.as_slice() {
        [only] => Ok((only, trim_inline(selection).to_owned())),
        _ => Err(DeskError::invalid(
            "This question has several items; give each selection as ITEM=CHOICE (the item's id, prompt or header)",
        )),
    }
}

/// The choice an app ask (a Cloud ask the app owns) reads from `selections`: one selection's part
/// after its first `=` (the whole selection without one), else empty.
pub fn app_ask_choice(selections: &[String]) -> String {
    match selections {
        [only] => only
            .splitn(2, '=')
            .filter(|part| !part.is_empty())
            .last()
            .unwrap_or_default()
            .to_owned(),
        _ => String::new(),
    }
}

/// The answered list after `entry`, the oldest dropped past [`ANSWERED_LIMIT`].
pub fn remember(mut answered: Vec<Value>, entry: Value) -> Vec<Value> {
    answered.push(entry);
    if answered.len() > ANSWERED_LIMIT {
        answered.drain(..answered.len() - ANSWERED_LIMIT);
    }
    answered
}

/// The answered entry an app ask's reply leaves.
pub fn app_ask_answered(id: &str, reply: &Value) -> Value {
    json!({"id": id, "request_id": id, "source": "cmux",
           "status": reply.get("status").cloned().unwrap_or_else(|| "answered".into())})
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn answer_preserves_unicode_and_equals_in_item_names_and_values() {
        let question: Question = serde_json::from_value(json!({"items": [
            {"id": "名=前", "allows_other": true},
            {"id": "別"}
        ]}))
        .unwrap();
        let selected = answer(&["名=前=値=あり".into()], &question).unwrap();
        assert_eq!(selected.get("名=前").unwrap().other.as_deref(), Some("値=あり"));
    }

    #[test]
    fn app_ask_choice_is_the_part_after_the_first_equals() {
        let one = |text: &str| app_ask_choice(&[text.to_owned()]);
        assert_eq!(one("db=MySQL"), "MySQL");
        assert_eq!(one("MySQL"), "MySQL");
        assert_eq!(one("a=b=c"), "b=c");
        assert_eq!(one("x="), "x");
        assert_eq!(one("=y"), "y");
        assert_eq!(app_ask_choice(&["a".into(), "b".into()]), "");
    }

    #[test]
    fn remember_keeps_the_last_fifty() {
        let answered = (0..60).fold(Vec::new(), |answered, index| remember(answered, json!(index)));
        assert_eq!(answered.len(), ANSWERED_LIMIT);
        assert_eq!(answered[0], json!(10));
    }
}
