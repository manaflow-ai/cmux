use std::collections::HashSet;

use serde_json::Value;

use crate::localization::Catalog;
use crate::model::{Conversation, Turn, item_id, item_status, item_type};

const MAX_DETAIL_CHARS: usize = 20_000;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LineTone {
    Normal,
    Dim,
    User,
    Agent,
    Accent,
    Success,
    Error,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct TrajectoryLine {
    pub text: String,
    pub indent: u16,
    pub tone: LineTone,
    pub accordion: Option<AccordionLine>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccordionLine {
    pub key: String,
    pub default_expanded: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AccordionPosition {
    pub line_index: usize,
    pub key: String,
    pub default_expanded: bool,
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct TrajectoryView {
    pub lines: Vec<TrajectoryLine>,
    pub accordions: Vec<AccordionPosition>,
}

#[derive(Debug, Clone, Default)]
pub struct ExpansionState {
    expanded: HashSet<String>,
    collapsed: HashSet<String>,
}

impl ExpansionState {
    pub fn is_expanded(&self, key: &str, default_expanded: bool) -> bool {
        if default_expanded { !self.collapsed.contains(key) } else { self.expanded.contains(key) }
    }

    pub fn toggle(&mut self, key: &str, default_expanded: bool) {
        if default_expanded {
            self.expanded.remove(key);
            if !self.collapsed.insert(key.to_string()) {
                self.collapsed.remove(key);
            }
        } else {
            self.collapsed.remove(key);
            if !self.expanded.insert(key.to_string()) {
                self.expanded.remove(key);
            }
        }
    }

    pub fn clear(&mut self) {
        self.expanded.clear();
        self.collapsed.clear();
    }
}

pub fn build_trajectory(
    conversation: &Conversation,
    width: usize,
    catalog: Catalog,
    expansion: &ExpansionState,
) -> TrajectoryView {
    let mut view = TrajectoryView::default();
    let stopped = conversation.is_stopped();
    for (index, turn) in conversation.turns.iter().enumerate() {
        if !view.lines.is_empty() {
            view.lines.push(line("", 0, LineTone::Normal));
        }
        let status = localized_turn_status(catalog, &turn.status);
        let duration = turn
            .duration_ms
            .map(|value| catalog.duration(value))
            .map(|value| format!(" · {value}"));
        view.lines.push(line(
            &format!("{} {} · {status}{}", catalog.turn(), index + 1, duration.unwrap_or_default()),
            0,
            LineTone::Dim,
        ));

        let internals = turn.internal_items().collect::<Vec<_>>();
        let mut rendered_internals = false;
        for item in &turn.items {
            match item_type(item) {
                "userMessage" => render_message(
                    &mut view,
                    catalog.you(),
                    user_message_text(item, catalog),
                    width,
                    LineTone::User,
                ),
                "agentMessage" => render_message(
                    &mut view,
                    catalog.codex(),
                    item.get("text").and_then(Value::as_str).unwrap_or_default(),
                    width,
                    LineTone::Agent,
                ),
                _ if !rendered_internals => {
                    render_work_group(
                        &mut view, turn, &internals, stopped, width, catalog, expansion,
                    );
                    rendered_internals = true;
                }
                _ => {}
            }
        }
        if !rendered_internals && !internals.is_empty() {
            render_work_group(&mut view, turn, &internals, stopped, width, catalog, expansion);
        }
        if let Some(error) = turn.error.as_ref() {
            let message = error
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or_else(|| error.as_str().unwrap_or_default());
            render_message(&mut view, catalog.error(), message, width, LineTone::Error);
        }
    }
    refresh_accordion_positions(&mut view);
    view
}

fn render_work_group(
    view: &mut TrajectoryView,
    turn: &Turn,
    items: &[&Value],
    conversation_stopped: bool,
    width: usize,
    catalog: Catalog,
    expansion: &ExpansionState,
) {
    if items.is_empty() {
        return;
    }
    let key = format!("turn:{}:work", turn.id);
    let default_expanded = !conversation_stopped && turn.status == "inProgress";
    let expanded = expansion.is_expanded(&key, default_expanded);
    let marker = if expanded { "▾" } else { "▸" };
    view.lines.push(TrajectoryLine {
        text: format!("{marker} {} · {} {}", catalog.work(), items.len(), catalog.steps()),
        indent: 0,
        tone: if turn.status == "inProgress" { LineTone::Accent } else { LineTone::Dim },
        accordion: Some(AccordionLine { key, default_expanded }),
    });
    if !expanded {
        return;
    }

    for item in items {
        render_internal_item(view, turn, item, width, catalog, expansion);
    }
}

fn render_internal_item(
    view: &mut TrajectoryView,
    turn: &Turn,
    item: &Value,
    width: usize,
    catalog: Catalog,
    expansion: &ExpansionState,
) {
    let item_type = item_type(item);
    let key = format!("turn:{}:item:{}", turn.id, item_id(item));
    let default_expanded = item_status(item) == Some("inProgress")
        || (item_type == "reasoning" && turn.status == "inProgress");
    let expanded = expansion.is_expanded(&key, default_expanded);
    let marker = if expanded { "▾" } else { "▸" };
    let status = item_status(item)
        .map(|value| localized_turn_status(catalog, value))
        .map(|value| format!(" · {value}"))
        .unwrap_or_default();
    let summary = item_summary(item, catalog);
    let label = catalog.item_label(item_type);
    let summary = if summary.is_empty() {
        format!("{marker} {label}{status}")
    } else {
        format!("{marker} {label}{status} · {summary}")
    };
    view.lines.push(TrajectoryLine {
        text: summary,
        indent: 1,
        tone: tone_for_item(item),
        accordion: Some(AccordionLine { key, default_expanded }),
    });
    if expanded {
        let detail = item_detail(item, catalog);
        if detail.trim().is_empty() {
            view.lines.push(line(catalog.empty(), 2, LineTone::Dim));
        } else {
            push_wrapped(view, &bounded_detail(&detail), width, 2, LineTone::Normal);
        }
    }
}

fn render_message(
    view: &mut TrajectoryView,
    label: &str,
    text: impl AsRef<str>,
    width: usize,
    tone: LineTone,
) {
    view.lines.push(line(label, 0, tone));
    push_wrapped(view, text.as_ref(), width, 1, LineTone::Normal);
}

fn user_message_text(item: &Value, catalog: Catalog) -> String {
    let Some(content) = item.get("content").and_then(Value::as_array) else {
        return String::new();
    };
    content
        .iter()
        .filter_map(|part| match part.get("type").and_then(Value::as_str) {
            Some("text") => part.get("text").and_then(Value::as_str).map(str::to_owned),
            Some("image") => part
                .get("url")
                .and_then(Value::as_str)
                .map(|value| format!("{}: {value}", catalog.image())),
            Some("localImage") | Some("localAudio") => part
                .get("path")
                .and_then(Value::as_str)
                .map(|value| format!("{}: {value}", catalog.image())),
            Some("audio") => Some(catalog.image().to_string()),
            _ => None,
        })
        .collect::<Vec<_>>()
        .join("\n")
}

fn item_summary(item: &Value, catalog: Catalog) -> String {
    match item_type(item) {
        "reasoning" => first_nonempty(
            item.get("summary")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str),
        ),
        "commandExecution" => {
            first_line(item.get("command").and_then(Value::as_str).unwrap_or_default())
        }
        "fileChange" => {
            let count = item.get("changes").and_then(Value::as_array).map_or(0, Vec::len);
            format!("{count} {}", catalog.changes())
        }
        "mcpToolCall" => join_nonempty([
            item.get("server").and_then(Value::as_str),
            item.get("tool").and_then(Value::as_str),
        ]),
        "dynamicToolCall" => join_nonempty([
            item.get("namespace").and_then(Value::as_str),
            item.get("tool").and_then(Value::as_str),
        ]),
        "collabAgentToolCall" | "collabToolCall" => {
            item.get("tool").and_then(Value::as_str).unwrap_or_default().to_string()
        }
        "subAgentActivity" => {
            item.get("agentPath").and_then(Value::as_str).unwrap_or_default().to_string()
        }
        "webSearch" => item.get("query").and_then(Value::as_str).unwrap_or_default().to_string(),
        "imageView" => item.get("path").and_then(Value::as_str).unwrap_or_default().to_string(),
        "sleep" => item
            .get("durationMs")
            .and_then(Value::as_i64)
            .map(|value| catalog.duration(value))
            .unwrap_or_default(),
        "plan" => first_line(item.get("text").and_then(Value::as_str).unwrap_or_default()),
        "enteredReviewMode" | "exitedReviewMode" => {
            first_line(item.get("review").and_then(Value::as_str).unwrap_or_default())
        }
        _ => String::new(),
    }
}

fn item_detail(item: &Value, catalog: Catalog) -> String {
    match item_type(item) {
        "reasoning" => item
            .get("summary")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .chain(item.get("content").and_then(Value::as_array).into_iter().flatten())
            .filter_map(Value::as_str)
            .filter(|value| !value.trim().is_empty())
            .collect::<Vec<_>>()
            .join("\n\n"),
        "commandExecution" => {
            let mut details = Vec::new();
            push_labeled(
                &mut details,
                catalog.working_directory(),
                item.get("cwd").and_then(Value::as_str),
            );
            push_labeled(
                &mut details,
                catalog.command(),
                item.get("command").and_then(Value::as_str),
            );
            push_labeled(
                &mut details,
                catalog.output(),
                item.get("aggregatedOutput").and_then(Value::as_str),
            );
            details.join("\n")
        }
        "fileChange" => item
            .get("changes")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .map(|change| {
                let path = change.get("path").and_then(Value::as_str).unwrap_or(catalog.unknown());
                let kind = change.get("kind").and_then(Value::as_str).unwrap_or_default();
                let diff = change.get("diff").and_then(Value::as_str).unwrap_or_default();
                format!("{kind} {path}\n{diff}")
            })
            .collect::<Vec<_>>()
            .join("\n\n"),
        "mcpToolCall" | "dynamicToolCall" => {
            let mut details = Vec::new();
            push_json(&mut details, catalog.arguments(), item.get("arguments"));
            push_json(&mut details, catalog.result(), item.get("result"));
            push_json(&mut details, catalog.result(), item.get("contentItems"));
            push_json(&mut details, catalog.error(), item.get("error"));
            details.join("\n")
        }
        "collabAgentToolCall" | "collabToolCall" => {
            let mut details = Vec::new();
            push_labeled(
                &mut details,
                catalog.details(),
                item.get("prompt").and_then(Value::as_str),
            );
            push_json(&mut details, catalog.result(), item.get("agentsStates"));
            push_json(&mut details, catalog.result(), item.get("receiverThreadIds"));
            details.join("\n")
        }
        "webSearch" => pretty_json(item.get("results").or_else(|| item.get("action"))),
        "plan" => item.get("text").and_then(Value::as_str).unwrap_or_default().to_string(),
        "enteredReviewMode" | "exitedReviewMode" => {
            item.get("review").and_then(Value::as_str).unwrap_or_default().to_string()
        }
        "imageView" => item.get("path").and_then(Value::as_str).unwrap_or_default().to_string(),
        "sleep" => item
            .get("durationMs")
            .and_then(Value::as_i64)
            .map(|value| catalog.duration(value))
            .unwrap_or_default(),
        "contextCompaction" => catalog.compaction().to_string(),
        _ => serde_json::to_string_pretty(item).unwrap_or_default(),
    }
}

fn push_labeled(details: &mut Vec<String>, label: &str, value: Option<&str>) {
    if let Some(value) = value.filter(|value| !value.is_empty()) {
        details.push(format!("{label}: {value}"));
    }
}

fn push_json(details: &mut Vec<String>, label: &str, value: Option<&Value>) {
    let text = pretty_json(value);
    if !text.is_empty() && text != "null" {
        details.push(format!("{label}:\n{text}"));
    }
}

fn pretty_json(value: Option<&Value>) -> String {
    value.and_then(|value| serde_json::to_string_pretty(value).ok()).unwrap_or_default()
}

fn tone_for_item(item: &Value) -> LineTone {
    match item_status(item) {
        Some("failed" | "declined") => LineTone::Error,
        Some("inProgress") => LineTone::Accent,
        Some("completed") => LineTone::Success,
        _ => LineTone::Dim,
    }
}

fn localized_turn_status(catalog: Catalog, status: &str) -> &'static str {
    match status {
        "inProgress" => catalog.in_progress(),
        "completed" => catalog.completed(),
        "failed" => catalog.failed(),
        "interrupted" => catalog.interrupted(),
        _ => catalog.unknown(),
    }
}

fn first_line(value: &str) -> String {
    value.lines().find(|line| !line.trim().is_empty()).unwrap_or_default().trim().to_string()
}

fn first_nonempty<'a>(mut values: impl Iterator<Item = &'a str>) -> String {
    values
        .find_map(|value| {
            let line = first_line(value);
            (!line.is_empty()).then_some(line)
        })
        .unwrap_or_default()
}

fn join_nonempty<const N: usize>(values: [Option<&str>; N]) -> String {
    values.into_iter().flatten().filter(|value| !value.is_empty()).collect::<Vec<_>>().join(" · ")
}

fn bounded_detail(value: &str) -> String {
    if value.chars().count() <= MAX_DETAIL_CHARS {
        return value.to_string();
    }
    let suffix = value
        .chars()
        .rev()
        .take(MAX_DETAIL_CHARS)
        .collect::<String>()
        .chars()
        .rev()
        .collect::<String>();
    format!("…\n{suffix}")
}

fn push_wrapped(view: &mut TrajectoryView, text: &str, width: usize, indent: u16, tone: LineTone) {
    let available = width.saturating_sub(indent as usize * 2).max(1);
    if text.is_empty() {
        view.lines.push(line("", indent, tone));
        return;
    }
    for source_line in text.lines() {
        if source_line.is_empty() {
            view.lines.push(line("", indent, tone));
            continue;
        }
        for wrapped in textwrap::wrap(source_line, available) {
            view.lines.push(line(wrapped.as_ref(), indent, tone));
        }
    }
}

fn line(text: &str, indent: u16, tone: LineTone) -> TrajectoryLine {
    TrajectoryLine { text: text.to_string(), indent, tone, accordion: None }
}

fn refresh_accordion_positions(view: &mut TrajectoryView) {
    view.accordions = view
        .lines
        .iter()
        .enumerate()
        .filter_map(|(line_index, line)| {
            line.accordion.as_ref().map(|accordion| AccordionPosition {
                line_index,
                key: accordion.key.clone(),
                default_expanded: accordion.default_expanded,
            })
        })
        .collect();
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    fn stopped_conversation() -> Conversation {
        Conversation {
            id: "thread".into(),
            status: json!({"type": "idle"}),
            turns: vec![Turn {
                id: "turn".into(),
                status: "completed".into(),
                items: vec![
                    json!({"type": "userMessage", "id": "user", "content": [{"type": "text", "text": "Run tests"}]}),
                    json!({"type": "commandExecution", "id": "tool", "command": "cargo test", "cwd": "/repo", "status": "completed", "aggregatedOutput": "ok"}),
                    json!({"type": "agentMessage", "id": "agent", "text": "Tests pass."}),
                ],
                ..Turn::default()
            }],
        }
    }

    #[test]
    fn stopped_conversation_hides_work_then_reveals_nested_details() {
        let conversation = stopped_conversation();
        let catalog = Catalog::new(crate::localization::Locale::English);
        let mut expansion = ExpansionState::default();

        let collapsed = build_trajectory(&conversation, 80, catalog, &expansion);
        assert!(collapsed.lines.iter().any(|line| line.text.contains("work · 1 steps")));
        assert!(!collapsed.lines.iter().any(|line| line.text.contains("cargo test")));

        expansion.toggle("turn:turn:work", false);
        let work_open = build_trajectory(&conversation, 80, catalog, &expansion);
        assert!(work_open.lines.iter().any(|line| line.text.contains("cargo test")));
        assert!(!work_open.lines.iter().any(|line| line.text.contains("output: ok")));

        expansion.toggle("turn:turn:item:tool", false);
        let tool_open = build_trajectory(&conversation, 80, catalog, &expansion);
        assert!(tool_open.lines.iter().any(|line| line.text.contains("output: ok")));
    }

    #[test]
    fn running_tool_is_expanded_incrementally() {
        let mut conversation = stopped_conversation();
        conversation.status = json!({"type": "active", "activeFlags": []});
        conversation.turns[0].status = "inProgress".into();
        conversation.turns[0].items[1]["status"] = json!("inProgress");
        conversation.turns[0].items[1]["aggregatedOutput"] = json!("building…");

        let view = build_trajectory(
            &conversation,
            80,
            Catalog::new(crate::localization::Locale::English),
            &ExpansionState::default(),
        );

        assert!(view.lines.iter().any(|line| line.text.contains("building…")));
    }
}
