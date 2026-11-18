//! `ui_surface`: an A2UI 1.0 surface the cmux NEXT chat draws with its own components
//! (plans/cmux-next/agent-ui-surfaces-DESIGN.md), behind `labs.agentUiSurfaces`.
//!
//! Like `render`, the tool reaches no owner: the acpmux daemon reads the call's own input
//! (`ui_surfaces.rs`), runs the same parser, and puts the normalized surface on the tool row.
//! This server only validates the messages and answers with what will be drawn, so the agent
//! learns about a fallback or a refused message without a screenshot. Listed only while the
//! setting is on.

use acpmux::ui_surfaces::surfaces::{SurfaceStore, catalog, model};
use serde_json::{Map, Value, json};

pub(super) const NAME: &str = "ui_surface";
/// The most input the tool takes, in UTF-8 bytes (a surface's cap).
const MAX_INPUT_BYTES: usize = 256 * 1024;

pub(super) fn listed() -> bool {
    acpmux::user_settings::agent_ui_surfaces_enabled()
}

pub(super) fn descriptor() -> Value {
    json!({
        "name": NAME,
        "title": "Show an interactive card in the chat",
        "description": format!(
            "Show a native, interactive card in the cmux chat, drawn with cmux's own components (not HTML): forms, choices, approvals, tables, charts, progress. \
             Pass A2UI 1.0 messages (https://a2ui.org/specification/v1.0-a2ui/) in `messages`, or the same as JSONL text in `jsonl`: a createSurface (surfaceId, catalogId, optional dataModel and sendDataModel), updateComponents with a flat component list containing id \"root\", and updateDataModel. \
             Supported catalogs: {basic} (Text, Image, Icon, Row, Column, List, Card, Tabs, Divider, Button, TextField, CheckBox, ChoicePicker, Slider, DateTimeInput); \
             {cmux} (basic plus ApprovalCard {{title, detail, risk: low|medium|high, facts: [{{label, value}}], approveAction, denyAction}}, ReviewCard {{title, prompt, options: [{{id, label, detail}}], multi, value: {{\"@path\"}}, submitAction}}, Table {{columns: [{{key, label, align}}], rows}}, Chart {{kind: bar|line|pie, series: [{{name, points: [{{x, y}}]}}], yLabel}}, Progress {{label, value, max, state: running|done|failed}}); \
             {travel} (basic; its own widgets draw as placeholders). An omitted catalogId means basic. \
             Bind values with {{\"@path\": \"/json/pointer\"}} (relative inside a children template) and format with {{\"@call\": \"formatString\", \"args\": {{\"value\": \"${{/path}}\"}}}}. \
             Strings are plain text: no HTML, no links that load. Buttons take an action {{\"event\": {{\"name\", \"context\": {{key: value or @path}}}}}}; when the person presses one and confirms, you get a user message with the A2UI action JSON (its context resolved). \
             Caps: 512 components, depth 32, 200 table rows, 1,000 chart points, 4 KB per string, 256 KB per surface.",
            basic = catalog::BASIC,
            cmux = catalog::CMUX,
            travel = catalog::TRAVEL,
        ),
        "inputSchema": {
            "type": "object",
            "additionalProperties": false,
            "properties": {
                "messages": {"type": "array", "items": {"type": "object"}, "description": "A2UI 1.0 server-to-client messages, in order."},
                "jsonl": {"type": "string", "description": "The same messages as JSONL, one per line."},
                "title": {"type": "string", "maxLength": 200, "description": "The card's heading."}
            }
        },
        "annotations": {"readOnlyHint": true, "destructiveHint": false, "idempotentHint": true, "openWorldHint": false},
    })
}

fn count(node: &model::Node, f: &mut impl FnMut(&model::NodeKind)) {
    f(&node.kind);
    if let model::NodeKind::Stack { children, .. }
    | model::NodeKind::Card { children }
    | model::NodeKind::List { children } = &node.kind
    {
        for c in children {
            count(c, f);
        }
    }
}

