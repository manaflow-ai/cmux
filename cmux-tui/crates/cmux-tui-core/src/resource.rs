//! Opaque public resource identities and protocol-v2 shared types.

use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::sync::OnceLock;

use crate::{PaneId, ScreenId, SplitId, SurfaceId, WorkspaceId};
use scope::canonical_resource_scope;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

pub const PROTOCOL: &str = "cmux.protocol/2";
pub const MAX_MESSAGE_BYTES: usize = 4 * 1024 * 1024;
pub const STREAM_EVENT_CAPACITY: usize = 256;
pub const STREAM_BYTE_CAPACITY: usize = 16 * 1024 * 1024;
pub const JOURNAL_CAPACITY: usize = 4096;
pub const JOURNAL_BYTE_CAPACITY: usize = 16 * 1024 * 1024;

#[derive(Clone, Debug, PartialEq, Eq, Hash, Serialize)]
#[serde(transparent)]
pub struct RequestId(String);

impl RequestId {
    pub const MAX_BYTES: usize = 128;

    pub fn parse(value: impl Into<String>) -> Result<Self, ResourceError> {
        let value = value.into();
        if value.is_empty() || value.len() > Self::MAX_BYTES {
            return Err(ResourceError::validation_invalid(
                Some("id"),
                "request id must contain 1 to 128 UTF-8 bytes",
            ));
        }
        Ok(Self(value))
    }

    pub fn as_str(&self) -> &str {
        &self.0
    }
}

