//! Opaque public resource identities and protocol-v2 shared types.

use std::collections::{HashMap, VecDeque};
use std::fmt;
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

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

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub struct WireDecimal(u64);

impl WireDecimal {
    pub const fn new(value: u64) -> Self {
        Self(value)
    }

    pub const fn get(self) -> u64 {
        self.0
    }
}

impl Serialize for WireDecimal {
    fn serialize<S>(&self, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: serde::Serializer,
    {
        serializer.serialize_str(&self.0.to_string())
    }
}

impl<'de> Deserialize<'de> for WireDecimal {
    fn deserialize<D>(deserializer: D) -> Result<Self, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        let value = String::deserialize(deserializer)?;
        if value.len() > 20
            || value.starts_with('+')
            || (value.starts_with('0') && value.len() != 1)
        {
            return Err(serde::de::Error::custom("invalid unsigned decimal string"));
        }
        value
            .parse::<u64>()
            .map(Self)
            .map_err(|_| serde::de::Error::custom("invalid unsigned decimal string"))
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
    #[serde(rename = "workspace.list")]
    WorkspaceList,
    #[serde(rename = "workspace.get")]
    WorkspaceGet,
    #[serde(rename = "workspace.create")]
    WorkspaceCreate,
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
}

impl ResourceOperation {
    pub const fn wire_name(self) -> &'static str {
        match self {
            Self::MachineList => "machine.list",
            Self::MachineGet => "machine.get",
            Self::SessionList => "session.list",
            Self::SessionOpen => "session.open",
            Self::SessionGet => "session.get",
            Self::SessionSnapshot => "session.snapshot",
            Self::SessionCreationResolve => "session.creation.resolve",
            Self::SessionEvents => "session.events",
            Self::SessionJournalSubscribe => "session.journal.subscribe",
            Self::SessionJournalProducerList => "session.journal.producer.list",
            Self::SessionJournalProducerPut => "session.journal.producer.put",
            Self::SessionJournalAppend => "session.journal.append",
            Self::SessionJournalCheckpointCreate => "session.journal.checkpoint.create",
            Self::SessionJournalCheckpointList => "session.journal.checkpoint.list",
            Self::SessionJournalHookList => "session.journal.hook.list",
            Self::SessionJournalHookPut => "session.journal.hook.put",
            Self::SessionJournalRestorePreview => "session.journal.restore.preview",
            Self::SessionJournalSegmentList => "session.journal.segment.list",
            Self::SessionJournalSegmentSeal => "session.journal.segment.seal",
            Self::SessionPing => "session.ping",
            Self::SessionShutdown => "session.shutdown",
            Self::SessionReloadConfig => "session.reload_config",
            Self::SessionTerminalDefaultsUpdate => "session.terminal_defaults.update",
            Self::ClientList => "client.list",
            Self::ClientGet => "client.get",
            Self::ClientMetadataUpdate => "client.metadata.update",
            Self::ClientSizingSet => "client.sizing.set",
            Self::ClientSizingRelease => "client.sizing.release",
            Self::ClientCellPixelsSet => "client.cell_pixels.set",
            Self::ClientDetach => "client.detach",
            Self::SessionWindowTitleSet => "session.window.title.set",
            Self::SessionWindowTitleClear => "session.window.title.clear",
            Self::PairingRequestList => "pairing_request.list",
            Self::PairingRequestResolve => "pairing_request.resolve",
            Self::RequestCancel => "request.cancel",
            Self::FrontendProjectionGet => "frontend_projection.get",
            Self::FrontendProjectionPut => "frontend_projection.put",
            Self::WorkspaceList => "workspace.list",
            Self::WorkspaceGet => "workspace.get",
            Self::WorkspaceCreate => "workspace.create",
            Self::WorkspaceRename => "workspace.rename",
            Self::WorkspaceMove => "workspace.move",
            Self::WorkspaceFocus => "workspace.focus",
            Self::WorkspaceClose => "workspace.close",
            Self::WorkspaceRun => "workspace.run",
            Self::WorkspaceLayoutApply => "workspace.layout.apply",
            Self::ScreenList => "screen.list",
            Self::ScreenGet => "screen.get",
            Self::ScreenCreate => "screen.create",
            Self::ScreenRename => "screen.rename",
            Self::ScreenFocus => "screen.focus",
            Self::ScreenClose => "screen.close",
            Self::ScreenLayoutExport => "screen.layout.export",
            Self::ScreenLayoutUndo => "screen.layout.undo",
            Self::PaneList => "pane.list",
            Self::PaneGet => "pane.get",
            Self::PaneCreate => "pane.create",
            Self::PaneSplit => "pane.split",
            Self::PaneRename => "pane.rename",
            Self::PaneFocus => "pane.focus",
            Self::PaneFocusDirection => "pane.focus_direction",
            Self::PaneNeighborGet => "pane.neighbor.get",
            Self::PaneSwap => "pane.swap",
            Self::PaneZoom => "pane.zoom",
            Self::PaneSplitRatioSet => "pane.split_ratio.set",
            Self::PaneViewportWidthSet => "pane.viewport_width.set",
            Self::PaneClose => "pane.close",
            Self::PaneRun => "pane.run",
            Self::TabList => "tab.list",
            Self::TabGet => "tab.get",
            Self::TabCreateTerminal => "tab.create_terminal",
            Self::TabCreateBrowser => "tab.create_browser",
            Self::TabRename => "tab.rename",
            Self::TabMove => "tab.move",
            Self::TabFocus => "tab.focus",
            Self::TabClose => "tab.close",
            Self::TerminalList => "terminal.list",
            Self::TerminalGet => "terminal.get",
            Self::TerminalInputWrite => "terminal.input.write",
            Self::TerminalInputKeys => "terminal.input.keys",
            Self::TerminalInputMouse => "terminal.input.mouse",
            Self::TerminalInputFocus => "terminal.input.focus",
            Self::TerminalScreenRead => "terminal.screen.read",
            Self::TerminalStateRead => "terminal.state.read",
            Self::TerminalHistoryRead => "terminal.history.read",
            Self::TerminalHistoryClear => "terminal.history.clear",
            Self::TerminalOutputRead => "terminal.output_read",
            Self::TerminalWait => "terminal.wait",
            Self::TerminalWaitExit => "terminal.wait_exit",
            Self::TerminalCopy => "terminal.copy",
            Self::TerminalProcessGet => "terminal.process.get",
            Self::TerminalRendererGrantCreate => "terminal.renderer_grant.create",
            Self::TerminalViewerResize => "terminal.viewer.resize",
            Self::TerminalViewerRelease => "terminal.viewer.release",
            Self::TerminalViewportScroll => "terminal.viewport.scroll",
            Self::TerminalMove => "terminal.move",
            Self::TerminalProject => "terminal.project",
            Self::TerminalAttach => "terminal.attach",
            Self::TerminalClose => "terminal.close",
            Self::BrowserList => "browser.list",
            Self::BrowserGet => "browser.get",
            Self::BrowserNavigate => "browser.navigate",
            Self::BrowserBack => "browser.back",
            Self::BrowserForward => "browser.forward",
            Self::BrowserReload => "browser.reload",
            Self::BrowserActivate => "browser.activate",
            Self::BrowserInputKey => "browser.input.key",
            Self::BrowserInputText => "browser.input.text",
            Self::BrowserInputMouse => "browser.input.mouse",
            Self::BrowserInputWheel => "browser.input.wheel",
            Self::BrowserViewerResize => "browser.viewer.resize",
            Self::BrowserViewerRelease => "browser.viewer.release",
            Self::BrowserAttach => "browser.attach",
            Self::BrowserClose => "browser.close",
            Self::NotificationList => "notification.list",
            Self::NotificationCreate => "notification.create",
            Self::AgentList => "agent.list",
            Self::AgentReport => "agent.report",
            Self::SidebarViewGet => "sidebar_view.get",
            Self::SidebarViewEnsure => "sidebar_view.ensure",
            Self::SidebarViewAttach => "sidebar_view.attach",
            Self::SidebarViewInput => "sidebar_view.input",
            Self::SidebarViewResize => "sidebar_view.resize",
            Self::SidebarViewReload => "sidebar_view.reload",
            Self::StreamCancel => "stream.cancel",
        }
    }
}

