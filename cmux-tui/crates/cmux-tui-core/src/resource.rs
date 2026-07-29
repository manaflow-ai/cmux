//! Opaque public resource identities and protocol-v1 shared types.

use std::collections::{HashMap, VecDeque};
use std::fmt;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

pub const PROTOCOL: &str = "cmux.protocol/1";
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
            return Err(ResourceError::new(
                "request.invalid_id",
                "request id must contain 1 to 128 UTF-8 bytes",
                json!({"length":value.len()}),
                false,
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
    #[serde(rename = "machine.create")]
    MachineCreate,
    #[serde(rename = "machine.rename")]
    MachineRename,
    #[serde(rename = "machine.delete")]
    MachineDelete,
    #[serde(rename = "machine.restore")]
    MachineRestore,
    #[serde(rename = "machine.purge")]
    MachinePurge,
    #[serde(rename = "machine.connect_external")]
    MachineConnectExternal,
    #[serde(rename = "session.list")]
    SessionList,
    #[serde(rename = "session.open")]
    SessionOpen,
    #[serde(rename = "session.get")]
    SessionGet,
    #[serde(rename = "session.snapshot")]
    SessionSnapshot,
    #[serde(rename = "session.events")]
    SessionEvents,
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
    #[serde(rename = "client.update")]
    ClientUpdate,
    #[serde(rename = "client.detach")]
    ClientDetach,
    #[serde(rename = "window.title.set")]
    WindowTitleSet,
    #[serde(rename = "window.title.clear")]
    WindowTitleClear,
    #[serde(rename = "pairing_request.list")]
    PairingRequestList,
    #[serde(rename = "pairing_request.resolve")]
    PairingRequestResolve,
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
    #[serde(rename = "terminal.create")]
    TerminalCreate,
    #[serde(rename = "terminal.run")]
    TerminalRun,
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
    #[serde(rename = "terminal.history.read")]
    TerminalHistoryRead,
    #[serde(rename = "terminal.history.clear")]
    TerminalHistoryClear,
    #[serde(rename = "terminal.wait")]
    TerminalWait,
    #[serde(rename = "terminal.copy")]
    TerminalCopy,
    #[serde(rename = "terminal.process.get")]
    TerminalProcessGet,
    #[serde(rename = "terminal.viewer_sizing.update")]
    TerminalViewerSizingUpdate,
    #[serde(rename = "terminal.viewer.resize")]
    TerminalViewerResize,
    #[serde(rename = "terminal.viewer.release")]
    TerminalViewerRelease,
    #[serde(rename = "terminal.viewport.scroll")]
    TerminalViewportScroll,
    #[serde(rename = "terminal.move")]
    TerminalMove,
    #[serde(rename = "terminal.attach")]
    TerminalAttach,
    #[serde(rename = "terminal.close")]
    TerminalClose,
    #[serde(rename = "browser.list")]
    BrowserList,
    #[serde(rename = "browser.get")]
    BrowserGet,
    #[serde(rename = "browser.create")]
    BrowserCreate,
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
    #[serde(rename = "provider_scope.list")]
    ProviderScopeList,
    #[serde(rename = "provider_action.invoke")]
    ProviderActionInvoke,
    #[serde(rename = "provider_notice.events")]
    ProviderNoticeEvents,
    #[serde(rename = "provider_authority.install")]
    ProviderAuthorityInstall,
    #[serde(rename = "stream.cancel")]
    StreamCancel,
}

impl ResourceOperation {
    pub fn is_mutation(self) -> bool {
        !matches!(
            self,
            Self::MachineList
                | Self::MachineGet
                | Self::SessionList
                | Self::SessionGet
                | Self::SessionSnapshot
                | Self::SessionEvents
                | Self::SessionPing
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
                | Self::TerminalHistoryRead
                | Self::TerminalWait
                | Self::TerminalProcessGet
                | Self::BrowserList
                | Self::BrowserGet
                | Self::NotificationList
                | Self::AgentList
                | Self::SidebarViewGet
                | Self::ProviderScopeList
                | Self::ProviderNoticeEvents
        )
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
            return Err(ResourceError::new(
                "protocol.invalid_envelope",
                "expected a cmux.protocol/1 request envelope",
                json!({"protocol":self.protocol,"type":self.envelope_type}),
                false,
            ));
        }
        if !self.params.is_object() {
            return Err(ResourceError::new(
                "request.invalid_params",
                "request params must be an object",
                json!({}),
                false,
            ));
        }
        match (&self.idempotency_key, self.operation.is_mutation()) {
            (None, true) => Err(ResourceError::new(
                "idempotency.required",
                "mutations require idempotency_key",
                json!({}),
                false,
            )),
            (Some(_), false) => Err(ResourceError::new(
                "idempotency.read_forbidden",
                "reads must omit idempotency_key",
                json!({}),
                false,
            )),
            (Some(key), true) if key.is_empty() || key.len() > 128 => Err(ResourceError::new(
                "idempotency.invalid",
                "idempotency_key must contain 1 to 128 UTF-8 bytes",
                json!({"length":key.len()}),
                false,
            )),
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
            return Err(ResourceError::new(
                "protocol.invalid_envelope",
                "expected a cmux.protocol/1 response envelope",
                json!({"protocol":self.protocol,"type":self.envelope_type}),
                false,
            ));
        }
        match (self.ok, self.result.is_some(), self.error.is_some()) {
            (true, true, false) | (false, false, true) => Ok(()),
            _ => Err(ResourceError::new(
                "protocol.invalid_response",
                "response must contain exactly one matching result or error",
                json!({"ok":self.ok}),
                false,
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

            pub fn random() -> anyhow::Result<Self> {
                let mut bytes = [0u8; 16];
                getrandom::fill(&mut bytes)
                    .map_err(|_| anyhow::anyhow!("could not allocate {} identity", $prefix))?;
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
public_id!(ProjectionPublicId, "projection");
public_id!(PairingRequestPublicId, "pairing");
public_id!(SidebarViewPublicId, "sidebar_view");
public_id!(SidebarPluginPublicId, "sidebar_plugin");

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
        Self { code: code.into(), message: message.into(), details, retryable }
    }

    fn invalid_id(kind: &str, value: &str) -> Self {
        Self::new(
            "selector.invalid",
            format!("invalid {kind} {value:?}"),
            json!({"kind":kind,"selector":value}),
            false,
        )
    }

    pub fn not_found(kind: &str, selector: &str) -> Self {
        Self::new(
            "selector.not_found",
            format!("no {kind} matches {selector:?}"),
            json!({"kind":kind,"selector":selector}),
            false,
        )
    }

    pub fn ambiguous(kind: &str, selector: &str, candidates: Vec<String>) -> Self {
        Self::new(
            "selector.ambiguous",
            format!("more than one {kind} is named {selector:?}"),
            json!({"kind":kind,"selector":selector,"candidates":candidates}),
            false,
        )
    }
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
        if value.contains('_') {
            return Err(ResourceError::new(
                "selector.escape_required",
                "names containing '_' must use the name: prefix",
                json!({"selector":value,"escaped":format!("name:{value}")}),
                false,
            ));
        }
        Ok(Self::Name(value.to_string()))
    }
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
                "stream.cursor_ahead",
                "resume cursor is ahead of the session revision",
                json!({"cursor":revision,"revision":self.revision,"generation":self.generation}),
                false,
            ));
        }
        let oldest = self.batches.front().map_or(self.revision, |(batch, _)| batch.revision.get());
        if revision.saturating_add(1) < oldest {
            return Err(ResourceError::new(
                "stream.gap",
                "resume cursor is no longer retained",
                json!({
                    "cursor":revision,
                    "oldest_revision":oldest,
                    "revision":self.revision,
                    "generation":self.generation
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

#[derive(Debug, Default)]
pub struct PublicSlotIndexes {
    pub workspaces: HashMap<WorkspacePublicId, crate::WorkspaceId>,
    pub screens: HashMap<ScreenPublicId, crate::ScreenId>,
    pub panes: HashMap<PanePublicId, crate::PaneId>,
    pub tabs: HashMap<TabPublicId, crate::SurfaceId>,
    pub content: HashMap<ContentPublicId, crate::SurfaceId>,
    pub workspace_ids: HashMap<crate::WorkspaceId, WorkspacePublicId>,
    pub screen_ids: HashMap<crate::ScreenId, ScreenPublicId>,
    pub pane_ids: HashMap<crate::PaneId, PanePublicId>,
    pub tab_ids: HashMap<crate::SurfaceId, TabPublicId>,
    pub content_ids: HashMap<crate::SurfaceId, ContentPublicId>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ids_reject_uppercase_wrong_prefix_and_wrong_width() {
        let id = WorkspacePublicId::random().unwrap();
        assert_eq!(WorkspacePublicId::parse(id.to_string()).unwrap(), id);
        assert!(WorkspacePublicId::parse(format!("ws_{}", "A".repeat(32))).is_err());
        assert!(WorkspacePublicId::parse(format!("term_{}", "a".repeat(32))).is_err());
        assert!(WorkspacePublicId::parse(format!("ws_{}", "a".repeat(31))).is_err());
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
        assert_eq!(Selector::parse("hello_world").unwrap_err().code, "selector.escape_required");
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

        let mut missing_key = mutation.clone();
        missing_key.idempotency_key = None;
        assert_eq!(missing_key.validate().unwrap_err().code, "idempotency.required");

        let mut read_with_key = read;
        read_with_key.idempotency_key = Some("unexpected".into());
        assert_eq!(read_with_key.validate().unwrap_err().code, "idempotency.read_forbidden");
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
        assert_eq!(invalid.validate().unwrap_err().code, "protocol.invalid_response");
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
