//! Opaque public resource identities and protocol-v2 shared types.

use std::collections::HashMap;
use std::fmt;
use std::sync::OnceLock;

use crate::{PaneId, ScreenId, SplitId, SurfaceId, WorkspaceId};
use scope::canonical_resource_scope;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

mod error;
pub use error::*;

pub const PROTOCOL: &str = "cmux.protocol/2";
pub const MAX_MESSAGE_BYTES: usize = 4 * 1024 * 1024;
pub const STREAM_EVENT_CAPACITY: usize = 256;
pub const STREAM_BYTE_CAPACITY: usize = 16 * 1024 * 1024;
pub const JOURNAL_CAPACITY: usize = 4096;
pub const JOURNAL_BYTE_CAPACITY: usize = 16 * 1024 * 1024;
pub const MAX_IDEMPOTENCY_KEY_BYTES: usize = 128;

pub fn validate_idempotency_key(value: &str) -> Result<(), ResourceError> {
    if value.trim().is_empty() {
        return Err(ResourceError::validation_invalid(
            Some("idempotency_key"),
            "idempotency_key must contain at least one non-whitespace Unicode scalar",
        ));
    }
    if value.len() > MAX_IDEMPOTENCY_KEY_BYTES {
        return Err(ResourceError::validation_invalid(
            Some("idempotency_key"),
            "idempotency_key must contain 1 to 128 UTF-8 bytes",
        ));
    }
    if value.chars().any(char::is_control) {
        return Err(ResourceError::validation_invalid(
            Some("idempotency_key"),
            "idempotency_key must not contain Unicode control characters",
        ));
    }
    Ok(())
}

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
    #[serde(rename = "conversation.list")]
    ConversationList,
    #[serde(rename = "conversation.get")]
    ConversationGet,
    #[serde(rename = "conversation.history")]
    ConversationHistory,
    #[serde(rename = "conversation.search")]
    ConversationSearch,
    #[serde(rename = "conversation.send")]
    ConversationSend,
    #[serde(rename = "conversation.typing")]
    ConversationTyping,
    #[serde(rename = "conversation.draft")]
    ConversationDraft,
    #[serde(rename = "conversation.events")]
    ConversationEvents,
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
    #[serde(rename = "origin.confirmation.issue")]
    OriginConfirmationIssue,
    #[serde(rename = "closed.list")]
    ClosedList,
    #[serde(rename = "closed.reopen")]
    ClosedReopen,
    #[serde(rename = "window_record.list")]
    WindowRecordList,
    #[serde(rename = "window_record.put")]
    WindowRecordPut,
    #[serde(rename = "window_record.delete")]
    WindowRecordDelete,
    #[serde(rename = "sidebar_layout.get")]
    SidebarLayoutGet,
    #[serde(rename = "sidebar_layout.update")]
    SidebarLayoutUpdate,
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
    #[serde(rename = "workspace.agent_folder.set")]
    WorkspaceAgentFolderSet,
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
                | Self::ConversationEvents
                | Self::TerminalAttach
                | Self::BrowserAttach
                | Self::SidebarViewAttach
        ) {
            OperationClass::StreamOpen
        } else if matches!(
            self,
            Self::RequestCancel
                | Self::StreamCancel
                | Self::OriginConfirmationIssue
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
                | Self::ConversationList
                | Self::ConversationGet
                | Self::ConversationHistory
                | Self::ConversationSearch
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
                | Self::SidebarLayoutGet
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

mod envelope;
mod journal;
#[cfg(test)]
#[path = "resource/wire_name_tests.rs"]
mod resource_operation_wire_name_tests;
mod scope;
mod wire_decimal;
mod wire_name;

pub use envelope::{RequestEnvelope, ResponseEnvelope};
pub use journal::{ResourceDelta, ResourceDeltaBatch, ResourceJournal};
pub use wire_decimal::WireDecimal;

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

/// A noun-first CLI token: a resource may keep the name; callers select it with `name:`.
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
