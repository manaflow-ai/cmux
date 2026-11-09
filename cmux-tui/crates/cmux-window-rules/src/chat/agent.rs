//! The agent chat handlers' rules: the tables the agent actions bind from,
//! where New Agent Chat opens (its pane, its machine, a targeted pane), how
//! Open File checks its path, the agent chat zoom, the Memory Inspector's
//! place and route, the model picker's catalog and an agent-opened
//! workspace's sidebar placement. The app reads the facts (its panes, the
//! invocation, the daemon's answers), asks here and acts: the tab, the
//! daemon command, the localized refusal.

use std::collections::{BTreeMap, BTreeSet};

use serde::{Deserialize, Serialize};

/// One agent chat page command a native row runs (the header and "..." menu).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PageCommand {
    pub action: &'static str,
    /// The page's command (the app maps it to the view's method).
    pub command: &'static str,
    /// A remote chat refuses it (its files are on another machine).
    pub refuses_remote: bool,
}

/// One permission row's action and the page command it runs.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PermissionCommand {
    pub action: &'static str,
    pub command: &'static str,
}

/// A copy action and the `_acpmux/session_files` kinds it copies, first match wins.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CopyFile {
    pub action: &'static str,
    pub kinds: Vec<&'static str>,
}

/// Launch Claude Teams or Launch Codex Teams: the action and the line typed
/// into the new terminal (the environment assignment applies to the agent
/// only, so the shell keeps its own environment after the agent exits).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TeamsLaunch {
    pub action: &'static str,
    pub harness: &'static str,
    pub shell_line: &'static str,
}

/// The tables the agent chat handlers bind from.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Tables {
    pub page_commands: Vec<PageCommand>,
    pub permission_commands: Vec<PermissionCommand>,
    pub copy_files: Vec<CopyFile>,
    pub teams: Vec<TeamsLaunch>,
    /// The protocol's effort names, the palette's suggestions for Set Effort.
    pub efforts: Vec<&'static str>,
    /// The protocol's mode names, the palette's suggestions for Set Mode.
    pub modes: Vec<&'static str>,
}

/// The agent chat handlers' tables.
pub fn tables() -> Tables {
    let page = |action, command, refuses_remote| PageCommand { action, command, refuses_remote };
    let permission = |action, command| PermissionCommand { action, command };
    let copy = |action, kinds: &[&'static str]| CopyFile { action, kinds: kinds.to_vec() };
    Tables {
        page_commands: vec![
            page("agentPane.toggleDisplaySettings", "toggleDisplaySettings", false),
            page("agentPane.replayConversation", "replayConversation", false),
            page("agentPane.editInstructions", "editProjectInstructions", true),
            page("agentPane.addProjectFiles", "addProjectFiles", true),
            page("agentPane.moveToFloatingChat", "moveToFloatingChat", false),
            page("agentPane.toggleMinimap", "toggleThreadMinimap", false),
            page("agentPane.continueAfterError", "continueAfterError", false),
        ],
        permission_commands: vec![
            permission("agentPane.permission.allowOnce", "permissionAllowOnce"),
            permission("agentPane.permission.allowChat", "permissionAllowChat"),
            permission("agentPane.permission.deny", "permissionDeny"),
            permission("agentPane.permission.expand", "permissionExpand"),
            permission("agentPane.permission.retry", "permissionRetry"),
            permission("agentPane.permission.revoke", "permissionRevoke"),
            permission("agentPane.permission.refresh", "permissionRefresh"),
        ],
        copy_files: vec![
            copy("agentChat.copyTranscriptFile", &["transcript"]),
            copy("agentChat.copyHarnessConfigFile", &["claude_config", "codex_config"]),
            copy("agentChat.copyHarnessSettingsFile", &["claude_settings"]),
            copy("agentChat.copyAcpmuxSessionFile", &["acpmux_session"]),
        ],
        teams: vec![
            TeamsLaunch {
                action: "palette.launchClaudeTeams",
                harness: "claude",
                shell_line: "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 claude --teammate-mode in-process\n",
            },
            TeamsLaunch {
                action: "palette.launchCodexTeams",
                harness: "codex",
                shell_line: "codex -c features.multi_agent=true\n",
            },
        ],
        efforts: vec!["default", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"],
        modes: vec!["default", "read-only", "agent", "agent-full-access", "plan"],
    }
}

/// The agent chat zoom after a step.
#[derive(Clone, Copy, Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Zoom {
    pub zoom: f64,
    /// What the zoom indicator shows.
    pub percent: i64,
}

/// `current` stepped by `delta`, clamped to `lower...upper` (`agentPane.zoom`).
pub fn zoom(current: f64, delta: f64, lower: f64, upper: f64) -> Zoom {
    let zoom = (current + delta).max(lower).min(upper);
    #[allow(
        clippy::cast_possible_truncation,
        reason = "the zoom is clamped to the pane's bounds (a few hundred percent); `as` saturates a float past i64"
    )]
    let percent = (zoom * 100.0).round() as i64;
    Zoom { zoom, percent }
}

