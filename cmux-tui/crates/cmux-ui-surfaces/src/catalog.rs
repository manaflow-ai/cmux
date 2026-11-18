//! Catalogs and the walk from A2UI component definitions to normalized nodes.
//!
//! - basic v1 (`BASIC`): every basic component; `Modal`, `Video` and
//!   `AudioPlayer` become fallbacks in the prototype.
//! - cmux (`CMUX`): basic plus `ApprovalCard`, `ReviewCard`, `Table`, `Chart`
//!   and `Progress` (props in the design doc, "cmux catalog").
//! - travel (`TRAVEL`, the a2ui.org quickstart): basic plus a fallback node
//!   naming each of its own widgets.
//! - the A2UI MCP catalog (`MCP`) is known only by name: `McpApp` and its
//!   functions draw as a fallback.

use crate::functions::{self, Ctx};
use crate::model::*;
use crate::{caps, pointer, text};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, BTreeSet, HashMap};

pub const BASIC: &str = "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json";
pub const CMUX: &str = "https://cmux.com/a2ui/catalog/v1";
pub const TRAVEL: &str = "https://travel-a2ui.dev/catalogs/a2ui-travel/catalog.json";
pub const MCP: &str = "https://a2ui.org/specification/v1_0/catalogs/mcp/catalog.json";

/// What this host advertises (`a2uiRendererCapabilities`).
pub const SUPPORTED: &[&str] = &[BASIC, CMUX, TRAVEL];

pub fn renderer_capabilities() -> Value {
    serde_json::json!({ "1.0": { "supportedCatalogIds": SUPPORTED } })
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Catalog {
    Basic,
    Cmux,
    Travel,
    Mcp,
}

impl Catalog {
    pub fn from_id(id: &str) -> Option<Self> {
        match id {
            BASIC => Some(Self::Basic),
            CMUX => Some(Self::Cmux),
            TRAVEL => Some(Self::Travel),
            MCP => Some(Self::Mcp),
            _ => None,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Self::Basic => "basic catalog",
            Self::Cmux => "cmux catalog",
            Self::Travel => "travel catalog",
            Self::Mcp => "MCP catalog",
        }
    }
}

/// The basic catalog's icon names; any other name draws nothing.
pub const ICONS: &[&str] = &[
    "accountCircle",
    "add",
    "arrowBack",
    "arrowForward",
    "attachFile",
    "calendarToday",
    "call",
    "camera",
    "check",
    "close",
    "delete",
    "download",
    "edit",
    "event",
    "error",
    "fastForward",
    "favorite",
    "favoriteOff",
    "folder",
    "help",
    "home",
    "info",
    "locationOn",
    "lock",
    "lockOpen",
    "mail",
    "menu",
    "moreVert",
    "moreHoriz",
    "notificationsOff",
    "notifications",
    "pause",
    "payment",
    "person",
    "phone",
    "photo",
    "play",
    "print",
    "refresh",
    "rewind",
    "search",
    "send",
    "settings",
    "share",
    "shoppingCart",
    "skipNext",
    "skipPrevious",
    "star",
    "starHalf",
    "starOff",
    "stop",
    "upload",
    "visibility",
    "visibilityOff",
    "volumeDown",
    "volumeMute",
    "volumeOff",
    "volumeUp",
    "warning",
];

const BASIC_COMPONENTS: &[&str] = &[
    "Text",
    "Image",
    "Icon",
    "Video",
    "AudioPlayer",
    "Row",
    "Column",
    "List",
    "Card",
    "Tabs",
    "Modal",
    "Divider",
    "Button",
    "TextField",
    "CheckBox",
    "ChoicePicker",
    "Slider",
    "DateTimeInput",
];
const CMUX_COMPONENTS: &[&str] = &["ApprovalCard", "ReviewCard", "Table", "Chart", "Progress"];

/// What a node's action does once confirmed. Held host-side only.
#[derive(Clone, Debug, PartialEq)]
pub enum ActionDef {
    Event {
        name: String,
        user_message: Option<Value>,
        context: Map<String, Value>,
        /// Paths the host adds to the context (a review card's selection).
        extra: Vec<(String, String)>,
        scope: String,
        index: Option<usize>,
        source_component: String,
        checks: Vec<(Value, String)>,
    },
    OpenUrl {
        url: Value,
        scope: String,
        index: Option<usize>,
    },
}

/// The drawn tree plus what the host must remember about it.
#[derive(Clone, Debug)]
pub struct Built {
    pub root: Node,
    pub actions: HashMap<String, ActionDef>,
    /// Every data-model path a field is bound to: the only keys accepted
    /// in an action's `values`.
    pub binds: BTreeSet<String>,
}

pub(crate) struct Builder<'a> {
    comps: &'a BTreeMap<String, Value>,
    catalog: Catalog,
    model: &'a Value,
    actions: HashMap<String, ActionDef>,
    binds: BTreeSet<String>,
    nodes: usize,
    bytes: usize,
    cut: bool,
    stack: Vec<String>,
}