#[cfg(test)]
mod resource_operation_wire_name_tests {
    use super::ResourceOperation;

    #[test]
    fn wire_names_match_serde_for_every_variant() {
        const NAMES: &[&str] = &[
+            "machine.list",
            "machine.get",
            "session.list",
            "session.open",
            "session.get",
            "session.snapshot",
            "session.creation.resolve",
            "session.events",
            "session.journal.subscribe",
            "session.journal.producer.list",
            "session.journal.producer.put",
            "session.journal.append",
            "session.journal.checkpoint.create",
            "session.journal.checkpoint.list",
            "session.journal.hook.list",
            "session.journal.hook.put",
            "session.journal.restore.preview",
            "session.journal.segment.list",
            "session.journal.segment.seal",
            "session.ping",
            "session.shutdown",
            "session.reload_config",
            "session.terminal_defaults.update",
            "client.list",
            "client.get",
            "client.metadata.update",
            "client.sizing.set",
            "client.sizing.release",
            "client.cell_pixels.set",
            "client.detach",
            "session.window.title.set",
            "session.window.title.clear",
            "pairing_request.list",
            "pairing_request.resolve",
            "request.cancel",
            "frontend_projection.get",
            "frontend_projection.put",
            "workspace.list",
            "workspace.get",
            "workspace.create",
            "workspace.rename",
            "workspace.move",
            "workspace.focus",
            "workspace.close",
            "workspace.run",
            "workspace.layout.apply",
            "screen.list",
            "screen.get",
            "screen.create",
            "screen.rename",
            "screen.focus",
            "screen.close",
            "screen.layout.export",
            "screen.layout.undo",
            "pane.list",
            "pane.get",
            "pane.create",
            "pane.split",
            "pane.rename",
            "pane.focus",
            "pane.focus_direction",
            "pane.neighbor.get",
            "pane.swap",
            "pane.zoom",
            "pane.split_ratio.set",
            "pane.viewport_width.set",
            "pane.close",
            "pane.run",
            "tab.list",
            "tab.get",
            "tab.create_terminal",
            "tab.create_browser",
            "tab.rename",
            "tab.move",
            "tab.focus",
            "tab.close",
            "terminal.list",
            "terminal.get",
            "terminal.input.write",
            "terminal.input.keys",
            "terminal.input.mouse",
            "terminal.input.focus",
            "terminal.screen.read",
            "terminal.state.read",
            "terminal.history.read",
            "terminal.history.clear",
            "terminal.output_read",
            "terminal.wait",
            "terminal.wait_exit",
            "terminal.copy",
            "terminal.process.get",
            "terminal.renderer_grant.create",
            "terminal.viewer.resize",
            "terminal.viewer.release",
            "terminal.viewport.scroll",
            "terminal.move",
            "terminal.project",
            "terminal.attach",
            "terminal.close",
            "browser.list",
            "browser.get",
            "browser.navigate",
            "browser.back",
            "browser.forward",
            "browser.reload",
            "browser.activate",
            "browser.input.key",
            "browser.input.text",
            "browser.input.mouse",
            "browser.input.wheel",
            "browser.viewer.resize",
            "browser.viewer.release",
            "browser.attach",
            "browser.close",
            "notification.list",
            "notification.create",
            "agent.list",
            "agent.report",
            "sidebar_view.get",
            "sidebar_view.ensure",
            "sidebar_view.attach",
            "sidebar_view.input",
            "sidebar_view.resize",
            "sidebar_view.reload",
            "stream.cancel",
        ];
        for &name in NAMES {
            let operation: ResourceOperation =
                serde_json::from_str(&format!("\"{name}\"")).expect("known operation");
            assert_eq!(operation.wire_name(), name);
            assert_eq!(serde_json::to_string(&operation).unwrap(), format!("\"{name}\""));
        }
    }
}