/// Where Open File opens a file.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FileTarget {
    /// A tab (the file pages, or a browser tab for HTML and SVG).
    #[default]
    Tab,
    /// The editor app.
    Editor,
}

/// What Open File does first.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "decision")]
pub enum FilePlace {
    /// No path (the File menu, a shortcut, `cmux file open`): the cmux picker.
    Picker,
    /// A place outside the catalog's: refused, not ignored.
    InvalidPlace { place: String },
    /// Open at `target`. `paneless`: the editor needs no pane (none named, none
    /// focused), so the file is this Mac's.
    Open { target: FileTarget, paneless: bool },
}

/// Open File's first step: `path` and `place` as the invocation gives them.
pub fn file_place(
    path: &str,
    place: Option<&str>,
    names_pane: bool,
    has_focused_pane: bool,
) -> FilePlace {
    if path.is_empty() {
        return FilePlace::Picker;
    }
    let target = match place.unwrap_or("tab") {
        "tab" => FileTarget::Tab,
        "editor" => FileTarget::Editor,
        other => return FilePlace::InvalidPlace { place: other.to_owned() },
    };
    FilePlace::Open {
        target,
        paneless: target == FileTarget::Editor && !names_pane && !has_focused_pane,
    }
}

/// Why Open File refuses a path before it reads the file.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum FileRefusal {
    /// Not an absolute path (or, on another machine, one with a NUL).
    NotAbsolute,
    /// A file on another machine opens only as a tab.
    RemotePreview,
}

/// Open File's path check: on another machine (`remote`, a Cloud pane) the path
/// must be absolute with no NUL and open as a tab; on this Mac a tab needs an
/// absolute path. The editor's checks are the file opening's own.
pub fn file_check(path: &str, target: FileTarget, remote: bool) -> Option<FileRefusal> {
    if remote {
        if !path.starts_with('/') || path.contains('\0') {
            return Some(FileRefusal::NotAbsolute);
        }
        return (target != FileTarget::Tab).then_some(FileRefusal::RemotePreview);
    }
    (target == FileTarget::Tab && !path.starts_with('/')).then_some(FileRefusal::NotAbsolute)
}

/// The pane a new agent chat (New Agent Chat, Add Harness...) opens in.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum PaneRoute {
    /// The invocation's pane.
    Open,
    /// No pane: refused.
    Refuse,
    /// The window shows a top page (Home): a new workspace whose only tab is the chat.
    OverTopPage,
    /// The active workspace has no mounted pane yet: its first pane, then the chat there.
    FirstPane,
}

/// Where a new chat opens. An explicit target opens in its shown pane or is
/// refused; over a top page the parked workspace never mounts a pane.
pub fn pane_route(
    targeted: bool,
    has_pane: bool,
    top_page: bool,
    has_workspace: bool,
) -> PaneRoute {
    if targeted {
        return if has_pane { PaneRoute::Open } else { PaneRoute::Refuse };
    }
    if top_page {
        return PaneRoute::OverTopPage;
    }
    if has_pane {
        return PaneRoute::Open;
    }
    if has_workspace { PaneRoute::FirstPane } else { PaneRoute::Refuse }
}

