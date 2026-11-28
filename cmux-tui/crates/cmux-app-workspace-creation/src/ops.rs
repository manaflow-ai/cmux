//! The JSON ops the app calls through the app FFI's JSON channel (cmux-layout-reducer-ffi
//! `cmux_layout_reducer_json`, ops `workspace_creation_*`). Every op is pure. Requests and replies
//! are in the shape Swift's synthesized `Codable` gives the app's types (camelCase).
//!
//! | op | request | reply |
//! | --- | --- | --- |
//! | `workspace_creation_expand_tilde` | `{path, home}` | `{path}` |
//! | `workspace_creation_folder_name` | `{directory, base?}` | `{name?}` |
//! | `workspace_creation_default_name` | `{workspaces, reserved}` | `{name}` |
//! | `workspace_creation_placement_env` | `{workspace?, terminal}` | `{env}` |
//! | `workspace_creation_terminal_env` | `{app, room?, caller, workspace, terminal}` | `{env}` |
//! | `workspace_creation_spawn_placement` | `{setting, placing}` | [`SpawnPlacement`] |
//! | `workspace_creation_spawn_from_invocation` | [`InvocationArgs`] | [`Spawn`] |
//! | `workspace_creation_spawn_facts` | `{spawn, local, tabs}` | `{plainNewTabPage, showsBeforeDaemon, opensPage}` |
//! | `workspace_creation_start_folder` | `{spawn, roomFolder?, local, daemonDefault?, home}` | `{cwd?}` |
//! | `workspace_creation_terminal_start` | `{spawn, facts}` | [`TerminalStart`] |
//! | `workspace_creation_new_terminal_workspace` | `{workspace, request}` | the applied request |
//! | `workspace_creation_create_plan` | `{terminalFirst, makesWorkspaceWithTerminal}` | [`CreatePlan`] |
//! | `workspace_creation_created_objects` | `{command, askedWorkspace, reply}` | `{created}` |
//! | `workspace_creation_session_tab_refusal` | [`SessionTabFacts`] | `{refusal?, message?}` |
//! | `workspace_creation_session_tab_start` | `{connected, facts}` | [`SessionTabStart`] |
//! | `workspace_creation_tab_key` | `{tabResourceId?, surface}` | `{key}` |
//! | `workspace_creation_failure_plan` | `{step, kind}` | [`FailurePlan`] |
//! | `workspace_creation_failure_end` | `{plan, closeFailed}` | [`FailureEnd`] |
//! | `workspace_creation_populating` | `{state, finish?: {succeeded, kept}}` | [`PopulateEnd`] |
//! | `workspace_creation_new_workspace` | `{spawn, facts}` | [`NewWorkspaceDecision`] |
//! | `workspace_creation_start_plan` | `{spawn, facts}` | [`StartPlan`] |
//! | `workspace_creation_create_route` | `{spawn, facts}` | [`CreateRoutePlan`] |

use crate::env::{placement_environment, terminal_environment};
use crate::half_created::{
    FailedStep, FailureEnd, FailureKind, FailurePlan, PopulateEnd, RepairState, begin_populating,
    failure_end, failure_plan, finish_populating,
};
use crate::naming::{ListedWorkspace, next_workspace_name};
use crate::new_workspace::{NewWorkspaceDecision, NewWorkspaceFacts, decide};
use crate::path::{expand_tilde, folder_name};
use crate::placement::{DefaultSlot, SpawnPlacement, SpawnPlacing, spawn_placement};
use crate::request::{
    CreatePlan, CreateTerminal, CreatedReply, CreatingCommand, NewTerminalWorkspace, create_plan,
    created_objects,
};
use crate::session_tab::{
    SessionTabFacts, SessionTabStart, session_tab_refusal, session_tab_start, tab_key,
};
use crate::spawn::{AgentTabFacts, InvocationArgs, Spawn, TerminalStart, TerminalStartFacts};
use crate::spawner::{
    CreateFacts, CreateRoutePlan, StartFacts, StartPlan, create_route, start_plan,
};
use serde::Deserialize;
use serde::de::DeserializeOwned;
use serde_json::{Value, json};
use std::collections::BTreeMap;

/// The ops' prefix.
pub const PREFIX: &str = "workspace_creation_";

/// Why an op failed.
#[derive(Debug, PartialEq, Eq)]
pub enum OpError {
    /// The op is not one of the table's.
    UnknownOp(String),
    /// The request is not the JSON the op takes.
    Invalid(String),
}

