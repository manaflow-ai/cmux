//! The normalized surface model, `cmux.ui-surface/1`
//! (plans/cmux-next/agent-ui-surfaces-DESIGN.md, "Normalized surface model").
//! Rust emits only this; the Mac page and the iPhone app draw only this.
//! Every string here is plain text.

use serde::{Deserialize, Serialize};
use serde_json::Value;

pub const SCHEMA: &str = "cmux.ui-surface/1";

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Surface {
    pub schema: String,
    pub surface_id: String,
    pub source: Source,
    pub status: Status,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    pub root: Node,
    pub frame: Option<Frame>,
    pub pending: Option<Pending>,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Source {
    pub kind: SourceKind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub tool: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resource_uri: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub catalog_id: Option<String>,
    /// The server is not one the person connected: the card shows "claimed".
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub claimed: bool,
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub enum SourceKind {
    #[default]
    #[serde(rename = "a2ui")]
    A2ui,
    #[serde(rename = "mcp-app")]
    McpApp,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Streaming,
    Ready,
    Error,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Frame {
    pub html: String,
    pub csp: String,
    pub height: u32,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Node {
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub a11y: Option<A11y>,
    #[serde(flatten)]
    pub kind: NodeKind,
}

#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct A11y {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub description: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub live: Option<Live>,
    #[serde(default, skip_serializing_if = "std::ops::Not::not")]
    pub hidden: bool,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Live {
    Polite,
    Assertive,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum TextStyle {
    Body,
    Heading,
    Caption,
    Code,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Axis {
    V,
    H,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Variant {
    Primary,
    Secondary,
    Danger,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum InputKind {
    Text,
    Checkbox,
    Choice,
    Slider,
    Date,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Risk {
    Low,
    Medium,
    High,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ChartKind {
    Bar,
    Line,
    Pie,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum ProgressState {
    Running,
    Done,
    Failed,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Align {
    Start,
    Center,
    End,
}

/// What a node's button sends. The renderer never builds a payload: it
/// names `id` in `uiSurfaceAction` and Rust writes the summary.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NodeAction {
    pub id: String,
    pub name: String,
    pub privileged: bool,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChoiceOption {
    pub value: String,
    pub label: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Fact {
    pub label: String,
    pub value: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReviewOption {
    pub id: String,
    pub label: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Column {
    pub key: String,
    pub label: String,
    pub align: Align,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Point {
    pub x: String,
    pub y: f64,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Series {
    pub name: String,
    pub points: Vec<Point>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "camelCase")]
pub enum NodeKind {
    Text {
        text: String,
        style: TextStyle,
    },
    Stack {
        axis: Axis,
        children: Vec<Node>,
    },
    Card {
        children: Vec<Node>,
    },
    List {
        children: Vec<Node>,
    },
    Divider,
    Icon {
        name: String,
    },
    Image {
        alt: String,
    },
    Button {
        label: String,
        action: Option<NodeAction>,
        variant: Variant,
    },
    #[serde(rename_all = "camelCase")]
    Field {
        label: String,
        input: InputKind,
        value: Value,
        #[serde(default, skip_serializing_if = "Vec::is_empty")]
        options: Vec<ChoiceOption>,
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        multi: bool,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        min: Option<f64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        max: Option<f64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        bind: Option<String>,
        /// Obscured text (a password): the renderer masks it.
        #[serde(default, skip_serializing_if = "std::ops::Not::not")]
        secure: bool,
    },
    Approval {
        title: String,
        detail: String,
        risk: Risk,
        facts: Vec<Fact>,
        approve: Option<NodeAction>,
        deny: Option<NodeAction>,
    },
    Review {
        title: String,
        prompt: String,
        options: Vec<ReviewOption>,
        multi: bool,
        submit: Option<NodeAction>,
        /// Where the selected option ids go in `values` (a data-model path).
        bind: String,
        /// The option ids selected now (the value at `bind`).
        selected: Vec<String>,
    },
    Table {
        columns: Vec<Column>,
        rows: Vec<Vec<String>>,
        truncated: bool,
    },
    #[serde(rename_all = "camelCase")]
    Chart {
        kind: ChartKind,
        series: Vec<Series>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        y_label: Option<String>,
    },
    Progress {
        label: String,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        value: Option<f64>,
        #[serde(default, skip_serializing_if = "Option::is_none")]
        max: Option<f64>,
        state: ProgressState,
    },
    Fallback {
        text: String,
    },
}

impl Node {
    pub fn new(id: impl Into<String>, kind: NodeKind) -> Self {
        Self { id: id.into(), a11y: None, kind }
    }

    pub fn fallback(id: impl Into<String>, text: impl Into<String>) -> Self {
        Self::new(id, NodeKind::Fallback { text: text.into() })
    }
}

/// One line of what a confirmed action would send.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Send {
    pub label: String,
    pub value: String,
}

/// An action waiting for the person's confirmation. `summary` and `sends`
/// are host-written and list exactly what Confirm sends.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Pending {
    pub request_id: String,
    pub action_id: String,
    pub summary: String,
    pub sends: Vec<Send>,
    /// `agent`, `tool:<name>` or `link:<https url>`.
    pub target: String,
}