/// How a chat machine (`host`) is reached, as the composer's inventory lists it.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum HostRoute {
    /// This Mac.
    #[default]
    Local,
    /// An acpmux peer.
    Peer { peer: String },
    /// A Cloud machine.
    Cloud { machine: String },
    /// Still being set up.
    Pending,
}

/// Why New Agent Chat on a machine is refused.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum HostRefusal {
    /// The open was cancelled while the inventory loaded.
    Cancelled,
    /// The machine is listed but not ready.
    NotReady,
    /// The target is not on this Mac.
    NoMachine,
}

/// What New Agent Chat on a machine does.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum HostOpen {
    Refuse {
        reason: HostRefusal,
    },
    /// The active window shows another machine: the chat opens in this Mac's
    /// workspace it would focus (made when there is none).
    LocalPlacement,
    /// The chat opens on this Cloud machine.
    Cloud {
        machine: String,
    },
    /// The chat opens in the invocation's local pane.
    Local,
}

/// New Agent Chat on a machine: the `host` argument the open runs with
/// (`local`, the peer, else unchanged) and the plan.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HostPlan {
    pub host: Option<String>,
    pub open: HostOpen,
}

/// The facts of New Agent Chat on a resolved machine.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HostFacts {
    pub route: HostRoute,
    pub ready: bool,
    pub cancelled: bool,
    /// The invocation names a pane or workspace.
    pub targeted: bool,
    /// That target is on this Mac.
    pub target_local: bool,
    /// The active window's machine is this Mac.
    pub active_local: bool,
}

/// The plan for New Agent Chat on a machine. A peer needs no cmux workspace
/// daemon: the tab stays in a local pane and the chat starts on the peer.
pub fn host_plan(facts: &HostFacts) -> HostPlan {
    let refuse = |reason| HostPlan { host: None, open: HostOpen::Refuse { reason } };
    if facts.cancelled {
        return refuse(HostRefusal::Cancelled);
    }
    if !facts.ready {
        return refuse(HostRefusal::NotReady);
    }
    let host = match &facts.route {
        HostRoute::Local => Some("local".to_owned()),
        HostRoute::Peer { peer } => Some(peer.clone()),
        HostRoute::Cloud { .. } | HostRoute::Pending => None,
    };
    let open = match &facts.route {
        HostRoute::Local | HostRoute::Peer { .. } if facts.targeted && !facts.target_local => {
            HostOpen::Refuse { reason: HostRefusal::NoMachine }
        }
        HostRoute::Local | HostRoute::Peer { .. } if !facts.targeted && !facts.active_local => {
            HostOpen::LocalPlacement
        }
        HostRoute::Cloud { machine } => HostOpen::Cloud { machine: machine.clone() },
        _ => HostOpen::Local,
    };
    HostPlan { host, open }
}

/// What a script's or agent's New Agent Chat aimed at a pane or workspace does.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "route")]
pub enum TargetedRoute {
    /// Not this path (no pane or workspace target, or a shown pane's view change).
    Skip,
    /// The target names nothing.
    NotFound,
    /// New Agent Chat's own placement in the shown pane.
    InShown,
    /// A tab on the workspace store in that pane; `selects` when no window shows it.
    Store { selects: bool },
}

/// The facts of a targeted New Agent Chat.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct TargetedFacts {
    /// The target is a pane (else a workspace).
    pub pane: bool,
    /// The target is a pane or a workspace.
    pub applies: bool,
    pub found: bool,
    /// A window shows the target's pane.
    pub shown: bool,
    /// That shown pane is a lone chat that docks when a tool opens.
    pub shown_docks_chat: bool,
    pub allows_view_change: bool,
}

/// A targeted New Agent Chat (#23016): the docked chat keeps New Agent Chat's
/// own placement; a person's run on a shown pane keeps the shown-pane path; a
/// shown workspace target opens in its pane; else a store tab, no view change.
pub fn targeted_route(facts: TargetedFacts) -> TargetedRoute {
    if !facts.applies {
        return TargetedRoute::Skip;
    }
    if !facts.found {
        return TargetedRoute::NotFound;
    }
    if facts.shown && facts.shown_docks_chat {
        return TargetedRoute::InShown;
    }
    if facts.shown && facts.allows_view_change {
        return if facts.pane { TargetedRoute::Skip } else { TargetedRoute::InShown };
    }
    TargetedRoute::Store { selects: !facts.shown }
}