fn str_prop(props: &Map<String, Value>, key: &str, ctx: Ctx<'_>) -> String {
    props.get(key).map(|v| text::clean(&functions::eval_text(v, ctx))).unwrap_or_default()
}

fn num_prop(props: &Map<String, Value>, key: &str, ctx: Ctx<'_>) -> Option<f64> {
    match functions::eval(props.get(key)?, ctx) {
        Value::Number(n) => n.as_f64().filter(|f| f.is_finite()),
        Value::String(s) => s.trim().parse().ok().filter(|f: &f64| f.is_finite()),
        _ => None,
    }
}

fn enum_prop<'v>(props: &'v Map<String, Value>, key: &str) -> Option<&'v str> {
    props.get(key).and_then(Value::as_str)
}

/// Strip a leading Markdown heading marker; A2UI Text uses `# ` for headings.
fn heading(s: &str) -> Option<&str> {
    let hashes = s.chars().take_while(|c| *c == '#').count();
    (1..=6).contains(&hashes).then(|| s[hashes..].strip_prefix(' ')).flatten()
}

/// Collect the plain text of a subtree (a button's label).
fn label_of(node: &Node) -> String {
    match &node.kind {
        NodeKind::Text { text, .. } => text.clone(),
        NodeKind::Stack { children, .. }
        | NodeKind::Card { children }
        | NodeKind::List { children } => {
            children.iter().map(label_of).filter(|s| !s.is_empty()).collect::<Vec<_>>().join(" ")
        }
        NodeKind::Icon { name } => name.clone(),
        _ => String::new(),
    }
}

impl<'a> Builder<'a> {
    pub(crate) fn new(
        comps: &'a BTreeMap<String, Value>,
        catalog: Catalog,
        model: &'a Value,
    ) -> Self {
        Self {
            comps,
            catalog,
            model,
            actions: HashMap::new(),
            binds: BTreeSet::new(),
            nodes: 0,
            bytes: 0,
            cut: false,
            stack: Vec::new(),
        }
    }

    pub(crate) fn build(mut self, dropped_components: usize) -> Built {
        let mut root = if self.comps.contains_key("root") {
            self.node("root", "", "", None, 0)
        } else {
            Node::new("root", NodeKind::Stack { axis: Axis::V, children: Vec::new() })
        };
        let mut notes = Vec::new();
        if dropped_components > 0 {
            notes.push(format!(
                "{dropped_components} component(s) over the {} cap were not drawn",
                caps::COMPONENTS
            ));
        }
        if self.cut {
            notes.push("Part of this surface was cut: it is over the size cap".to_string());
        }
        if !notes.is_empty() {
            let mut children = vec![root];
            for (i, n) in notes.into_iter().enumerate() {
                children.push(Node::fallback(format!("cap-note-{i}"), n));
            }
            root = Node::new("cap-root", NodeKind::Stack { axis: Axis::V, children });
        }
        Built { root, actions: self.actions, binds: self.binds }
    }