/// The receipt for the call's messages, or why none is drawn.
pub(super) fn receipt(arguments: &Map<String, Value>) -> Result<Value, String> {
    receipt_when(arguments, listed())
}

fn receipt_when(arguments: &Map<String, Value>, on: bool) -> Result<Value, String> {
    if !on {
        return Err("ui_surface is off: the person turns it on with the setting labs.agentUiSurfaces. Use render for an HTML page instead.".into());
    }
    if let Some(name) =
        arguments.keys().find(|n| !matches!(n.as_str(), "messages" | "jsonl" | "title"))
    {
        return Err(format!("ui_surface has no argument {name:?}"));
    }
    let input = match (arguments.get("messages"), arguments.get("jsonl")) {
        (Some(m @ Value::Array(_)), None) => m.clone(),
        (None, Some(j @ Value::String(_))) => j.clone(),
        _ => {
            return Err(
                "ui_surface needs exactly one of messages (an array) or jsonl (a string)".into()
            );
        }
    };
    if input.to_string().len() > MAX_INPUT_BYTES {
        return Err(format!("ui_surface input is larger than {} KiB", MAX_INPUT_BYTES >> 10));
    }
    let mut store = SurfaceStore::new();
    let out = store.apply_value(&input, &model::Source::default(), true);
    store.finish_all();
    if out.changed.is_empty() {
        let why = out.errors.first().cloned().unwrap_or_else(|| "no createSurface".into());
        return Err(format!("ui_surface drew nothing: {why}"));
    }
    let mut surfaces = Vec::new();
    for id in &out.changed {
        let Some(s) = store.surface(id) else { continue };
        let (mut nodes, mut buttons, mut fallbacks) = (0usize, 0usize, Vec::new());
        count(&s.root, &mut |k| {
            nodes += 1;
            match k {
                model::NodeKind::Button { action: Some(_), .. }
                | model::NodeKind::Approval { .. }
                | model::NodeKind::Review { .. } => buttons += 1,
                model::NodeKind::Fallback { text } => fallbacks.push(text.clone()),
                _ => {}
            }
        });
        fallbacks.truncate(10);
        surfaces.push(json!({"surfaceId": id, "status": s.status, "error": s.error,
            "nodes": nodes, "actions": buttons, "notDrawn": fallbacks}));
    }
    Ok(json!({
        "drawn": true,
        "surfaces": surfaces,
        "errors": out.errors,
        "a2uiRendererCapabilities": catalog::renderer_capabilities(),
        "message": "The cmux chat shows this card on the call. A confirmed button press comes back to you as a user message with the A2UI action JSON; the person sees exactly what it sends before confirming.",
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(v: Value) -> Map<String, Value> {
        v.as_object().cloned().unwrap_or_default()
    }

    #[test]
    fn receipt_names_what_is_drawn_and_refuses_when_off() {
        let call = args(json!({"messages": [
            {"version": "1.0", "createSurface": {"surfaceId": "s", "catalogId": catalog::CMUX, "components": [
                {"id": "root", "component": "Column", "children": ["a", "w"]},
                {"id": "a", "component": "ApprovalCard", "title": "Deploy", "approveAction": {"event": {"name": "ok"}}},
                {"id": "w", "component": "Widget"}
            ]}}
        ]}));
        let r = receipt_when(&call, true).unwrap();
        assert_eq!(r["surfaces"][0]["surfaceId"], "s");
        assert_eq!(r["surfaces"][0]["actions"], 1);
        assert_eq!(r["surfaces"][0]["notDrawn"][0], "Widget (cmux catalog)");
        assert!(receipt_when(&call, false).unwrap_err().contains("labs.agentUiSurfaces"));
        assert!(receipt_when(&args(json!({"messages": []})), true).is_err());
        assert!(receipt_when(&args(json!({"html": "<p>"})), true).is_err());
        let jsonl =
            args(json!({"jsonl": "{\"version\":\"1.0\",\"createSurface\":{\"surfaceId\":\"j\"}}"}));
        assert_eq!(
            receipt_when(&jsonl, true).unwrap()["surfaces"][0]["status"],
            "error",
            "no root"
        );
    }
}
