//! The tree JSON of the control protocol (workspaces, screens, panes, tabs,
//! tree entities and deltas), below `server`: `mux` publishes tree deltas
//! with it, so it must not need the server (RFD 0174 slice 5, step 2 of
//! breaking `cmux-tui-core`'s cycle at `server`).

pub(crate) mod home;
pub(crate) mod raw_tab;
pub(crate) mod screen_json;
pub(crate) mod tree_json;

use std::collections::HashMap;

use cmux_layout_reducer::floating_panes::{Floating, Quick};
use serde_json::{Value, json};

use crate::model::State;
use crate::panic_free::JsonFields;
use crate::state::conversation_tabs_store::CONVERSATION_KIND;
use crate::state::remote_terminal_tabs_store::{REMOTE_TERMINAL_KIND, RemoteTerminalRecord};
use crate::{Node, PaneId, SplitDir, SplitId, TreeDecorations};

pub(crate) use screen_json::screen_layout_json;
use screen_json::screen_json;
#[cfg(all(test, unix))]
pub(crate) use tree_json::skip_entity_check_on_this_thread_for_bench as skip_tree_entity_check;
pub(crate) use tree_json::{
    selection_changed_json, tree_entity_json, workspace_presentation_changed_json, workspaces_json,
};
use tree_json::{ShortIds, pane_json};
#[cfg(test)]
pub(crate) use tree_json::{panes_built_for_test, set_entity_check_hook_for_test};

/// One layout node. `split_ids`: the public ids of the splits
/// (`State::resource_indexes`); a split with one carries it as `split_id`
/// (`split-client-split-id-v1`).
pub(crate) fn node_json(
    node: &Node,
    active_pane: PaneId,
    split_ids: &HashMap<SplitId, crate::resource::SplitPublicId>,
) -> Value {
    match node {
        Node::Leaf(id) => json!({ "type": "leaf", "pane": id }),
        Node::Split { id, dir, ratio, a, b, .. } => {
            let mut value = json!({
                "type": "split",
                "split": id,
                "dir": match dir { SplitDir::Right => "right", SplitDir::Down => "down" },
                "ratio": ratio,
                "a": node_json(a, active_pane, split_ids),
                "b": node_json(b, active_pane, split_ids),
            });
            if let Some(public_id) = split_ids.get(id) {
                value.set("split_id", json!(public_id));
            }
            value
        }
        Node::Stack { panes, expanded } => json!({
            "type": "stack",
            "panes": panes.as_slice(),
            "expanded": if panes.contains(&active_pane) {
                active_pane
            } else {
                *expanded
            },
        }),
    }
}

/// `Screen.floating`: one `{pane, x, y, w, h}` for each floating pane, back to
/// front.
pub(crate) fn floating_json(list: &[Floating<PaneId>]) -> Value {
    Value::Array(
        list.iter()
            .map(|entry| {
                let [x, y, w, h] = entry.frame.fractions();
                json!({"pane": entry.pane, "x": x, "y": y, "w": w, "h": h})
            })
            .collect(),
    )
}

/// `Screen.quick_terminal`: the pane of the quick terminal, whether it is
/// hidden, and `from`, the pane that gets the focus back at a hide (null when
/// the mark names none).
pub(crate) fn quick_terminal_json(pane: PaneId, mark: Quick<PaneId>) -> Value {
    json!({"pane": pane, "hidden": mark.hidden, "from": mark.from})
}

pub(crate) fn pane_tab_group_json(run: &crate::mux::PaneTabGroup, pane: Option<PaneId>) -> Value {
    let mut value = json!({
        "id": run.group.id,
        "name": run.group.name,
        "color": run.group.color,
        "collapsed": run.group.collapsed,
        "saved_id": run.group.saved_id,
        "icon": run.group.icon,
        "start": run.start,
        "count": run.members.len(),
        "surfaces": run.members,
    });
    if let Some(pane) = pane {
        value.insert("pane", json!(pane));
    }
    value
}

pub(crate) fn workspace_group_json(
    group: &crate::workspace_registry::WorkspaceGroupRecord,
    index: usize,
) -> Value {
    json!({
        "id": group.id,
        "name": group.name,
        "color": group.color,
        "collapsed": group.collapsed,
        "index": index,
    })
}

pub(crate) fn workspace_groups_json(
    presentation: &crate::workspace_registry::PresentationSnapshot,
) -> Value {
    json!(
        presentation
            .groups
            .iter()
            .enumerate()
            .map(|(index, group)| workspace_group_json(group, index))
            .collect::<Vec<_>>()
    )
}

/// The raw tree `kind` of a tab: `conversation` for a conversation tab.
pub(crate) fn raw_tab_kind(surface_kind: &'static str, conversation: bool) -> &'static str {
    if conversation { CONVERSATION_KIND } else { surface_kind }
}

/// Report a remote-terminal tab's placeholder as a remote-terminal tab:
/// `kind:"remote-terminal"` with its `remote` reference and title, and none
/// of the placeholder browser's or a local terminal's fields.
pub(crate) fn remote_terminal_tab_apply(tab: &mut Value, remote: Option<&RemoteTerminalRecord>) {
    let (Some(remote), Some(object)) = (remote, tab.as_object_mut()) else { return };
    for field in ["terminal_id", "terminal_resource_id", "terminal_incarnation"] {
        object.remove(field);
    }
    for field in [
        "browser_source",
        "browser_status",
        "browser_error",
        "browser_renderer",
        "browser_engine",
        "browser_owner",
        "favicon_url",
        "browser_profile_id",
        "browser_frames_stalled",
        "url",
        "cwd",
        "git_branch",
    ] {
        object.insert(field.to_string(), Value::Null);
    }
    object.insert("kind".into(), json!(REMOTE_TERMINAL_KIND));
    object.insert("remote".into(), remote.wire());
    object.insert("title".into(), json!(remote.display_title()));
}