/// One column of the focused pane's screen, left to right.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct InspectorColumn {
    pub panes: Vec<u64>,
    /// Docked to an edge (the Home Chief dock or a tool dock): never takes the tab.
    pub dock: bool,
}

/// Where "Chief: Open Memory Inspector" puts its tab.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum InspectorPlacement {
    /// A new tab in this pane (Home's right column).
    Tab { pane: u64 },
    /// A new column right of this pane's column.
    NewColumn { pane: u64 },
}

/// The inspector's place while `focused` has focus (a243). Outside Home a new
/// column right of the focused pane; in Home a tab in the first scrolling
/// column (the pinned Chief dock refuses tabs, and a new column lands off
/// screen), the focused pane's when it scrolls. None: Home has no scrolling
/// column, so a user workspace takes it.
pub fn inspector_placement(
    focused: u64,
    in_home: bool,
    columns: &[InspectorColumn],
) -> Option<InspectorPlacement> {
    if !in_home {
        return Some(InspectorPlacement::NewColumn { pane: focused });
    }
    let mut scrolling = columns.iter().filter(|column| !column.dock);
    if scrolling.clone().any(|column| column.panes.contains(&focused)) {
        return Some(InspectorPlacement::Tab { pane: focused });
    }
    let right = scrolling.next()?.panes.first()?;
    Some(InspectorPlacement::Tab { pane: *right })
}

/// A workspace as the inspector's anchor reads it.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AnchorWorkspace {
    /// The home workspace (it holds only the Chief conversation).
    pub home: bool,
    /// Its first screen has a pane.
    pub has_pane: bool,
}

impl AnchorWorkspace {
    fn is_user(self) -> bool {
        !self.home && self.has_pane
    }
}

/// The pane a new inspector column goes right of.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum InspectorAnchor {
    /// The focused or targeted pane.
    Pane,
    /// The last pane of the invocation's workspace.
    ScopeWorkspace,
    /// The last pane of the machine's workspace at this index.
    Workspace { index: usize },
    /// No pane to anchor it.
    Refuse,
}

/// The facts of the inspector's anchor.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct AnchorFacts {
    pub targeted: bool,
    /// The invocation's pane; `Some(true)` when it is in the home workspace.
    pub pane_in_home: Option<bool>,
    pub scope_workspace: Option<AnchorWorkspace>,
    /// The machine's workspaces, in order.
    pub workspaces: Vec<AnchorWorkspace>,
}

/// The inspector's anchor: the focused (or targeted) pane unless it is in
/// Home (a243: a Home pane never anchors a new column), else the last pane of
/// the invocation's workspace or of the first user workspace.
pub fn inspector_anchor(facts: &AnchorFacts) -> InspectorAnchor {
    if facts.pane_in_home == Some(false) {
        return InspectorAnchor::Pane;
    }
    if facts.targeted && facts.pane_in_home.is_none() {
        return InspectorAnchor::Refuse;
    }
    if facts.scope_workspace.is_some_and(AnchorWorkspace::is_user) {
        return InspectorAnchor::ScopeWorkspace;
    }
    match facts.workspaces.iter().position(|workspace| workspace.is_user()) {
        Some(index) => InspectorAnchor::Workspace { index },
        None => InspectorAnchor::Refuse,
    }
}

/// Which Chief a Memory Inspector tab shows, as the tab's persisted route.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase", tag = "kind")]
pub enum ChiefPlace {
    /// A Chief this Mac runs; None for its default Chief.
    Local { chief: Option<String> },
    /// The Chief on a paired server.
    Server {
        #[serde(rename = "machineId")]
        machine_id: String,
    },
}

/// The route of `server`'s Chief, else of Chief `chief` on this Mac, else of
/// this Mac's default Chief: `server:<machine id>`, `local:<chief id>`, `local`.
/// Empty values name nothing.
pub fn memory_route(server: Option<&str>, chief: Option<&str>) -> String {
    match (server.filter(|s| !s.is_empty()), chief.filter(|c| !c.is_empty())) {
        (Some(machine), _) => format!("server:{machine}"),
        (None, Some(chief)) => format!("local:{chief}"),
        (None, None) => "local".to_owned(),
    }
}

