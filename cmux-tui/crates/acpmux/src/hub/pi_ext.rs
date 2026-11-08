//! Pi extension UI and custom tool normalization.
//!
//! `pi-acp` translates Pi's `select` and `confirm` dialogs to ACP permission
//! requests.  The adapter's request carries the original method in
//! `toolCall.rawInput.method`; marking `select` as interactive makes it use
//! the shared question card, while `confirm` remains the ordinary permission
//! card.  A direct Pi bridge may also forward `extension_ui_request` itself;
//! those requests use the same permission path and are answered in Pi's wire
//! shape here.

use super::*;
use cmux_json::JsonSet as _;
use serde_json::{Value, json};

const ALLOW: &str = "allow_once";
const REJECT: &str = "reject_once";
// pi-acp's extension UI bridge sends these ids back unchanged.
const CHOICE_PREFIX: &str = "choice-";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum RequestKind {
    Select,
    Confirm,
    Input,
    Editor,
}

pub(super) fn request_kind(method: &str) -> Option<RequestKind> {
    match method {
        "select" => Some(RequestKind::Select),
        "confirm" => Some(RequestKind::Confirm),
        "input" => Some(RequestKind::Input),
        "editor" => Some(RequestKind::Editor),
        _ => None,
    }
}

fn raw_method(request: &Value) -> Option<&str> {
    request.pointer("/toolCall/rawInput/method").and_then(Value::as_str)
}

/// Pi's `select` permission is a choice question, not an approval.  The
/// option ids are already the ids Pi's ACP adapter expects back, so the
/// generic ACP question answer needs no further translation.
pub(super) fn normalize_permission(session: &Session, request: &mut Value) {
    let harness = session.meta().harness;
    normalize_permission_for_harness(&harness, request);
}

fn normalize_permission_for_harness(harness: &str, request: &mut Value) {
    if harness != "pi" || raw_method(request) != Some("select") {
        return;
    }
    let Some(tool) = request.get_mut("toolCall") else { return };
    let Some(input) = tool.get("rawInput").cloned() else { return };
    let Some(options) = input.get("options").and_then(Value::as_array) else { return };
    if options.is_empty() || tool.pointer("/_meta/acpmux/question").is_some() {
        return;
    }
    let choices: Vec<Value> = options
        .iter()
        .enumerate()
        .filter_map(|(index, option)| {
            option
                .as_str()
                .map(|label| json!({"id": format!("{CHOICE_PREFIX}{index}"), "label": label}))
        })
        .collect();
    if choices.is_empty() {
        return;
    }
    tool.set(
        "_meta",
        json!({
            "acpmux": {
                "interactive": true,
                "question": {
                    "harness": "acp",
                    "agent": "Pi",
                    "items": [{
                        "id": "selection",
                        "prompt": input["title"].as_str().unwrap_or("Choose an option"),
                        "options": choices,
                        "multiSelect": false,
                        "allowsOther": false
                    }]
                }
            }
        }),
    );
}

/// Mark Pi custom tools for the generic rich row.  The raw input and output
/// remain in their normal ACP fields; this marker only selects the richer row
/// and avoids duplicating potentially large payloads in the transcript.
pub(super) fn annotate_tool(session: &Session, kind: &str, msg: &mut Value) {
    let harness = session.meta().harness;
    annotate_tool_for_harness(&harness, kind, msg);
}

fn annotate_tool_for_harness(harness: &str, kind: &str, msg: &mut Value) {
    if harness != "pi" || !matches!(kind, "tool_call" | "tool_call_update") {
        return;
    }
    let Some(update) = msg.pointer_mut("/params/update").and_then(Value::as_object_mut) else {
        return;
    };
    // Shell calls already have a dedicated terminal row.  Pi custom tools
    // are `kind: other` and carry structured args/results.
    if update.get("kind").and_then(Value::as_str) == Some("execute")
        || update.get("rawInput").and_then(|value| value.pointer("/command")).is_some()
        || update.get("_meta").and_then(|value| value.pointer("/terminal_info")).is_some()
    {
        return;
    }
    let has_payload = update.get("rawInput").is_some_and(|value| !value.is_null())
        || update.get("rawOutput").is_some_and(|value| !value.is_null())
        || update.get("content").is_some_and(|value| !value.is_null());
    if !has_payload {
        return;
    }
    let meta = update.entry("_meta").or_insert_with(|| json!({}));
    let Some(pi) = meta.as_object_mut() else { return };
    let rich = pi.entry("piAcp").or_insert_with(|| json!({}));
    if let Some(rich) = rich.as_object_mut() {
        rich.insert("rich".into(), json!({"renderer": "generic"}));
    }
}

