//! Chat widgets (`cmux.chat.widget/1`): which installed extension draws a card in the agent chat,
//! and the mount context its render export gets. cmux ships no widgets of its own (Leo,
//! 2026-11-14: "we want them to be super supported but not necessarily ship built versions
//! ourselves (yet)"); every widget is an installed extension's.
//!
//! `apps.chat_widgets.route {key, tool | app+props}` answers `{widget: null}` or
//! `{widget: {app, interface, title, symbol?, context}}`:
//!
//! - Under a tool call (`tool: {name, title?, status?, input?, output?}`): the installed, enabled
//!   and visible app whose `options.tools` holds a pattern matching `tool.name`. `*` matches any
//!   run of characters. The pattern with the most literal characters wins, then the lowest app id,
//!   so the answer does not depend on install order.
//! - For a widget part an agent sent (`app`, `props`): that app, when it is installed, enabled,
//!   visible and implements the interface with a scene export.
//!
//! The context is built here, not by the page: `{surface: "chatWidget", widget: {key}, tool?,
//! props?}`, with `tool.input` dropped and `tool.output` cut at a character boundary once either
//! passes 16 KiB. The page mounts the answer through the panels bridge and draws the scene it
//! gets; it holds no routing of its own. Routing reads the catalog and the mirror only: no host
//! starts until a page mounts the widget. A local extension's save reloads its open widgets like
//! any other mount (`local_reload.rs`).

use serde::Deserialize;
use serde_json::{Map, Value, json};

use super::store::{bad_request, params, text};
use super::supervisor::{ApiError, Supervisor};