impl<'de> Deserialize<'de> for RequestId {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        Self::parse(String::deserialize(deserializer)?).map_err(serde::de::Error::custom)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum EnvelopeType {
    #[serde(rename = "request")]
    Request,
    #[serde(rename = "response")]
    Response,
    #[serde(rename = "stream_item")]
    StreamItem,
    #[serde(rename = "stream_end")]
    StreamEnd,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum ResourceOperation {
    #[serde(rename = "machine.list")]
    MachineList,
    #[serde(rename = "machine.get")]
    MachineGet,
    #[serde(rename = "session.list")]
    SessionList,
    #[serde(rename = "session.open")]
    SessionOpen,
    #[serde(rename = "session.get")]
    SessionGet,
    #[serde(rename = "session.snapshot")]
    SessionSnapshot,
    #[serde(rename = "session.creation.resolve")]
    SessionCreationResolve,
    #[serde(rename = "session.events")]
    SessionEvents,
    #[serde(rename = "session.journal.subscribe")]
    SessionJournalSubscribe,
    #[serde(rename = "session.journal.producer.list")]
    SessionJournalProducerList,
    #[serde(rename = "session.journal.producer.put")]
    SessionJournalProducerPut,
    #[serde(rename = "session.journal.append")]
    SessionJournalAppend,
    #[serde(rename = "session.journal.checkpoint.create")]
    SessionJournalCheckpointCreate,
    #[serde(rename = "session.journal.checkpoint.list")]
    SessionJournalCheckpointList,
    #[serde(rename = "session.journal.hook.list")]
    SessionJournalHookList,
    #[serde(rename = "session.journal.hook.put")]
    SessionJournalHookPut,
    #[serde(rename = "session.journal.restore.preview")]
    SessionJournalRestorePreview,
    #[serde(rename = "session.journal.segment.list")]
    SessionJournalSegmentList,
    #[serde(rename = "session.journal.segment.seal")]
    SessionJournalSegmentSeal,
    #[serde(rename = "session.ping")]
    SessionPing,
    #[serde(rename = "session.shutdown")]
    SessionShutdown,
    #[serde(rename = "session.reload_config")]
    SessionReloadConfig,
    #[serde(rename = "session.terminal_defaults.update")]
    SessionTerminalDefaultsUpdate,
    #[serde(rename = "client.list")]
    ClientList,
    #[serde(rename = "client.get")]
    ClientGet,
    #[serde(rename = "client.metadata.update")]
    ClientMetadataUpdate,
    #[serde(rename = "client.sizing.set")]
    ClientSizingSet,
    #[serde(rename = "client.sizing.release")]
    ClientSizingRelease,
    #[serde(rename = "client.cell_pixels.set")]
    ClientCellPixelsSet,
    #[serde(rename = "client.detach")]
    ClientDetach,
    #[serde(rename = "session.window.title.set")]
    SessionWindowTitleSet,
    #[serde(rename = "session.window.title.clear")]
    SessionWindowTitleClear,
    #[serde(rename = "pairing_request.list")]
    PairingRequestList,
    #[serde(rename = "pairing_request.resolve")]
    PairingRequestResolve,
    #[serde(rename = "request.cancel")]
    RequestCancel,
    #[serde(rename = "frontend_projection.get")]
    FrontendProjectionGet,
    #[serde(rename = "frontend_projection.put")]
    FrontendProjectionPut,
    #[serde(rename = "git.checkpoint.create")]
    GitCheckpointCreate,
    #[serde(rename = "git.checkpoint.diff")]
    GitCheckpointDiff,
    #[serde(rename = "git.checkpoint.get")]
    GitCheckpointGet,
    #[serde(rename = "git.checkpoint.list")]
    GitCheckpointList,
    #[serde(rename = "git.checkpoint.pin")]
    GitCheckpointPin,
    #[serde(rename = "git.checkpoint.unpin")]
    GitCheckpointUnpin,
    #[serde(rename = "git.diff")]
    GitDiff,
    #[serde(rename = "git.files.search")]
    GitFilesSearch,
    #[serde(rename = "git.status")]
    GitStatus,
    #[serde(rename = "workspace.list")]
    WorkspaceList,
    #[serde(rename = "workspace.get")]
    WorkspaceGet,
    #[serde(rename = "workspace.create")]
    WorkspaceCreate,
    #[serde(rename = "workspace.ensure_home")]
    WorkspaceEnsureHome,
    #[serde(rename = "workspace.rename")]
    WorkspaceRename,
    #[serde(rename = "workspace.move")]
    WorkspaceMove,
    #[serde(rename = "workspace.focus")]
    WorkspaceFocus,
    #[serde(rename = "workspace.close")]
    WorkspaceClose,
    #[serde(rename = "workspace.run")]
    WorkspaceRun,
    #[serde(rename = "workspace.layout.apply")]
    WorkspaceLayoutApply,
    #[serde(rename = "screen.list")]
    ScreenList,
    #[serde(rename = "screen.get")]
    ScreenGet,
    #[serde(rename = "screen.create")]
    ScreenCreate,
    #[serde(rename = "screen.rename")]
    ScreenRename,
    #[serde(rename = "screen.focus")]
    ScreenFocus,
    #[serde(rename = "screen.close")]
    ScreenClose,
    #[serde(rename = "screen.layout.export")]
    ScreenLayoutExport,
    #[serde(rename = "screen.layout.undo")]
    ScreenLayoutUndo,
    #[serde(rename = "pane.list")]
    PaneList,
    #[serde(rename = "pane.get")]
    PaneGet,
    #[serde(rename = "pane.create")]
    PaneCreate,
    #[serde(rename = "pane.split")]
    PaneSplit,
    #[serde(rename = "pane.rename")]
    PaneRename,
    #[serde(rename = "pane.focus")]
    PaneFocus,
    #[serde(rename = "pane.focus_direction")]
    PaneFocusDirection,
    #[serde(rename = "pane.neighbor.get")]
    PaneNeighborGet,
    #[serde(rename = "pane.swap")]
    PaneSwap,
    #[serde(rename = "pane.zoom")]
    PaneZoom,
    #[serde(rename = "pane.split_ratio.set")]
    PaneSplitRatioSet,
    #[serde(rename = "pane.viewport_width.set")]
    PaneViewportWidthSet,
    #[serde(rename = "column.update")]
    ColumnUpdate,
    #[serde(rename = "pane.close")]
    PaneClose,
    #[serde(rename = "pane.run")]
    PaneRun,
    #[serde(rename = "tab.list")]
    TabList,
    #[serde(rename = "tab.get")]
    TabGet,
    #[serde(rename = "tab.create_terminal")]
    TabCreateTerminal,
    #[serde(rename = "tab.create_browser")]
    TabCreateBrowser,
    #[serde(rename = "tab.rename")]
    TabRename,
    #[serde(rename = "tab.move")]
    TabMove,
    #[serde(rename = "tab.focus")]
    TabFocus,
    #[serde(rename = "tab.close")]
    TabClose,
    #[serde(rename = "terminal.list")]
    TerminalList,
    #[serde(rename = "terminal.get")]
    TerminalGet,
    #[serde(rename = "terminal.input.write")]
    TerminalInputWrite,
    #[serde(rename = "terminal.input.keys")]
    TerminalInputKeys,
    #[serde(rename = "terminal.input.mouse")]
    TerminalInputMouse,
    #[serde(rename = "terminal.input.focus")]
    TerminalInputFocus,
    #[serde(rename = "terminal.screen.read")]
    TerminalScreenRead,
    #[serde(rename = "terminal.state.read")]
    TerminalStateRead,
    #[serde(rename = "terminal.history.read")]
    TerminalHistoryRead,
    #[serde(rename = "terminal.history.clear")]
    TerminalHistoryClear,
    #[serde(rename = "terminal.output_read")]
    TerminalOutputRead,
    #[serde(rename = "terminal.wait")]
    TerminalWait,
    #[serde(rename = "terminal.wait_exit")]
    TerminalWaitExit,
    #[serde(rename = "terminal.copy")]
    TerminalCopy,
    #[serde(rename = "terminal.process.get")]
    TerminalProcessGet,
    #[serde(rename = "terminal.renderer_grant.create")]
    TerminalRendererGrantCreate,
    #[serde(rename = "terminal.viewer.resize")]
    TerminalViewerResize,
    #[serde(rename = "terminal.viewer.release")]
    TerminalViewerRelease,
    #[serde(rename = "terminal.viewport.scroll")]
    TerminalViewportScroll,
    #[serde(rename = "terminal.move")]
    TerminalMove,
    #[serde(rename = "terminal.project")]
    TerminalProject,
    #[serde(rename = "terminal.attach")]
    TerminalAttach,
    #[serde(rename = "terminal.close")]
    TerminalClose,
    #[serde(rename = "browser.list")]
    BrowserList,
    #[serde(rename = "browser.get")]
    BrowserGet,
    #[serde(rename = "browser.navigate")]
    BrowserNavigate,
    #[serde(rename = "browser.back")]
    BrowserBack,
    #[serde(rename = "browser.forward")]
    BrowserForward,
    #[serde(rename = "browser.reload")]
    BrowserReload,
    #[serde(rename = "browser.activate")]
    BrowserActivate,
    #[serde(rename = "browser.input.key")]
    BrowserInputKey,
    #[serde(rename = "browser.input.text")]
    BrowserInputText,
    #[serde(rename = "browser.input.mouse")]
    BrowserInputMouse,
    #[serde(rename = "browser.input.wheel")]
    BrowserInputWheel,
    #[serde(rename = "browser.viewer.resize")]
    BrowserViewerResize,
    #[serde(rename = "browser.viewer.release")]
    BrowserViewerRelease,
    #[serde(rename = "browser.attach")]
    BrowserAttach,
    #[serde(rename = "browser.close")]
    BrowserClose,
    #[serde(rename = "notification.list")]
    NotificationList,
    #[serde(rename = "notification.create")]
    NotificationCreate,
    #[serde(rename = "notification.ack")]
    NotificationAck,
    #[serde(rename = "notification.clear")]
    NotificationClear,
    #[serde(rename = "agent.list")]
    AgentList,
    #[serde(rename = "agent.report")]
    AgentReport,
    #[serde(rename = "sidebar_view.get")]
    SidebarViewGet,
    #[serde(rename = "sidebar_view.ensure")]
    SidebarViewEnsure,
    #[serde(rename = "sidebar_view.attach")]
    SidebarViewAttach,
    #[serde(rename = "sidebar_view.input")]
    SidebarViewInput,
    #[serde(rename = "sidebar_view.resize")]
    SidebarViewResize,
    #[serde(rename = "sidebar_view.reload")]
    SidebarViewReload,
    #[serde(rename = "stream.cancel")]
    StreamCancel,
    #[serde(rename = "closed.list")]
    ClosedList,
    #[serde(rename = "closed.reopen")]
    ClosedReopen,
    #[serde(rename = "closed.delete")]
    ClosedDelete,
    #[serde(rename = "window_record.list")]
    WindowRecordList,
    #[serde(rename = "window_record.put")]
    WindowRecordPut,
    #[serde(rename = "window_record.delete")]
    WindowRecordDelete,
    #[serde(rename = "room.create")]
    RoomCreate,
    #[serde(rename = "room.delete")]
    RoomDelete,
    #[serde(rename = "room.follow")]
    RoomFollow,
    #[serde(rename = "room.list")]
    RoomList,
    #[serde(rename = "room.move")]
    RoomMove,
    #[serde(rename = "room.pin")]
    RoomPin,
    #[serde(rename = "room.unpin")]
    RoomUnpin,
    #[serde(rename = "room.update")]
    RoomUpdate,
    #[serde(rename = "saved_tab_group.delete")]
    SavedTabGroupDelete,
    #[serde(rename = "saved_tab_group.list")]
    SavedTabGroupList,
    #[serde(rename = "saved_tab_group.reopen")]
    SavedTabGroupReopen,
    #[serde(rename = "saved_tab_group.save")]
    SavedTabGroupSave,
    #[serde(rename = "screen.move")]
    ScreenMove,
    #[serde(rename = "screen.update")]
    ScreenUpdate,
    #[serde(rename = "screen_group.add_screens")]
    ScreenGroupAddScreens,
    #[serde(rename = "screen_group.create")]
    ScreenGroupCreate,
    #[serde(rename = "screen_group.get")]
    ScreenGroupGet,
    #[serde(rename = "screen_group.list")]
    ScreenGroupList,
    #[serde(rename = "screen_group.remove_screens")]
    ScreenGroupRemoveScreens,
    #[serde(rename = "screen_group.ungroup")]
    ScreenGroupUngroup,
    #[serde(rename = "screen_group.update")]
    ScreenGroupUpdate,
    #[serde(rename = "tab.pin")]
    TabPin,
    #[serde(rename = "tab.unpin")]
    TabUnpin,
    #[serde(rename = "tab.update")]
    TabUpdate,
    #[serde(rename = "tab_group.add_tabs")]
    TabGroupAddTabs,
    #[serde(rename = "tab_group.close")]
    TabGroupClose,
    #[serde(rename = "tab_group.create")]
    TabGroupCreate,
    #[serde(rename = "tab_group.get")]
    TabGroupGet,
    #[serde(rename = "tab_group.list")]
    TabGroupList,
    #[serde(rename = "tab_group.move")]
    TabGroupMove,
    #[serde(rename = "tab_group.remove_tabs")]
    TabGroupRemoveTabs,
    #[serde(rename = "tab_group.ungroup")]
    TabGroupUngroup,
    #[serde(rename = "tab_group.update")]
    TabGroupUpdate,
    #[serde(rename = "workspace.place")]
    WorkspacePlace,
    #[serde(rename = "workspace.placement.list")]
    WorkspacePlacementList,
    #[serde(rename = "workspace.update")]
    WorkspaceUpdate,
    #[serde(rename = "workspace_group.create")]
    WorkspaceGroupCreate,
    #[serde(rename = "workspace_group.delete")]
    WorkspaceGroupDelete,
    #[serde(rename = "workspace_group.list")]
    WorkspaceGroupList,
    #[serde(rename = "workspace_group.move")]
    WorkspaceGroupMove,
    #[serde(rename = "workspace_group.update")]
    WorkspaceGroupUpdate,
    #[serde(rename = "workspace_log.append")]
    WorkspaceLogAppend,
    #[serde(rename = "workspace_log.clear")]
    WorkspaceLogClear,
    #[serde(rename = "workspace_log.list")]
    WorkspaceLogList,
    #[serde(rename = "workspace_progress.clear")]
    WorkspaceProgressClear,
    #[serde(rename = "workspace_progress.set")]
    WorkspaceProgressSet,
    #[serde(rename = "workspace_status.clear")]
    WorkspaceStatusClear,
    #[serde(rename = "workspace_status.list")]
    WorkspaceStatusList,
    #[serde(rename = "workspace_status.set")]
    WorkspaceStatusSet,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OperationClass {
    Read,
    Mutation,
    StreamOpen,
    ConnectionControl,
    Local,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub enum LocalOperation {
    #[serde(rename = "sidebar_plugin.list")]
    SidebarPluginList,
    #[serde(rename = "sidebar_plugin.install")]
    SidebarPluginInstall,
    #[serde(rename = "sidebar_plugin.use")]
    SidebarPluginUse,
    #[serde(rename = "sidebar_plugin.update")]
    SidebarPluginUpdate,
    #[serde(rename = "sidebar_plugin.remove")]
    SidebarPluginRemove,
    #[serde(rename = "sidebar_plugin.use_builtin")]
    SidebarPluginUseBuiltin,
}

impl LocalOperation {
    pub const fn class(self) -> OperationClass {
        OperationClass::Local
    }
}

impl ResourceOperation {
    pub const fn class(self) -> OperationClass {
        if matches!(
            self,
            Self::SessionEvents
                | Self::SessionJournalSubscribe
                | Self::TerminalAttach
                | Self::BrowserAttach
                | Self::SidebarViewAttach
        ) {
            OperationClass::StreamOpen
        } else if matches!(
            self,
            Self::RequestCancel
                | Self::StreamCancel
                | Self::ClientMetadataUpdate
                | Self::ClientSizingSet
                | Self::ClientSizingRelease
                | Self::ClientCellPixelsSet
                | Self::ClientDetach
                | Self::TerminalRendererGrantCreate
                | Self::TerminalViewerResize
                | Self::TerminalViewerRelease
                | Self::BrowserViewerResize
                | Self::BrowserViewerRelease
        ) {
            OperationClass::ConnectionControl
        } else if matches!(
            self,
            Self::MachineList
                | Self::MachineGet
                | Self::SessionList
                | Self::SessionGet
                | Self::SessionSnapshot
                | Self::SessionCreationResolve
                | Self::SessionPing
                | Self::SessionJournalProducerList
                | Self::SessionJournalHookList
                | Self::SessionJournalCheckpointList
                | Self::SessionJournalRestorePreview
                | Self::SessionJournalSegmentList
                | Self::ClientList
                | Self::ClientGet
                | Self::PairingRequestList
                | Self::FrontendProjectionGet
                | Self::GitCheckpointDiff
                | Self::GitCheckpointGet
                | Self::GitCheckpointList
                | Self::GitDiff
                | Self::GitFilesSearch
                | Self::GitStatus
                | Self::WorkspaceList
                | Self::WorkspaceGet
                | Self::ScreenList
                | Self::ScreenGet
                | Self::ScreenLayoutExport
                | Self::PaneList
                | Self::PaneGet
                | Self::PaneNeighborGet
                | Self::TabList
                | Self::TabGet
                | Self::TerminalList
                | Self::TerminalGet
                | Self::TerminalScreenRead
                | Self::TerminalStateRead
                | Self::TerminalHistoryRead
                | Self::TerminalOutputRead
                | Self::TerminalWait
                | Self::TerminalWaitExit
                | Self::TerminalCopy
                | Self::TerminalProcessGet
                | Self::BrowserList
                | Self::BrowserGet
                | Self::NotificationList
                | Self::AgentList
                | Self::SidebarViewGet
                | Self::ClosedList
                | Self::WindowRecordList
                | Self::RoomList
                | Self::SavedTabGroupList
                | Self::ScreenGroupGet
                | Self::ScreenGroupList
                | Self::TabGroupGet
                | Self::TabGroupList
                | Self::WorkspacePlacementList
                | Self::WorkspaceGroupList
                | Self::WorkspaceLogList
                | Self::WorkspaceStatusList
        ) {
            OperationClass::Read
        } else {
            OperationClass::Mutation
        }
    }

    pub const fn is_mutation(self) -> bool {
        matches!(self.class(), OperationClass::Mutation)
    }
}

#[cfg(test)]
#[path = "resource/wire_name_tests.rs"]
mod resource_operation_wire_name_tests;
mod idempotency_key;
mod scope;
mod wire_decimal;
mod wire_name;

pub use idempotency_key::{MAX_IDEMPOTENCY_KEY_BYTES, validate_idempotency_key};
pub use wire_decimal::WireDecimal;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RequestEnvelope {
    pub protocol: String,
    #[serde(rename = "type")]
    pub envelope_type: EnvelopeType,
    pub id: RequestId,
    pub operation: ResourceOperation,
    pub params: Value,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub idempotency_key: Option<String>,
}

impl RequestEnvelope {
    pub fn validate(&self) -> Result<(), ResourceError> {
        if self.protocol != PROTOCOL || self.envelope_type != EnvelopeType::Request {
            return Err(ResourceError::validation_invalid(
                Some("protocol"),
                "expected a cmux.protocol/2 request envelope",
            ));
        }
        if !self.params.is_object() {
            return Err(ResourceError::validation_invalid(
                Some("params"),
                "request params must be an object",
            ));
        }
        match (&self.idempotency_key, self.operation.class()) {
            (None, OperationClass::Mutation) => Err(ResourceError::validation_invalid(
                Some("idempotency_key"),
                "mutations require idempotency_key",
            )),
            (Some(_), class) if class != OperationClass::Mutation => {
                Err(ResourceError::validation_invalid(
                    Some("idempotency_key"),
                    "only mutations accept idempotency_key",
                ))
            }
            (Some(key), OperationClass::Mutation) => validate_idempotency_key(key),
            _ => Ok(()),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResponseEnvelope {
    pub protocol: String,
    #[serde(rename = "type")]
    pub envelope_type: EnvelopeType,
    pub id: RequestId,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub result: Option<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ResourceError>,
}

impl ResponseEnvelope {
    pub fn success(id: RequestId, result: Value) -> Self {
        Self {
            protocol: PROTOCOL.to_string(),
            envelope_type: EnvelopeType::Response,
            id,
            ok: true,
            result: Some(result),
            error: None,
        }
    }

    pub fn failure(id: RequestId, error: ResourceError) -> Self {
        Self {
            protocol: PROTOCOL.to_string(),
            envelope_type: EnvelopeType::Response,
            id,
            ok: false,
            result: None,
            error: Some(error),
        }
    }

    pub fn validate(&self) -> Result<(), ResourceError> {
        if self.protocol != PROTOCOL || self.envelope_type != EnvelopeType::Response {
            return Err(ResourceError::validation_invalid(
                Some("protocol"),
                "expected a cmux.protocol/2 response envelope",
            ));
        }
        match (self.ok, self.result.is_some(), self.error.is_some()) {
            (true, true, false) | (false, false, true) => Ok(()),
            _ => Err(ResourceError::validation_invalid(
                None,
                "response must contain exactly one matching result or error",
            )),
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ResourceCursor {
    pub generation: String,
    pub revision: WireDecimal,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StreamItemEnvelope {
    pub protocol: String,
    #[serde(rename = "type")]
    pub envelope_type: EnvelopeType,
    pub stream_id: StreamPublicId,
    pub sequence: WireDecimal,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<ResourceCursor>,
    pub item: Value,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StreamEndReason {
    Completed,
    Canceled,
    Closed,
    Gap,
    Error,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct StreamEndEnvelope {
    pub protocol: String,
    #[serde(rename = "type")]
    pub envelope_type: EnvelopeType,
    pub stream_id: StreamPublicId,
    pub reason: StreamEndReason,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub cursor: Option<ResourceCursor>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<ResourceError>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub recovery: Option<String>,
}

macro_rules! public_id {
    ($name:ident, $prefix:literal) => {
        #[derive(Clone, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize)]
        #[serde(transparent)]
        pub struct $name(String);

        impl $name {
            pub const PREFIX: &'static str = $prefix;

            pub fn random() -> Result<Self, ResourceError> {
                let mut bytes = [0u8; 16];
                getrandom::fill(&mut bytes).map_err(|_| ResourceError::allocation($prefix))?;
                Ok(Self(format!("{}_{}", $prefix, encode_hex(bytes))))
            }

            pub fn parse(value: impl Into<String>) -> Result<Self, ResourceError> {
                let value = value.into();
                let payload = value
                    .strip_prefix(concat!($prefix, "_"))
                    .ok_or_else(|| ResourceError::invalid_id(stringify!($name), &value))?;
                if payload.len() != 32
                    || !payload
                        .bytes()
                        .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
                {
                    return Err(ResourceError::invalid_id(stringify!($name), &value));
                }
                Ok(Self(value))
            }

            pub fn as_str(&self) -> &str {
                &self.0
            }

            pub fn into_string(self) -> String {
                self.0
            }
        }

        impl fmt::Debug for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.debug_tuple(stringify!($name)).field(&self.0).finish()
            }
        }

        impl fmt::Display for $name {
            fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
                formatter.write_str(&self.0)
            }
        }

        impl<'de> Deserialize<'de> for $name {
            fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
            where
                D: serde::Deserializer<'de>,
            {
                let value = String::deserialize(deserializer)?;
                Self::parse(value).map_err(serde::de::Error::custom)
            }
        }
    };
}

public_id!(MachinePublicId, "machine");
public_id!(SessionPublicId, "session");
public_id!(WorkspacePublicId, "ws");
public_id!(ScreenPublicId, "screen");
public_id!(PanePublicId, "pane");
public_id!(TabPublicId, "tab");
public_id!(TerminalPublicId, "term");
public_id!(BrowserPublicId, "browser");
public_id!(ClientPublicId, "client");
public_id!(SplitPublicId, "split");
public_id!(StreamPublicId, "stream");
public_id!(NotificationPublicId, "notification");
public_id!(AgentPublicId, "agent");
public_id!(FrontendProjectionPublicId, "projection");
public_id!(PairingRequestPublicId, "pairing");
public_id!(SidebarViewPublicId, "sidebar_view");
public_id!(SidebarPluginPublicId, "sidebar_plugin");

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct TabResourceIdentity {
    pub tab_id: TabPublicId,
    pub content_id: ContentPublicId,
}

impl TabResourceIdentity {
    pub fn new(tab_id: TabPublicId, content_id: ContentPublicId) -> Self {
        Self { tab_id, content_id }
    }

    pub fn persisted_terminal(tab_id: TabPublicId, terminal_id: TerminalPublicId) -> Self {
        Self::new(tab_id, ContentPublicId::Terminal(terminal_id))
    }

    pub fn persisted_browser(tab_id: TabPublicId, browser_id: BrowserPublicId) -> Self {
        Self::new(tab_id, ContentPublicId::Browser(browser_id))
    }

    pub fn terminal(terminal_id: Option<TerminalPublicId>) -> Result<Self, ResourceError> {
        let terminal_id = match terminal_id {
            Some(terminal_id) => terminal_id,
            None => TerminalPublicId::random()?,
        };
        Ok(Self::persisted_terminal(TabPublicId::random()?, terminal_id))
    }

    pub fn browser() -> Result<Self, ResourceError> {
        Ok(Self::persisted_browser(TabPublicId::random()?, BrowserPublicId::random()?))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(tag = "kind", content = "id", rename_all = "lowercase")]
pub enum ContentPublicId {
    Terminal(TerminalPublicId),
    Browser(BrowserPublicId),
}

impl ContentPublicId {
    pub fn as_str(&self) -> &str {
        match self {
            Self::Terminal(id) => id.as_str(),
            Self::Browser(id) => id.as_str(),
        }
    }
}

fn encode_hex(bytes: [u8; 16]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(32);
    for byte in bytes {
        output.push(char::from(HEX[(byte >> 4) as usize]));
        output.push(char::from(HEX[(byte & 0x0f) as usize]));
    }
    output
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResourceError {
    pub code: String,
    pub message: String,
    pub details: Value,
    pub retryable: bool,
}

impl ResourceError {
    pub fn new(
        code: impl Into<String>,
        message: impl Into<String>,
        details: Value,
        retryable: bool,
    ) -> Self {
        let code = code.into();
        assert!(
            is_catalog_error_code(&code),
            "resource error code {code:?} is absent from spec/resource-operations-v2.json"
        );
        assert!(
            catalog_error_contract_matches(&code, &details, retryable),
            "resource error {code:?} violates its catalog details or retryable contract: {details}"
        );
        Self { code, message: message.into(), details, retryable }
    }

    pub fn operation_failed(
        operation: impl Into<String>,
        reason: impl Into<String>,
        extra: Value,
    ) -> Self {
        let operation = operation.into();
        let reason = reason.into();
        assert!(extra.is_object(), "operation.failed extra must be an object");
        let mut details = json!({
            "operation":operation,
            "reason":reason,
        });
        if extra.as_object().is_some_and(|extra| !extra.is_empty()) {
            details["extra"] = extra;
        }
        Self::new("operation.failed", reason, details, false)
    }

    fn invalid_id(kind: &str, value: &str) -> Self {
        let scope = canonical_resource_scope(kind);
        Self::new(
            "selector.invalid",
            format!("invalid {kind} {value:?}"),
            json!({
                "scope":scope,
                "selector":value,
                "reason":format!("invalid {kind} resource identity"),
            }),
            false,
        )
    }

    pub fn not_found(kind: &str, selector: &str) -> Self {
        let scope = canonical_resource_scope(kind);
        Self::new(
            "selector.not_found",
            format!("no {kind} matches {selector:?}"),
            json!({"scope":scope,"selector":selector}),
            false,
        )
    }

    pub fn ambiguous(kind: &str, selector: &str, candidates: Vec<String>) -> Self {
        let scope = canonical_resource_scope(kind);
        Self::new(
            "selector.ambiguous",
            format!("more than one {kind} is named {selector:?}"),
            json!({"scope":scope,"selector":selector,"candidates":candidates}),
            false,
        )
    }

    pub fn allocation(kind: &str) -> Self {
        Self::operation_failed(
            "resource.allocate",
            format!("could not allocate {kind} identity"),
            json!({"kind":kind}),
        )
    }

    pub fn selector_invalid(scope: &str, selector: &str, reason: impl Into<String>) -> Self {
        let reason = reason.into();
        Self::new(
            "selector.invalid",
            reason.clone(),
            json!({
                "scope":canonical_resource_scope(scope),
                "selector":selector,
                "reason":reason,
            }),
            false,
        )
    }

    pub fn validation_invalid(field: Option<&str>, reason: impl Into<String>) -> Self {
        let reason = reason.into();
        let mut details = json!({"reason":reason});
        if let Some(field) = field {
            details["field"] = json!(field);
        }
        Self::new("validation.invalid", reason, details, false)
    }

    pub fn transport_closed(reason: impl Into<String>) -> Self {
        let reason = reason.into();
        Self::new("transport.closed", reason.clone(), json!({"reason":reason}), true)
    }

    pub fn terminal_closed(terminal_id: &TerminalPublicId) -> Self {
        Self::new(
            "terminal.closed",
            format!("terminal {terminal_id} is closed"),
            json!({"terminal_id":terminal_id}),
            false,
        )
    }

    pub fn idempotency_conflict(idempotency_key: &str, committed_operation: &str) -> Self {
        Self::new(
            "idempotency.conflict",
            "the idempotency key was already committed with different input",
            json!({
                "idempotency_key":idempotency_key,
                "committed_operation":committed_operation,
            }),
            false,
        )
    }

    pub fn creation_conflict(
        correlation_key: &str,
        existing_operation: &str,
        requested_operation: &str,
        existing_fingerprint: &str,
        requested_fingerprint: &str,
    ) -> Self {
        Self::new(
            "creation.conflict",
            "the creation correlation key is bound to different semantics",
            json!({
                "correlation_key":correlation_key,
                "existing_operation":existing_operation,
                "requested_operation":requested_operation,
                "existing_fingerprint":existing_fingerprint,
                "requested_fingerprint":requested_fingerprint,
            }),
            false,
        )
    }

    pub fn revision_conflict(expected: u64, actual: u64) -> Self {
        Self::new(
            "revision.conflict",
            "the resource revision changed",
            json!({
                "expected":expected.to_string(),
                "actual":actual.to_string(),
            }),
            true,
        )
    }
}

pub(crate) const RESOURCE_ERROR_CODES: &[&str] = &[
    "confirmation.required",
    "creation.conflict",
    "cursor.gap",
    "cursor.invalid",
    "home.not_closable",
    "home.pinned_first",
    "idempotency.conflict",
    "local.io",
    "mutation.indeterminate",
    "operation.failed",
    "operation.unsupported",
    "resource.not_found",
    "revision.conflict",
    "selector.ambiguous",
    "selector.invalid",
    "selector.not_found",
    "selector.wrong_parent",
    "terminal.closed",
    "transport.closed",
    "validation.invalid",
];

pub(crate) fn is_catalog_error_code(code: &str) -> bool {
    RESOURCE_ERROR_CODES.contains(&code)
}

fn error_catalog() -> &'static Value {
    static CATALOG: OnceLock<Value> = OnceLock::new();
    CATALOG.get_or_init(|| {
        serde_json::from_str(include_str!("../../../spec/resource-operations-v2.json"))
            .expect("checked-in resource operation catalog")
    })
}

fn catalog_error_contract_matches(code: &str, details: &Value, retryable: bool) -> bool {
    let Some(error) = error_catalog()["errors"].get(code) else { return false };
    error["retryable"].as_bool() == Some(retryable)
        && catalog_value_matches(details, &error["details"])
}

fn catalog_value_matches(value: &Value, descriptor: &Value) -> bool {
    match descriptor["kind"].as_str() {
        Some("primitive") => match descriptor["name"].as_str() {
            Some("json") => true,
            Some("string") => {
                let Some(value) = value.as_str() else { return false };
                descriptor["min_length"]
                    .as_u64()
                    .is_none_or(|minimum| value.len() >= minimum as usize)
                    && descriptor["max_length"]
                        .as_u64()
                        .is_none_or(|maximum| value.len() <= maximum as usize)
            }
            Some("decimal") => value.as_str().is_some_and(|value| {
                value == "0"
                    || (!value.starts_with('0')
                        && value.len() <= 20
                        && value.bytes().all(|byte| byte.is_ascii_digit())
                        && value.parse::<u64>().is_ok())
            }),
            Some("boolean") => value.is_boolean(),
            Some("uint32") => value.as_u64().is_some_and(|value| u32::try_from(value).is_ok()),
            Some("uint64") => value.is_u64(),
            _ => false,
        },
        Some("resource_id") => {
            let Some(value) = value.as_str() else { return false };
            let Some(resource) = descriptor["resource"].as_str() else { return false };
            resource_id_has_kind(value, resource)
        }
        Some("enum") => {
            descriptor["values"].as_array().is_some_and(|values| values.contains(value))
        }
        Some("array") => {
            let Some(values) = value.as_array() else { return false };
            descriptor["min_items"].as_u64().is_none_or(|minimum| values.len() >= minimum as usize)
                && descriptor["max_items"]
                    .as_u64()
                    .is_none_or(|maximum| values.len() <= maximum as usize)
                && values.iter().all(|value| catalog_value_matches(value, &descriptor["items"]))
        }
        Some("map") => value.as_object().is_some_and(|values| {
            values.values().all(|value| catalog_value_matches(value, &descriptor["values"]))
        }),
        Some("object") => {
            let Some(value) = value.as_object() else { return false };
            let Some(fields) = descriptor["fields"].as_object() else { return false };
            if descriptor["extra"] == Value::Bool(false)
                && value.keys().any(|name| !fields.contains_key(name))
            {
                return false;
            }
            fields.iter().all(|(name, field)| match value.get(name) {
                Some(value) => catalog_value_matches(value, &field["type"]),
                None => field["required"] != Value::Bool(true),
            })
        }
        Some("ref") => descriptor["name"]
            .as_str()
            .and_then(|name| error_catalog()["types"].get(name))
            .is_some_and(|descriptor| catalog_value_matches(value, descriptor)),
        _ => false,
    }
}

fn resource_id_has_kind(value: &str, kind: &str) -> bool {
    let prefix = match kind {
        "machine" => "machine_",
        "session" => "session_",
        "client" => "client_",
        "workspace" => "ws_",
        "screen" => "screen_",
        "pane" => "pane_",
        "split" => "split_",
        "tab" => "tab_",
        "terminal" => "term_",
        "browser" => "browser_",
        "notification" => "notification_",
        "agent" => "agent_",
        "frontend_projection" => "projection_",
        "pairing_request" => "pairing_",
        "sidebar_view" => "sidebar_view_",
        "stream" => "stream_",
        _ => return false,
    };
    value.strip_prefix(prefix).is_some_and(is_lower_hex_128)
}

fn is_lower_hex_128(value: &str) -> bool {
    value.len() == 32
        && value.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

impl fmt::Display for ResourceError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

impl std::error::Error for ResourceError {}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Selector {
    Current,
    Id(String),
    Name(String),
}

impl Selector {
    pub fn parse(value: &str) -> Result<Self, ResourceError> {
        if let Some(name) = value.strip_prefix("name:") {
            return Ok(Self::Name(name.to_string()));
        }
        if value == "current" {
            return Ok(Self::Current);
        }
        if is_registered_public_id(value) {
            return Ok(Self::Id(value.to_string()));
        }
        if value.contains('_') || is_reserved_selector_token(value) {
            return Err(ResourceError::validation_invalid(
                None,
                "reserved or ambiguous names must use the name: prefix",
            ));
        }
        Ok(Self::Name(value.to_string()))
    }
}

/// Tokens consumed by the noun-first CLI grammar. A resource may retain any
/// of these exact names, but callers must select it with the `name:` escape.
pub fn is_reserved_selector_token(value: &str) -> bool {
    matches!(
        value,
        "machine"
            | "session"
            | "client"
            | "window"
            | "pairing"
            | "request"
            | "frontend"
            | "projection"
            | "workspace"
            | "screen"
            | "pane"
            | "tab"
            | "terminal"
            | "browser"
            | "split"
            | "notification"
            | "agent"
            | "sidebar"
            | "view"
            | "plugin"
            | "provider"
            | "scope"
            | "action"
            | "notice"
            | "list"
            | "get"
            | "show"
            | "create"
            | "open"
            | "rename"
            | "delete"
            | "restore"
            | "purge"
            | "connect"
            | "snapshot"
            | "events"
            | "ping"
            | "shutdown"
            | "update"
            | "metadata"
            | "detach"
            | "set"
            | "clear"
            | "resolve"
            | "put"
            | "move"
            | "focus"
            | "close"
            | "run"
            | "apply"
            | "export"
            | "undo"
            | "neighbor"
            | "swap"
            | "zoom"
            | "resize"
            | "send"
            | "keys"
            | "read"
            | "history"
            | "state"
            | "direction"
            | "process"
            | "renderer"
            | "grant"
            | "cell"
            | "pixels"
            | "copy"
            | "attach"
            | "navigate"
            | "back"
            | "forward"
            | "reload"
            | "activate"
            | "install"
            | "use"
            | "builtin"
            | "disable"
            | "remove"
            | "report"
            | "notify"
    )
}

fn is_registered_public_id(value: &str) -> bool {
    let Some((prefix, payload)) = value.rsplit_once('_') else {
        return false;
    };
    matches!(
        prefix,
        "machine"
            | "session"
            | "ws"
            | "screen"
            | "pane"
            | "tab"
            | "term"
            | "browser"
            | "client"
            | "split"
            | "stream"
            | "notification"
            | "agent"
            | "projection"
            | "pairing"
            | "sidebar_view"
            | "sidebar_plugin"
    ) && payload.len() == 32
        && payload.bytes().all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

pub fn resolve_name<T: Clone>(
    kind: &str,
    selector: &str,
    candidates: impl IntoIterator<Item = (String, Option<String>, T)>,
) -> Result<T, ResourceError> {
    let mut matches = candidates
        .into_iter()
        .filter(|(_, name, _)| name.as_deref() == Some(selector))
        .collect::<Vec<_>>();
    match matches.len() {
        0 => Err(ResourceError::not_found(kind, selector)),
        1 => Ok(matches.pop().expect("one match").2),
        _ => {
            let mut ids = matches.into_iter().map(|(id, _, _)| id).collect::<Vec<_>>();
            ids.sort();
            Err(ResourceError::ambiguous(kind, selector, ids))
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResourceDelta {
    pub sequence: u32,
    pub event: String,
    pub data: Value,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ResourceDeltaBatch {
    pub previous_revision: WireDecimal,
    pub revision: WireDecimal,
    pub deltas: Vec<ResourceDelta>,
}

/// Bounded contiguous journal. One commit advances the resource revision
/// exactly once and may append several ordered deltas at that revision.
#[derive(Debug)]
pub struct ResourceJournal {
    generation: String,
    revision: u64,
    batches: VecDeque<(ResourceDeltaBatch, usize)>,
    capacity: usize,
    byte_capacity: usize,
    retained_bytes: usize,
}

impl ResourceJournal {
    pub fn new(generation: String, revision: u64) -> Self {
        Self {
            generation,
            revision,
            batches: VecDeque::new(),
            capacity: JOURNAL_CAPACITY,
            byte_capacity: JOURNAL_BYTE_CAPACITY,
            retained_bytes: 0,
        }
    }

    pub fn generation(&self) -> &str {
        &self.generation
    }

    pub fn revision(&self) -> u64 {
        self.revision
    }

    pub fn commit(&mut self, events: Vec<(String, Value)>) -> anyhow::Result<u64> {
        let previous_revision = self.revision;
        let revision = self
            .revision
            .checked_add(1)
            .ok_or_else(|| anyhow::anyhow!("resource revision exhausted"))?;
        let deltas = events
            .into_iter()
            .enumerate()
            .map(|(sequence, (event, data))| {
                Ok(ResourceDelta {
                    sequence: u32::try_from(sequence).map_err(|_| {
                        anyhow::anyhow!("too many deltas in one resource transaction")
                    })?,
                    event,
                    data,
                })
            })
            .collect::<anyhow::Result<Vec<_>>>()?;
        let batch = ResourceDeltaBatch {
            previous_revision: WireDecimal::new(previous_revision),
            revision: WireDecimal::new(revision),
            deltas,
        };
        let bytes = serde_json::to_vec(&batch)?.len();
        if bytes > self.byte_capacity {
            anyhow::bail!("one resource delta batch exceeds journal byte capacity");
        }
        self.revision = revision;
        self.batches.push_back((batch, bytes));
        self.retained_bytes = self.retained_bytes.saturating_add(bytes);
        while self.batches.len() > self.capacity || self.retained_bytes > self.byte_capacity {
            let Some((_, removed)) = self.batches.pop_front() else { break };
            self.retained_bytes = self.retained_bytes.saturating_sub(removed);
        }
        Ok(self.revision)
    }

    pub fn after(&self, revision: u64) -> Result<Vec<ResourceDeltaBatch>, ResourceError> {
        if revision > self.revision {
            return Err(ResourceError::new(
                "cursor.invalid",
                "resume cursor is ahead of the session revision",
                json!({
                    "requested":{
                        "generation":self.generation,
                        "revision":revision.to_string(),
                    },
                    "current":{
                        "generation":self.generation,
                        "revision":self.revision.to_string(),
                    },
                    "reason":"resume cursor is ahead of the session revision",
                }),
                false,
            ));
        }
        let oldest = self.batches.front().map_or(self.revision, |(batch, _)| batch.revision.get());
        if revision.saturating_add(1) < oldest {
            return Err(ResourceError::new(
                "cursor.gap",
                "resume cursor is no longer retained",
                json!({
                    "requested":{
                        "generation":self.generation,
                        "revision":revision.to_string(),
                    },
                    "current":{
                        "generation":self.generation,
                        "revision":self.revision.to_string(),
                    },
                    "oldest_revision":oldest.to_string(),
                }),
                true,
            ));
        }
        Ok(self
            .batches
            .iter()
            .filter(|(batch, _)| batch.revision.get() > revision)
            .map(|(batch, _)| batch.clone())
            .collect())
    }
}

#[derive(Debug, Default, Clone)]
pub struct PublicSlotIndexes {
    pub workspaces: HashMap<WorkspacePublicId, WorkspaceId>,
    pub screens: HashMap<ScreenPublicId, ScreenId>,
    pub panes: HashMap<PanePublicId, PaneId>,
    pub tabs: HashMap<TabPublicId, SurfaceId>,
    /// Every view placement of a content resource. Terminal content may have
    /// any number of placements; browser content currently has one.
    pub content_placements: HashMap<ContentPublicId, Vec<SurfaceId>>,
    pub workspace_ids: HashMap<WorkspaceId, WorkspacePublicId>,
    pub screen_ids: HashMap<ScreenId, ScreenPublicId>,
    pub pane_ids: HashMap<PaneId, PanePublicId>,
    pub tab_ids: HashMap<SurfaceId, TabPublicId>,
    pub content_ids: HashMap<SurfaceId, ContentPublicId>,
    pub splits: HashMap<SplitPublicId, SplitId>,
    pub split_ids: HashMap<SplitId, SplitPublicId>,
    pub screen_workspace: HashMap<ScreenId, WorkspaceId>,
    pub pane_screen: HashMap<PaneId, ScreenId>,
    pub tab_pane: HashMap<SurfaceId, PaneId>,
}

#[cfg(test)]
mod tests;