    fn budget_ok(&mut self, add_bytes: usize) -> bool {
        self.nodes += 1;
        self.bytes += add_bytes + 48;
        if self.nodes > caps::NODES || self.bytes > caps::SURFACE_BYTES {
            self.cut = true;
            return false;
        }
        true
    }

    fn children(
        &mut self,
        raw: Option<&Value>,
        suffix: &str,
        scope: &str,
        index: Option<usize>,
        depth: usize,
    ) -> Vec<Node> {
        let mut out = Vec::new();
        match raw {
            Some(Value::Array(ids)) => {
                for id in ids.iter().filter_map(Value::as_str) {
                    if self.comps.contains_key(id) {
                        out.push(self.node(id, suffix, scope, index, depth + 1));
                    }
                    if self.cut {
                        break;
                    }
                }
            }
            Some(Value::Object(t)) => {
                let (Some(path), Some(cid)) = (
                    t.get("path").and_then(Value::as_str),
                    t.get("componentId").and_then(Value::as_str),
                ) else {
                    return out;
                };
                if !self.comps.contains_key(cid) {
                    return out;
                }
                let base = pointer::absolute(scope, path);
                let len =
                    pointer::get(self.model, &base).and_then(Value::as_array).map_or(0, Vec::len);
                for i in 0..len {
                    let item_scope = format!("{base}/{i}");
                    let item_suffix =
                        if suffix.is_empty() { format!("#{i}") } else { format!("{suffix}.{i}") };
                    out.push(self.node(cid, &item_suffix, &item_scope, Some(i), depth + 1));
                    if self.cut {
                        break;
                    }
                }
            }
            _ => {}
        }
        out
    }

    fn one_child(
        &mut self,
        raw: Option<&Value>,
        suffix: &str,
        scope: &str,
        index: Option<usize>,
        depth: usize,
    ) -> Vec<Node> {
        match raw.and_then(Value::as_str) {
            Some(id) if self.comps.contains_key(id) => {
                vec![self.node(id, suffix, scope, index, depth + 1)]
            }
            _ => Vec::new(),
        }
    }

    fn action(
        &mut self,
        raw: Option<&Value>,
        action_id: String,
        comp: &Map<String, Value>,
        comp_id: &str,
        scope: &str,
        index: Option<usize>,
    ) -> Option<NodeAction> {
        let raw = raw?.as_object()?;
        let checks = comp
            .get("@checks")
            .and_then(Value::as_array)
            .map(|cs| {
                cs.iter()
                    .filter_map(|c| {
                        let c = c.as_object()?;
                        Some((
                            c.get("condition")?.clone(),
                            c.get("message")
                                .and_then(Value::as_str)
                                .unwrap_or("Check failed")
                                .to_string(),
                        ))
                    })
                    .collect()
            })
            .unwrap_or_default();
        let (name, def) = if let Some(ev) = raw.get("event").and_then(Value::as_object) {
            let name = ev.get("name").and_then(Value::as_str).filter(|n| !n.is_empty())?;
            (
                name.to_string(),
                ActionDef::Event {
                    name: text::clean(name),
                    user_message: ev.get("userMessage").cloned(),
                    context: ev
                        .get("context")
                        .and_then(Value::as_object)
                        .cloned()
                        .unwrap_or_default(),
                    extra: Vec::new(),
                    scope: scope.to_string(),
                    index,
                    source_component: comp_id.to_string(),
                    checks,
                },
            )
        } else if let Some(fc) = raw.get("functionCall").and_then(Value::as_object) {
            // Only openUrl runs from a button; any other local function
            // (the MCP catalog's callMcpTool, ...) leaves the button inert.
            if fc.get("@call").and_then(Value::as_str) != Some("openUrl") {
                return None;
            }
            let url = fc.get("args").and_then(|a| a.get("url")).cloned().unwrap_or(Value::Null);
            ("openUrl".to_string(), ActionDef::OpenUrl { url, scope: scope.to_string(), index })
        } else {
            return None;
        };
        self.actions.insert(action_id.clone(), def);
        Some(NodeAction { id: action_id, name: text::clean(&name), privileged: true })
    }

