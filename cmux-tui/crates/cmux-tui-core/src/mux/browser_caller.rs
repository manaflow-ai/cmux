//! `browser-open-caller-v1`: a browser open names its caller, and it never
//! makes a workspace.
//!
//! `tab.create_browser` and `browser.profile.open` take an optional
//! `caller {workspace?, agent_session?}`: the workspace the caller runs in
//! (`CMUX_WORKSPACE_ID`, a workspace key in UUID form, or a `ws_…` id) and
//! its acpmux session (`CMUX_AGENT_SESSION`). The CLI and the MCP server send
//! it for a caller inside cmux. It only changes the no-focused-workspace
//! fallback, which used to make a blank `workspace-N` for every link an
//! agent opened while the person looked at no workspace:
//!
//! 1. While a workspace has the focus, an open goes where it always did (the
//!    focused pane), caller or not. A person's own opens are unchanged.
//! 2. With no workspace focused and no workspace, screen or pane named, the
//!    caller's workspace is the one that shows the agent session's chat tab,
//!    else the one `workspace` names, and the tab opens in the rightmost
//!    pane of its focused screen ([`rightmost_pane`]): the pane at the right
//!    end of the layout, the row focused last in a column, never an agent
//!    chat dock or a pinned column that takes no tabs.
//! 3. With no caller, or a caller this session does not know (its workspace
//!    is gone), the tab opens in the home workspace (`workspace-kind-v1`),
//!    as `workspace.open_url` does. Only a session with no workspace at all
//!    keeps the old new workspace, and never for a caller.
//!    `workspace.ensure_app` still makes its app's workspace.

use super::*;
use crate::model::DockRole;
use crate::state::conversation_tabs_store::ConversationTabRecord;

/// Advertised by `identify`: the `caller` field of the browser opens.
pub(crate) const BROWSER_OPEN_CALLER_CAPABILITY: &str = "browser-open-caller-v1";
/// The `caller` field of `tab.create_browser` and `browser.profile.open`.
pub(crate) const CALLER_FIELD: &str = "caller";

impl Mux {
    /// The workspace of `caller` (a [`CALLER_FIELD`] value) in this session:
    /// the one showing its agent session's chat, else the one it names.
    pub(crate) fn caller_workspace_in_state(
        &self,
        state: &State,
        caller: &Value,
    ) -> Option<WorkspaceId> {
        let named = |field| caller.get(field).and_then(Value::as_str).filter(|v| !v.is_empty());
        if let Some(session) = named("agent_session")
            && let Some(workspace) = self.agent_session_workspace(state, session)
        {
            return Some(workspace);
        }
        named("workspace").and_then(|raw| workspace_named(state, raw))
    }

    /// Where a session-target `tab.create_browser` opens when no workspace
    /// has the focus: the rightmost pane of the caller's workspace (the
    /// workspace itself while it has no screen), else the home workspace.
    /// `path` stays as resolved while a workspace has the focus, when
    /// neither applies, and for `workspace.ensure_app`.
    pub(crate) fn browser_open_path(
        &self,
        state: &State,
        fields: &Map<String, Value>,
        path: &mut crate::resource_selector::ResolvedResourcePath,
    ) {
        if state.workspaces.get(state.active_workspace).is_some()
            || fields.contains_key(crate::state::app_workspaces::APP_WORKSPACE_FIELD)
        {
            return;
        }
        let caller = self.caller_workspace_field(state, fields);
        let Some(workspace) = caller.or_else(|| self.home_workspace_in_state(state)) else {
            return;
        };
        let indexes = &state.resource_indexes;
        path.workspace = indexes.workspace_ids.get(&workspace).cloned();
        let Some(pane) = caller.and_then(|workspace| rightmost_pane(state, workspace)) else {
            return;
        };
        let screen = indexes.pane_screen.get(&pane);
        path.screen = screen.and_then(|screen| indexes.screen_ids.get(screen)).cloned();
        path.pane = indexes.pane_ids.get(&pane).cloned();
    }

    /// The workspace of the [`CALLER_FIELD`] in `fields`, if it names one
    /// this session knows.
    pub(crate) fn caller_workspace_field(
        &self,
        state: &State,
        fields: &Map<String, Value>,
    ) -> Option<WorkspaceId> {
        let caller = fields.get(CALLER_FIELD)?;
        self.caller_workspace_in_state(state, caller)
    }