#[derive(Deserialize)]
struct TildeRequest {
    path: String,
    #[serde(default)]
    home: String,
}

#[derive(Deserialize)]
struct FolderNameRequest {
    directory: String,
    #[serde(default)]
    base: Option<String>,
}

#[derive(Deserialize)]
struct DefaultNameRequest {
    #[serde(default)]
    workspaces: Vec<ListedWorkspace>,
    #[serde(default)]
    reserved: Vec<String>,
}

#[derive(Deserialize)]
struct PlacementEnvRequest {
    #[serde(default)]
    workspace: Option<String>,
    terminal: String,
}

#[derive(Deserialize)]
struct TerminalEnvRequest {
    #[serde(default)]
    app: BTreeMap<String, String>,
    #[serde(default)]
    room: Option<BTreeMap<String, String>>,
    #[serde(default)]
    caller: BTreeMap<String, String>,
    workspace: String,
    terminal: String,
}

#[derive(Deserialize)]
struct SpawnPlacementRequest {
    #[serde(default)]
    setting: DefaultSlot,
    #[serde(default)]
    placing: SpawnPlacing,
}

#[derive(Deserialize)]
struct SpawnFactsRequest {
    #[serde(default)]
    spawn: Spawn,
    #[serde(default)]
    local: bool,
    #[serde(default)]
    tabs: AgentTabFacts,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StartFolderRequest {
    #[serde(default)]
    spawn: Spawn,
    #[serde(default)]
    room_folder: Option<String>,
    #[serde(default)]
    local: bool,
    #[serde(default)]
    daemon_default: Option<String>,
    #[serde(default)]
    home: String,
}

#[derive(Deserialize)]
struct WithSpawn<F> {
    #[serde(default)]
    spawn: Spawn,
    facts: F,
}

#[derive(Deserialize)]
struct NewTerminalWorkspaceRequest {
    workspace: NewTerminalWorkspace,
    request: CreateTerminal,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreatePlanRequest {
    #[serde(default = "yes")]
    terminal_first: bool,
    #[serde(default)]
    makes_workspace_with_terminal: bool,
}

fn yes() -> bool {
    true
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct CreatedObjectsRequest {
    command: CreatingCommand,
    #[serde(default)]
    asked_workspace: bool,
    #[serde(default)]
    reply: CreatedReply,
}

#[derive(Deserialize)]
struct SessionTabStartRequest {
    #[serde(default)]
    connected: bool,
    #[serde(default)]
    facts: SessionTabFacts,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct TabKeyRequest {
    #[serde(default)]
    tab_resource_id: Option<String>,
    surface: String,
}

#[derive(Deserialize)]
struct FailurePlanRequest {
    step: FailedStep,
    kind: FailureKind,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FailureEndRequest {
    plan: FailurePlan,
    #[serde(default)]
    close_failed: bool,
}

#[derive(Deserialize)]
struct PopulatingFinish {
    succeeded: bool,
    #[serde(default)]
    kept: bool,
}

#[derive(Deserialize)]
struct PopulatingRequest {
    state: RepairState,
    #[serde(default)]
    finish: Option<PopulatingFinish>,
}

fn parse<T: DeserializeOwned>(request: Value) -> Result<T, OpError> {
    serde_json::from_value(request).map_err(|error| OpError::Invalid(error.to_string()))
}

fn encode<T: serde::Serialize>(value: &T) -> Value {
    serde_json::to_value(value).unwrap_or(Value::Null)
}

/// True for the ops [`call`] answers.
pub fn serves(op: &str) -> bool {
    op.starts_with(PREFIX)
}

/// Runs `op` on `request` (a JSON object; null means `{}`).
pub fn call(op: &str, request: Value) -> Result<Value, OpError> {
    let request = if request.is_null() { json!({}) } else { request };
    let Some(name) = op.strip_prefix(PREFIX) else {
        return Err(OpError::UnknownOp(op.to_owned()));
    };
    match name {
        "expand_tilde" => {
            let TildeRequest { path, home } = parse(request)?;
            Ok(json!({ "path": expand_tilde(&path, &home) }))
        }
        "folder_name" => {
            let FolderNameRequest { directory, base } = parse(request)?;
            Ok(json!({ "name": folder_name(&directory, base.as_deref()) }))
        }
        "default_name" => {
            let DefaultNameRequest { workspaces, reserved } = parse(request)?;
            Ok(json!({ "name": next_workspace_name(&workspaces, &reserved) }))
        }
        "placement_env" => {
            let PlacementEnvRequest { workspace, terminal } = parse(request)?;
            Ok(json!({ "env": placement_environment(workspace.as_deref(), &terminal) }))
        }
        "terminal_env" => {
            let TerminalEnvRequest { app, room, caller, workspace, terminal } = parse(request)?;
            let env = terminal_environment(&app, room.as_ref(), &caller, &workspace, &terminal);
            Ok(json!({ "env": env }))
        }
        "spawn_placement" => {
            let SpawnPlacementRequest { setting, placing } = parse(request)?;
            let placement: SpawnPlacement = spawn_placement(&setting, placing);
            Ok(encode(&placement))
        }
        "spawn_from_invocation" => {
            let args: InvocationArgs = parse(request)?;
            Ok(encode(&Spawn::from_invocation(&args)))
        }
        "spawn_facts" => {
            let SpawnFactsRequest { spawn, local, tabs } = parse(request)?;
            Ok(json!({
                "plainNewTabPage": spawn.is_plain_new_tab_page(),
                "showsBeforeDaemon": spawn.shows_before_daemon(local),
                "opensPage": spawn.opens_page(&tabs),
            }))
        }
        "start_folder" => {
            let StartFolderRequest { spawn, room_folder, local, daemon_default, home } =
                parse(request)?;
            let cwd =
                spawn.start_folder(room_folder.as_deref(), local, daemon_default.as_deref(), &home);
            Ok(json!({ "cwd": cwd }))
        }
        "terminal_start" => {
            let WithSpawn::<TerminalStartFacts> { spawn, facts } = parse(request)?;
            let start: TerminalStart = spawn.terminal_start(&facts);
            Ok(encode(&start))
        }
        "new_terminal_workspace" => {
            let NewTerminalWorkspaceRequest { workspace, request } = parse(request)?;
            Ok(encode(&workspace.applied(&request)))
        }
        "create_plan" => {
            let CreatePlanRequest { terminal_first, makes_workspace_with_terminal } =
                parse(request)?;
            let plan: CreatePlan = create_plan(terminal_first, makes_workspace_with_terminal);
            Ok(encode(&plan))
        }
        "created_objects" => {
            let CreatedObjectsRequest { command, asked_workspace, reply } = parse(request)?;
            Ok(json!({ "created": created_objects(command, asked_workspace, &reply) }))
        }
        "session_tab_refusal" => {
            let facts: SessionTabFacts = parse(request)?;
            let refusal = session_tab_refusal(&facts);
            let message = refusal.as_ref().map(|refusal| refusal.message());
            Ok(json!({ "refusal": refusal, "message": message }))
        }
        "session_tab_start" => {
            let SessionTabStartRequest { connected, facts } = parse(request)?;
            let start: SessionTabStart = session_tab_start(connected, &facts);
            Ok(encode(&start))
        }
        "tab_key" => {
            let TabKeyRequest { tab_resource_id, surface } = parse(request)?;
            Ok(json!({ "key": tab_key(tab_resource_id.as_deref(), &surface) }))
        }
        "failure_plan" => {
            let FailurePlanRequest { step, kind } = parse(request)?;
            Ok(encode(&failure_plan(step, kind)))
        }
        "failure_end" => {
            let FailureEndRequest { plan, close_failed } = parse(request)?;
            let end: FailureEnd = failure_end(plan, close_failed);
            Ok(encode(&end))
        }
        "populating" => {
            let PopulatingRequest { state, finish } = parse(request)?;
            let end: PopulateEnd = match finish {
                Some(PopulatingFinish { succeeded, kept }) => {
                    finish_populating(state, succeeded, kept)
                }
                None => PopulateEnd {
                    state: begin_populating(state),
                    clears_kept: false,
                    records_failure: false,
                },
            };
            Ok(encode(&end))
        }
        "new_workspace" => {
            let WithSpawn::<NewWorkspaceFacts> { spawn, facts } = parse(request)?;
            let decision: NewWorkspaceDecision = decide(&spawn, &facts);
            Ok(encode(&decision))
        }
        "start_plan" => {
            let WithSpawn::<StartFacts> { spawn, facts } = parse(request)?;
            let plan: StartPlan = start_plan(&spawn, &facts);
            Ok(encode(&plan))
        }
        "create_route" => {
            let WithSpawn::<CreateFacts> { spawn, facts } = parse(request)?;
            let plan: CreateRoutePlan = create_route(&spawn, &facts);
            Ok(encode(&plan))
        }
        _ => Err(OpError::UnknownOp(op.to_owned())),
    }
}