    fn node(
        &mut self,
        comp_id: &str,
        suffix: &str,
        scope: &str,
        index: Option<usize>,
        depth: usize,
    ) -> Node {
        let id = format!("{comp_id}{suffix}");
        if depth >= caps::DEPTH {
            return Node::fallback(id, format!("Nested deeper than {} levels", caps::DEPTH));
        }
        if self.stack.iter().any(|s| s == comp_id) {
            return Node::fallback(id, format!("{comp_id} contains itself"));
        }
        let Some(comp) = self.comps.get(comp_id).and_then(Value::as_object) else {
            return Node::fallback(id, "Missing component");
        };
        let ctx = Ctx { model: self.model, scope, index };
        let kind = comp.get("component").and_then(Value::as_str).unwrap_or("");
        let est = serde_json::to_string(comp).map_or(0, |s| s.len());
        if !self.budget_ok(est) {
            return Node::fallback(id, "Cut: surface over its size cap");
        }
        let catalog = match comp.get("@catalogId").and_then(Value::as_str) {
            None => self.catalog,
            Some(c) => match Catalog::from_id(c) {
                Some(cat) => cat,
                None => {
                    return Node::fallback(
                        id,
                        format!("{} (unsupported catalog)", text::clean(kind)),
                    );
                }
            },
        };
        self.stack.push(comp_id.to_string());
        let mut node =
            self.kind(catalog, kind, comp, &id, comp_id, suffix, scope, index, depth, ctx);
        self.stack.pop();
        node.a11y = a11y(comp, ctx);
        node
    }

