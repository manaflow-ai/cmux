//! `cmux-window-rules` over the JSON channel (ops `window_*`): the window
//! handlers' rules. The app reads its tab models, settings and the daemon's
//! answers, sends the facts and acts on the answer (the dialog, the toast,
//! the daemon command).

use cmux_window_rules::close::{self, ClosingTab, TerminalAnswer, Warnings};
use serde::Deserialize;
use serde_json::json;

use crate::ERR_INVALID;

#[path = "window_rules_misc.rs"]
mod misc;
#[path = "window_rules_workspaces.rs"]
mod workspaces;

/// Whether `operation` is one of this module's.
pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"window_")
}

fn read<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
struct Toasting {
    #[serde(default)]
    tabs: Vec<ClosingTab>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Closing {
    #[serde(default)]
    tabs: Vec<ClosingTab>,
    #[serde(flatten)]
    warnings: Warnings,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Asked {
    #[serde(default)]
    agents: Vec<Option<String>>,
    #[serde(default)]
    answers: Vec<TerminalAnswer>,
    #[serde(default)]
    unanswered_asks: bool,
    #[serde(flatten)]
    warnings: Warnings,
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    if operation.starts_with(b"window_tabs_") || operation.starts_with(b"window_panes_") {
        return respond_tabs(operation, request);
    }
    let answer = match operation {
        // The smaller handlers' tables and refusals (notifications, history, remote, browser, files, appearance).
        operation if misc::handles(operation) => return misc::respond_misc(operation, request),
        // Whether closing these tabs together earns the undo toast.
        b"window_close_toast" => {
            let request: Toasting = read(request)?;
            serde_json::to_value(close::toast(&request.tabs)).map_err(|_| ERR_INVALID)?
        }
        // What a close reads before it knows its question; `reads` null: it never asks.
        b"window_close_reads" => {
            let request: Closing = read(request)?;
            json!({ "reads": close::reads(&request.tabs, request.warnings) })
        }
        // The close's question from the terminals' answers; `warning` null: close at once.
        b"window_close_warning" => {
            let request: Asked = read(request)?;
            json!({ "warning": close::warning(&request.agents, &request.answers, request.unanswered_asks, request.warnings) })
        }
        operation
            if operation.starts_with(b"window_chat_")
                || operation.starts_with(b"window_columns_") =>
        {
            return respond_chat(operation, request);
        }
        _ => return respond_workspaces(operation, request),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}

/// The tab and pane rules (`window_tabs_*`, `window_panes_*`; cmux-window-rules `tabs`).
fn respond_tabs(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    use cmux_window_rules::tabs::{self, panes};

    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Number {
        number: i64,
        count: usize,
    }
    #[derive(Deserialize, Default)]
    #[serde(rename_all = "camelCase", default)]
    struct Agent {
        agent: Option<String>,
        session: Option<String>,
    }
    #[derive(Deserialize, Default)]
    #[serde(rename_all = "camelCase", default)]
    struct Tabs {
        tabs: Vec<tabs::DuplicateFacts>,
    }
    #[derive(Deserialize, Default)]
    #[serde(rename_all = "camelCase", default)]
    struct Collapse {
        value: Option<bool>,
        current: bool,
    }
    #[derive(Deserialize, Default)]
    #[serde(rename_all = "camelCase", default)]
    struct Icon {
        user: bool,
        previous: Option<String>,
        icon: Option<String>,
    }
    #[derive(Deserialize, Default)]
    #[serde(rename_all = "camelCase", default)]
    struct Identifiers {
        workspaces: Vec<String>,
        refs: bool,
        workspace: Option<String>,
        pane: Option<String>,
        surface: Option<String>,
    }
    #[derive(Deserialize, Default)]
    #[serde(rename_all = "camelCase", default)]
    struct Text {
        text: String,
    }

    fn value<T: serde::Serialize>(answer: &T) -> Result<serde_json::Value, i32> {
        serde_json::to_value(answer).map_err(|_| ERR_INVALID)
    }
    let answer = match operation {
        // What a new tab opens next to the selected tab, and the kind New <Kind> Tab names.
        b"window_tabs_new_tab_kind" => {
            let facts: tabs::NewTabFacts = read(request)?;
            json!({ "kind": value(&tabs::new_tab_kind(&facts))?, "sameKind": value(&tabs::same_kind(&facts))? })
        }
        // What `openBrowser` does with its `url` and `engine` arguments.
        b"window_tabs_browser_open" => value(&tabs::browser_open(&read(request)?))?,
        // Whether a new browser tab opens behind, and whether it is an agent's.
        b"window_tabs_browser_placement" => value(&tabs::browser_placement(read(request)?))?,
        // Open in Chromium / Open in WebKit.
        b"window_tabs_reopen" => value(&tabs::reopen(&read(request)?))?,
        // Open Terminal as Chat's route; `harness` alone for a name.
        b"window_tabs_terminal_chat" => {
            let request: Agent = read(request)?;
            json!({
                "chat": value(&tabs::terminal_chat(request.agent.as_deref(), request.session.as_deref()))?,
                "harness": tabs::harness(request.agent.as_deref()),
            })
        }
        // Duplicate Tab per tab; `actions` null: refused (a page tab opens once).
        b"window_tabs_duplicate" => {
            let request: Tabs = read(request)?;
            json!({ "actions": value(&tabs::duplicate(&request.tabs))? })
        }
        b"window_tabs_by_number" => {
            let request: Number = read(request)?;
            json!({ "index": tabs::tab_by_number(request.number, request.count) })
        }
        b"window_tabs_move_to_split" => value(&tabs::move_to_split(&read(request)?))?,
        b"window_tabs_group_collapse" => {
            let request: Collapse = read(request)?;
            json!({ "collapsed": tabs::group_collapse(request.value, request.current) })
        }
        b"window_tabs_restart" => {
            json!({ "refusal": value(&tabs::restart_refusal(read(request)?))? })
        }
        b"window_tabs_icon_undo" => {
            let request: Icon = read(request)?;
            json!({ "undo": value(&tabs::icon_undo(request.user, request.previous.as_deref(), request.icon.as_deref()))? })
        }
        // Copy Workspace ID(s) (`workspaces`), or Copy IDs on a tab (`pane` and `surface`).
        b"window_tabs_identifiers" => {
            let request: Identifiers = read(request)?;
            let text = match (request.pane.as_deref(), request.surface.as_deref()) {
                (Some(pane), Some(surface)) => {
                    tabs::identifiers_text(request.workspace.as_deref(), pane, surface)
                }
                _ => tabs::workspace_id_text(&request.workspaces, request.refs),
            };
            json!({ "text": text })
        }
        b"window_panes_by_number" => {
            let request: Number = read(request)?;
            json!({ "index": tabs::pane_by_number(request.number, request.count) })
        }
        b"window_panes_split" => value(&panes::split(&read(request)?))?,
        b"window_panes_auto_direction" => value(&panes::auto_direction(read(request)?))?,
        b"window_panes_tab_bar" => value(&panes::tab_bar(read(request)?))?,
        b"window_panes_terminal_bindings" => json!({ "bindings": panes::TERMINAL_BINDINGS }),
        b"window_panes_clear_failure" => {
            let request: Text = read(request)?;
            json!({ "kind": panes::clear_failure_kind(&request.text) })
        }
        b"window_panes_shell_quote" => {
            let request: Text = read(request)?;
            json!({ "text": panes::shell_quoted(&request.text) })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}

/// The `chat` ops: the chat dock and column placement, then the agent chat handlers' rules.
fn respond_chat(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    use cmux_window_rules::chat;
    let answer = match operation {
        // Every chat placement of one pane: a new tab's, a new chat's, the New Tab page's, the dock's.
        b"window_chat_column" => {
            let r: ChatColumn = read(request)?;
            serde_json::to_value(chat::read(&r.pane, &r.columns, &r.recent, r.zoomed, r.moving))
                .map_err(|_| ERR_INVALID)?
        }
        // What a person's Cmd-I does.
        b"window_chat_docked_open" => {
            let r: chat::DockedOpen = read(request)?;
            serde_json::to_value(chat::docked_open(&r)).map_err(|_| ERR_INVALID)?
        }
        // A drop on a pane's edge, and the pane (index) a drop on a workspace lands in.
        b"window_chat_drop" => {
            let r: ChatDrop = read(request)?;
            json!({ "split": chat::drop_split(r.room_decided, r.into_chat_dock),
                    "pane": chat::drop_pane(&r.chat_docks) })
        }
        // A scripted chat's pane by the windows' focus; null: ask `window_chat_latest`.
        b"window_chat_destination" => {
            let r: ChatDestinationRequest = read(request)?;
            json!({ "destination": chat::destination(&r.windows, &r.workspaces) })
        }
        // The pane focused last across workspaces with a key.
        b"window_chat_latest" => {
            let r: ChatWorkspaces = read(request)?;
            json!({ "destination": chat::latest_pane(&r.workspaces) })
        }
        // The pane a chat's target (`pane`, `workspace`) names.
        b"window_chat_target" => {
            let r: ChatTarget = read(request)?;
            json!({ "destination": chat::target(r.kind, &r.id, &r.workspaces) })
        }
        // The folder a new chat starts in.
        b"window_chat_cwd" => {
            let r: ChatCwd = read(request)?;
            json!({ "cwd": chat::cwd(r.given.as_deref(), r.agent_folder.as_deref(), &r.tabs, r.selected) })
        }
        // The column and canvas action ids the app binds.
        b"window_columns_actions" => {
            serde_json::to_value(chat::column_actions()).map_err(|_| ERR_INVALID)?
        }
        // A column action's plan over the column the app found.
        b"window_columns_plan" => {
            let r: ColumnsPlan = read(request)?;
            serde_json::to_value(chat::column_plan(&r.action, &r.facts)).map_err(|_| ERR_INVALID)?
        }
        // Why a column action is disabled up front; `unavailable` null: it is not.
        b"window_columns_availability" => {
            let r: ColumnsAvailability = read(request)?;
            json!({ "unavailable": chat::column_availability(&r.action, r.column.as_ref()) })
        }
        // The capability a dock change lacks; `needs` null: send it.
        b"window_columns_dock" => {
            let r: chat::DockFacts = read(request)?;
            json!({ "needs": chat::dock_needs(r) })
        }
        // How the focused tab of a lone column moves into a new dock.
        b"window_columns_dock_move" => {
            let r: chat::DockMoveFacts = read(request)?;
            serde_json::to_value(chat::dock_move(&r)).map_err(|_| ERR_INVALID)?
        }
        _ => return respond_chat_agent(operation, request),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChatColumn {
    pane: String,
    #[serde(default)]
    columns: Vec<cmux_window_rules::chat::Column>,
    #[serde(default)]
    recent: Vec<String>,
    #[serde(default)]
    zoomed: bool,
    #[serde(default)]
    moving: Option<cmux_window_rules::chat::Moving>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ChatDrop {
    room_decided: bool,
    into_chat_dock: bool,
    chat_docks: Vec<bool>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ChatDestinationRequest {
    windows: Vec<cmux_window_rules::chat::ChatWindow>,
    workspaces: Vec<cmux_window_rules::chat::ChatWorkspace>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ChatWorkspaces {
    workspaces: Vec<cmux_window_rules::chat::ChatWorkspace>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChatTarget {
    kind: cmux_window_rules::chat::TargetKind,
    id: String,
    #[serde(default)]
    workspaces: Vec<cmux_window_rules::chat::ChatWorkspace>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct ChatCwd {
    given: Option<String>,
    agent_folder: Option<String>,
    tabs: Vec<Option<String>>,
    selected: i64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ColumnsPlan {
    action: String,
    #[serde(default, flatten)]
    facts: cmux_window_rules::chat::ColumnFacts,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ColumnsAvailability {
    action: String,
    #[serde(default)]
    column: Option<cmux_window_rules::chat::ActionColumn>,
}

/// The agent chat handlers' ops (`chat::agent`).
fn respond_chat_agent(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    use cmux_window_rules::chat::agent;
    fn value<T: serde::Serialize>(answer: T) -> Result<serde_json::Value, i32> {
        serde_json::to_value(answer).map_err(|_| ERR_INVALID)
    }
    let answer = match operation {
        // The tables the agent actions bind from.
        b"window_chat_agent_tables" => value(agent::tables())?,
        // The agent chat zoom after a step, clamped, and its percent.
        b"window_chat_agent_zoom" => {
            let request: AgentZoom = read(request)?;
            value(agent::zoom(request.current, request.delta, request.lower, request.upper))?
        }
        // Open File's first step: the picker, a refused place, or the target.
        b"window_chat_agent_file_place" => {
            let request: AgentFilePlace = read(request)?;
            value(agent::file_place(
                &request.path,
                request.place.as_deref(),
                request.names_pane,
                request.has_focused_pane,
            ))?
        }
        // Open File's path check; `refusal` null: go on.
        b"window_chat_agent_file_check" => {
            let request: AgentFileCheck = read(request)?;
            json!({ "refusal": agent::file_check(&request.path, request.target, request.remote) })
        }
        // The pane a new agent chat opens in.
        b"window_chat_agent_pane_route" => {
            let request: AgentPaneRoute = read(request)?;
            json!({ "route": agent::pane_route(request.targeted, request.has_pane, request.top_page, request.has_workspace) })
        }
        // New Agent Chat on a resolved machine: its host argument and plan.
        b"window_chat_agent_host_plan" => {
            let request: agent::HostFacts = read(request)?;
            value(agent::host_plan(&request))?
        }
        // A script's New Agent Chat aimed at a pane or workspace.
        b"window_chat_agent_targeted_route" => value(agent::targeted_route(read(request)?))?,
        // Where the Memory Inspector's tab goes; `placement` null: a user workspace.
        b"window_chat_agent_inspector_placement" => {
            let request: AgentInspectorPlacement = read(request)?;
            json!({ "placement": agent::inspector_placement(request.focused, request.in_home, &request.columns) })
        }
        // The pane a new Memory Inspector column goes right of.
        b"window_chat_agent_inspector_anchor" => {
            let request: agent::AnchorFacts = read(request)?;
            value(agent::inspector_anchor(&request))?
        }
        // The persisted route of a Chief (`server`, else `chief`, else the default).
        b"window_chat_agent_memory_route" => {
            let request: AgentMemoryRoute = read(request)?;
            json!({ "route": agent::memory_route(request.server.as_deref(), request.chief.as_deref()) })
        }
        // The Chief a persisted route names; `place` null: unreadable.
        b"window_chat_agent_memory_place" => {
            let request: AgentMemoryPlace = read(request)?;
            json!({ "place": agent::parse_memory_route(&request.route) })
        }
        // The Set Model picker's catalog by harness name.
        b"window_chat_agent_model_catalog" => {
            let request: AgentModelCatalog = read(request)?;
            json!({ "harnesses": agent::model_catalog(&request.harnesses) })
        }
        // An agent-opened workspace's sidebar placement.
        b"window_chat_agent_session_placement" => {
            let request: AgentSessionPlacement = read(request)?;
            value(agent::session_placement(request.group, request.top))?
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&answer).map_err(|_| ERR_INVALID)
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AgentZoom {
    current: f64,
    delta: f64,
    lower: f64,
    upper: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AgentFilePlace {
    #[serde(default)]
    path: String,
    #[serde(default)]
    place: Option<String>,
    #[serde(default)]
    names_pane: bool,
    #[serde(default)]
    has_focused_pane: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AgentFileCheck {
    #[serde(default)]
    path: String,
    #[serde(default)]
    target: cmux_window_rules::chat::agent::FileTarget,
    #[serde(default)]
    remote: bool,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct AgentPaneRoute {
    targeted: bool,
    has_pane: bool,
    top_page: bool,
    has_workspace: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AgentInspectorPlacement {
    focused: u64,
    #[serde(default)]
    in_home: bool,
    #[serde(default)]
    columns: Vec<cmux_window_rules::chat::agent::InspectorColumn>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AgentMemoryRoute {
    #[serde(default)]
    server: Option<String>,
    #[serde(default)]
    chief: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AgentMemoryPlace {
    route: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct AgentModelCatalog {
    #[serde(default)]
    harnesses: Vec<cmux_window_rules::chat::agent::HarnessModels>,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct AgentSessionPlacement {
    group: bool,
    top: bool,
}

/// The target, workspace and closed history ops (`window_rules_workspaces.rs`).
fn respond_workspaces(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    workspaces::respond(operation, request)
}