fn question_request(session: &Session, params: &Value, kind: RequestKind) -> Value {
    let id = params["id"].as_str().unwrap_or("pi-extension-ui");
    let title = params["title"].as_str().filter(|s| !s.trim().is_empty()).unwrap_or("Pi");
    let (harness, item) = match kind {
        RequestKind::Select => {
            let options: Vec<Value> = params["options"]
                .as_array()
                .into_iter()
                .flatten()
                .enumerate()
                .filter_map(|(index, option)| {
                    option.as_str().map(
                        |label| json!({"id": format!("{CHOICE_PREFIX}{index}"), "label": label}),
                    )
                })
                .collect();
            (
                "acp",
                json!({"id": "selection", "prompt": title, "options": options, "multiSelect": false, "allowsOther": false}),
            )
        }
        RequestKind::Input | RequestKind::Editor => (
            "codex",
            json!({
                "id": "value",
                "prompt": params["message"].as_str().or(params["title"].as_str()).unwrap_or("Pi input"),
                "options": [],
                "multiSelect": false,
                "allowsOther": true
            }),
        ),
        RequestKind::Confirm => unreachable!(),
    };
    let mut request = json!({
        "sessionId": session.meta().agent_session_id,
        "toolCall": {
            "toolCallId": format!("pi-ui-{id}"),
            "title": title,
            "kind": "other",
            "status": "pending",
            "rawInput": params,
            "_meta": {"acpmux": {"interactive": true, "question": {"harness": harness, "agent": "Pi", "items": [item]}}}
        },
        "options": [{"optionId": ALLOW, "name": "Answer", "kind": "allow_once"}, {"optionId": REJECT, "name": "Cancel", "kind": "reject_once"}]
    });
    if kind == RequestKind::Select {
        let options = params["options"].as_array().cloned().unwrap_or_default();
        request["options"] = Value::Array(options.iter().enumerate().map(|(index, option)| {
            json!({"optionId": format!("{CHOICE_PREFIX}{index}"), "name": option.as_str().unwrap_or(""), "kind": "allow_once"})
        }).collect());
    }
    request
}

fn confirm_request(session: &Session, params: &Value) -> Value {
    let id = params["id"].as_str().unwrap_or("pi-extension-ui");
    let title = params["title"].as_str().filter(|s| !s.trim().is_empty()).unwrap_or("Confirm");
    json!({
        "sessionId": session.meta().agent_session_id,
        "toolCall": {"toolCallId": format!("pi-ui-{id}"), "title": title, "kind": "other", "status": "pending", "rawInput": params},
        "options": [{"optionId": "yes", "name": "Yes", "kind": "allow_once"}, {"optionId": "no", "name": "No", "kind": "reject_once"}]
    })
}

fn answer(kind: RequestKind, params: &Value, outcome: &Value) -> Value {
    let selected = outcome.pointer("/outcome/optionId").and_then(Value::as_str);
    match kind {
        RequestKind::Confirm => json!({"confirmed": selected == Some("yes")}),
        RequestKind::Select => {
            let Some(option) = selected.filter(|value| value.starts_with(CHOICE_PREFIX)) else {
                return json!({"cancelled": true});
            };
            let index = option.trim_start_matches(CHOICE_PREFIX).parse::<usize>().ok();
            let value = index.and_then(|index| params["options"].as_array()?.get(index)?.as_str());
            value.map_or_else(|| json!({"cancelled": true}), |value| json!({"value": value}))
        }
        RequestKind::Input | RequestKind::Editor => {
            if selected != Some(ALLOW) {
                return json!({"cancelled": true});
            }
            let value = outcome
                .pointer("/_meta/updatedInput/answers/value/answers/0")
                .and_then(Value::as_str);
            value.map_or_else(|| json!({"cancelled": true}), |value| json!({"value": value}))
        }
    }
}

impl Hub {
    pub(super) async fn handle_pi_request(
        self: &Arc<Self>,
        session: &Arc<Session>,
        kind: RequestKind,
        params: Value,
        epoch: u64,
        turn_id: Option<String>,
    ) -> Result<Value, RpcError> {
        if !params.is_object() {
            return Err(RpcError::invalid_params("Pi extension UI params must be an object"));
        }
        let request = match kind {
            RequestKind::Confirm => confirm_request(session, &params),
            RequestKind::Select | RequestKind::Input | RequestKind::Editor => {
                question_request(session, &params, kind)
            }
        };
        let outcome =
            self.handle_permission_for(session, request, epoch, turn_id, None, None, None).await;
        Ok(answer(kind, &params, &outcome))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixture_marks_select_as_a_question() {
        let fixture: Value =
            serde_json::from_str(include_str!("../../tests/fixtures/pi-extension-ui.json"))
                .unwrap();
        let mut request = fixture["selectPermission"].clone();
        normalize_permission_for_harness("pi", &mut request);
        let tool = request.get("toolCall").unwrap();
        assert_eq!(tool["_meta"]["acpmux"]["interactive"], true);
        assert_eq!(tool["_meta"]["acpmux"]["question"]["harness"], "acp");
        assert_eq!(tool["_meta"]["acpmux"]["question"]["items"][0]["options"][1]["id"], "choice-1");
        assert_eq!(request["toolCall"]["rawInput"]["method"], "select");
    }

    #[test]
    fn select_answer_returns_pi_value() {
        let params = json!({"options": ["Fast", "Safe"]});
        let outcome = json!({"outcome": {"optionId": "choice-1"}});
        assert_eq!(answer(RequestKind::Select, &params, &outcome), json!({"value": "Safe"}));
    }

    #[test]
    fn fixture_marks_custom_tool_call_and_result_as_rich() {
        let fixture: Value =
            serde_json::from_str(include_str!("../../tests/fixtures/pi-extension-ui.json"))
                .unwrap();
        let mut call = json!({"params": {"update": fixture["customToolCall"].clone()}});
        annotate_tool_for_harness("pi", "tool_call", &mut call);
        assert_eq!(call["params"]["update"]["_meta"]["piAcp"]["rich"]["renderer"], "generic");
        let mut result = json!({"params": {"update": fixture["customToolResult"].clone()}});
        annotate_tool_for_harness("pi", "tool_call_update", &mut result);
        assert_eq!(result["params"]["update"]["_meta"]["piAcp"]["rich"]["renderer"], "generic");
        assert_eq!(result["params"]["update"]["rawOutput"]["points"], 3);
    }
}