    /// The live home workspace (`workspace-kind-v1`). The presentation lock
    /// is a leaf, safe under the state lock.
    pub(crate) fn home_workspace_in_state(&self, state: &State) -> Option<WorkspaceId> {
        let home = self.presentation_snapshot().home_workspace.clone()?;
        state.workspace_id_by_key.get(&home).copied()
    }

    /// The workspace whose layout holds the chat tab of agent `session`.
    fn agent_session_workspace(&self, state: &State, session: &str) -> Option<WorkspaceId> {
        let presentation = self.presentation_snapshot();
        presentation.conversation_tabs.iter().find_map(|(browser, record)| {
            let ConversationTabRecord::AgentSession { session: Some(bound), .. } = record else {
                return None;
            };
            if bound != session {
                return None;
            }
            let browser = crate::resource::BrowserPublicId::parse(browser.clone()).ok()?;
            let content = ContentPublicId::Browser(browser);
            let surfaces = state.resource_indexes.content_placements.get(&content)?;
            surfaces.iter().find_map(|surface| {
                let pane = state.pane_of(*surface)?;
                let (workspace, _) = state.screen_of(pane)?;
                Some(state.workspaces[workspace].id)
            })
        })
    }
}

/// The workspace `raw` names: a `ws_…` id, else a workspace key in any case
/// and with or without dashes (`CMUX_WORKSPACE_ID` is the key in the old
/// app's uppercase UUID form).
fn workspace_named(state: &State, raw: &str) -> Option<WorkspaceId> {
    if raw.starts_with("ws_") {
        let id = WorkspacePublicId::parse(raw.to_string()).ok()?;
        return state.resource_indexes.workspaces.get(&id).copied();
    }
    let plain = |key: &str| -> String {
        key.chars().filter(|c| *c != '-').flat_map(char::to_lowercase).collect()
    };
    let wanted = plain(raw);
    if wanted.is_empty() {
        return None;
    }
    state.workspaces.iter().find(|workspace| plain(&workspace.key) == wanted).map(|w| w.id)
}

/// The pane a caller's browser tab opens in: the rightmost pane of the
/// workspace's focused screen (else its first) that takes a browser tab.
/// Right to left through the layout; in a column of rows, the row focused
/// last first. An agent chat dock and a pinned column that takes no tabs
/// are skipped. `None` when the workspace has no such pane (no screen yet).
pub(crate) fn rightmost_pane(state: &State, workspace: WorkspaceId) -> Option<PaneId> {
    let workspace = state.workspace_by_id(workspace)?;
    let screen = workspace.active_screen_ref().or_else(|| workspace.screens.first())?;
    let chat = |column: &&LayoutColumn| {
        column.dock.as_ref().is_some_and(|dock| dock.role == Some(DockRole::AgentChat))
    };
    let chat_dock = screen
        .layout_columns
        .iter()
        .filter(chat)
        .flat_map(|column| column.root.pane_ids_vec())
        .collect::<Vec<_>>();
    let mut order = Vec::new();
    right_to_left(&screen.root, state, &mut order);
    let operation = ResourceOperation::TabCreateBrowser.wire_name();
    order.into_iter().find(|pane| {
        !chat_dock.contains(pane)
            && state.panes.contains_key(pane)
            && ensure_pane_takes_tabs(operation, state, *pane).is_ok()
    })
}

fn right_to_left(node: &Node, state: &State, out: &mut Vec<PaneId>) {
    match node {
        Node::Leaf(pane) => out.push(*pane),
        Node::Split { dir: SplitDir::Right, a, b, .. } => {
            right_to_left(b, state, out);
            right_to_left(a, state, out);
        }
        Node::Split { a, b, .. } => {
            let (first, second) =
                if focused_last(b, state) > focused_last(a, state) { (b, a) } else { (a, b) };
            right_to_left(first, state, out);
            right_to_left(second, state, out);
        }
        Node::Stack { panes, expanded } => {
            out.push(*expanded);
            out.extend(panes.as_slice().iter().copied().filter(|pane| pane != expanded));
        }
    }
}

/// When a pane of `node` last had the focus.
fn focused_last(node: &Node, state: &State) -> u64 {
    node.pane_ids_vec()
        .iter()
        .filter_map(|pane| state.panes.get(pane))
        .map(|pane| pane.focused_at)
        .max()
        .unwrap_or(0)
}

#[cfg(test)]
#[path = "browser_caller_tests.rs"]
mod tests;