/// The place a persisted route names, or None for a route this build cannot read.
pub fn parse_memory_route(route: &str) -> Option<ChiefPlace> {
    if route == "local" {
        return Some(ChiefPlace::Local { chief: None });
    }
    if let Some(chief) = route.strip_prefix("local:").filter(|c| !c.is_empty()) {
        return Some(ChiefPlace::Local { chief: Some(chief.to_owned()) });
    }
    route
        .strip_prefix("server:")
        .filter(|m| !m.is_empty())
        .map(|machine| ChiefPlace::Server { machine_id: machine.to_owned() })
}

/// One model a harness lists (`_acpmux/models`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct ModelEntry {
    pub id: String,
    /// Its display name; the id when it has none.
    pub name: Option<String>,
}

/// One harness's models.
#[derive(Clone, Debug, Default, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct HarnessModels {
    pub harness: String,
    pub models: Vec<ModelEntry>,
}

/// A model choice of the palette's Set Model picker.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelChoice {
    pub value: String,
    pub title: String,
}

/// The picker's choices of one harness name (unsorted: the app sorts them the
/// way Finder does).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HarnessChoices {
    pub harness: String,
    pub models: Vec<ModelChoice>,
}

/// The model picker's catalog by harness name: each harness's models by id
/// (the last of an id wins; an empty id is skipped), and each harness also by
/// its id's last `/` component, which the pane records. Two harnesses sharing
/// that component fail closed: neither's models show under it.
pub fn model_catalog(harnesses: &[HarnessModels]) -> Vec<HarnessChoices> {
    let mut by_harness: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    for harness in harnesses {
        let mut choices = BTreeMap::new();
        for model in harness.models.iter().filter(|model| !model.id.is_empty()) {
            choices
                .insert(model.id.clone(), model.name.clone().unwrap_or_else(|| model.id.clone()));
        }
        by_harness.insert(harness.harness.clone(), choices);
    }
    let mut aliases: BTreeMap<String, BTreeMap<String, String>> = BTreeMap::new();
    let mut collisions = BTreeSet::new();
    for (harness, choices) in &by_harness {
        let Some(short) = harness.split('/').rfind(|part| !part.is_empty()) else { continue };
        if aliases.contains_key(short) {
            collisions.insert(short.to_owned());
        } else {
            aliases.insert(short.to_owned(), choices.clone());
        }
    }
    for collision in &collisions {
        aliases.remove(collision);
        by_harness.remove(collision);
    }
    for (short, choices) in aliases {
        by_harness.entry(short).or_insert(choices);
    }
    by_harness
        .into_iter()
        .map(|(harness, choices)| HarnessChoices {
            harness,
            models: choices
                .into_iter()
                .map(|(value, title)| ModelChoice { value, title })
                .collect(),
        })
        .collect()
}

/// The default sidebar slot an agent-opened workspace takes.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum DefaultSlot {
    /// First below Home.
    Top,
    /// Like Cmd-N (`workspaces.newPlacement`).
    NewWorkspace,
}

/// Where an agent-opened workspace goes in the sidebar.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionPlacement {
    /// It joins its named group, from its first frame (the group is its only place).
    pub joins_group: bool,
    /// It goes below its caller's grouped row, when the caller has one.
    pub below_caller: bool,
    /// The default rule it takes; None with a group (the group places it).
    pub default_slot: Option<DefaultSlot>,
}

/// The sidebar placement of a workspace `agent.openSessionWorkspace` opens:
/// into its named group alone, else below its caller's grouped row (unless
/// `top`), else like Cmd-N; `top` first below Home.
pub fn session_placement(group: bool, top: bool) -> SessionPlacement {
    let slot = if top { DefaultSlot::Top } else { DefaultSlot::NewWorkspace };
    SessionPlacement {
        joins_group: group,
        below_caller: !group && !top,
        default_slot: (!group).then_some(slot),
    }
}

#[cfg(test)]
#[path = "agent_tests.rs"]
mod tests;
