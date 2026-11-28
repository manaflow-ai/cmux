//! The create's requests: whether a new terminal workspace is one request
//! (`create-terminal-workspace-v1`) or two (`create-workspace`, then `create-terminal`), the first
//! terminal's request asking for its workspace too (`NewTerminalWorkspace.applied`), and what each
//! creating request made for `action.run`'s `created` list (`CreatingRequests.swift`).

use serde::{Deserialize, Serialize};

/// The capability that lets `create-terminal` make its workspace.
pub const CREATE_TERMINAL_WORKSPACE: &str = "create-terminal-workspace-v1";
/// The capability that lets `create-workspace` make a browser tab as its only tab.
pub const WORKSPACE_FIRST_TAB: &str = "workspace-first-tab-v1";

/// Where a `create-terminal` goes (`CreateTerminalRequest.workspace`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum WorkspaceRef {
    /// A workspace by its key.
    Key(String),
    /// A workspace by the daemon's handle.
    Handle(u64),
}

/// The fields of a `create-terminal` the create decides (`CreateTerminalRequest`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateTerminal {
    /// Its workspace.
    pub workspace: WorkspaceRef,
    /// Its mutation identity; nil for an unkeyed request.
    #[serde(default)]
    pub mutation: Option<String>,
    /// The client-chosen terminal id.
    #[serde(default)]
    pub terminal_id: Option<String>,
    /// Ask the daemon to make the workspace too.
    #[serde(default)]
    pub create_workspace: Option<bool>,
    /// The workspace's name, with `create_workspace`.
    #[serde(default)]
    pub workspace_name: Option<String>,
}

/// A workspace made with its first terminal (`NewTerminalWorkspace`).
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(default)]
pub struct NewTerminalWorkspace {
    /// The key of the workspace to make.
    pub key: String,
    /// Its name; nil: the daemon names it.
    pub name: Option<String>,
}

impl NewTerminalWorkspace {
    /// `request` asking for this workspace too, when it is a keyed first terminal of `key` (its
    /// workspace by this key, with a mutation identity and a terminal id); else `request` as it is.
    pub fn applied(&self, request: &CreateTerminal) -> CreateTerminal {
        let keyed = request.workspace == WorkspaceRef::Key(self.key.clone())
            && request.mutation.is_some()
            && request.terminal_id.is_some();
        if !keyed {
            return request.clone();
        }
        CreateTerminal {
            create_workspace: Some(true),
            workspace_name: self.name.clone(),
            ..request.clone()
        }
    }
}

/// How `WorkspaceCreation.create` makes a workspace with its first terminal.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CreatePlan {
    /// The first terminal's request makes the workspace (the connection took the
    /// `NewTerminalWorkspace`).
    pub one_request: bool,
    /// The app sends `create-workspace` first.
    pub sends_create_workspace: bool,
}

/// The create's requests: one when the terminal comes first (`terminal_first`; false when the
/// caller's terminal step needs the workspace before it) and the daemon serves
/// `create-terminal-workspace-v1`, else `create-workspace` then the terminal.
pub fn create_plan(terminal_first: bool, makes_workspace_with_terminal: bool) -> CreatePlan {
    let one_request = terminal_first && makes_workspace_with_terminal;
    CreatePlan { one_request, sends_create_workspace: !one_request }
}

/// The kind of a created object (`DaemonCreatedObject.Kind`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum CreatedKind {
    /// A workspace, by its key.
    Workspace,
    /// A screen, by its handle.
    Screen,
    /// A pane.
    Pane,
    /// A tab, by its surface handle.
    Tab,
    /// A terminal, by its id.
    Terminal,
    /// A tab group.
    TabGroup,
    /// A workspace group.
    WorkspaceGroup,
}

/// One object a creating request made (`DaemonCreatedObject`).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct CreatedObject {
    /// Its kind.
    pub kind: CreatedKind,
    /// Its handle, key or id, as text.
    pub id: String,
}

impl CreatedObject {
    fn new(kind: CreatedKind, id: impl Into<String>) -> CreatedObject {
        CreatedObject { kind, id: id.into() }
    }
}

/// What a creating request's reply reports.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CreatedReply {
    /// The workspace key in the reply.
    pub key: Option<String>,
    /// The new tab's surface handle.
    pub surface: Option<String>,
    /// The new terminal's id.
    pub terminal_id: Option<String>,
    /// The new screen's handle.
    pub screen: Option<String>,
    /// The new tab group's id (`group.id`, else `groupID`).
    pub group_id: Option<String>,
}

/// The creating requests `action.run` reports.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum CreatingCommand {
    /// `new-tab`, `new-screen`, `split`, `new-pane`, `new-pane-right`: a tab and maybe its terminal.
    Surface,
    /// `new-screen` with a spec: maybe a screen, then a tab and maybe its terminal.
    ScreenWithSpec,
    /// `create-terminal`.
    CreateTerminal,
    /// A frontend browser tab.
    BrowserTab,
    /// `create-workspace`.
    CreateWorkspace,
    /// `create-tab-group`.
    CreateTabGroup,
}

/// What `command` made, from its `reply`; `asked_workspace` is a `create-terminal` that asked for
/// its workspace too (`createWorkspace == true`). A `create-terminal` that asked for its workspace
/// names that workspace first, by the key in the reply: each caller asks with a new key, so the
/// named workspace is one the run made. A field the reply lacks names nothing, except a
/// `create-terminal`'s terminal and a browser tab's surface, which the reply always carries (an
/// empty id when the app passes none).
pub fn created_objects(
    command: CreatingCommand,
    asked_workspace: bool,
    reply: &CreatedReply,
) -> Vec<CreatedObject> {
    let surface_created = |reply: &CreatedReply| {
        let mut out = Vec::new();
        if let Some(surface) = &reply.surface {
            out.push(CreatedObject::new(CreatedKind::Tab, surface.clone()));
        }
        if let Some(terminal) = &reply.terminal_id {
            out.push(CreatedObject::new(CreatedKind::Terminal, terminal.clone()));
        }
        out
    };
    match command {
        CreatingCommand::Surface => surface_created(reply),
        CreatingCommand::ScreenWithSpec => {
            let mut out: Vec<CreatedObject> = reply
                .screen
                .iter()
                .map(|screen| CreatedObject::new(CreatedKind::Screen, screen.clone()))
                .collect();
            out.extend(surface_created(reply));
            out
        }
        CreatingCommand::CreateTerminal => {
            let mut out = Vec::new();
            if asked_workspace {
                out.push(CreatedObject::new(
                    CreatedKind::Workspace,
                    reply.key.clone().unwrap_or_default(),
                ));
            }
            if let Some(surface) = &reply.surface {
                out.push(CreatedObject::new(CreatedKind::Tab, surface.clone()));
            }
            out.push(CreatedObject::new(
                CreatedKind::Terminal,
                reply.terminal_id.clone().unwrap_or_default(),
            ));
            out
        }
        CreatingCommand::BrowserTab => {
            vec![CreatedObject::new(CreatedKind::Tab, reply.surface.clone().unwrap_or_default())]
        }
        CreatingCommand::CreateWorkspace => {
            vec![CreatedObject::new(CreatedKind::Workspace, reply.key.clone().unwrap_or_default())]
        }
        CreatingCommand::CreateTabGroup => reply
            .group_id
            .iter()
            .map(|group| CreatedObject::new(CreatedKind::TabGroup, group.clone()))
            .collect(),
    }
}
