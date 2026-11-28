//! `cmux-window-rules`' workspace names over the JSON channel (ops
//! `workspace_name_*`): the name a workspace made from a tab takes, the
//! sidebar row's automatic label and the name `persist` writes
//! (`workspaces.autoName`), and Name from Activity's prompt and reply.
//! The app reads its tab models and chat titles, sends them, and shows or
//! sends the answer.

use cmux_window_rules::naming::{self, AutoName, Destination, Front, Named, Tab, activity};
use serde::Deserialize;
use serde_json::{Value, json};

use crate::ERR_INVALID;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"workspace_name_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
struct Text {
    #[serde(default)]
    text: Option<String>,
}

#[derive(Deserialize)]
struct OneTab {
    tab: Tab,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LastTab {
    #[serde(flatten)]
    workspace: Named,
    /// The moved tab, read with `for_tab`; or `tabName`, its name already read.
    #[serde(default)]
    tab: Option<Tab>,
    #[serde(default)]
    tab_name: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Group {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    first_tab: Option<Tab>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Auto {
    rule: AutoName,
    #[serde(flatten)]
    workspace: Named,
    #[serde(default)]
    front: Option<Front>,
    #[serde(default)]
    anchor: Option<Front>,
    #[serde(flatten)]
    destination: Destination,
}

#[derive(Deserialize)]
struct Tabs {
    #[serde(default)]
    tabs: Vec<activity::Tab>,
}

#[derive(Deserialize)]
struct Reply {
    reply: String,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let answer: Value = match operation {
        // One line, trimmed, at most 80 characters; `name` null when empty.
        b"workspace_name_clean" => {
            json!({ "name": naming::clean(read::<Text>(request)?.text.as_deref()) })
        }
        // A daemon-given name (`workspace-N`, `~`, empty) and the exact numbered default.
        b"workspace_name_is_default" => {
            let text = read::<Text>(request)?.text.unwrap_or_default();
            json!({ "default": naming::is_default_workspace_name(&text), "numbered": naming::is_numbered_default_name(&text) })
        }
        // The name for a workspace made from one tab (drag-out, tear-off, Move Pane).
        b"workspace_name_for_tab" => {
            json!({ "name": naming::for_tab(&read::<OneTab>(request)?.tab) })
        }
        // The name for a workspace made from another one's last tab.
        b"workspace_name_for_last_tab" => {
            let request: LastTab = read(request)?;
            let tab_name = request.tab.as_ref().map_or(request.tab_name, naming::for_tab);
            json!({ "name": naming::for_last_tab(&request.workspace, tab_name) })
        }
        // The name for a workspace made from a tab group.
        b"workspace_name_for_group" => {
            let request: Group = read(request)?;
            json!({ "name": naming::for_group(request.name.as_deref(), request.first_tab.as_ref()) })
        }
        // Whether a title or the name's source protects the workspace from automatic naming.
        b"workspace_name_is_user_named" => {
            json!({ "userNamed": naming::is_user_named(&read(request)?) })
        }
        // The sidebar row's label, the name `persist` writes, and whether a rename may still go.
        b"workspace_name_auto" => {
            let request: Auto = read(request)?;
            json!({
                "label": request.rule.label(&request.workspace, request.front.as_ref(), request.anchor.as_ref()),
                "persisted": request.rule.persisted_name(&request.workspace, request.front.as_ref(), request.destination),
                "confirms": request.rule.confirms_rename(&request.workspace),
            })
        }
        // Name from Activity: whether any tab says something, the prompt, and the
        // completion's bounds (the fallback request leaves out harness and model).
        b"workspace_name_activity_prompt" => {
            let activity = activity::Activity::new(read::<Tabs>(request)?.tabs);
            json!({
                "empty": activity.tabs.is_empty(),
                "prompt": activity.prompt(),
                "maxTokens": activity::MAX_TOKENS,
                "timeoutMs": activity::TIMEOUT_MS,
                "harness": activity::HARNESS,
                "model": activity::MODEL,
            })
        }
        // One snippet of a tab for the prompt; `snippet` null when empty.
        b"workspace_name_activity_snippet" => {
            json!({ "snippet": activity::snippet(read::<Text>(request)?.text.as_deref()) })
        }
        // The name in the model's reply; `name` null when nothing is left.
        b"workspace_name_activity_reply" => {
            json!({ "name": activity::name_from_reply(&read::<Reply>(request)?.reply) })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}