#[cfg(test)]
mod resource_operation_wire_name_tests {
    use super::ResourceOperation;

    #[test]
    fn wire_names_match_serde_for_every_variant() {
        const NAMES: &[&str] = &[
+            "machine.list",
            "machine.get",
            "session.list",
            "session.open",
            "session.get",
            "session.snapshot",
            "session.creation.resolve",
            "session.events",
            "session.journal.subscribe",
            "session.journal.producer.list",
            "session.journal.producer.put",
            "session.journal.append",
            "session.journal.checkpoint.create",
            "session.journal.checkpoint.list",
            "session.journal.hook.list",
            "session.journal.hook.put",
            "session.journal.restore.preview",
            "session.journal.segment.list",
            "session.journal.segment.seal",
            "session.ping",
            "session.shutdown",
            "session.reload_config",
            "session.terminal_defaults.update",
            "client.list",
            "client.get",
            "client.metadata.update",
            "client.sizing.set",
            "client.sizing.release",
            "client.cell_pixels.set",
            "client.detach",
            "session.window.title.set",
            "session.window.title.clear",
            "pairing_request.list",
            "pairing_request.resolve",
            "request.cancel",
            "frontend_projection.get",
            "frontend_projection.put",
            "workspace.list",
            "workspace.get",
            "workspace.create",
            "workspace.rename",
            "workspace.move",
            "workspace.focus",
            "workspace.close",
            "workspace.run",
            "workspace.layout.apply",
            "screen.list",
            "screen.get",
            "screen.create",
            "screen.rename",
            "screen.focus",
            "screen.close",
            "screen.layout.export",
            "screen.layout.undo",
            "pane.list",
            "pane.get",
            "pane.create",
            "pane.split",
            "pane.rename",
            "pane.focus",
            "pane.focus_direction",
            "pane.neighbor.get",
            "pane.swap",
            "pane.zoom",
            "pane.split_ratio.set",
            "pane.viewport_width.set",
            "pane.close",
            "pane.run",
            "tab.list",
            "tab.get",
            "tab.create_terminal",
            "tab.create_browser",
            "tab.rename",
            "tab.move",
            "tab.focus",
            "tab.close",
            "terminal.list",
            "terminal.get",
            "terminal.input.write",
            "terminal.input.keys",
            "terminal.input.mouse",
            "terminal.input.focus",
            "terminal.screen.read",
            "terminal.state.read",
            "terminal.history.read",
            "terminal.history.clear",
            "terminal.output_read",
            "terminal.wait",
            "terminal.wait_exit",
            "terminal.copy",
            "terminal.process.get",
            "terminal.renderer_grant.create",
            "terminal.viewer.resize",
            "terminal.viewer.release",
            "terminal.viewport.scroll",
            "terminal.move",
            "terminal.project",
            "terminal.attach",
            "terminal.close",
            "browser.list",
            "browser.get",
            "browser.navigate",
            "browser.back",
            "browser.forward",
            "browser.reload",
            "browser.activate",
            "browser.input.key",
            "browser.input.text",
            "browser.input.mouse",
            "browser.input.wheel",
            "browser.viewer.resize",
            "browser.viewer.release",
            "browser.attach",
            "browser.close",
            "notification.list",
            "notification.create",
            "agent.list",
            "agent.report",
            "sidebar_view.get",
            "sidebar_view.ensure",
            "sidebar_view.attach",
            "sidebar_view.input",
            "sidebar_view.resize",
            "sidebar_view.reload",
            "stream.cancel",
        ];
        for &name in NAMES {
            let operation: ResourceOperation =
                serde_json::from_str(&format!("\"{name}\"")).expect("known operation");
            assert_eq!(operation.wire_name(), name);
            assert_eq!(serde_json::to_string(&operation).unwrap(), format!("\"{name}\""));
        }
    }
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

fn canonical_resource_scope(kind: &str) -> &'static str {
    match kind.trim_end_matches('s') {
        "machine" | "MachinePublicId" => "machine",
        "session" | "SessionPublicId" => "session",
        "client" | "ClientPublicId" => "client",
        "workspace" | "WorkspacePublicId" | "ws" => "workspace",
        "screen" | "ScreenPublicId" => "screen",
        "pane" | "PanePublicId" => "pane",
        "split" | "SplitPublicId" => "split",
        "tab" | "TabPublicId" => "tab",
        "terminal" | "TerminalPublicId" | "term" => "terminal",
        "browser" | "BrowserPublicId" => "browser",
        "notification" | "NotificationPublicId" => "notification",
        "agent" | "AgentPublicId" => "agent",
        "frontend_projection" | "FrontendProjectionPublicId" | "projection" => {
            "frontend_projection"
        }
        "pairing_request" | "PairingRequestPublicId" | "pairing" => "pairing_request",
        "sidebar_view" | "SidebarViewPublicId" => "sidebar_view",
        "sidebar_plugin" | "SidebarPluginPublicId" => "sidebar_plugin",
        "stream" | "StreamPublicId" => "stream",
        other => panic!("unknown catalog resource scope {other:?}"),
    }
}