/// The interface a chat widget implements.
pub(super) const INTERFACE: &str = "cmux.chat.widget/1";
/// The surface name the page mounts a widget on (`AppMountSurface.chatWidget`).
const SURFACE: &str = "chatWidget";
/// The most bytes of a call's input (serialized) or output, and of a part's props, a widget gets.
pub(super) const MAX_FIELD_BYTES: usize = 16 * 1024;
/// The longest widget key (`<chat>#<tool call id>`, `<message>#<part>`).
const MAX_KEY_BYTES: usize = 256;
/// The longest tool name (as the interface's `options.tools` patterns).
const MAX_TOOL_NAME_BYTES: usize = 128;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct RouteParams {
    /// Stable for the call or the part; the widget keeps its state under it.
    key: String,
    tool: Option<ToolCall>,
    /// A widget part's app (with `props`), instead of `tool`.
    app: Option<String>,
    props: Option<Value>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ToolCall {
    name: String,
    title: Option<String>,
    status: Option<String>,
    input: Option<Value>,
    output: Option<String>,
}

/// Whether `name` matches `pattern`, where `*` matches any run of characters (none included).
pub(super) fn tool_matches(pattern: &str, name: &str) -> bool {
    let mut parts = pattern.split('*');
    let first = parts.next().unwrap_or_default();
    let Some(mut rest) = name.strip_prefix(first) else { return false };
    let tail: Vec<&str> = parts.collect();
    let Some((last, middle)) = tail.split_last() else {
        // No `*`: the whole name.
        return rest.is_empty();
    };
    for part in middle {
        match rest.split_once(*part) {
            Some((_, after)) => rest = after,
            None => return false,
        }
    }
    rest.ends_with(last)
}

/// How specific a pattern is: its literal characters. A pattern of only `*` scores 0 and never
/// answers (the interface schema refuses it too).
pub(super) fn specificity(pattern: &str) -> usize {
    pattern.chars().filter(|c| *c != '*').count()
}

/// `s` cut to at most `max` bytes, at a character boundary.
fn cut(s: &str, max: usize) -> &str {
    if s.len() <= max {
        return s;
    }
    // 0 is always a boundary, so a boundary is found; `get` cannot miss on one.
    (0..=max)
        .rev()
        .find(|&end| s.is_char_boundary(end))
        .and_then(|end| s.get(..end))
        .unwrap_or_default()
}

impl Supervisor {
    /// `apps.chat_widgets.route`.
    pub(super) fn chat_widget_route(&self, args: Value) -> Result<Value, ApiError> {
        let p: RouteParams = params(args)?;
        if p.key.is_empty() || p.key.len() > MAX_KEY_BYTES {
            return Err(bad_request("key must be 1 to 256 bytes"));
        }
        let mut context = Map::new();
        context.insert("surface".into(), json!(SURFACE));
        context.insert("widget".into(), json!({ "key": p.key }));
        let chosen = match (p.tool, p.app) {
            (Some(tool), None) => {
                if p.props.is_some() {
                    return Err(bad_request("props go with app, not with tool"));
                }
                if tool.name.is_empty() || tool.name.len() > MAX_TOOL_NAME_BYTES {
                    return Err(bad_request("tool.name must be 1 to 128 bytes"));
                }
                let chosen = self.chat_widget_for_tool(&tool.name);
                context.insert("tool".into(), tool_context(tool));
                chosen
            }
            (None, Some(app)) => {
                let props = p.props.unwrap_or_else(|| json!({}));
                let fits = serde_json::to_vec(&props).is_ok_and(|b| b.len() <= MAX_FIELD_BYTES);
                if !props.is_object() || !fits {
                    return Err(bad_request("props must be an object of at most 16 KiB"));
                }
                context.insert("props".into(), props);
                self.chat_widget_of_app(&app)
            }
            _ => return Err(bad_request("name either tool or app")),
        };
        Ok(json!({
            "widget": chosen.map(|(app, entry)| {
                let mut widget = json!({
                    "app": app,
                    "interface": INTERFACE,
                    "title": entry.get("title").map_or_else(|| app.clone(), text),
                    "context": Value::Object(context),
                });
                if let (Some(symbol), Some(fields)) =
                    (entry.get("symbol").and_then(Value::as_str), widget.as_object_mut())
                {
                    fields.insert("symbol".into(), json!(symbol));
                }
                widget
            })
        }))
    }

    /// The best widget for a tool call: (app id, its implementation entry).
    fn chat_widget_for_tool(&self, name: &str) -> Option<(String, Value)> {
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut best: Option<(usize, String, Value)> = None;
        // The mirror is ordered by app id, so a tie keeps the lowest id.
        for (app, record) in &inner.mirror.apps {
            if !(record.installed && record.enabled && !record.hidden) {
                continue;
            }
            let Some(entry) = drawn_widget(inner.catalog.packages.get(app).map(|p| &p.manifest))
            else {
                continue;
            };
            let score = entry
                .pointer("/options/tools")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .filter(|pattern| specificity(pattern) > 0 && tool_matches(pattern, name))
                .map(specificity)
                .max();
            if let Some(score) = score
                && best.as_ref().is_none_or(|(top, _, _)| score > *top)
            {
                best = Some((score, app.clone(), entry.clone()));
            }
        }
        best.map(|(_, app, entry)| (app, entry))
    }

    /// The widget of the app a widget part names, when it shows.
    fn chat_widget_of_app(&self, app: &str) -> Option<(String, Value)> {
        let inner = self.inner.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let record = inner.mirror.apps.get(app)?;
        if !(record.installed && record.enabled && !record.hidden) {
            return None;
        }
        let entry = drawn_widget(inner.catalog.packages.get(app).map(|p| &p.manifest))?;
        Some((app.to_string(), entry.clone()))
    }
}

/// The manifest's `cmux.chat.widget/1` entry, when a scene export draws it.
fn drawn_widget(manifest: Option<&Value>) -> Option<&Value> {
    let entry = manifest?.get("implements")?.get(INTERFACE)?;
    entry.get("export").and_then(Value::as_str).is_some().then_some(entry)
}

/// The `tool` a widget's render gets, with input and output held to `MAX_FIELD_BYTES`.
fn tool_context(tool: ToolCall) -> Value {
    let mut out = Map::new();
    out.insert("name".into(), json!(tool.name));
    if let Some(title) = tool.title {
        out.insert("title".into(), json!(cut(&title, 512)));
    }
    if let Some(status) = tool.status {
        out.insert("status".into(), json!(cut(&status, 64)));
    }
    if let Some(input) = tool.input
        && serde_json::to_vec(&input).is_ok_and(|b| b.len() <= MAX_FIELD_BYTES)
    {
        out.insert("input".into(), input);
    }
    if let Some(output) = tool.output {
        out.insert("output".into(), json!(cut(&output, MAX_FIELD_BYTES)));
    }
    Value::Object(out)
}

#[cfg(test)]
mod tests;