    #[allow(clippy::too_many_arguments)]
    fn kind(
        &mut self,
        catalog: Catalog,
        kind: &str,
        comp: &Map<String, Value>,
        id: &str,
        comp_id: &str,
        suffix: &str,
        scope: &str,
        index: Option<usize>,
        depth: usize,
        ctx: Ctx<'_>,
    ) -> Node {
        let is_basic = BASIC_COMPONENTS.contains(&kind) && catalog != Catalog::Mcp;
        let is_cmux = CMUX_COMPONENTS.contains(&kind) && catalog == Catalog::Cmux;
        if !is_basic && !is_cmux {
            let name = if kind.is_empty() { "Component" } else { kind };
            return Node::fallback(id, format!("{} ({})", text::clean(name), catalog.label()));
        }
        let k = match kind {
            "Text" => {
                let raw = str_prop(comp, "text", ctx);
                match heading(&raw) {
                    Some(h) => NodeKind::Text { text: h.to_string(), style: TextStyle::Heading },
                    None => NodeKind::Text {
                        style: if enum_prop(comp, "variant") == Some("caption") {
                            TextStyle::Caption
                        } else {
                            TextStyle::Body
                        },
                        text: raw,
                    },
                }
            }
            "Image" => {
                let alt = str_prop(comp, "description", ctx);
                NodeKind::Image { alt: if alt.is_empty() { "Image".into() } else { alt } }
            }
            "Icon" => {
                let name = enum_prop(comp, "name").filter(|n| ICONS.contains(n)).unwrap_or("");
                NodeKind::Icon { name: name.to_string() }
            }
            "Video" | "AudioPlayer" | "Modal" => {
                NodeKind::Fallback { text: format!("{kind} (not drawn in this version)") }
            }
            "Row" | "Column" => NodeKind::Stack {
                axis: if kind == "Row" { Axis::H } else { Axis::V },
                children: self.children(comp.get("children"), suffix, scope, index, depth),
            },
            "List" => NodeKind::List {
                children: self.children(comp.get("children"), suffix, scope, index, depth),
            },
            "Card" => NodeKind::Card {
                children: self.one_child(comp.get("child"), suffix, scope, index, depth),
            },
            "Tabs" => {
                let mut children = Vec::new();
                for (i, tab) in
                    comp.get("tabs").and_then(Value::as_array).into_iter().flatten().enumerate()
                {
                    let Some(tab) = tab.as_object() else { continue };
                    children.push(Node::new(
                        format!("{id}.tab{i}"),
                        NodeKind::Text {
                            text: str_prop(tab, "title", ctx),
                            style: TextStyle::Heading,
                        },
                    ));
                    children.extend(self.one_child(tab.get("child"), suffix, scope, index, depth));
                }
                NodeKind::Stack { axis: Axis::V, children }
            }
            "Divider" => NodeKind::Divider,
            "Button" => {
                let label = self
                    .one_child(comp.get("child"), suffix, scope, index, depth)
                    .first()
                    .map(label_of)
                    .unwrap_or_default();
                let action =
                    self.action(comp.get("action"), id.to_string(), comp, comp_id, scope, index);
                NodeKind::Button {
                    label: text::clean(&label),
                    action,
                    variant: if enum_prop(comp, "variant") == Some("primary") {
                        Variant::Primary
                    } else {
                        Variant::Secondary
                    },
                }
            }
            "TextField" | "CheckBox" | "ChoicePicker" | "Slider" | "DateTimeInput" => {
                self.field(kind, comp, scope, ctx)
            }
            "ApprovalCard" => NodeKind::Approval {
                title: str_prop(comp, "title", ctx),
                detail: str_prop(comp, "detail", ctx),
                risk: match enum_prop(comp, "risk") {
                    Some("low") => Risk::Low,
                    Some("high") => Risk::High,
                    _ => Risk::Medium,
                },
                facts: pairs(comp.get("facts"), ctx, "label", "value")
                    .into_iter()
                    .map(|(label, value)| Fact { label, value })
                    .collect(),
                approve: self.action(
                    comp.get("approveAction"),
                    format!("{id}.approve"),
                    comp,
                    comp_id,
                    scope,
                    index,
                ),
                deny: self.action(
                    comp.get("denyAction"),
                    format!("{id}.deny"),
                    comp,
                    comp_id,
                    scope,
                    index,
                ),
            },
            "ReviewCard" => {
                let bind = comp
                    .get("value")
                    .and_then(|v| functions::bound_path(v, scope))
                    .unwrap_or_else(|| format!("/@review/{id}"));
                self.binds.insert(bind.clone());
                let submit = self.action(
                    comp.get("submitAction"),
                    format!("{id}.submit"),
                    comp,
                    comp_id,
                    scope,
                    index,
                );
                if let Some(ActionDef::Event { extra, .. }) =
                    submit.as_ref().and_then(|a| self.actions.get_mut(&a.id))
                {
                    extra.push(("selected".to_string(), bind.clone()));
                }
                let options =
                    match functions::eval(comp.get("options").unwrap_or(&Value::Null), ctx) {
                        Value::Array(items) => items
                            .iter()
                            .filter_map(Value::as_object)
                            .map(|o| ReviewOption {
                                id: text::clean(&text::display(
                                    o.get("id").unwrap_or(&Value::Null),
                                )),
                                label: text::clean(&text::display(
                                    o.get("label").unwrap_or(&Value::Null),
                                )),
                                detail: o
                                    .get("detail")
                                    .map(|d| text::clean(&text::display(d)))
                                    .filter(|d| !d.is_empty()),
                            })
                            .filter(|o| !o.id.is_empty())
                            .take(caps::TABLE_ROWS)
                            .collect(),
                        _ => Vec::new(),
                    };
                NodeKind::Review {
                    title: str_prop(comp, "title", ctx),
                    prompt: str_prop(comp, "prompt", ctx),
                    options,
                    multi: comp.get("multi").and_then(Value::as_bool).unwrap_or(false),
                    submit,
                    selected: match pointer::get(self.model, &bind) {
                        Some(Value::Array(items)) => {
                            items.iter().filter_map(Value::as_str).map(text::clean).collect()
                        }
                        Some(Value::String(s)) => vec![text::clean(s)],
                        _ => Vec::new(),
                    },
                    bind,
                }
            }
            "Table" => table(comp, ctx),
            "Chart" => chart(comp, ctx),
            "Progress" => {
                let state = match enum_prop(comp, "state") {
                    Some("done") => ProgressState::Done,
                    Some("failed") => ProgressState::Failed,
                    _ => ProgressState::Running,
                };
                NodeKind::Progress {
                    label: str_prop(comp, "label", ctx),
                    value: num_prop(comp, "value", ctx),
                    max: num_prop(comp, "max", ctx),
                    state,
                }
            }
            _ => NodeKind::Fallback { text: text::clean(kind) },
        };
        Node::new(id, k)
    }