pub(crate) const RESOURCE_ERROR_CODES: &[&str] = &[
    "confirmation.required",
    "creation.conflict",
    "cursor.gap",
    "cursor.invalid",
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
    pub workspaces: HashMap<WorkspacePublicId, crate::WorkspaceId>,
    pub screens: HashMap<ScreenPublicId, crate::ScreenId>,
    pub panes: HashMap<PanePublicId, crate::PaneId>,
    pub tabs: HashMap<TabPublicId, crate::SurfaceId>,
    /// Every view placement of a content resource. Terminal content may have
    /// any number of placements; browser content currently has one.
    pub content_placements: HashMap<ContentPublicId, Vec<crate::SurfaceId>>,
    pub workspace_ids: HashMap<crate::WorkspaceId, WorkspacePublicId>,
    pub screen_ids: HashMap<crate::ScreenId, ScreenPublicId>,
    pub pane_ids: HashMap<crate::PaneId, PanePublicId>,
    pub tab_ids: HashMap<crate::SurfaceId, TabPublicId>,
    pub content_ids: HashMap<crate::SurfaceId, ContentPublicId>,
    pub splits: HashMap<SplitPublicId, crate::SplitId>,
    pub split_ids: HashMap<crate::SplitId, SplitPublicId>,
    pub screen_workspace: HashMap<crate::ScreenId, crate::WorkspaceId>,
    pub pane_screen: HashMap<crate::PaneId, crate::ScreenId>,
    pub tab_pane: HashMap<crate::SurfaceId, crate::PaneId>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn locally_emittable_error_codes_exactly_match_the_catalog() {
        let catalog: Value =
            serde_json::from_str(include_str!("../../../spec/resource-operations-v2.json"))
                .unwrap();
        let mut declared =
            catalog["errors"].as_object().unwrap().keys().map(String::as_str).collect::<Vec<_>>();
        let mut emitted = RESOURCE_ERROR_CODES.to_vec();
        declared.sort_unstable();
        emitted.sort_unstable();
        assert_eq!(emitted, declared);
        for code in declared {
            assert!(is_catalog_error_code(code));
        }
    }

    #[test]
    fn catalog_error_details_and_retryability_are_recursively_enforced() {
        let cursor = json!({"generation":"generation","revision":"4"});
        let cases = [
            (
                "confirmation.required",
                json!({
                    "confirmation_token":"layout-confirmation-token",
                    "revision":"4",
                    "closes_panes":[format!("pane_{}", "0".repeat(32))]
                }),
                false,
            ),
            (
                "creation.conflict",
                json!({
                    "correlation_key":"create-42",
                    "existing_operation":"workspace.create",
                    "requested_operation":"screen.create",
                    "existing_fingerprint":"fingerprint-a",
                    "requested_fingerprint":"fingerprint-b",
                }),
                false,
            ),
            (
                "cursor.gap",
                json!({
                    "requested":cursor,
                    "current":cursor,
                    "oldest_revision":"2",
                }),
                true,
            ),
            (
                "cursor.invalid",
                json!({"requested":cursor,"current":cursor,"reason":"ahead"}),
                false,
            ),
            (
                "idempotency.conflict",
                json!({"idempotency_key":"key","committed_operation":"workspace.rename"}),
                false,
            ),
            ("local.io", json!({"path":"/tmp/socket","reason":"closed"}), false),
            (
                "mutation.indeterminate",
                json!({
                    "idempotency_key":"key",
                    "operation":"browser.navigate",
                    "recovery":"inspect_state_then_retry_with_new_key",
                }),
                false,
            ),
            (
                "operation.failed",
                json!({"operation":"workspace.close","reason":"failed","extra":{"errno":5}}),
                false,
            ),
            (
                "operation.unsupported",
                json!({"capability":"session-journal-v1","action":"restart_session"}),
                false,
            ),
            (
                "resource.not_found",
                json!({"scope":"terminal","id":format!("term_{}", "0".repeat(32))}),
                false,
            ),
            ("revision.conflict", json!({"expected":"3","actual":"4"}), true),
            (
                "selector.ambiguous",
                json!({"scope":"workspace","selector":"name:api","candidates":["a","b"]}),
                false,
            ),
            (
                "selector.invalid",
                json!({"scope":"workspace","selector":"_","reason":"invalid"}),
                false,
            ),
            ("selector.not_found", json!({"scope":"workspace","selector":"name:missing"}), false),
            (
                "selector.wrong_parent",
                json!({
                    "scope":"pane",
                    "selector":"current",
                    "parent_scope":"screen",
                    "expected_parent":"screen-a",
                    "actual_parent":"screen-b",
                }),
                false,
            ),
            ("transport.closed", json!({"reason":"closed"}), true),
            ("validation.invalid", json!({"field":"rows","reason":"must be positive"}), false),
        ];
        for (code, details, retryable) in cases {
            assert!(catalog_error_contract_matches(code, &details, retryable), "{code}: {details}");
        }
        assert!(!catalog_error_contract_matches(
            "operation.failed",
            &json!({"operation":"workspace.close","required_context":"connection"}),
            false,
        ));
        assert!(!catalog_error_contract_matches(
            "transport.closed",
            &json!({"reason":"closed"}),
            false,
        ));
    }

    #[test]
    fn ids_reject_uppercase_wrong_prefix_and_wrong_width() {
        let id = WorkspacePublicId::random().unwrap();
        assert_eq!(WorkspacePublicId::parse(id.to_string()).unwrap(), id);
        assert!(WorkspacePublicId::parse(format!("ws_{}", "A".repeat(32))).is_err());
        assert!(WorkspacePublicId::parse(format!("term_{}", "a".repeat(32))).is_err());
        assert!(WorkspacePublicId::parse(format!("ws_{}", "a".repeat(31))).is_err());
    }

    #[test]
    fn projection_and_pairing_ids_use_the_canonical_prefix_registry() {
        let payload = "0".repeat(32);
        assert_eq!(
            FrontendProjectionPublicId::parse(format!("projection_{payload}")).unwrap().as_str(),
            format!("projection_{payload}")
        );
        assert!(PairingRequestPublicId::parse(format!("pairing_{payload}")).is_ok());
    }

    #[test]
    fn name_escape_selects_reserved_and_id_shaped_names() {
        assert_eq!(Selector::parse("current").unwrap(), Selector::Current);
        assert_eq!(Selector::parse("name:current").unwrap(), Selector::Name("current".into()));
        assert!(matches!(
            Selector::parse(&WorkspacePublicId::random().unwrap().to_string()).unwrap(),
            Selector::Id(_)
        ));
        assert_eq!(
            Selector::parse(&format!("name:ws_{}", "a".repeat(32))).unwrap(),
            Selector::Name(format!("ws_{}", "a".repeat(32)))
        );
        assert_eq!(
            Selector::parse("name:hello_world").unwrap(),
            Selector::Name("hello_world".into())
        );
        assert_eq!(Selector::parse("hello_world").unwrap_err().code, "validation.invalid");
        for reserved in ["create", "show", "close", "screen", "pane", "tab"] {
            assert_eq!(Selector::parse(reserved).unwrap_err().code, "validation.invalid");
            assert_eq!(
                Selector::parse(&format!("name:{reserved}")).unwrap(),
                Selector::Name(reserved.into())
            );
        }
        for legacy in ["send-key", "clear-history", "vt-state", "focus-direction"] {
            assert_eq!(Selector::parse(legacy).unwrap(), Selector::Name(legacy.into()));
        }
    }

    #[test]
    fn terminal_public_identity_is_independent_from_host_uuid_bits() {
        let terminal = TerminalPublicId::parse("term_ffffffffffffffffffffffffffffffff").unwrap();
        let tab = TabPublicId::parse("tab_00000000000000000000000000000001").unwrap();
        let identity = TabResourceIdentity::persisted_terminal(tab, terminal.clone());
        assert_eq!(identity.content_id, ContentPublicId::Terminal(terminal));
    }

    #[test]
    fn duplicate_names_return_every_candidate_without_selecting() {
        let result = resolve_name(
            "workspace",
            "api",
            [("ws_1".into(), Some("api".into()), 1), ("ws_2".into(), Some("api".into()), 2)],
        )
        .unwrap_err();
        assert_eq!(result.code, "selector.ambiguous");
        assert_eq!(result.details["candidates"], json!(["ws_1", "ws_2"]));
    }

    #[test]
    fn journal_revision_is_per_atomic_commit_and_detects_gaps() {
        let mut journal = ResourceJournal::new("generation".into(), 8);
        assert_eq!(
            journal
                .commit(vec![
                    ("pane.created".into(), json!({"id":"pane"})),
                    ("tab.created".into(), json!({"id":"tab"})),
                ])
                .unwrap(),
            9
        );
        let batches = journal.after(8).unwrap();
        assert_eq!(batches.len(), 1);
        assert_eq!(batches[0].previous_revision.get(), 8);
        assert_eq!(batches[0].revision.get(), 9);
        assert_eq!(batches[0].deltas[0].sequence, 0);
        assert_eq!(batches[0].deltas[1].sequence, 1);
    }

    #[test]
    fn wire_decimals_are_strings_and_reject_noncanonical_values() {
        assert_eq!(serde_json::to_value(WireDecimal::new(42)).unwrap(), json!("42"));
        assert_eq!(serde_json::from_value::<WireDecimal>(json!("0")).unwrap().get(), 0);
        for invalid in
            [json!(42), json!(""), json!("01"), json!("-1"), json!("18446744073709551616")]
        {
            assert!(serde_json::from_value::<WireDecimal>(invalid).is_err());
        }
    }

    #[test]
    fn terminal_multiview_uses_a_new_public_protocol_version() {
        assert_eq!(PROTOCOL, "cmux.protocol/2");
    }

    #[test]
    fn requests_enforce_envelope_and_idempotency_rules() {
        let read: RequestEnvelope = serde_json::from_value(json!({
            "protocol": PROTOCOL,
            "type": "request",
            "id": "read-1",
            "operation": "workspace.list",
            "params": {}
        }))
        .unwrap();
        read.validate().unwrap();

        let mutation: RequestEnvelope = serde_json::from_value(json!({
            "protocol": PROTOCOL,
            "type": "request",
            "id": "write-1",
            "operation": "workspace.create",
            "params": {"name":"api"},
            "idempotency_key": "create-api"
        }))
        .unwrap();
        mutation.validate().unwrap();

        let mut missing_key = mutation;
        missing_key.idempotency_key = None;
        assert_eq!(missing_key.validate().unwrap_err().code, "validation.invalid");

        let mut read_with_key = read;
        read_with_key.idempotency_key = Some("unexpected".into());
        assert_eq!(read_with_key.validate().unwrap_err().code, "validation.invalid");

        for invalid in [
            "".to_string(),
            " \u{00a0}\u{3000}".to_string(),
            "key\nwith-control".to_string(),
            "key\u{0085}with-control".to_string(),
            "\u{00e9}".repeat(65),
        ] {
            let invalid_request: RequestEnvelope = serde_json::from_value(json!({
                "protocol": PROTOCOL,
                "type": "request",
                "id": "write-invalid",
                "operation": "workspace.create",
                "params": {"name":"api"},
                "idempotency_key": invalid,
            }))
            .unwrap();
            let error = invalid_request.validate().unwrap_err();
            assert_eq!(error.code, "validation.invalid");
            assert_eq!(error.details["field"], "idempotency_key");
        }

        for valid in [
            "key".to_string(),
            " \u{00a0}key\u{3000} ".to_string(),
            "\u{feff}".to_string(),
            "\u{00e9}".repeat(64),
        ] {
            let request: RequestEnvelope = serde_json::from_value(json!({
                "protocol": PROTOCOL,
                "type": "request",
                "id": "write-valid",
                "operation": "workspace.create",
                "params": {"name":"api"},
                "idempotency_key": valid,
            }))
            .unwrap();
            request.validate().unwrap();
        }
    }

    #[test]
    fn operation_classes_keep_stream_and_connection_control_out_of_durable_idempotency() {
        for operation in [
            ResourceOperation::SessionEvents,
            ResourceOperation::SessionJournalSubscribe,
            ResourceOperation::TerminalAttach,
            ResourceOperation::BrowserAttach,
            ResourceOperation::SidebarViewAttach,
        ] {
            assert_eq!(operation.class(), OperationClass::StreamOpen);
        }
        assert_eq!(ResourceOperation::RequestCancel.class(), OperationClass::ConnectionControl);
        assert_eq!(ResourceOperation::StreamCancel.class(), OperationClass::ConnectionControl);
        let connection_control = [
            ResourceOperation::ClientMetadataUpdate,
            ResourceOperation::ClientSizingSet,
            ResourceOperation::ClientSizingRelease,
            ResourceOperation::ClientCellPixelsSet,
            ResourceOperation::ClientDetach,
            ResourceOperation::TerminalRendererGrantCreate,
            ResourceOperation::TerminalViewerResize,
            ResourceOperation::TerminalViewerRelease,
            ResourceOperation::BrowserViewerResize,
            ResourceOperation::BrowserViewerRelease,
        ];
        for operation in connection_control {
            assert_eq!(operation.class(), OperationClass::ConnectionControl);
        }
        assert_eq!(ResourceOperation::WorkspaceList.class(), OperationClass::Read);
        assert_eq!(ResourceOperation::WorkspaceCreate.class(), OperationClass::Mutation);
        assert_eq!(ResourceOperation::TabCreateTerminal.class(), OperationClass::Mutation);
        assert_eq!(ResourceOperation::TabCreateBrowser.class(), OperationClass::Mutation);
        assert_eq!(ResourceOperation::TerminalCopy.class(), OperationClass::Read);
        assert_eq!(LocalOperation::SidebarPluginUseBuiltin.class(), OperationClass::Local);

        for operation in [
            ResourceOperation::SessionEvents,
            ResourceOperation::SessionJournalSubscribe,
            ResourceOperation::RequestCancel,
            ResourceOperation::StreamCancel,
            ResourceOperation::ClientMetadataUpdate,
            ResourceOperation::ClientDetach,
        ] {
            let request = RequestEnvelope {
                protocol: PROTOCOL.into(),
                envelope_type: EnvelopeType::Request,
                id: RequestId::parse("class").unwrap(),
                operation,
                params: json!({}),
                idempotency_key: None,
            };
            request.validate().unwrap();
            let mut keyed = request;
            keyed.idempotency_key = Some("forbidden".into());
            assert_eq!(keyed.validate().unwrap_err().code, "validation.invalid");
        }
    }

    #[test]
    fn envelopes_reject_unknown_fields_and_non_string_request_ids() {
        assert!(
            serde_json::from_value::<RequestEnvelope>(json!({
                "protocol": PROTOCOL,
                "type": "request",
                "id": "request",
                "operation": "workspace.list",
                "params": {},
                "extra": true
            }))
            .is_err()
        );
        assert!(
            serde_json::from_value::<RequestEnvelope>(json!({
                "protocol": PROTOCOL,
                "type": "request",
                "id": 1,
                "operation": "workspace.list",
                "params": {}
            }))
            .is_err()
        );
    }

    #[test]
    fn response_invariant_is_checked() {
        ResponseEnvelope::success(RequestId::parse("ok").unwrap(), json!({"value":1}))
            .validate()
            .unwrap();
        ResponseEnvelope::failure(
            RequestId::parse("error").unwrap(),
            ResourceError::not_found("workspace", "missing"),
        )
        .validate()
        .unwrap();

        let invalid = ResponseEnvelope {
            protocol: PROTOCOL.into(),
            envelope_type: EnvelopeType::Response,
            id: RequestId::parse("invalid").unwrap(),
            ok: true,
            result: None,
            error: None,
        };
        assert_eq!(invalid.validate().unwrap_err().code, "validation.invalid");
    }

    #[test]
    fn oversized_journal_commit_does_not_advance_revision() {
        let mut journal = ResourceJournal::new("generation".into(), 4);
        journal.byte_capacity = 32;
        assert!(journal.commit(vec![("event".into(), json!({"large":"x".repeat(128)}))]).is_err());
        assert_eq!(journal.revision(), 4);
        assert!(journal.after(4).unwrap().is_empty());
    }
}
