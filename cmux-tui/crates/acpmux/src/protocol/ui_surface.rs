//! Agent UI surfaces (`ui_surfaces.rs`, labs.agentUiSurfaces). The surface itself rides on the
//! tool row as body `uiSurface` (`cmux.ui-surface/1`, plans/cmux-next/agent-ui-surfaces-DESIGN.md);
//! these are the page's and phone's requests about it.

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

/// A button press: `values` are the renderer's current field values keyed by their `bind`.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct UiSurfaceActionParams {
    pub session_id: String,
    pub surface_id: String,
    pub action_id: String,
    #[serde(default)]
    pub values: Map<String, Value>,
}

/// The host-written confirm strip. Nothing is sent until a confirm.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct UiSurfacePending {
    pub request_id: String,
    pub action_id: String,
    pub summary: String,
    pub sends: Vec<UiSurfaceSend>,
    /// `agent`, `tool:<name>` or `link:<https url>`.
    pub target: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct UiSurfaceSend {
    pub label: String,
    pub value: String,
}

/// Confirm a Pending. `values` (the renderer's field values now) make it stale when they
/// change what would be sent.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct UiSurfaceConfirmParams {
    pub session_id: String,
    pub surface_id: String,
    pub request_id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub values: Option<Map<String, Value>>,
}

/// What the confirm did: `sent: "agent"` (a user turn), `"tool"` (with the view's `reply`),
/// `"link"` (`openUrl` for the page to open, and the view's `reply`), or `"none"` (model
/// context, not delivered in the prototype).
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct UiSurfaceConfirmResult {
    pub sent: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub open_url: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct UiSurfaceCancelParams {
    pub session_id: String,
    pub surface_id: String,
    pub request_id: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
pub struct UiSurfaceCancelResult {
    pub cancelled: bool,
}

/// One JSON-RPC message an MCP App view posted.
#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct UiSurfaceBridgeParams {
    pub session_id: String,
    pub surface_id: String,
    pub message: Value,
}

/// The decision on a view message: `reply` to post to the view, `notify` to post after it,
/// `height` for the frame (clamped 40-1200), `blocked` why it was refused, `pending` a confirm
/// strip, `draft` composer text (the person presses Send).
#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "camelCase")]
pub struct UiSurfaceBridgeResult {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply: Option<Value>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notify: Option<Vec<Value>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub height: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blocked: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending: Option<UiSurfacePending>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub draft: Option<String>,
}