    fn field(
        &mut self,
        kind: &str,
        comp: &Map<String, Value>,
        scope: &str,
        ctx: Ctx<'_>,
    ) -> NodeKind {
        let raw_value = comp.get("value").unwrap_or(&Value::Null);
        let bind = functions::bound_path(raw_value, scope);
        if let Some(b) = &bind {
            self.binds.insert(b.clone());
        }
        let value = functions::eval(raw_value, ctx);
        let label = str_prop(comp, "label", ctx);
        let mut options = Vec::new();
        let mut multi = false;
        let (input, value) = match kind {
            "CheckBox" => (InputKind::Checkbox, Value::Bool(value.as_bool().unwrap_or(false))),
            "ChoicePicker" => {
                multi = enum_prop(comp, "variant") == Some("multipleSelection");
                options = pairs(comp.get("options"), ctx, "value", "label")
                    .into_iter()
                    .map(|(value, label)| ChoiceOption { value, label })
                    .collect();
                let selected: Vec<Value> = match value {
                    Value::Array(items) => items
                        .iter()
                        .map(|v| Value::String(text::clean(&text::display(v))))
                        .collect(),
                    Value::Null => Vec::new(),
                    other => vec![Value::String(text::clean(&text::display(&other)))],
                };
                (InputKind::Choice, Value::Array(selected))
            }
            "Slider" => (InputKind::Slider, value.as_f64().map(Value::from).unwrap_or(Value::Null)),
            "DateTimeInput" => {
                (InputKind::Date, Value::String(text::clean(&text::display(&value))))
            }
            _ => (InputKind::Text, Value::String(text::clean(&text::display(&value)))),
        };
        NodeKind::Field {
            label,
            input,
            value,
            options,
            multi,
            min: num_prop(comp, "min", ctx),
            max: num_prop(comp, "max", ctx),
            bind,
            secure: enum_prop(comp, "variant") == Some("obscured"),
        }
    }
}

fn a11y(comp: &Map<String, Value>, ctx: Ctx<'_>) -> Option<A11y> {
    let a = comp.get("@accessibility")?.as_object()?;
    let s = |k: &str| {
        a.get(k).map(|v| text::clean(&functions::eval_text(v, ctx))).filter(|s| !s.is_empty())
    };
    Some(A11y {
        label: s("label"),
        description: s("description"),
        live: match a.get("live").and_then(Value::as_str) {
            Some("polite") => Some(Live::Polite),
            Some("assertive") => Some(Live::Assertive),
            _ => None,
        },
        hidden: a.get("hidden").and_then(Value::as_bool).unwrap_or(false),
    })
}

/// `[{a, b}]` (each dynamic) as cleaned string pairs.
fn pairs(raw: Option<&Value>, ctx: Ctx<'_>, a: &str, b: &str) -> Vec<(String, String)> {
    let Some(raw) = raw else { return Vec::new() };
    match functions::eval(raw, ctx) {
        Value::Array(items) => items
            .iter()
            .filter_map(Value::as_object)
            .take(caps::TABLE_ROWS)
            .map(|o| {
                let get = |k: &str| text::clean(&text::display(o.get(k).unwrap_or(&Value::Null)));
                (get(a), get(b))
            })
            .collect(),
        _ => Vec::new(),
    }
}

fn table(comp: &Map<String, Value>, ctx: Ctx<'_>) -> NodeKind {
    let columns: Vec<Column> =
        match functions::eval(comp.get("columns").unwrap_or(&Value::Null), ctx) {
            Value::Array(cols) => cols
                .iter()
                .take(32)
                .filter_map(|c| match c {
                    Value::String(s) => Some(Column {
                        key: text::clean(s),
                        label: text::clean(s),
                        align: Align::Start,
                    }),
                    Value::Object(o) => {
                        let key = text::clean(&text::display(o.get("key")?));
                        let label = o
                            .get("label")
                            .map(|l| text::clean(&text::display(l)))
                            .unwrap_or_else(|| key.clone());
                        let align = match o.get("align").and_then(Value::as_str) {
                            Some("center") => Align::Center,
                            Some("end" | "right") => Align::End,
                            _ => Align::Start,
                        };
                        Some(Column { key, label, align })
                    }
                    _ => None,
                })
                .collect(),
            _ => Vec::new(),
        };
    let rows_raw = match functions::eval(comp.get("rows").unwrap_or(&Value::Null), ctx) {
        Value::Array(r) => r,
        _ => Vec::new(),
    };
    let truncated = rows_raw.len() > caps::TABLE_ROWS;
    let rows = rows_raw
        .iter()
        .take(caps::TABLE_ROWS)
        .map(|row| match row {
            Value::Array(cells) => cells
                .iter()
                .take(columns.len().max(1))
                .map(|c| text::clean(&text::display(c)))
                .collect(),
            Value::Object(o) => columns
                .iter()
                .map(|c| text::clean(&text::display(o.get(&c.key).unwrap_or(&Value::Null))))
                .collect(),
            other => vec![text::clean(&text::display(other))],
        })
        .collect();
    NodeKind::Table { columns, rows, truncated }
}

fn chart(comp: &Map<String, Value>, ctx: Ctx<'_>) -> NodeKind {
    let kind = match enum_prop(comp, "kind") {
        Some("line") => ChartKind::Line,
        Some("pie") => ChartKind::Pie,
        _ => ChartKind::Bar,
    };
    let mut budget = caps::CHART_POINTS;
    let series = match functions::eval(comp.get("series").unwrap_or(&Value::Null), ctx) {
        Value::Array(items) => items
            .iter()
            .filter_map(Value::as_object)
            .take(32)
            .map(|s| {
                let points: Vec<Point> = s
                    .get("points")
                    .and_then(Value::as_array)
                    .into_iter()
                    .flatten()
                    .filter_map(|p| {
                        let p = p.as_object()?;
                        let y = match p.get("y")? {
                            Value::Number(n) => n.as_f64()?,
                            Value::String(s) => s.trim().parse().ok()?,
                            _ => return None,
                        };
                        y.is_finite().then(|| Point {
                            x: text::clean(&text::display(p.get("x").unwrap_or(&Value::Null))),
                            y,
                        })
                    })
                    .take(budget)
                    .collect();
                budget -= points.len();
                Series {
                    name: text::clean(&text::display(s.get("name").unwrap_or(&Value::Null))),
                    points,
                }
            })
            .collect(),
        _ => Vec::new(),
    };
    let y_label = Some(str_prop(comp, "yLabel", ctx)).filter(|s| !s.is_empty());
    NodeKind::Chart { kind, series, y_label }
}
